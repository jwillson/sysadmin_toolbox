# NFS over RDMA migration runbook

Nov 4, 2026 · @Jason Willson

## Overview

This runbook moves an InfiniBand-attached NAS and its clients from NFS over TCP/IPoIB to native NFS over RDMA. It applies to any NAS on EL7–EL10 or Ubuntu Server 24.04/26.04 with a ConnectX-3 or newer HCA, on ZFS or any other local filesystem. The exports, storage and fabric stay as they are, and four things change:

| Item | Typical now | Target |
| --- | --- | --- |
| IB partition MTU (set by the subnet manager) | 2048 | 4096 |
| IPoIB mode / MTU | datagram / 2044 | datagram / 4092 (recommended), or connected / 65520 |
| nfsd threads | 8 (distribution default) | max(64, logical CPUs rounded up to a multiple of 16), validated by measurement |
| Server listeners | tcp 2049 | rdma 20049 + tcp 2049 (TCP kept as fallback) |
| Client mounts | proto=tcp, vers=4.2 | proto=rdma,port=20049, vers=4.2 |

Each NAS is different, so start every host with the preflight (Phase 3, step 0). It discovers the distribution, platform, CPU, storage behind the exports, HCA model, driver and PCIe slot, and the tool that configures IPoIB. From those it reports that host's current values and prints its own command list. The same capture script runs before and after, so the report compares like with like.

Three points shape the plan:

- **The ports are usually already in InfiniBand mode.** IPoIB only runs on the IB link layer, so if IPoIB works, RDMA is available; NFS just isn't using it. The real change is the NFS transport.
- **There are two MTUs.** The IB MTU that matters here comes from the subnet manager's partition (4096 max on FDR and EDR). Each port also reports its own `active_mtu`, which can already read 4096 while the partition is still 2048. The IPoIB MTU is the IP-layer value: IB MTU − 4 in datagram mode (2044 at 2048, 4092 at 4096), up to 65520 in connected mode. So IPoIB at 2044 in datagram mode means the partition is 2048, whatever `active_mtu` says.
- **With proto=rdma, NFS data does not cross IPoIB.** IPoIB is used only to resolve the server's address; reads and writes move over RDMA connections. IPoIB MTU and mode therefore matter for the TCP baseline, fallback and other IP traffic, while the IB MTU matters for RDMA.

Only the IB MTU change, and the IPoIB MTU that follows it, needs a cluster-wide maintenance window. More nfsd threads, the RDMA listener, the `insecure` export option and a pilot client can all be done live beforehand. Turning on NFSv4.2 on a server that has it disabled needs an nfsd restart, so it also goes in the window.

## Platform differences

The commands below show the EL8/EL9 form first. This table lists what differs elsewhere; the preflight detects the host and prints the right form.

| | EL7 | EL8 | EL9 | EL10 | Ubuntu 24.04 / 26.04 |
| --- | --- | --- | --- | --- | --- |
| Install with | `yum` | `dnf` | `dnf` | `dnf` | `apt-get` |
| NFS server package | nfs-utils | nfs-utils | nfs-utils | nfs-utils | nfs-kernel-server |
| ibverbs tools package | libibverbs-utils | libibverbs-utils | libibverbs-utils | libibverbs-utils | ibverbs-utils |
| nfsd settings | `/etc/sysconfig/nfs`: `RPCNFSDCOUNT=`, `RPCNFSDARGS="--rdma=20049"` | `/etc/nfs.conf` `[nfsd]` | `/etc/nfs.conf`; `/etc/nfs.conf.d/*.conf` overrides it | as EL9 | as EL9 (upgrades from 20.04 may have `nfs.conf.d/local.conf`) |
| Load svcrdma at boot | `SVCRDMA_LOAD=yes` in `/etc/rdma/rdma.conf` | `/etc/modules-load.d/nfs-rdma.conf` | same | same | same |
| NFS/RDMA kernel module | in the kernel | in the kernel | in the kernel | in the kernel | may need `linux-modules-extra-$(uname -r)` |
| IPoIB configured by | NetworkManager or ifcfg | NetworkManager or ifcfg | NetworkManager | NetworkManager (ifcfg removed) | netplan |
| Firewall | firewalld | firewalld | firewalld | firewalld | ufw, often inactive |
| ConnectX-3 (mlx4) | supported | supported | supported | **removed** | supported |
| Default boot kernel | `grubby --default-kernel` | same | same | same | `/boot/vmlinuz` link, `GRUB_DEFAULT` |

NFSv4.2: every client mounts `vers=4.2`, so the server must offer it. EL8 and later and Ubuntu enable it by default. Check `/proc/fs/nfsd/versions` on EL7; if it shows `-4.2`, add `-V 4.2` to `RPCNFSDARGS`. The preflight fails the check and plans the fix whenever 4.2 is missing.

## Hardware notes

- **HCA driver.** ConnectX-4 and newer use mlx5, which runs Enhanced IPoIB: datagram mode only, unless the driver exposes `ipoib_enhanced`. ConnectX-3 uses mlx4, which has no Enhanced IPoIB and supports connected mode directly. EL10 dropped mlx4, so a ConnectX-3 host there has no driver at all; keep it on EL9 or older, or replace the card.
- **PCIe slot.** RDMA moves data at close to wire speed, so the slot can become the limit. PCIe 3.0 x16 carries about 126 Gb/s and x8 about 63 Gb/s. An EDR (100 Gb/s) card in an x8 slot, or a card that negotiated fewer lanes than it supports, tops out well below line rate. The preflight compares the negotiated PCIe link with the IB rate and warns. On servers with several riser options, check which slots are x16.
- **NUMA.** The preflight shows which NUMA node the HCA hangs off. On dual-socket hosts the per-node nfsd pools (below) keep threads near their memory.
- **Storage.** On ZFS, the preflight checks pool health, ZFS modules for the boot kernel, and `sharenfs` options. On other filesystems it checks md arrays and, when `perccli`/`storcli` is installed, PERC/MegaRAID virtual drives. Capture uses `zpool iostat` on ZFS servers and `iostat -x` otherwise.

## Tools

Every metric comes from standard distribution packages; the scripts in this directory drive them and build the report.

| Tool | Package | Runs on | What it measures |
| --- | --- | --- | --- |
| `fio` (libaio, O\_DIRECT) | fio | clients | NFS IOPS, bandwidth, mean and p99 latency |
| `/proc/self/mountstats` | kernel | clients | per-RPC round-trip time for READ/WRITE |
| `mpstat`, `iostat` | sysstat | server + clients | CPU busy % and kernel share; disk I/O on non-ZFS servers |
| `/proc/fs/nfsd/pool_stats` | kernel | server | arrivals that found no idle nfsd thread: (packets-arrived − threads-woken) / packets-arrived |
| `zpool iostat` | zfs | ZFS servers | pool bandwidth/IOPS during each test |
| `iperf3` | iperf3 | client → server | IPoIB TCP throughput |
| `ib_write_bw`, `ib_read_bw`, `ib_read_lat` | perftest | client → server | raw RDMA ceiling of the fabric |
| `ibstat`, `ibv_devinfo` | infiniband-diags, (lib)ibverbs-utils | both | link layer, rate, active MTU |
| `nfsstat` | nfs-utils / nfs-common | both | op mix, server counters, client mount options |

Install on the server and on the test clients:

```bash
dnf install -y fio sysstat iperf3 perftest infiniband-diags libibverbs-utils rdma-core nfs-utils     # EL8-EL10; yum on EL7
apt-get install -y fio sysstat iperf3 perftest infiniband-diags ibverbs-utils rdma-core nfs-common  # Ubuntu (server: nfs-kernel-server)
```

The scripts:

- **`nfs-rdma-preflight.sh`** runs on the NAS and changes nothing. It discovers the host, checks every precondition, works out that host's values (thread count, IPoIB MTU, the exact NFS config edit) and prints the commands, split into what can be done live and what needs the window.
- **`nfsbench.sh`** runs on a client. `run <label> <mount>` snapshots client and server config, runs the fabric tests, then a 7-test fio suite while sampling server and client CPU, nfsd thread pressure, storage I/O and RPC times. Results land in `results/<label>/`. `./nfsbench.sh check` lists missing tools and the install command for that host.
- **`nfs_report.py`** reads one or more result directories and writes a self-contained HTML report plus a Markdown copy, with a % change column against the first run. It needs only Python 3.6+, which every supported release has.

Server-side capture uses passwordless root ssh from the test client to the NAS (`SERVER_SSH`). Without it the fio numbers are still captured, but the server CPU, nfsd and storage columns stay empty. The scripts find the RDMA device and IPoIB interface on each host themselves; set `IBDEV`/`IPOIB_IF` (and `SRV_IBDEV`/`SRV_IPOIB_IF` for the server) only to pick a different one. iperf3 before 3.16 is single-threaded, so its 8 streams share one core; treat that number as a lower bound.

## Phase 1 — Capture the baseline

One `run` takes about 15 minutes and records config, fabric ceiling and seven fio tests. Do it while the NAS is quiet, then repeat it unchanged after the migration.

### Quiet periods to ask for

The captures need the NAS under test quiet, not the whole cluster. Other users' I/O mixes into the numbers, so before and after stop being comparable. The benchmark also pushes the NAS to its limits, so anyone using it during a run sees slow I/O. Ask the cluster owner for two quiet periods:

| Period | Length | What's needed |
| --- | --- | --- |
| Baseline (Phase 1) | about 2 h; more with `baseline-cold` | no other jobs using this NAS; the test nodes (e.g. node01–08) reserved, such as with a Slurm reservation |
| Migration window, then the after capture (Phases 3–4) | the window, then about 2 h | cluster drained for the window; kept off this NAS for the after capture |

The 2 hours covers two single-client runs, two multi-client runs and setup. Jobs that use other storage, or only compute, can keep running. Run the after capture straight after the window, while the cluster is still drained, so the client only arranges two interruptions.

No quiet period is needed for the preflight or the live steps (4–5 and the pilot client). The preflight should run under normal load, because it samples nfsd thread pressure from real traffic.

### On a Slurm cluster

Each quiet period is a maintenance reservation. Compare `nfs-clients.txt` with `sinfo -N`: if every compute node mounts this NAS, a quiet NAS means no jobs anywhere, so reserve all nodes. Otherwise reserve the nodes that mount it, plus the test nodes. Create the reservation at least one maximum job time limit ahead (`sinfo -o '%P %l'`); Slurm then starts no job that would run into it.

```bash
scontrol create reservation reservationname=nfs-bench starttime=2026-11-20T08:00:00 duration=02:00:00 \
    nodes=ALL users=root flags=maint,ignore_jobs
scontrol show reservation nfs-bench
squeue -t R -h | wc -l                                     # 0 once it starts; jobs already running past the start keep running
scontrol delete reservationname=nfs-bench                  # when done
```

A reservation doesn't cover login nodes, where users can still touch the NAS. Announce each quiet period to users as well.

### Ground rules

So before and after are comparable:

- Before each run, check the NAS is idle: `zpool iostat 1` on ZFS, `iostat -x 1` otherwise, and `cat /proc/fs/nfsd/pool_stats` twice, 10 s apart, where packets-arrived should barely move. Idle autofs mounts stay connected, so a client in `nfs-clients.txt` isn't necessarily active.
- Keep the same clients, export, NFS version and rsize/wsize for every run. Note the current options with `nfsstat -m`.
- Write results to local disk on the client (`RESULTS=/root/nfsbench/results`), not to the NFS share.
- Run each capture twice. More than \~5% difference between the two means the cluster wasn't quiet.

What the defaults measure: fio uses O\_DIRECT, so the client page cache is bypassed. The write tests lay files down first, and 4–8 jobs × 8 GiB fit in the server's cache (the ARC on ZFS, the page cache otherwise), so reads are served from server RAM. That isolates the transport, which is exactly what this migration changes. For a disk-bound view, add a second capture with total data above 2× server RAM (the report shows RAM and, on ZFS, ARC max), e.g. `SIZE=96G` with label `baseline-cold`.

Single client, from one compute node:

```bash
mkdir -p /root/nfsbench && cd /root/nfsbench      # copy nfsbench.sh and nfs_report.py here
export SERVER_SSH=root@nas01 SERVER_IB_IP=10.10.0.1 RESULTS=/root/nfsbench/results
./nfsbench.sh check
./nfsbench.sh run baseline /mnt/scratch
```

Replace `nas01`, `10.10.0.1` (the server's IPoIB address) and `/mnt/scratch` with yours. On a ZFS server, `ZPOOL=<pool>` limits `zpool iostat` to one pool.

Aggregate load from several clients (one TCP client rarely fills 100 Gb/s, so this shows the server's limit). Start all clients together; only node01 samples the server:

```bash
# on node01
pdsh -w node[02-08] 'cd /root/nfsbench && RESULTS=/root/nfsbench/results ./nfsbench.sh fio baseline-8n /mnt/scratch' &
./nfsbench.sh fio baseline-8n /mnt/scratch
wait
# collect every node's results into one directory
for n in node0{2..8}; do rsync -a $n:/root/nfsbench/results/baseline-8n/ results/baseline-8n/; done
```

Per test, `results/<label>/` holds the fio JSON, client and server `mpstat`, `pool_stats` and `mountstats` snapshots taken before and after, and the server's `storage_iostat` output. The fio test files stay in `<mount>/nfsbench.<host>/` so the after-run reuses the same layout; delete them when you're done.

## Phase 2 — Build the report

One command turns result directories into `nfs-report.html` (self-contained, opens in any browser, safe to email) and `nfs-report.md`:

```bash
python3 nfs_report.py results/baseline -o nfs-report.html
```

The report has a one-line-per-test summary, a configuration table, the fabric ceiling, and a section per fio test. The configuration table covers OS, platform, CPU, exported filesystems, ARC (ZFS only), nfsd threads and listeners, HCA, driver, PCIe link, IB rate and MTU, IPoIB mode, mount options and the actual transport. Each test shows bandwidth, IOPS, mean and p99 latency, NFS RPC round-trip, server and client CPU, and nfsd thread pressure. Later you pass more directories; the first is the reference and every other run gets a green/red % change column.

How to read the baseline before changing anything:

- **nfsd arrivals that found no idle thread** above \~1–2% under load means the server is thread-starved. Expect this at 8 threads. (The `sockets-enqueued` column is not used: since EL8 it counts every enqueue, not only those that waited.)
- **Server CPU in kernel** high during TCP tests is network-stack and copy overhead, which RDMA removes.
- **fio latency far above the NFS RPC round-trip** means time is lost queuing on the client, not on the server or wire.
- **Sequential read near the iperf3 figure** means IPoIB TCP is the ceiling; near the RDMA figure means the transport isn't the limit. An RDMA figure well below the link rate points at the PCIe slot (check the configuration table).

## Phase 3 — Migrate

Steps 1 and 4–5, plus a pilot of step 6 on one node, can be done live; TCP clients keep working. Steps 2–3, enabling NFSv4.2 where it is off, and moving the clients in step 6 interrupt service and belong in the window. On Slurm, groups of nodes can also be drained and moved beforehand (step 6).

On a Slurm cluster, before the window:

- **Reserve it.** Create a maintenance reservation on all nodes, as in Phase 1, covering the window plus about 2 h for the after capture. Create it at least one maximum job time limit ahead.
- **Check what Slurm keeps on this NAS.** Run `scontrol show config | grep -E 'StateSaveLocation|SlurmdSpoolDir'`, and check whether home directories live here. If the controller's state is on this NAS, slurmctld stalls whenever the NAS is unreachable: during the IPoIB bounce and the nfs-server restart's grace period (90 s by default).
- **Check whether Slurm traffic uses IPoIB.** If node addresses in `slurm.conf` are on IPoIB, the step 3 bounce briefly cuts slurmctld off from slurmd. A node unreachable for longer than `SlurmdTimeout` is marked DOWN; bring it back with `scontrol update nodename=<node> state=resume`.
- **Include the login nodes.** They need the same IPoIB MTU and client change, and users there should know about the window.

### 0. Dry run on each NAS

`nfs-rdma-preflight.sh` reads the current state and changes nothing. First it discovers the host. Then it flags blockers:

- link not InfiniBand
- HCA without a driver
- no NFS/RDMA module
- NFSv4.2 not offered
- unhealthy pool, md array or RAID volume
- a default boot kernel missing the ZFS, HCA or NFS/RDMA modules

It finds the subnet manager, samples nfsd thread pressure, and warns when the PCIe slot is slower than the IB link. It writes the proposed NFS config and the list of connected NFS clients. It ends with a "Discovered" summary and two numbered command lists for this host: before the window, and in the window.

```bash
mkdir -p /root/nfs-tuning && cd /root/nfs-tuning    # copy the script here
./nfs-rdma-preflight.sh 60        # 60 s thread-pressure sample; run it during normal load
less /root/nfs-tuning/preflight-*/report.txt
```

Run it as root; without root, the subnet manager, export, netplan and firewall checks are incomplete. Three environment variables change its defaults: `THREADS=` overrides the computed nfsd thread count, `IPOIB_IF=` picks the IPoIB interface when there is more than one, and `OUT=` moves the report directory (default `/root/nfs-tuning`).

Each run writes `preflight-<host>-<timestamp>/` with four files:

- `report.txt`: everything printed
- `nfs.conf.orig`: the current config (`sysconfig-nfs.orig` on EL7)
- `nfs.conf.proposed`: the version the plan installs (`sysconfig-nfs.proposed` on EL7)
- `nfs-clients.txt`: hosts connected over TCP 2049, the mounts to convert

When several NAS hosts share the fabric, run it on each and keep the reports together. The subnet manager change (step 2) is shared by all of them; everything else is per host. Run it again after each change and once after the window; the warnings should disappear as steps are completed.

### 0a. Save the current state

On the server and one client:

```bash
mkdir -p /root/pre-rdma
cp -a /etc/nfs.conf /etc/nfs.conf.d /etc/sysconfig/nfs /etc/exports /etc/exports.d /etc/fstab \
      /etc/modprobe.d /etc/modules-load.d /etc/rdma /etc/netplan /root/pre-rdma/ 2>/dev/null
ip -d link show ib0 > /root/pre-rdma/ib0.link
nmcli -f all con show "$(nmcli -g NAME,DEVICE con show --active | awk -F: '$2=="ib0"{print $1}')" > /root/pre-rdma/ib0.nmcli 2>/dev/null
```

Replace `ib0` with the interface the preflight reports. If compute nodes boot from an image (Warewulf, xCAT, etc.), every client change below must go into the image or provisioning config, or it disappears on reboot.

### 1. Confirm the ports are in InfiniBand mode

```bash
ibstat | grep -E 'CA type|State|Rate|Link layer'          # Active, 100 (EDR) or 56 (FDR), InfiniBand
ibv_devinfo | grep -E 'hca_id|link_layer|max_mtu|active_mtu'
```

Expect `Link layer: InfiniBand` and `max_mtu: 4096`. `active_mtu` may read 2048 or already 4096; either way the partition (step 2) is what caps IPoIB. Since IPoIB works, the link layer is already InfiniBand. Only if a VPI port shows `Ethernet` (ConnectX-3 through current cards):

```bash
dnf install -y mstflint                                   # apt-get on Ubuntu
lspci -D | grep -i mellanox                               # e.g. 0000:3b:00.0
mstconfig -d 0000:3b:00.0 query | grep LINK_TYPE
mstconfig -d 0000:3b:00.0 set LINK_TYPE_P1=1               # 1 = IB, 2 = ETH; then reboot
```

If MLNX\_OFED or DOCA-OFED is installed instead of the inbox stack (`ofed_info -s` prints a version), confirm `modinfo rpcrdma` resolves. Older MLNX\_OFED releases only included NFS over RDMA when installed with `--with-nfsrdma`.

### 2. Raise the IB MTU to 4096 at the subnet manager

The MTU that caps IPoIB is set by the subnet manager's partition, not on the hosts. Check it from any node as root; the IPoIB broadcast group's `Mtu` field ends in 4 for 2048 and 5 for 4096 (e.g. `0x84`, `0x85`):

```bash
saquery -g | grep -A2 'ff12:401b:ffff::ffff:ffff'          # default partition's IPv4 broadcast group
```

Find where the SM runs with `sminfo` (SM LID), then `smpquery nodedesc <lid>`.

- **OpenSM on a host:** in the partitions file, set the default partition to `mtu=5` (5 = 4096), then `systemctl restart opensm`. The file is usually `/etc/rdma/partitions.conf` on EL and `/etc/opensm/partitions.conf` on Ubuntu; check `partition_config_file` in the opensm config.

```text
Default=0x7fff, ipoib, mtu=5 : ALL=full;
```

- **SM on a managed switch or UFM:** set the Default partition's MTU to 4K in the switch's partition settings, following its vendor documentation.

The IPoIB broadcast group is re-created at the new MTU, so bounce IPoIB on every node (step 3 does this) or reboot them. Re-run the `saquery` check, then after step 3 check the whole cluster:

```bash
pdsh -a 'cat /sys/class/net/ib0/mtu' | dshbak -c           # every node: 4092; 2044 means the partition is still 2048
```

### 3. Set IPoIB mode and MTU (server and every client)

Check what the driver allows first:

```bash
cat /sys/class/net/ib0/mode
basename "$(readlink /sys/class/net/ib0/device/driver)"     # mlx5_core or mlx4_core
modinfo ib_ipoib | grep -i enhanced; modinfo mlx5_ib | grep -i enhanced
```

**Option A — datagram, MTU 4092 (recommended).** Works on every card. On mlx5 (ConnectX-4 and newer) it keeps Enhanced IPoIB's RSS/TSS, multi-queue and offloads. Once NFS uses RDMA, IPoIB carries little NFS data, so this is the low-risk choice.

```bash
# NetworkManager (EL)
nmcli con mod ib0 infiniband.transport-mode datagram infiniband.mtu 4092
nmcli con up ib0

# netplan (Ubuntu): under the ib0 entry in /etc/netplan/<file>.yaml
#     infiniband-mode: datagram
#     mtu: 4092
netplan try                                                 # reverts after 120 s unless confirmed

# ifcfg (EL7/EL8 without NetworkManager): MTU=4092 in ifcfg-ib0, then ifdown ib0; ifup ib0
```

**Option B — connected, MTU 65520.** Better single-stream TCP over IPoIB. On mlx4 (ConnectX-3) it is available directly. On mlx5 it is only possible if one of the `modinfo` checks above lists an `ipoib_enhanced` parameter, and disabling that gives up the Enhanced offloads:

```bash
# mlx5 only: use the module that listed ipoib_enhanced
echo 'options ib_ipoib ipoib_enhanced=0' > /etc/modprobe.d/ipoib-cm.conf
dracut -f && reboot                                        # Ubuntu: update-initramfs -u && reboot
# then, any card:
nmcli con mod ib0 infiniband.transport-mode connected infiniband.mtu 65520 && nmcli con up ib0
#   netplan: infiniband-mode: connected, mtu: 65520; ifcfg: CONNECTED_MODE=yes, MTU=65520
cat /sys/class/net/ib0/mode                                 # must say connected
```

Use the same IPoIB MTU on every host in the IPoIB subnet (NAS, compute, login nodes); a mismatch silently drops large packets. With mixed cards, option A is the one every host can run.

### 4. Size the nfsd threads

nfsd threads mostly wait on storage and the network, so more threads than cores is normal; 8 is a small-server default. Start at **max(64, logical CPUs rounded up to a multiple of 16)**. For example, a host with 24 or 48 logical CPUs gets 64, and one with 88 gets 96. The preflight never proposes fewer threads than the host already runs.

On a shared HPC cluster, start higher. Slurm jobs that span many nodes read inputs and write checkpoints from all of them at once, so burst concurrency is far above the average. With 20 or more clients, 128 is a reasonable start; `THREADS=128` makes the preflight plan it.

```bash
lscpu | grep -E '^(CPU\(s\)|Socket|Core|Thread|NUMA node\(s\))'
echo 64 > /proc/fs/nfsd/threads                             # takes effect now, no restart
cat /proc/fs/nfsd/threads
```

Step 5 makes it persistent. Validate with the report: if *nfsd arrivals that found no idle thread* stays above \~1–2% under the multi-client run, raise threads by half and re-run; stop around 256 unless the data says otherwise.

Optional for dual-socket hosts: `options sunrpc pool_mode=pernode` in `/etc/modprobe.d/sunrpc.conf` (applied at reboot) gives each socket its own thread pool. Test it as its own labelled run rather than bundling it with the rest. Recent upstream kernels deprecate the parameter and always use per-node pools; the preflight prints the current value.

### 5. Enable the RDMA listener on the server

Load the transport now and at boot:

```bash
modprobe svcrdma                                            # alias for rpcrdma on current kernels
echo svcrdma > /etc/modules-load.d/nfs-rdma.conf            # EL8+ and Ubuntu
# EL7: set SVCRDMA_LOAD=yes in /etc/rdma/rdma.conf instead
```

If `modprobe svcrdma` fails on Ubuntu, install `linux-modules-extra-$(uname -r)`.

Make the settings persistent. **EL8+ and Ubuntu**: edit `/etc/nfs.conf`, keeping your existing `vers*` lines (add `vers4.2=y` only if the preflight says 4.2 is off):

```ini
[nfsd]
threads=64
tcp=y
rdma=y
rdma-port=20049
```

Files in `/etc/nfs.conf.d/` are read after `nfs.conf` and override it, so a `threads=8` left there by an Ubuntu upgrade wins. The preflight flags such lines. Check the merged result with `nfsconf --dump`.

**EL7**: edit `/etc/sysconfig/nfs`, then `systemctl restart nfs-config` (it regenerates the nfsd arguments; nfsd keeps running):

```bash
RPCNFSDCOUNT=64
RPCNFSDARGS="--rdma=20049"              # add -V 4.2 if /proc/fs/nfsd/versions shows -4.2
```

Add the listener to the running server; no restart, TCP clients unaffected:

```bash
firewall-cmd --permanent --add-port={20049/tcp,20049/udp} && firewall-cmd --reload   # EL with firewalld
ufw allow 20049/tcp                                                                 # Ubuntu with ufw active
echo 'rdma 20049' > /proc/fs/nfsd/portlist
cat /proc/fs/nfsd/portlist                                  # rdma 20049 and tcp 2049
```

RDMA traffic bypasses netfilter, but Red Hat's procedure opens the port and it does no harm. The config edit makes the listener and thread count persist. `systemctl restart nfs-server` proves it, but it starts an NFSv4 grace period (90 s by default) during which v4 clients stall, so leave that for the window. The restart is required there if NFSv4.2 had to be enabled.

Exports need the `insecure` option: the kernel's NFS/RDMA documentation requires it because RDMA clients don't use a reserved source port. Add it to each client spec in `/etc/exports` (and `/etc/exports.d/*.exports`) and run `exportfs -ra`. For ZFS datasets, append it to `sharenfs` (`zfs set sharenfs='<current>,insecure' <dataset>`); the preflight prints the exact commands. Keeping `tcp=y` leaves TCP available as a fallback.

### 6. Move the clients to RDMA

Pilot one node, re-run the fio suite on it, then roll out by rack.

On a Slurm cluster, drain a node before touching its mounts; a mount a job is using can't be unmounted. For the pilot:

```bash
scontrol update nodename=node01 state=drain reason="nfs-rdma pilot"
squeue -w node01                                            # wait until empty
# switch the mount as below and run the fio suite, then:
scontrol update nodename=node01 state=resume
```

After the pilot, you can move further nodes the same way, a group at a time (`nodename=node[09-16]`), before the window; RDMA mounts don't depend on the IPoIB MTU. Switch whatever is left during the window, when every node is already idle.

```bash
dnf install -y rdma-core nfs-utils                          # EL7: yum; Ubuntu: apt-get install -y rdma-core nfs-common
echo xprtrdma > /etc/modules-load.d/nfs-rdma.conf && modprobe xprtrdma
umount /mnt/scratch
mount -t nfs -o proto=rdma,port=20049,vers=4.2,rsize=1048576,wsize=1048576,hard nas01-ib:/tank/scratch /mnt/scratch
nfsstat -m | grep -A1 /mnt/scratch                          # proto=rdma
grep -A4 'on /mnt/scratch ' /proc/self/mountstats | grep xprt   # xprt: rdma ...
```

Keep `vers=4.2`, which the clients already mount, and `rsize`/`wsize` the same as the baseline, so only the transport changes. Mount by the server's IPoIB name or address; RDMA uses it to find the server. Then make it permanent:

```text
# /etc/fstab
nas01-ib:/tank/scratch  /mnt/scratch  nfs  proto=rdma,port=20049,vers=4.2,rsize=1048576,wsize=1048576,hard,_netdev  0 0

# autofs map entry
scratch  -fstype=nfs,proto=rdma,port=20049,vers=4.2,hard  nas01-ib:/tank/scratch
```

With autofs, the new options apply at the next mount. After editing the map on an idle node, run `systemctl reload autofs` and unmount any automounts still active.

Watch `dmesg | grep -i rpcrdma` on the pilot node for an hour of real jobs before rolling out further.

### 7. Roll back

Reverse order, clients first:

1. Clients: restore the old fstab/autofs line and remount with `proto=tcp`. On Slurm, drain them first.
2. Server: set `rdma=n` in `nfs.conf` (EL7: drop `--rdma` from `RPCNFSDARGS`), or leave it (an idle listener is harmless), and restart nfs-server.
3. IPoIB: re-apply the saved MTU and mode from `/root/pre-rdma/` (nmcli, netplan or ifcfg); remove `ipoib-cm.conf` if used and rebuild the initramfs.
4. Subnet manager: restore the old partitions file, restart opensm and bounce IPoIB.

## Phase 4 — Capture again and compare

Re-run the identical capture on the same client(s) with a new label, then pass both directories to the report, baseline first.

```bash
export SERVER_SSH=root@nas01 SERVER_IB_IP=10.10.0.1 RESULTS=/root/nfsbench/results
./nfsbench.sh run rdma /mnt/scratch
python3 nfs_report.py results/baseline results/rdma -o nfs-report.html
```

Keep `SIZE`, `RUNTIME`, the client list and the dataset the same. Repeat for each variant you captured in Phase 1 (`baseline-8n` → `rdma-8n`, `baseline-cold` → `rdma-cold`), one report per pair or all in one command. Use one results directory per NAS so reports don't mix servers.

To see which change bought what, add an intermediate capture after steps 2–4 (new MTU and threads, still TCP), labelled `tuned-tcp`. The report then reads left to right:

```bash
python3 nfs_report.py results/baseline results/tuned-tcp results/rdma -o nfs-report.html
```

What to expect, and what it means if you don't see it:

- **Fabric:** RDMA bandwidth should sit near line rate (roughly 95+ Gb/s on EDR, 50+ on FDR) in both runs; it doesn't depend on NFS. If it is far lower, check the PCIe link in the configuration table. iperf3 should rise with the larger IPoIB MTU.
- **Small I/O and QD1 latency:** the largest relative gains, with lower server kernel CPU. If they don't move, check the configuration table says `rdma` for the transport.
- **Large sequential reads (warm):** should approach the RDMA ceiling until a client's CPU or the server's memory bandwidth becomes the limit; the multi-client run shows the server's limit.
- **Writes:** if sync-heavy, often bound by the storage rather than the transport (on ZFS, the intent log and SLOG), so gains may be modest. Check the `storage_iostat` output.
- **nfsd arrivals that found no idle thread** should be near zero with the new thread count; if not, raise threads and re-run.

## Troubleshooting

| Symptom | Likely cause | Check / fix |
| --- | --- | --- |
| `mount: Protocol not supported` | RDMA client module not loaded, or a kernel/OFED build without NFS over RDMA | `modprobe xprtrdma`; `modinfo rpcrdma`; on Ubuntu install `linux-modules-extra-$(uname -r)` |
| RDMA mount hangs or times out | Server has no RDMA listener, wrong address, or SM down | `cat /proc/fs/nfsd/portlist`; ping the server's IPoIB address; `ibstat` shows Active |
| `vers=4.2` mount refused, 4.1 works | Server has NFSv4.2 disabled | `cat /proc/fs/nfsd/versions`; enable it (step 5) and restart nfs-server in the window |
| Access denied over RDMA, TCP works | Export lacks `insecure`, so it rejects the client's non-reserved source port | Add `insecure` to that export (step 5), then `exportfs -ra` |
| Settings revert after restart (EL9+, Ubuntu) | An `/etc/nfs.conf.d/*.conf` file overrides `nfs.conf` | `nfsconf --dump`; fix or remove the overriding line |
| No IB device after upgrading to EL10 | ConnectX-3 (mlx4) driver removed in EL10 | Stay on EL9 for that host, or move to ConnectX-4 or newer |
| RDMA bandwidth well below link rate | HCA in an x8 slot or negotiated fewer lanes | Preflight's PCIe line; `lspci -vv -s <pci>` LnkSta; move to an x16 slot |
| IPoIB MTU stays 2044 after step 3, with no error | Partition still 2048: opensm not restarted, a standby SM took over with the old file, or IPoIB not re-joined | `saquery -g` (step 2); change every SM's partitions file, restart opensm; bounce `ib0` |
| Mode stays `datagram` after option B | Enhanced IPoIB still active (mlx5) | Use option A, or set `ipoib_enhanced=0` on the module that offers it and rebuild initramfs |
| Large IP packets dropped, small ones fine | IPoIB MTU differs between hosts | Same MTU on every host in the subnet |
| High *nfsd arrivals that found no idle thread* | Too few threads for the load | Raise threads by half; re-run the multi-client capture |
| `rpcrdma` errors or reconnects in `dmesg` | Fabric errors on a port or cable | `ibqueryerrors`; `perfquery -x` on the affected ports |

## Sources

- [Red Hat: Enabling NFS over RDMA on an NFS server (RHEL 9)](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_infiniband_and_rdma_networks/enabling-nfs-over-rdma-on-an-nfs-server_configuring-infiniband-and-rdma-networks); the [RHEL 8 version](https://docs.redhat.com/es/documentation/red_hat_enterprise_linux/8/html/configuring_infiniband_and_rdma_networks/enabling-nfs-over-rdma-on-an-nfs-server_configuring-infiniband-and-rdma-networks) gives the same steps
- [Red Hat Bugzilla 1248307](https://bugzilla.redhat.com/show_bug.cgi?id=1248307) — RHEL 7: `SVCRDMA_LOAD=yes` in `/etc/rdma/rdma.conf`, `RPCNFSDARGS="--rdma=20049"`
- [Red Hat: RHEL 10 hardware enablement](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/considerations_in_adopting_rhel_10/hardware-enablement) — mlx4 removed
- [Ubuntu Server: NFS](https://ubuntu.com/server/docs/network-file-system-nfs) — `nfs.conf` and `nfs.conf.d`; [nfs.conf(5)](https://www.man7.org/linux/man-pages/man5/nfs.conf.5.html) — drop-ins override the main file
- [Netplan YAML reference](https://netplan.readthedocs.io/en/stable/netplan-yaml/) — `infiniband-mode`, `mtu`
- [NVIDIA MLNX\_OFED: IP over InfiniBand](<https://docs.nvidia.com/networking/display/ofedv501000/ip+over+infiniband+(ipoib)>) — partition `mtu=5`, `ipoib_enhanced`
- [NVIDIA MLNX\_OFED 5.1: Enhanced IPoIB](<https://docs.nvidia.com/networking/display/mlnxofedv512620/ip+over+infiniband+(ipoib)>) — datagram only, no connected mode
- [Linux kernel: knfsd statistics (pool\_stats)](https://docs.kernel.org/filesystems/nfs/knfsd-stats.html)
- [Linux kernel: NFS/RDMA](https://www.kernel.org/doc/Documentation/filesystems/nfs/nfs-rdma.txt) — adding the listener through `/proc/fs/nfsd/portlist`, `insecure` exports

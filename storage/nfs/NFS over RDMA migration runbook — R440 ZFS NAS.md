# NFS over RDMA migration runbook — R440 ZFS NAS

Oct 29, 2026 · @Jason Willson

## Overview

The pool, exports and fabric stay as they are; four things change: IB link MTU 2048 → 4096, IPoIB MTU, nfsd threads 8 → sized to the CPU, and the NFS transport from TCP over IPoIB to native RDMA on port 20049. The same capture script runs before and after, so the report compares like with like. Commands are written for Springdale 8.6 and carry over to Rocky 9 NAS hosts unchanged.

| Item | Now | Target |
| --- | --- | --- |
| IB link MTU (set by the subnet manager) | 2048 | 4096 |
| IPoIB mode / MTU | datagram / 2044 (assumed; confirm in Phase 1) | datagram / 4092 (recommended), or connected / 65520 |
| nfsd threads | 8 | max(64, logical CPUs rounded up to a multiple of 16), validated by measurement |
| Server listeners | tcp 2049 | rdma 20049 + tcp 2049 (TCP kept as fallback) |
| Client mounts | proto=tcp | proto=rdma,port=20049 |

Three points shape the plan:

- **The ports are already in InfiniBand mode.** IPoIB only runs on the IB link layer, so RDMA is available today; NFS just isn't using it. Step 1 below only confirms `LINK_TYPE`; the real change is the NFS transport.
- **There are two MTUs.** The IB link MTU comes from the subnet manager's partition (EDR max 4096). The IPoIB MTU is the IP-layer value: IB MTU − 4 in datagram mode (2044 today, 4092 after), up to 65520 in connected mode. Your "2048" is most likely the IB MTU.
- **With proto=rdma, NFS data does not cross IPoIB.** IPoIB is used only to resolve the server's address; reads and writes move over RDMA connections. IPoIB MTU and mode therefore matter for the TCP baseline, fallback and other IP traffic, while the IB MTU matters for RDMA.

The IB MTU change and the nfs-server restart interrupt service cluster-wide; schedule a maintenance window.

## Tools

Every metric comes from standard EL8 packages; two scripts (sent alongside this doc) drive them and build the report.

| Tool | Package | Runs on | What it measures |
| --- | --- | --- | --- |
| `fio` (libaio, O\_DIRECT) | fio | clients | NFS IOPS, bandwidth, mean and p99 latency |
| `/proc/self/mountstats` | kernel (read by `mountstats`/`nfsiostat` in nfs-utils) | clients | per-RPC round-trip time for READ/WRITE |
| `mpstat` | sysstat | server + clients | CPU busy % and kernel share during each test |
| `/proc/fs/nfsd/pool_stats` | kernel | server | arrivals that had to wait for a free nfsd thread |
| `zpool iostat` | zfs | server | pool bandwidth/IOPS during each test |
| `iperf3` | iperf3 | client → server | IPoIB TCP throughput |
| `ib_write_bw`, `ib_read_bw`, `ib_read_lat` | perftest | client → server | raw RDMA ceiling of the fabric |
| `ibstat`, `ibv_devinfo` | infiniband-diags, libibverbs-utils | both | link layer, rate, active MTU |
| `nfsstat` | nfs-utils | both | op mix, server counters, client mount options |

Install on the server and on the test clients:

```bash
dnf install -y fio sysstat iperf3 perftest infiniband-diags libibverbs-utils rdma-core nfs-utils
```

The two scripts:

- **`nfsbench.sh`** runs on a client. `run <label> <mount>` snapshots client and server config, runs the fabric tests, then a 7-test fio suite while sampling server and client CPU, nfsd thread pressure, zpool I/O and RPC times. Results land in `results/<label>/`. `./nfsbench.sh check` lists missing tools.
- **`nfs_report.py`** reads one or more result directories and writes a self-contained HTML report plus a Markdown copy, with a % change column against the first run. It needs only Python 3.6+ (the platform python on Springdale 8).

Server-side capture uses passwordless root ssh from the test client to the NAS (`SERVER_SSH`). Without it the fio numbers are still captured, but server CPU, nfsd and zpool columns stay empty. EL8's iperf3 (3.5) is single-threaded, so its 8 streams share one core; treat that number as a lower bound.

## Phase 1 — Capture the baseline

One `run` takes about 15 minutes and records config, fabric ceiling and seven fio tests. Do it on a quiet cluster, then repeat it unchanged after the migration.

Ground rules, so before and after are comparable:

- Drain or reserve the test nodes; other jobs' I/O skews every number. Check `zpool iostat 1` on the NAS is near idle first.
- Keep the same clients, export, NFS version and rsize/wsize for every run. Note the current options with `nfsstat -m`.
- Write results to local disk on the client (`RESULTS=/root/nfsbench/results`), not to the NFS share.
- Run each capture twice. More than \~5% difference between the two means the cluster wasn't quiet.

What the defaults measure: fio uses O\_DIRECT, so the client page cache is bypassed. The write tests lay files down first, and 4–8 jobs × 8 GiB fit in a large ARC, so reads are served from server RAM. That isolates the transport, which is exactly what this migration changes. For a disk-bound view, add a second capture with total data above 2× ARC max (the report shows ARC max), e.g. `SIZE=96G` with label `baseline-cold`.

Single client, from one compute node:

```bash
mkdir -p /root/nfsbench && cd /root/nfsbench      # copy nfsbench.sh and nfs_report.py here
export SERVER_SSH=root@nas01 SERVER_IB_IP=10.10.0.1 ZPOOL=tank RESULTS=/root/nfsbench/results
./nfsbench.sh check
./nfsbench.sh run baseline /mnt/scratch
```

Replace `nas01`, `10.10.0.1` (the server's IPoIB address), `tank` and `/mnt/scratch` with yours. Set `IBDEV`/`IPOIB_IF` if your names differ from `mlx5_0`/`ib0`.

Aggregate load from several clients (one TCP client rarely fills 100 Gb/s, so this shows the server's limit). Start all clients together; only node01 samples the server:

```bash
# on node01
pdsh -w node[02-08] 'cd /root/nfsbench && RESULTS=/root/nfsbench/results ./nfsbench.sh fio baseline-8n /mnt/scratch' &
./nfsbench.sh fio baseline-8n /mnt/scratch
wait
# collect every node's results into one directory
for n in node0{2..8}; do rsync -a $n:/root/nfsbench/results/baseline-8n/ results/baseline-8n/; done
```

Per test, `results/<label>/` holds the fio JSON, client and server `mpstat`, `pool_stats` and `mountstats` snapshots taken before and after, and `zpool iostat` output. The fio test files stay in `<mount>/nfsbench.<host>/` so the after-run reuses the same layout; delete them when you're done.

## Phase 2 — Build the report

One command turns result directories into `nfs-report.html` (self-contained, opens in any browser, safe to email) and `nfs-report.md`:

```bash
python3 nfs_report.py results/baseline -o nfs-report.html
```

The report has a one-line-per-test summary, a configuration table (OS, CPU, ARC, nfsd threads and listeners, IB and IPoIB MTU/mode, mount options, actual transport), the fabric ceiling, and a section per fio test. Each test shows bandwidth, IOPS, mean and p99 latency, NFS RPC round-trip, server and client CPU, and nfsd thread pressure. Later you pass more directories; the first is the reference and every other run gets a green/red % change column.

How to read the baseline before changing anything:

- **nfsd arrivals that waited for a free thread** above \~1–2% under load means the server is thread-starved. Expect this at 8 threads.
- **Server CPU in kernel** high during TCP tests is network-stack and copy overhead, which RDMA removes.
- **fio latency far above the NFS RPC round-trip** means time is lost queuing on the client, not on the server or wire.
- **Sequential read near the iperf3 figure** means IPoIB TCP is the ceiling; near the RDMA figure means the transport isn't the limit.

## Phase 3 — Migrate

Work in this order: verify the link, raise the IB MTU, set IPoIB, size nfsd, enable RDMA on the server, then move clients one at a time. Steps 2, 3 and 5 interrupt service.

### 0. Save the current state

On the server and one client:

```bash
mkdir -p /root/pre-rdma
cp -a /etc/nfs.conf /etc/exports /etc/fstab /etc/modprobe.d /etc/rdma /root/pre-rdma/ 2>/dev/null
nmcli -f all con show "$(nmcli -g NAME,DEVICE con show --active | awk -F: '$2=="ib0"{print $1}')" > /root/pre-rdma/ib0.nmcli
```

If compute nodes boot from an image (Warewulf, xCAT, etc.), every client change below must go into the image or provisioning config, or it disappears on reboot.

### 1. Confirm the ports are in InfiniBand mode

```bash
ibstat mlx5_0 | grep -E 'State|Rate|Link layer'          # Active, 100, InfiniBand
ibv_devinfo -d mlx5_0 | grep -E 'link_layer|max_mtu|active_mtu'
```

Expect `Link layer: InfiniBand`, `max_mtu: 4096`, and today `active_mtu: 2048`. Since IPoIB works, the link layer is already InfiniBand. Only if a VPI port shows `Ethernet`:

```bash
dnf install -y mstflint
lspci -D | grep -i mellanox                               # e.g. 0000:3b:00.0
mstconfig -d 0000:3b:00.0 query | grep LINK_TYPE
mstconfig -d 0000:3b:00.0 set LINK_TYPE_P1=1               # 1 = IB, 2 = ETH; then reboot
```

If MLNX\_OFED or DOCA-OFED is installed instead of the inbox stack (`ofed_info -s` prints a version), confirm `modinfo rpcrdma` resolves. Older MLNX\_OFED releases only included NFS over RDMA when installed with `--with-nfsrdma`.

### 2. Raise the IB MTU to 4096 at the subnet manager

The link MTU is set by the subnet manager's partition, not on the hosts. Find where the SM runs with `sminfo` (SM LID), then `smpquery nodedesc <lid>`.

- **OpenSM on a host:** in the partitions file (on EL8 usually `/etc/rdma/partitions.conf`; check `partition_config_file` in the opensm config), set the default partition to `mtu=5` (5 = 4096), then `systemctl restart opensm`:

```text
Default=0x7fff, ipoib, mtu=5 : ALL=full;
```

- **SM on a managed switch or UFM:** set the Default partition's MTU to 4K in the switch's partition settings, following its vendor documentation.

The IPoIB broadcast group is re-created at the new MTU, so bounce IPoIB on every node (`nmcli con down ib0 && nmcli con up ib0`) or reboot them. Then check the whole cluster:

```bash
pdsh -a 'ibv_devinfo | grep active_mtu' | dshbak -c          # every node: 4096 (5)
```

### 3. Set IPoIB mode and MTU (server and every client)

Check what the driver allows first:

```bash
cat /sys/class/net/ib0/mode
modinfo ib_ipoib | grep -i enhanced; modinfo mlx5_ib | grep -i enhanced
```

**Option A — datagram, MTU 4092 (recommended).** ConnectX-5 runs Enhanced IPoIB, which keeps RSS/TSS, multi-queue and offloads but supports datagram mode only. Once NFS uses RDMA, IPoIB carries little NFS data, so this is the low-risk choice.

```bash
nmcli con mod ib0 infiniband.transport-mode datagram infiniband.mtu 4092
nmcli con up ib0
```

**Option B — connected, MTU 65520.** Only possible if one of the `modinfo` checks above lists an `ipoib_enhanced` parameter; disabling it gives up the Enhanced offloads in exchange for better single-stream TCP. Use the module that listed it:

```bash
echo 'options ib_ipoib ipoib_enhanced=0' > /etc/modprobe.d/ipoib-cm.conf
dracut -f && reboot
nmcli con mod ib0 infiniband.transport-mode connected infiniband.mtu 65520 && nmcli con up ib0
cat /sys/class/net/ib0/mode                                 # must say connected
```

Use the same IPoIB MTU on every host in the IPoIB subnet (NAS, compute, login nodes); a mismatch silently drops large packets. Hosts still on ifcfg files use `MTU=4092` (and `CONNECTED_MODE=yes` for option B) in `ifcfg-ib0`.

### 4. Size the nfsd threads

nfsd threads mostly wait on ZFS and the network, so more threads than cores is normal; 8 is a small-server default. Start at **max(64, logical CPUs rounded up to a multiple of 16)**: a dual 12-core R440 (48 logical CPUs) gets 64, a dual 20-core (80) gets 80.

```bash
lscpu | grep -E '^(CPU\(s\)|Socket|Core|Thread|NUMA node\(s\))'
grep -s RPCNFSDCOUNT /etc/sysconfig/nfs                     # EL8 ignores this file; nfs.conf wins
rpc.nfsd 64                                                 # takes effect now, no restart
cat /proc/fs/nfsd/threads
```

Make it persistent in `/etc/nfs.conf` under `[nfsd]` with `threads=64` (done in step 5). Validate with the report: if *nfsd arrivals that waited* stays above \~1–2% under the multi-client run, raise threads by half and re-run; stop around 256 unless the data says otherwise.

Optional for a dual-socket R440: `options sunrpc pool_mode=pernode` in `/etc/modprobe.d/sunrpc.conf` (applied at reboot) gives each socket its own thread pool. Test it as its own labelled run rather than bundling it with the rest.

### 5. Enable the RDMA listener on the server

```bash
dnf install -y rdma-core nfs-utils
grep -E '^(xprtrdma|svcrdma)' /etc/rdma/modules/rdma.conf   # both lines present, uncommented
modprobe svcrdma                                            # alias for rpcrdma on EL8
```

Edit `/etc/nfs.conf` (keep your existing `vers*` lines):

```ini
[nfsd]
threads=64
tcp=y
rdma=y
rdma-port=20049
```

```bash
firewall-cmd --permanent --add-port={20049/tcp,20049/udp} && firewall-cmd --reload
systemctl restart nfs-server
cat /proc/fs/nfsd/portlist                                  # rdma 20049 and tcp 2049
```

RDMA traffic bypasses netfilter, but Red Hat's procedure opens the port and it does no harm. The restart starts an NFSv4 grace period (90 s by default) during which v4 clients stall. Exports, ZFS `sharenfs` and the pool need no changes. Keeping `tcp=y` leaves TCP available as a fallback.

### 6. Move the clients to RDMA

Pilot one node, re-run the fio suite on it, then roll out by rack.

```bash
dnf install -y rdma-core nfs-utils
echo xprtrdma > /etc/modules-load.d/nfs-rdma.conf && modprobe xprtrdma
umount /mnt/scratch
mount -t nfs -o proto=rdma,port=20049,vers=3,rsize=1048576,wsize=1048576,hard nas01-ib:/tank/scratch /mnt/scratch
nfsstat -m | grep -A1 /mnt/scratch                          # proto=rdma
grep -A4 'on /mnt/scratch ' /proc/self/mountstats | grep xprt   # xprt: rdma ...
```

Keep `vers` and `rsize`/`wsize` the same as the baseline. Mount by the server's IPoIB name or address; RDMA uses it to find the server. Then make it permanent:

```text
# /etc/fstab
nas01-ib:/tank/scratch  /mnt/scratch  nfs  proto=rdma,port=20049,vers=3,rsize=1048576,wsize=1048576,hard,_netdev  0 0

# autofs map entry
scratch  -fstype=nfs,proto=rdma,port=20049,vers=3,hard  nas01-ib:/tank/scratch
```

Watch `dmesg | grep -i rpcrdma` on the pilot node for an hour of real jobs before rolling out further.

### 7. Roll back

Reverse order, clients first:

1. Clients: restore the old fstab/autofs line and remount with `proto=tcp`.
2. Server: set `rdma=n` (or leave it; an idle listener is harmless) and restart nfs-server.
3. IPoIB: re-apply the saved MTU and mode from `/root/pre-rdma/ib0.nmcli`; remove `ipoib-cm.conf` if used and rebuild initramfs.
4. Subnet manager: restore the old partitions file, restart opensm and bounce IPoIB.

## Phase 4 — Capture again and compare

Re-run the identical capture on the same client(s) with a new label, then pass both directories to the report, baseline first.

```bash
export SERVER_SSH=root@nas01 SERVER_IB_IP=10.10.0.1 ZPOOL=tank RESULTS=/root/nfsbench/results
./nfsbench.sh run rdma /mnt/scratch
python3 nfs_report.py results/baseline results/rdma -o nfs-report.html
```

Keep `SIZE`, `RUNTIME`, the client list and the dataset the same. Repeat for each variant you captured in Phase 1 (`baseline-8n` → `rdma-8n`, `baseline-cold` → `rdma-cold`), one report per pair or all in one command.

To see which change bought what, add an intermediate capture after steps 2–4 (new MTU and threads, still TCP), labelled `tuned-tcp`. The report then reads left to right:

```bash
python3 nfs_report.py results/baseline results/tuned-tcp results/rdma -o nfs-report.html
```

What to expect, and what it means if you don't see it:

- **Fabric:** RDMA bandwidth should sit near line rate (roughly 95+ Gb/s) in both runs; it doesn't depend on NFS. iperf3 should rise with the larger IPoIB MTU.
- **Small I/O and QD1 latency:** the largest relative gains, with lower server kernel CPU. If they don't move, check the configuration table says `rdma` for the transport.
- **Large sequential reads (warm):** should approach the RDMA ceiling until a client's CPU or the server's memory bandwidth becomes the limit; the multi-client run shows the server's limit.
- **Writes:** if sync-heavy, often bound by the ZFS intent log and SLOG rather than the transport, so gains may be modest. Check `zpool iostat` output for the log device.
- **nfsd arrivals that waited** should be near zero with the new thread count; if not, raise threads and re-run.

## Troubleshooting

| Symptom | Likely cause | Check / fix |
| --- | --- | --- |
| `mount: Protocol not supported` | RDMA client module not loaded, or an OFED build without NFS over RDMA | `modprobe xprtrdma`; `modinfo rpcrdma` |
| RDMA mount hangs or times out | Server has no RDMA listener, wrong address, or SM down | `cat /proc/fs/nfsd/portlist`; ping the server's IPoIB address; `ibstat` shows Active |
| Access denied over RDMA, TCP works | Export rejects the client's non-reserved source port | Add `insecure` to that export (the kernel's NFS/RDMA notes call for it), then `exportfs -ra` |
| `active_mtu` still 2048 after step 2 | Partition not reloaded, or IPoIB not re-joined | Restart opensm; bounce `ib0` or reboot the node |
| Mode stays `datagram` after option B | Enhanced IPoIB still active | Use option A, or set `ipoib_enhanced=0` on the module that offers it and rebuild initramfs |
| Large IP packets dropped, small ones fine | IPoIB MTU differs between hosts | Same MTU on every host in the subnet |
| High *nfsd arrivals that waited* | Too few threads for the load | Raise `threads=` by half; re-run the multi-client capture |
| `rpcrdma` errors or reconnects in `dmesg` | Fabric errors on a port or cable | `ibqueryerrors`; `perfquery -x` on the affected ports |

## Sources

- [Red Hat: Enabling NFS over RDMA on an NFS server (RHEL 9)](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_infiniband_and_rdma_networks/enabling-nfs-over-rdma-on-an-nfs-server_configuring-infiniband-and-rdma-networks); the [RHEL 8 version](https://docs.redhat.com/es/documentation/red_hat_enterprise_linux/8/html/configuring_infiniband_and_rdma_networks/enabling-nfs-over-rdma-on-an-nfs-server_configuring-infiniband-and-rdma-networks) gives the same steps
- [NVIDIA MLNX\_OFED: IP over InfiniBand](<https://docs.nvidia.com/networking/display/ofedv501000/ip+over+infiniband+(ipoib)>) — partition `mtu=5`, `ipoib_enhanced`
- [NVIDIA MLNX\_OFED 5.1: Enhanced IPoIB](<https://docs.nvidia.com/networking/display/mlnxofedv512620/ip+over+infiniband+(ipoib)>) — datagram only, no connected mode
- [Linux kernel: knfsd statistics (pool\_stats)](https://docs.kernel.org/filesystems/nfs/knfsd-stats.html)

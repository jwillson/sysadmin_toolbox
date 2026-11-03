#!/usr/bin/env bash
# nfs-rdma-preflight.sh — read-only dry run of the NFS-over-RDMA migration on a NAS.
#
# Changes nothing: no modprobe, no config edits, no service restarts, no nmcli
# changes, no exportfs. It reads the current state, flags blockers, works out
# the values for this host, and prints the exact commands for each step, split
# into what can be done live and what needs the maintenance window.
#
# Writes only:  $OUT/preflight-<host>-<timestamp>/
#                 report.txt          everything printed to the screen
#                 nfs.conf.orig       copy of the current /etc/nfs.conf
#                 nfs.conf.proposed   the edited version the plan installs
#                 nfs-clients.txt     hosts currently connected over TCP 2049
#
# Usage:  ./nfs-rdma-preflight.sh [sample_seconds]
#   sample_seconds  seconds to sample nfsd thread pressure (default 30, 0 = skip)
#
# Settings (environment):
#   OUT=/root/nfs-tuning   TARGET_IB_MTU=4096   RDMA_PORT=20049
#   THREADS=               override the computed nfsd thread count
#   IPOIB_IF=              IPoIB interface (default: first one found)
#   NFS_CONF=/etc/nfs.conf   NFSD_PROC=/proc/fs/nfsd   (only for testing)
#
# Works on EL8 (Springdale/Rocky/RHEL 8) and EL9.

set -uo pipefail
export LC_ALL=C

SAMPLE=${1:-30}
OUT=${OUT:-/root/nfs-tuning}
TARGET_IB_MTU=${TARGET_IB_MTU:-4096}
RDMA_PORT=${RDMA_PORT:-20049}
NFS_CONF=${NFS_CONF:-/etc/nfs.conf}
NFSD_PROC=${NFSD_PROC:-/proc/fs/nfsd}
HOST=$(hostname -s)
DIR="$OUT/preflight-$HOST-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DIR" || { echo "cannot create $DIR" >&2; exit 1; }
exec > >(tee "$DIR/report.txt") 2>&1

NPASS=0 NWARN=0 NFAIL=0
LIVE=() WINDOW=() VERIFY=()
pass()   { printf '  [ OK ] %s\n' "$*"; NPASS=$((NPASS + 1)); }
warn()   { printf '  [WARN] %s\n' "$*"; NWARN=$((NWARN + 1)); }
fail()   { printf '  [FAIL] %s\n' "$*"; NFAIL=$((NFAIL + 1)); }
info()   { printf '  [info] %s\n' "$*"; }
head1()  { printf '\n== %s ==\n' "$*"; }
have()   { command -v "$1" >/dev/null 2>&1; }
live()   { LIVE+=("$1"); }
window() { WINDOW+=("$1"); }
verify() { VERIFY+=("$1"); }
mtu_code() { case $1 in 256) echo 1;; 512) echo 2;; 1024) echo 3;; 2048) echo 4;; 4096) echo 5;; *) echo "";; esac; }

echo "NFS over RDMA preflight (read-only) — $HOST — $(date '+%Y-%m-%d %H:%M %Z')"
echo "Report directory: $DIR"

# ------------------------------------------------------------------ host
head1 "Host"
OSNAME=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown OS}")
info "$OSNAME, kernel $(uname -r)"
[[ $EUID -eq 0 ]] || warn "not running as root: subnet manager, export and firewall checks will be incomplete"
logical=$(nproc --all)
lsc=$(lscpu 2>/dev/null)
sockets=$(awk -F: '/^Socket\(s\)/{gsub(/ /,"",$2);print $2;exit}' <<<"$lsc")
cps=$(awk -F: '/^Core\(s\) per socket/{gsub(/ /,"",$2);print $2;exit}' <<<"$lsc")
model=$(awk -F: '/^Model name/{sub(/^ +/,"",$2);print $2;exit}' <<<"$lsc")
numa=$(awk -F: '/^NUMA node\(s\)/{gsub(/ /,"",$2);print $2;exit}' <<<"$lsc")
physical=$(( ${sockets:-1} * ${cps:-1} ))
info "CPU: ${model:-?}; ${sockets:-?} socket(s), $physical cores, $logical logical CPUs, ${numa:-?} NUMA node(s)"
info "RAM: $(awk '/MemTotal/{printf "%.0f GiB", $2/1048576}' /proc/meminfo)"

# A reboot in the window boots the default kernel, which needs a ZFS module.
bootk=""
if have grubby; then bootk=$(grubby --default-kernel 2>/dev/null | sed 's|^/boot/vmlinuz-||'); fi
if [[ -n $bootk ]]; then
  if [[ $bootk == "$(uname -r)" ]]; then
    pass "default boot kernel is the running kernel"
  else
    warn "default boot kernel is $bootk, not the running $(uname -r); a reboot in the window changes kernels"
    if find "/lib/modules/$bootk" -name 'zfs.ko*' 2>/dev/null | grep -q .; then
      pass "a ZFS module exists for $bootk"
    else
      fail "no zfs.ko for $bootk: the pool would not import after a reboot. Build ZFS for it, or keep the current kernel: grubby --set-default /boot/vmlinuz-$(uname -r)"
    fi
  fi
fi

# ------------------------------------------------------------------ zfs
head1 "ZFS"
if have zpool; then
  st=$(zpool status -x 2>&1)
  if [[ $st == "all pools are healthy" ]]; then pass "all pools healthy"
  else fail "pool status: $(head -3 <<<"$st" | tr '\n' ' ')— resolve or account for this before the window"; fi
  while read -r n s a h; do [[ -n $n ]] && info "pool $n: size $s, allocated $a, $h"; done \
    < <(zpool list -H -o name,size,alloc,health 2>/dev/null)
else
  warn "zpool command not found"
fi

# ------------------------------------------------------------------ packages
head1 "Packages"
missing=()
if have rpm; then
  for p in rdma-core nfs-utils infiniband-diags libibverbs-utils perftest; do
    if rpm -q "$p" >/dev/null 2>&1; then pass "$p $(rpm -q --qf '%{VERSION}-%{RELEASE}' "$p")"
    else warn "$p not installed"; missing+=("$p"); fi
  done
  ((${#missing[@]})) && live "Install missing packages (no service impact)
    dnf install -y ${missing[*]}"
fi
have ofed_info && info "vendor OFED installed: $(ofed_info -s 2>/dev/null) — NFS/RDMA modules must come from it"

# ------------------------------------------------------------------ infiniband
head1 "InfiniBand"
ipoib=()
for n in /sys/class/net/*; do [[ $(cat "$n/type" 2>/dev/null) == 32 ]] && ipoib+=("${n##*/}"); done
IF=${IPOIB_IF:-${ipoib[0]:-}}
ibdev=""
[[ -n $IF ]] && ibdev=$(ls "/sys/class/net/$IF/device/infiniband" 2>/dev/null | head -1)
cur_mtu=""
ndev=0
for d in /sys/class/infiniband/*; do
  [[ -e $d ]] || continue
  dev=${d##*/}
  for p in "$d"/ports/*; do
    [[ -e $p ]] || continue
    ndev=$((ndev + 1)); port=${p##*/}
    ll=$(cat "$p/link_layer" 2>/dev/null); state=$(cat "$p/state" 2>/dev/null); rate=$(cat "$p/rate" 2>/dev/null)
    dvi=$(ibv_devinfo -d "$dev" -i "$port" 2>/dev/null)
    amtu=$(awk '/active_mtu/{print $2;exit}' <<<"$dvi"); mmtu=$(awk '/max_mtu/{print $2;exit}' <<<"$dvi")
    tag=""; [[ $dev == "$ibdev" ]] && tag=" (carries $IF)"
    info "$dev port $port$tag: $ll, $state, $rate, MTU active ${amtu:-?} / max ${mmtu:-?}"
    [[ $dev == "$ibdev" || -z $ibdev ]] || continue
    if [[ $ll == InfiniBand ]]; then pass "$dev port $port is in InfiniBand mode (RDMA available)"
    else fail "$dev port $port link layer is $ll; set LINK_TYPE_P$port=1 with mstconfig and reboot"; fi
    [[ $state == *ACTIVE* ]] && pass "$dev port $port is ACTIVE" || fail "$dev port $port is not ACTIVE ($state)"
    cur_mtu=${amtu:-$cur_mtu}
    if [[ -n $mmtu && $mmtu -lt $TARGET_IB_MTU ]]; then
      fail "$dev max MTU $mmtu is below the $TARGET_IB_MTU target"
    fi
  done
done
((ndev)) || fail "no InfiniBand devices found under /sys/class/infiniband"
if [[ -n $cur_mtu ]]; then
  if [[ $cur_mtu -ge $TARGET_IB_MTU ]]; then pass "IB link MTU already $cur_mtu"
  else warn "IB link MTU is $cur_mtu; target $TARGET_IB_MTU is set at the subnet manager (see below)"; fi
fi

# ------------------------------------------------------------------ subnet manager
head1 "Subnet manager"
code=$(mtu_code "$TARGET_IB_MTU")
smdesc=""
if have sminfo; then
  smi=$(sminfo 2>&1)
  smlid=$(sed -n 's/.*sm lid \([0-9][0-9]*\).*/\1/p' <<<"$smi")
  if [[ -n $smlid ]]; then
    smdesc=$(smpquery nodedesc "$smlid" 2>/dev/null | sed 's/^Node Description:\.*//')
    info "master SM: LID $smlid on \"${smdesc:-unknown node}\""
  else
    warn "sminfo gave no SM: $(head -1 <<<"$smi")"
  fi
else
  warn "sminfo not found (infiniband-diags): cannot locate the subnet manager"
fi
if systemctl is-active -q opensm 2>/dev/null; then
  pf=""
  for c in /etc/rdma/opensm.conf /etc/opensm/opensm.conf; do
    [[ -r $c ]] && pf=$(awk '$1=="partition_config_file"{print $2;exit}' "$c") && [[ -n $pf ]] && break
  done
  pf=${pf:-/etc/rdma/partitions.conf}
  info "opensm runs on this host; partition file: $pf"
  if [[ -r $pf ]]; then
    defl=$(grep -E '^[[:space:]]*Default[[:space:]]*=' "$pf" | head -1)
    info "current: ${defl:-<no Default line>}"
    if [[ $defl =~ mtu=([0-9]) ]]; then
      sedcmd="sed -i -E '/^[[:space:]]*Default[[:space:]]*=/ s/mtu=[0-9]/mtu=$code/' $pf"
    elif [[ -n $defl ]]; then
      sedcmd="sed -i -E '/^[[:space:]]*Default[[:space:]]*=/ s/[[:space:]]*:/, mtu=$code :/' $pf"
    else
      sedcmd="echo 'Default=0x7fff, ipoib, mtu=$code : ALL=full;' >> $pf"
    fi
  else
    info "no partition file yet (opensm defaults to a 2048 MTU)"
    sedcmd="echo 'Default=0x7fff, ipoib, mtu=$code : ALL=full;' > $pf"
  fi
  [[ ${cur_mtu:-0} -lt $TARGET_IB_MTU ]] && window "Raise the IB MTU at the subnet manager (cluster-wide IPoIB rejoin; do the same on any standby SM)
    cp -a $pf $pf.pre-rdma 2>/dev/null
    $sedcmd
    grep -E '^[[:space:]]*Default' $pf      # expect mtu=$code ($TARGET_IB_MTU)
    systemctl restart opensm"
else
  info "opensm is not running on this host"
  [[ ${cur_mtu:-0} -lt $TARGET_IB_MTU ]] && window "Raise the IB MTU at the subnet manager on \"${smdesc:-the SM node}\" (cluster-wide IPoIB rejoin)
    OpenSM host: set mtu=$code on the Default line of its partitions file, then systemctl restart opensm
    Managed switch / UFM: set the Default partition MTU to 4K per the vendor's procedure
    Apply the same change on every standby SM"
fi

# ------------------------------------------------------------------ ipoib
head1 "IPoIB${IF:+ ($IF)}"
addr=""
con=""
if [[ -z $IF ]]; then
  fail "no IPoIB interface found"
else
  mode=$(cat "/sys/class/net/$IF/mode" 2>/dev/null)
  mtu=$(cat "/sys/class/net/$IF/mtu" 2>/dev/null)
  addr=$(ip -4 -o addr show dev "$IF" 2>/dev/null | awk '{print $4; exit}')
  info "mode ${mode:-?}, MTU ${mtu:-?}, address ${addr:-none}"
  [[ -n $addr ]] && pass "IPoIB has an address (RDMA mounts resolve the server through it)" \
                 || fail "$IF has no IPv4 address; NFS/RDMA needs one to resolve the server"
  if have nmcli; then
    con=$(nmcli -g GENERAL.CONNECTION device show "$IF" 2>/dev/null)
    [[ $con == "--" ]] && con=""
  fi
  if [[ -n $con ]]; then info "NetworkManager connection: \"$con\""
  elif [[ -r /etc/sysconfig/network-scripts/ifcfg-$IF ]]; then info "configured by ifcfg-$IF"
  fi
  enh=""
  for m in ib_ipoib mlx5_ib; do modinfo -F parm "$m" 2>/dev/null | grep -q '^ipoib_enhanced' && enh=$m; done
  if [[ -n $enh ]]; then info "connected mode is possible via '$enh ipoib_enhanced=0' (gives up Enhanced IPoIB offloads)"
  else info "driver has no ipoib_enhanced parameter: datagram mode only (runbook option A)"; fi
  tgt=$((TARGET_IB_MTU - 4))
  if [[ $mode == datagram && ${mtu:-0} -lt $tgt ]]; then
    if [[ -n $con ]]; then cmd="nmcli con mod \"$con\" infiniband.transport-mode datagram infiniband.mtu $tgt
    nmcli con up \"$con\""
    else cmd="set MTU=$tgt in /etc/sysconfig/network-scripts/ifcfg-$IF, then: ifdown $IF; ifup $IF"; fi
    window "After the SM change: IPoIB MTU $tgt on this host (brief IPoIB drop), and the same on EVERY host in the IPoIB subnet
    $cmd
    cat /sys/class/net/$IF/mtu      # expect $tgt"
  fi
fi

# ------------------------------------------------------------------ rdma modules
head1 "NFS/RDMA kernel support"
if modinfo rpcrdma >/dev/null 2>&1; then pass "rpcrdma module available ($(modinfo -F filename rpcrdma 2>/dev/null))"
else fail "rpcrdma module not found: this kernel/OFED build has no NFS over RDMA"; fi
if lsmod 2>/dev/null | grep -q '^rpcrdma'; then pass "rpcrdma loaded"
else info "rpcrdma not loaded yet"; fi
rc=/etc/rdma/modules/rdma.conf
if grep -Eq '^[[:space:]]*svcrdma' "$rc" 2>/dev/null; then pass "svcrdma enabled in $rc (loads at boot)"
else warn "svcrdma not enabled in $rc"
     live "Load svcrdma at boot (no impact)
    echo svcrdma >> $rc"; fi

# ------------------------------------------------------------------ nfs server
head1 "NFS server"
systemctl is-active -q nfs-server 2>/dev/null && pass "nfs-server active" || warn "nfs-server not active"
threads=$(cat "$NFSD_PROC/threads" 2>/dev/null)
portlist=$(paste -sd',' "$NFSD_PROC/portlist" 2>/dev/null)
info "threads: ${threads:-?}; listeners: ${portlist:-?}; versions: $(cat "$NFSD_PROC/versions" 2>/dev/null)"
info "sunrpc pool_mode: $(cat /sys/module/sunrpc/parameters/pool_mode 2>/dev/null || echo '?')"
ceil16=$(( (logical + 15) / 16 * 16 ))
T=$(( ceil16 > 64 ? ceil16 : 64 ))
T=${THREADS:-$T}
info "planned nfsd threads: $T (max(64, $logical logical CPUs rounded up to 16); override with THREADS=)"

live "Load the RDMA server transport and add the RDMA listener to the running server (TCP clients unaffected)
    modprobe svcrdma
    grep -q 'rdma $RDMA_PORT' $NFSD_PROC/portlist || echo 'rdma $RDMA_PORT' > $NFSD_PROC/portlist
    cat $NFSD_PROC/portlist          # expect rdma $RDMA_PORT alongside tcp 2049"
grep -q "rdma $RDMA_PORT" "$NFSD_PROC/portlist" 2>/dev/null && pass "RDMA listener already on port $RDMA_PORT"

if [[ ${threads:-0} -lt $T ]]; then
  live "Raise nfsd threads on the running server (immediate, no restart)
    echo $T > $NFSD_PROC/threads
    cat $NFSD_PROC/threads"
fi

if grep -qs '^[[:space:]]*RPCNFSDCOUNT' /etc/sysconfig/nfs; then
  warn "/etc/sysconfig/nfs sets $(grep -m1 '^[[:space:]]*RPCNFSDCOUNT' /etc/sysconfig/nfs); EL8 reads /etc/nfs.conf — remove it so the two can't disagree"
fi

# nfs.conf: current [nfsd] settings and the proposed file
if [[ -s $NFS_CONF ]]; then
  cp -a "$NFS_CONF" "$DIR/nfs.conf.orig"
  info "active [nfsd] lines in $NFS_CONF:"
  awk '/^[[:space:]]*\[/{s=$0; gsub(/[][[:space:]]/,"",s); sec=tolower(s); next}
       sec=="nfsd" && /^[[:space:]]*[A-Za-z][^=]*=/ {print "           " $0}' "$NFS_CONF"
  awk -v T="$T" -v P="$RDMA_PORT" '
    BEGIN { n = split("threads tcp rdma rdma-port", order, " ")
            want["threads"] = T; want["tcp"] = "y"; want["rdma"] = "y"; want["rdma-port"] = P }
    function key(line,  k) { k = line; sub(/=.*/, "", k); gsub(/[[:space:]]/, "", k); return k }
    function hdr(line,  s) { s = line; gsub(/[][[:space:]]/, "", s); return tolower(s) }
    NR == FNR { if ($0 ~ /^[[:space:]]*\[/) { sec = hdr($0); if (sec == "nfsd") has = 1; next }
                if (sec == "nfsd" && $0 ~ /^[[:space:]]*[A-Za-z][^=]*=/) present[key($0)] = 1
                next }
    FNR == 1 { sec = "" }
    /^[[:space:]]*\[/ { sec = hdr($0); print
                        if (sec == "nfsd") for (i = 1; i <= n; i++) if (!(order[i] in present)) print order[i] "=" want[order[i]]
                        next }
    sec == "nfsd" && /^[[:space:]]*[A-Za-z][^=]*=/ { k = key($0)
                        if (k in want) { if (!(k in done)) print k "=" want[k]; done[k] = 1; next } }
    { print }
    END { if (!has) { print ""; print "[nfsd]"; for (i = 1; i <= n; i++) print order[i] "=" want[order[i]] } }
  ' "$NFS_CONF" "$NFS_CONF" > "$DIR/nfs.conf.proposed"
else
  info "$NFS_CONF missing or empty; proposing a minimal one"
  : > "$DIR/nfs.conf.orig"
  printf '[nfsd]\nthreads=%s\ntcp=y\nrdma=y\nrdma-port=%s\n' "$T" "$RDMA_PORT" > "$DIR/nfs.conf.proposed"
fi
if cmp -s "$DIR/nfs.conf.orig" "$DIR/nfs.conf.proposed"; then
  pass "$NFS_CONF already has the planned [nfsd] settings"
else
  info "proposed change to $NFS_CONF:"
  diff -u "$DIR/nfs.conf.orig" "$DIR/nfs.conf.proposed" | tail -n +3 | sed 's/^/           /'
  if have nfsconf; then
    if [[ $(nfsconf --file "$DIR/nfs.conf.proposed" --get nfsd rdma 2>/dev/null) == y ]]; then
      pass "nfsconf parses the proposed file (nfsd rdma=y)"
    else
      warn "nfsconf could not confirm the proposed file; check it by eye"
    fi
  fi
  live "Stage $NFS_CONF so the settings persist (read at the next nfs-server start; nothing changes now)
    cmp -s $NFS_CONF $DIR/nfs.conf.orig && cp -a $NFS_CONF $NFS_CONF.pre-rdma && cp $DIR/nfs.conf.proposed $NFS_CONF"
fi

# nfsd thread pressure, same method as nfsd-starve.sh:
# share of arrivals that did not wake an idle thread = (arrived - woken) / arrived
if (( SAMPLE > 0 )) && [[ -r $NFSD_PROC/pool_stats ]]; then
  snap() {
    awk '/^#/ { for (i = 2; i <= NF; i++) c[$i] = i - 1; next }
         { ca = ("packets-arrived" in c) ? c["packets-arrived"] : 2
           cw = ("threads-woken"  in c) ? c["threads-woken"]  : 4
           a += $ca; w += $cw }
         END { print a + 0, w + 0 }' "$NFSD_PROC/pool_stats"
  }
  info "sampling nfsd thread pressure for ${SAMPLE}s ..."
  read -r a1 w1 < <(snap); sleep "$SAMPLE"; read -r a2 w2 < <(snap)
  da=$((a2 - a1)); dw=$((w2 - w1))
  if (( da > 0 )); then
    pct=$(awk -v a="$da" -v w="$dw" 'BEGIN{printf "%.2f", 100 * (a - w) / a}')
    msg="$(( da / SAMPLE )) arrivals/s; ${pct}% found no idle nfsd thread (${threads:-?} threads)"
    if awk -v p="$pct" 'BEGIN{exit !(p < 0.5)}'; then pass "$msg"
    else warn "$msg — under current load the server needs more threads"; fi
  else
    info "no NFS traffic during the sample; run again under load for a thread-pressure reading"
  fi
fi

# ------------------------------------------------------------------ exports
head1 "Exports"
first_export=""
if have exportfs; then
  ex=$(exportfs -s 2>/dev/null)
  if [[ -z $ex ]]; then
    warn "no exports listed (not root, or nothing exported)"
  else
    noins=()
    while read -r path specs; do
      [[ -z $path ]] && continue
      first_export=${first_export:-$path}
      for s in $specs; do
        opts=${s#*(}; opts=${opts%)}
        [[ ,$opts, == *,insecure,* ]] || noins+=("$path ${s%%(*}")
      done
    done <<<"$ex"
    info "$(wc -l <<<"$ex") export line(s)"
    if ((${#noins[@]})); then
      warn "${#noins[@]} export/client pair(s) lack 'insecure'; the kernel's NFS/RDMA docs require it because RDMA clients don't use a reserved port:"
      printf '           %s\n' "${noins[@]}"
      zcmds=""
      if have zfs; then
        while IFS=$'\t' read -r ds val; do
          if [[ $val == on ]]; then zcmds+=$'\n'"    # $ds has sharenfs=on: set explicit options including insecure, e.g. zfs set sharenfs='rw,insecure,...' $ds"
          elif [[ $val != *insecure* ]]; then zcmds+=$'\n'"    zfs set sharenfs='$val,insecure' $ds"; fi
        done < <(zfs get -H -o name,value -s local sharenfs 2>/dev/null | awk -F'\t' '$2 != "off"')
      fi
      live "Add 'insecure' to the exports above (re-export only; brief and low impact, best done at a quiet moment)
    /etc/exports entries: add insecure to the client options, then: exportfs -ra${zcmds}
    exportfs -s | grep -v insecure     # expect no output"
    else
      pass "all exports allow unreserved ports (insecure)"
    fi
  fi
else
  warn "exportfs not found"
fi

# ------------------------------------------------------------------ firewall
head1 "Firewall"
if systemctl is-active -q firewalld 2>/dev/null; then
  if firewall-cmd --query-port="$RDMA_PORT/tcp" >/dev/null 2>&1; then pass "firewalld allows $RDMA_PORT/tcp"
  else
    info "firewalld active, $RDMA_PORT not open (RDMA bypasses netfilter; Red Hat's procedure opens it anyway)"
    live "Open the NFS/RDMA port in firewalld (no impact)
    firewall-cmd --permanent --add-port={$RDMA_PORT/tcp,$RDMA_PORT/udp} && firewall-cmd --reload"
  fi
else
  info "firewalld not active"
fi

# ------------------------------------------------------------------ clients
head1 "Current NFS clients"
if have ss; then
  ss -Htn state established '( sport = :2049 )' 2>/dev/null \
    | awk '{p = $4; sub(/:[0-9]+$/, "", p); gsub(/^\[|\]$/, "", p); sub(/^::ffff:/, "", p); print p}' \
    | sort -uV | while read -r ip; do
        printf '%s %s\n' "$ip" "$(getent hosts "$ip" | awk '{print $2; exit}')"
      done > "$DIR/nfs-clients.txt"
  nc=$(wc -l < "$DIR/nfs-clients.txt")
  info "$nc host(s) connected over TCP 2049 — these are the mounts to convert (list in nfs-clients.txt)"
  head -8 "$DIR/nfs-clients.txt" | sed 's/^/           /'
  (( nc > 8 )) && info "... and $((nc - 8)) more"
fi

# ------------------------------------------------------------------ plan
ip_only=${addr%/*}
live "Pilot ONE client over RDMA (only that node is affected; RDMA works at the current IB MTU)
    # on the client, with the same rsize/wsize it uses today:
    dnf install -y rdma-core nfs-utils && modprobe xprtrdma
    mkdir -p /mnt/rdmatest
    mount -t nfs -o proto=rdma,port=$RDMA_PORT,vers=4.2,hard ${ip_only:-<NAS IPoIB address>}:${first_export:-<export>} /mnt/rdmatest
    grep -A4 ' /mnt/rdmatest ' /proc/self/mountstats | grep xprt    # expect: xprt: rdma
    # optional: ./nfsbench.sh fio pilot /mnt/rdmatest ; then umount /mnt/rdmatest"

window "Confirm the new MTU everywhere
    ibv_devinfo | grep active_mtu                       # this host: $TARGET_IB_MTU
    pdsh -a 'ibv_devinfo | grep active_mtu' | dshbak -c # every node"
window "Move clients to RDMA (update fstab/autofs per runbook step 6, then remount), in the order of nfs-clients.txt"
window "Optional: prove the staged config survives a restart (NFSv4 clients pause for the grace period)
    systemctl restart nfs-server
    cat $NFSD_PROC/portlist $NFSD_PROC/threads"

verify "Re-run this script: every [WARN] above should be gone and the IB MTU should read $TARGET_IB_MTU"
verify "On a client: nfsstat -m shows proto=rdma; then capture the after-run with nfsbench.sh"
verify "dmesg -T | grep -iE 'rpcrdma|svcrdma' on the NAS and a client: no errors"

printf '\n== Summary ==\n  %d OK, %d warnings, %d blockers\n' "$NPASS" "$NWARN" "$NFAIL"
(( NFAIL )) && echo "  Resolve every [FAIL] before the window."

printplan() {
  local title=$1; shift
  printf '\n== %s ==\n' "$title"
  local i=1 s
  for s in "$@"; do printf '\n%2d. %s\n' "$i" "$s"; i=$((i + 1)); done
}
printplan "Plan A: before the window (live; TCP clients keep working)" "${LIVE[@]}"
printplan "Plan B: in the window (cluster-wide interruption), in this order" "${WINDOW[@]}"
printplan "Verify" "${VERIFY[@]}"
printf '\nNothing was changed on this host. Report: %s/report.txt\n' "$DIR"

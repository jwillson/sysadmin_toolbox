#!/usr/bin/env bash
# nfsbench.sh — capture NFS / InfiniBand performance metrics so a "before" and
# "after" run can be compared with nfs_report.py.
#
# Run it on an NFS CLIENT (compute node). With SERVER_SSH set it also captures
# server-side config, CPU, nfsd thread pressure and zpool I/O over ssh.
#
#   Subcommands
#     run    <label> <mountpoint>   env snapshot (client+server) + fabric + fio suite
#     fio    <label> <mountpoint>   fio suite only (use on extra clients for aggregate runs)
#     fabric <label>                iperf3 (IPoIB/TCP) + perftest (raw RDMA) to the server
#     env    <label> <server|client> [mountpoint]   config snapshot of THIS host
#     check                         report missing tools
#
#   Settings (environment variables)
#     RESULTS=./results     where results/<label>/... is written (use local disk)
#     SERVER_SSH=           ssh target for the NFS server, e.g. root@nas01 (enables server capture)
#     SERVER_IB_IP=         server IPoIB address (needed for fabric tests)
#     IBDEV=mlx5_0          RDMA device on this host         SRV_IBDEV defaults to IBDEV
#     IPOIB_IF=ib0          IPoIB interface on this host     SRV_IPOIB_IF defaults to IPOIB_IF
#     ZPOOL=                pool name for zpool iostat (empty = all pools)
#     SIZE=8G               file size per fio job
#     RUNTIME=60 RAMP=10    seconds per fio test (measured) and warm-up (discarded)
#     TESTS=all             comma list of test names to run (see TEST_DEFS below)
#     SKIP_FABRIC=0         set 1 to skip fabric tests in "run"
#
# Example:
#   SERVER_SSH=root@nas01 SERVER_IB_IP=10.10.0.1 ZPOOL=tank \
#     ./nfsbench.sh run baseline /mnt/scratch

set -uo pipefail

RESULTS=${RESULTS:-./results}
SERVER_SSH=${SERVER_SSH:-}
SERVER_IB_IP=${SERVER_IB_IP:-}
IBDEV=${IBDEV:-mlx5_0}
IPOIB_IF=${IPOIB_IF:-ib0}
SRV_IBDEV=${SRV_IBDEV:-$IBDEV}
SRV_IPOIB_IF=${SRV_IPOIB_IF:-$IPOIB_IF}
ZPOOL=${ZPOOL:-}
SIZE=${SIZE:-8G}
RUNTIME=${RUNTIME:-60}
RAMP=${RAMP:-10}
TESTS=${TESTS:-all}
SKIP_FABRIC=${SKIP_FABRIC:-0}
HOST=$(hostname -s)
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)

# name            rw         bs   iodepth numjobs
TEST_DEFS=(
  "seq_write_1m   write      1M   16      4"
  "seq_read_1m    read       1M   16      4"
  "rand_write_4k  randwrite  4k   32      8"
  "rand_read_4k   randread   4k   32      8"
  "mixed_64k_70r  randrw     64k  16      4"
  "lat_write_4k   randwrite  4k   1       1"
  "lat_read_4k    randread   4k   1       1"
)

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }
kv()   { printf '%s=%s\n' "$1" "$2"; }
sect() { printf '\n===== %s =====\n' "$1"; }
srv()  { ssh "${SSH_OPTS[@]}" "$SERVER_SSH" "$@"; }

# ---------------------------------------------------------------- env snapshot
envprint() {
  local role=${1:-client} mnt=${2:-}
  echo "#### KV"
  kv role "$role"
  kv host "$(hostname -s)"
  kv date "$(date -Is)"
  kv os "$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
  kv kernel "$(uname -r)"
  kv cpu_model "$(LC_ALL=C lscpu | awk -F: '/^Model name/{sub(/^ +/,"",$2);print $2;exit}')"
  kv cpu_sockets "$(LC_ALL=C lscpu | awk -F: '/^Socket\(s\)/{gsub(/ /,"",$2);print $2;exit}')"
  kv cpu_logical "$(nproc --all)"
  kv numa_nodes "$(LC_ALL=C lscpu | awk -F: '/^NUMA node\(s\)/{gsub(/ /,"",$2);print $2;exit}')"
  kv mem_gib "$(awk '/MemTotal/{printf "%.0f",$2/1048576}' /proc/meminfo)"
  kv ib_link_layer "$(ibv_devinfo -d "$IBDEV" 2>/dev/null | awk '/link_layer/{print $2;exit}')"
  kv ib_active_mtu "$(ibv_devinfo -d "$IBDEV" 2>/dev/null | awk '/active_mtu/{print $2;exit}')"
  kv ib_rate "$(cat /sys/class/infiniband/"$IBDEV"/ports/1/rate 2>/dev/null)"
  kv ipoib_mode "$(cat /sys/class/net/"$IPOIB_IF"/mode 2>/dev/null)"
  kv ipoib_mtu "$(cat /sys/class/net/"$IPOIB_IF"/mtu 2>/dev/null)"
  kv rpcrdma_loaded "$(lsmod | awk '$1=="rpcrdma"{f=1} END{print f?"yes":"no"}')"
  if [[ $role == server ]]; then
    kv nfsd_threads "$(cat /proc/fs/nfsd/threads 2>/dev/null)"
    kv nfsd_listeners "$(paste -sd' ' /proc/fs/nfsd/portlist 2>/dev/null)"
    kv nfsd_versions "$(cat /proc/fs/nfsd/versions 2>/dev/null)"
    kv sunrpc_pool_mode "$(cat /sys/module/sunrpc/parameters/pool_mode 2>/dev/null)"
    kv zfs_version "$(cat /sys/module/zfs/version 2>/dev/null)"
    kv arc_max_gib "$(awk '$1=="c_max"{printf "%.1f",$3/1073741824}' /proc/spl/kstat/zfs/arcstats 2>/dev/null)"
  else
    kv nfs_mountpoint "$(findmnt -no TARGET --target "$mnt" 2>/dev/null)"
    kv nfs_source "$(findmnt -no SOURCE --target "$mnt" 2>/dev/null)"
    kv nfs_fstype "$(findmnt -no FSTYPE --target "$mnt" 2>/dev/null)"
    kv nfs_mount_opts "$(findmnt -no OPTIONS --target "$mnt" 2>/dev/null)"
  fi
  echo "#### RAW"
  sect "ibstat";            ibstat 2>&1
  sect "ibv_devinfo";       ibv_devinfo -d "$IBDEV" 2>&1
  sect "ip link";           ip -d link show "$IPOIB_IF" 2>&1
  sect "ipoib module";      grep -H . /sys/module/ib_ipoib/parameters/* 2>/dev/null
  sect "lscpu";             lscpu 2>&1
  if [[ $role == server ]]; then
    sect "/etc/nfs.conf (active lines)"; grep -Ev '^\s*(#|$)' /etc/nfs.conf 2>&1
    sect "exportfs -v";     exportfs -v 2>&1
    sect "pool_stats";      cat /proc/fs/nfsd/pool_stats 2>&1
    sect "nfsstat -s";      nfsstat -s 2>&1
    sect "zpool status";    zpool status 2>&1
    sect "zpool list";      zpool list -v 2>&1
    sect "zfs props";       zfs get -t filesystem -o name,property,value \
                              recordsize,compression,sync,atime,primarycache,logbias,xattr 2>&1
    sect "arc_summary";     (arc_summary -s arc 2>/dev/null || arc_summary 2>&1) | head -60
  else
    sect "nfsstat -m";      nfsstat -m 2>&1
  fi
}

cmd_env() {
  local label=$1 role=$2 mnt=${3:-}
  local d="$RESULTS/$label/env"; mkdir -p "$d"
  envprint "$role" "$mnt" > "$d/$role-$HOST.txt"
  log "env snapshot -> $d/$role-$HOST.txt"
}

server_env() {
  local label=$1
  [[ -n $SERVER_SSH ]] || { log "SERVER_SSH not set; skipping server snapshot"; return; }
  local d="$RESULTS/$label/env"; mkdir -p "$d"
  local shost; shost=$(srv hostname -s) || { log "cannot ssh to $SERVER_SSH"; return; }
  srv "IBDEV=$SRV_IBDEV IPOIB_IF=$SRV_IPOIB_IF bash -s -- envprint server" < "$0" \
    > "$d/server-$shost.txt"
  log "server env snapshot -> $d/server-$shost.txt"
}

# ---------------------------------------------------------------- fabric tests
perftest_pair() {   # $1=tool $2=outfile, remaining = extra args
  local tool=$1 out=$2; shift 2
  srv "timeout 90 $tool -d $SRV_IBDEV -F $*" > "$out.server" 2>&1 &
  local spid=$!
  sleep 2
  timeout 90 "$tool" -d "$IBDEV" -F "$@" "$SERVER_IB_IP" > "$out" 2>&1 \
    || log "$tool client exited non-zero (see $out)"
  wait "$spid" 2>/dev/null
}

cmd_fabric() {
  local label=$1
  [[ -n $SERVER_SSH && -n $SERVER_IB_IP ]] || die "fabric needs SERVER_SSH and SERVER_IB_IP"
  local d="$RESULTS/$label/fabric"; mkdir -p "$d"
  log "fabric: iperf3 over IPoIB (TCP) to $SERVER_IB_IP"
  srv "pkill -x iperf3; iperf3 -s -D -1" >/dev/null 2>&1
  sleep 1
  iperf3 -c "$SERVER_IB_IP" -P 8 -t 20 -J > "$d/iperf3_tcp.json" 2>&1 \
    || log "iperf3 failed (see $d/iperf3_tcp.json)"
  log "fabric: ib_write_bw / ib_read_bw / ib_read_lat (raw RDMA)"
  perftest_pair ib_write_bw "$d/ib_write_bw.txt" --report_gbits -D 10 -q 4 -s 1048576
  perftest_pair ib_read_bw  "$d/ib_read_bw.txt"  --report_gbits -D 10 -q 4 -s 1048576
  perftest_pair ib_read_lat "$d/ib_read_lat.txt" -n 10000
}

# ---------------------------------------------------------------- fio suite
selected() { [[ $TESTS == all ]] || [[ ",$TESTS," == *",$1,"* ]]; }

cmd_fio() {
  local label=$1 mnt=$2
  [[ -d $mnt ]] || die "mountpoint $mnt not found"
  local base="$RESULTS/$label"
  local fdir="$base/fio/$HOST" cdir="$base/client/$HOST" sdir="$base/server"
  local wdir="$mnt/nfsbench.$HOST"
  mkdir -p "$fdir" "$cdir" || die "cannot create $base"
  mkdir -p "$wdir" || die "cannot create $wdir on the NFS mount"
  {
    kv label "$label"; kv host "$HOST"; kv date "$(date -Is)"
    kv mountpoint "$(findmnt -no TARGET --target "$mnt")"
    kv workdir "$wdir"; kv size_per_job "$SIZE"; kv runtime "$RUNTIME"; kv ramp "$RAMP"
    kv fio_version "$(fio --version 2>/dev/null)"
  } > "$cdir/meta.txt"
  [[ -n $SERVER_SSH ]] && mkdir -p "$sdir"

  local def name rw bs qd nj extra
  for def in "${TEST_DEFS[@]}"; do
    read -r name rw bs qd nj <<< "$def"
    selected "$name" || continue
    extra=()
    [[ $rw == randrw ]] && extra+=(--rwmixread=70)
    log "fio: $name (rw=$rw bs=$bs iodepth=$qd numjobs=$nj size=$SIZE)"

    cp /proc/self/mountstats "$cdir/$name.mountstats.before"
    (sleep "$RAMP"; LC_ALL=C mpstat 1 "$RUNTIME" > "$cdir/$name.mpstat.txt" 2>&1) &
    if [[ -n $SERVER_SSH ]]; then
      srv cat /proc/fs/nfsd/pool_stats > "$sdir/$name.pool_stats.before" 2>&1
      srv "sleep $RAMP; LC_ALL=C mpstat 1 $RUNTIME" > "$sdir/$name.mpstat.txt" 2>&1 &
      srv "sleep $RAMP; zpool iostat -y $ZPOOL 1 $RUNTIME" > "$sdir/$name.zpool_iostat.txt" 2>&1 &
    fi

    fio --name="$name" --directory="$wdir" --filename_format='nfsbench.$jobnum' \
        --rw="$rw" --bs="$bs" --iodepth="$qd" --numjobs="$nj" --size="$SIZE" \
        --ioengine=libaio --direct=1 --invalidate=1 --fallocate=none --randrepeat=0 \
        --time_based --runtime="$RUNTIME" --ramp_time="$RAMP" --group_reporting \
        "${extra[@]}" --output-format=json --output="$fdir/$name.json" \
      || log "fio $name failed (see $fdir/$name.json)"

    wait
    cp /proc/self/mountstats "$cdir/$name.mountstats.after"
    [[ -n $SERVER_SSH ]] && srv cat /proc/fs/nfsd/pool_stats > "$sdir/$name.pool_stats.after" 2>&1
  done
  log "fio suite done. Test files left in $wdir (remove with: rm -rf $wdir)"
}

cmd_check() {
  local t missing=0
  for t in fio mpstat iperf3 ib_write_bw ib_read_bw ib_read_lat ibstat ibv_devinfo findmnt nfsstat; do
    command -v "$t" >/dev/null || { echo "missing: $t"; missing=1; }
  done
  [[ $missing == 0 ]] && echo "all client-side tools present"
  echo "packages: dnf install fio sysstat iperf3 perftest infiniband-diags libibverbs-utils nfs-utils"
}

cmd_run() {
  local label=$1 mnt=$2
  [[ -e $RESULTS/$label ]] && log "note: $RESULTS/$label exists; files will be overwritten"
  cmd_env "$label" client "$mnt"
  server_env "$label"
  if [[ $SKIP_FABRIC != 1 && -n $SERVER_IB_IP && -n $SERVER_SSH ]]; then
    cmd_fabric "$label"
  else
    log "skipping fabric tests (need SERVER_SSH + SERVER_IB_IP, SKIP_FABRIC!=1)"
  fi
  cmd_fio "$label" "$mnt"
  log "done. Generate the report with: python3 nfs_report.py $RESULTS/<before> $RESULTS/<after>"
}

case ${1:-} in
  run)      [[ $# -eq 3 ]] || die "usage: $0 run <label> <mountpoint>";    cmd_run "$2" "$3" ;;
  fio)      [[ $# -eq 3 ]] || die "usage: $0 fio <label> <mountpoint>";    cmd_fio "$2" "$3" ;;
  fabric)   [[ $# -eq 2 ]] || die "usage: $0 fabric <label>";              cmd_fabric "$2" ;;
  env)      [[ $# -ge 3 ]] || die "usage: $0 env <label> <server|client> [mountpoint]"
            cmd_env "$2" "$3" "${4:-}" ;;
  envprint) envprint "${2:-client}" "${3:-}" ;;
  check)    cmd_check ;;
  *)        sed -n '2,32p' "$0"; exit 1 ;;
esac

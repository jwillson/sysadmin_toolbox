#!/usr/bin/env bash
# nfsbench.sh — capture NFS / InfiniBand performance metrics so a "before" and
# "after" run can be compared with nfs_report.py.
#
# Run it on an NFS CLIENT (compute node). With SERVER_SSH set it also captures
# server-side config, CPU, nfsd thread pressure and storage I/O over ssh
# (zpool iostat on ZFS servers, iostat -x otherwise).
#
# Works on EL7-EL10 and Ubuntu 24.04/26.04, on clients and servers alike.
#
#   Subcommands
#     run    <label> <mountpoint>   env snapshot (client+server) + fabric + fio suite
#     fio    <label> <mountpoint>   fio suite only (use on extra clients for aggregate runs)
#     local  <label> <directory>    on the NAS itself: fio suite against the dataset, no NFS
#                                   (storage maximum; use SIZE large enough to exceed RAM/ARC)
#     fabric <label>                iperf3 (IPoIB/TCP) + perftest (raw RDMA) to the server
#     env    <label> <server|client> [mountpoint]   config snapshot of THIS host
#     check                         report missing tools
#
#   Settings (environment variables)
#     RESULTS=./results     where results/<label>/... is written (use local disk)
#     SERVER_SSH=           ssh target for the NFS server, e.g. root@nas01 (enables server capture)
#     SERVER_IB_IP=         server IPoIB address (needed for fabric tests)
#     IPOIB_IF=             IPoIB interface on this host (default: first one found)
#     IBDEV=                RDMA device on this host (default: the one carrying IPOIB_IF)
#     SRV_IPOIB_IF= SRV_IBDEV=   same for the server (default: detected on the server)
#     ZPOOL=                ZFS servers: pool for zpool iostat (empty = all pools)
#     SIZE=8G               file size per fio job
#     RUNTIME=60 RAMP=10    seconds per fio test (measured) and warm-up (discarded)
#     TESTS=all             comma list of test names to run (see TEST_DEFS below)
#     META_JOBS=8 META_FILES=5000   metadata tests: parallel jobs, files per job
#     SKIP_FABRIC=0         set 1 to skip fabric tests in "run"
#
# Example:
#   SERVER_SSH=root@nas01 SERVER_IB_IP=10.10.0.1 \
#     ./nfsbench.sh run baseline /mnt/scratch

set -uo pipefail

RESULTS=${RESULTS:-./results}
SERVER_SSH=${SERVER_SSH:-}
SERVER_IB_IP=${SERVER_IB_IP:-}
first_ipoib() { local n; for n in /sys/class/net/*; do [[ $(cat "$n/type" 2>/dev/null) == 32 ]] && { echo "${n##*/}"; return; }; done; }
ipoib_ibdev() { ls "/sys/class/net/$1/device/infiniband" 2>/dev/null | head -1; }
IPOIB_IF=${IPOIB_IF:-$(first_ipoib)}
IBDEV=${IBDEV:-$(ipoib_ibdev "$IPOIB_IF")}
IBDEV=${IBDEV:-$(ls /sys/class/infiniband 2>/dev/null | head -1)}
SRV_IBDEV=${SRV_IBDEV:-}
SRV_IPOIB_IF=${SRV_IPOIB_IF:-}
ZPOOL=${ZPOOL:-}
SIZE=${SIZE:-8G}
RUNTIME=${RUNTIME:-60}
RAMP=${RAMP:-10}
TESTS=${TESTS:-all}
META_JOBS=${META_JOBS:-8}
META_FILES=${META_FILES:-5000}
LOCAL=0
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
  # metadata: empty files, timed per operation; run in this order (stat and delete reuse the created files)
  "meta_create    filecreate -    1       $META_JOBS"
  "meta_stat      filestat   -    1       $META_JOBS"
  "meta_delete    filedelete -    1       $META_JOBS"
)
# Open-ended samplers (metadata tests run for a file count, not a time) use this sample
# count as a marker so samplers_stop can find them.
OPEN_COUNT=86399
SAMPLER_RE="^(mpstat|iostat|zpool iostat)( .*)? 1 $OPEN_COUNT\$"

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }
kv()   { printf '%s=%s\n' "$1" "$2"; }
sect() { printf '\n===== %s =====\n' "$1"; }
srv()  { ssh "${SSH_OPTS[@]}" "$SERVER_SSH" "$@"; }
srv_ibdev() {   # RDMA device on the server, detected once
  [[ -n $SRV_IBDEV ]] && return
  SRV_IBDEV=$(srv 'for n in /sys/class/net/*; do [ "$(cat $n/type 2>/dev/null)" = 32 ] && { ls $n/device/infiniband 2>/dev/null | head -1; exit; }; done; ls /sys/class/infiniband | head -1')
}

# ---------------------------------------------------------------- env snapshot
envprint() {
  local role=${1:-client} mnt=${2:-}
  echo "#### KV"
  kv role "$role"
  kv host "$(hostname -s)"
  kv date "$(date -Is)"
  kv os "$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
  kv kernel "$(uname -r)"
  kv platform "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) $(cat /sys/class/dmi/id/product_name 2>/dev/null)"
  kv cpu_model "$(LC_ALL=C lscpu | awk -F: '/^Model name/{sub(/^ +/,"",$2);print $2;exit}')"
  kv cpu_sockets "$(LC_ALL=C lscpu | awk -F: '/^Socket\(s\)/{gsub(/ /,"",$2);print $2;exit}')"
  kv cpu_logical "$(nproc --all)"
  kv numa_nodes "$(LC_ALL=C lscpu | awk -F: '/^NUMA node\(s\)/{gsub(/ /,"",$2);print $2;exit}')"
  kv mem_gib "$(awk '/MemTotal/{printf "%.0f",$2/1048576}' /proc/meminfo)"
  kv ib_link_layer "$(ibv_devinfo -d "$IBDEV" 2>/dev/null | awk '/link_layer/{print $2;exit}')"
  kv ib_active_mtu "$(ibv_devinfo -d "$IBDEV" 2>/dev/null | awk '/active_mtu/{print $2;exit}')"
  kv ib_rate "$(cat /sys/class/infiniband/"$IBDEV"/ports/1/rate 2>/dev/null)"
  kv ib_device "$IBDEV"
  kv ib_driver "$(basename "$(readlink /sys/class/infiniband/"$IBDEV"/device/driver 2>/dev/null)" 2>/dev/null)"
  local ibs=/sys/class/infiniband/$IBDEV
  kv hca "$([[ -n $IBDEV && -e $ibs ]] && echo "$(cat "$ibs/hca_type" 2>/dev/null) fw $(cat "$ibs/fw_ver" 2>/dev/null)")"
  kv pcie_link "$([[ -n $IBDEV && -e $ibs/device/current_link_width ]] && echo "$(cat "$ibs/device/current_link_speed") x$(cat "$ibs/device/current_link_width")")"
  kv ipoib_mode "$(cat /sys/class/net/"$IPOIB_IF"/mode 2>/dev/null)"
  kv ipoib_mtu "$(cat /sys/class/net/"$IPOIB_IF"/mtu 2>/dev/null)"
  kv rpcrdma_loaded "$(lsmod | awk '$1=="rpcrdma"{f=1} END{print f?"yes":"no"}')"
  if [[ $role == server ]]; then
    kv nfsd_threads "$(cat /proc/fs/nfsd/threads 2>/dev/null)"
    kv nfsd_listeners "$(paste -sd' ' /proc/fs/nfsd/portlist 2>/dev/null)"
    kv nfsd_versions "$(cat /proc/fs/nfsd/versions 2>/dev/null)"
    kv sunrpc_pool_mode "$(cat /sys/module/sunrpc/parameters/pool_mode 2>/dev/null)"
    kv storage "$(exportfs -s 2>/dev/null | awk 'NF{print $1}' | sort -u | while read -r p; do findmnt -no FSTYPE -T "$p"; done | sort | uniq -c | awk '{printf "%s%s x%s", (NR>1?", ":""), $2, $1}')"
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
    if command -v nfsconf >/dev/null; then
      sect "nfsconf --dump (nfs.conf + nfs.conf.d)"; nfsconf --dump 2>&1
    else
      sect "/etc/sysconfig/nfs (active lines)"; grep -Ev '^\s*(#|$)' /etc/sysconfig/nfs 2>&1
    fi
    sect "exportfs -v";     exportfs -v 2>&1
    sect "pool_stats";      cat /proc/fs/nfsd/pool_stats 2>&1
    sect "nfsstat -s";      nfsstat -s 2>&1
    sect "exported filesystems"
    exportfs -s 2>/dev/null | awk 'NF{print $1}' | sort -u | while read -r p; do
      findmnt -no TARGET,FSTYPE,SOURCE,OPTIONS -T "$p"; done 2>&1
    sect "lsblk";           lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT,MODEL 2>&1
    [ -r /proc/mdstat ] && { sect "mdstat"; cat /proc/mdstat; }
    if command -v zpool >/dev/null && [ -n "$(zpool list -H -o name 2>/dev/null)" ]; then
      sect "zpool status";  zpool status 2>&1
      sect "zpool list";    zpool list -v 2>&1
      sect "zfs props";     zfs get -t filesystem -o name,property,value \
                              recordsize,compression,sync,atime,primarycache,logbias,xattr 2>&1
      sect "arc_summary";   (arc_summary -s arc 2>/dev/null || arc_summary 2>&1) | head -60
    fi
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
  srv "IBDEV='$SRV_IBDEV' IPOIB_IF='$SRV_IPOIB_IF' bash -s -- envprint server" < "$0" \
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
  srv_ibdev
  [[ -n $IBDEV && -n $SRV_IBDEV ]] || die "no RDMA device found (client: '$IBDEV', server: '$SRV_IBDEV'); set IBDEV/SRV_IBDEV"
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

storage_cmd() {   # storage I/O sampler: zpool iostat on ZFS hosts, iostat -x otherwise
  echo "if command -v zpool >/dev/null && [ -n \"\$(zpool list -H -o name 2>/dev/null)\" ]; then zpool iostat -y $ZPOOL 1 $1; else LC_ALL=C iostat -dxmy 1 $1; fi"
}

# samplers_start <name> <delay> <count>: CPU and storage samplers for one test.
# NFS mode: client mpstat locally, server mpstat + storage over ssh. Local mode: all on this host.
samplers_start() {
  local name=$1 delay=$2 count=$3
  if ((LOCAL)); then
    (sleep "$delay"; LC_ALL=C exec mpstat 1 "$count") > "$sdir/$name.mpstat.txt" 2>&1 &
    (sleep "$delay"; eval "$(storage_cmd "$count")") > "$sdir/$name.storage_iostat.txt" 2>&1 &
    return
  fi
  (sleep "$delay"; LC_ALL=C exec mpstat 1 "$count") > "$cdir/$name.mpstat.txt" 2>&1 &
  if [[ -n $SERVER_SSH ]]; then
    srv "sleep $delay; LC_ALL=C exec mpstat 1 $count" > "$sdir/$name.mpstat.txt" 2>&1 &
    srv "sleep $delay; $(storage_cmd "$count")" > "$sdir/$name.storage_iostat.txt" 2>&1 &
  fi
}

# samplers_stop: end open-ended samplers. SIGINT first so mpstat prints its averages.
samplers_stop() {
  if [[ -n $SERVER_SSH ]] && ! ((LOCAL)); then
    srv "pkill -INT -f '$SAMPLER_RE'; sleep 1; pkill -f '$SAMPLER_RE'" >/dev/null 2>&1
  fi
  pkill -INT -f "$SAMPLER_RE"; sleep 1; pkill -f "$SAMPLER_RE"
  return 0
}

cmd_fio() {
  local label=$1 mnt=$2
  [[ -d $mnt ]] || die "$mnt not found"
  local base="$RESULTS/$label"
  local fdir="$base/fio/$HOST" cdir="$base/client/$HOST" sdir="$base/server"
  local wdir="$mnt/nfsbench.$HOST"
  mkdir -p "$fdir" "$cdir" || die "cannot create $base"
  mkdir -p "$wdir" || die "cannot create $wdir"
  {
    kv label "$label"; kv host "$HOST"; kv date "$(date -Is)"
    if ((LOCAL)); then kv capture "local on the NAS (no NFS)"; else kv capture "NFS client"; fi
    kv mountpoint "$(findmnt -no TARGET --target "$mnt")"
    kv workdir "$wdir"; kv size_per_job "$SIZE"; kv runtime "$RUNTIME"; kv ramp "$RAMP"
    kv meta_files "$META_JOBS jobs x $META_FILES files"
    kv fio_version "$(fio --version 2>/dev/null)"
  } > "$cdir/meta.txt"
  { ((LOCAL)) || [[ -n $SERVER_SSH ]]; } && mkdir -p "$sdir"

  local def name rw bs qd nj extra meta engines
  engines=$(fio --enghelp 2>/dev/null)
  for def in "${TEST_DEFS[@]}"; do
    read -r name rw bs qd nj <<< "$def"
    selected "$name" || continue
    meta=0; [[ $rw == file* ]] && meta=1
    if ((meta)) && ! grep -qw "$rw" <<< "$engines"; then
      log "fio: skipping $name (this fio has no $rw engine; check fio --enghelp)"; continue
    fi

    if ! ((LOCAL)); then
      cp /proc/self/mountstats "$cdir/$name.mountstats.before"
      [[ -n $SERVER_SSH ]] && srv cat /proc/fs/nfsd/pool_stats > "$sdir/$name.pool_stats.before" 2>&1
    fi

    if ((meta)); then
      log "fio: $name ($rw, $nj jobs x $META_FILES files)"
      [[ $name == meta_create ]] && rm -f "$wdir"/nfsbench-meta.* 2>/dev/null
      samplers_start "$name" 0 "$OPEN_COUNT"
      fio --name="$name" --directory="$wdir" --filename_format='nfsbench-meta.$jobnum.$filenum' \
          --ioengine="$rw" --filesize=4k --nrfiles="$META_FILES" --openfiles=1 --create_on_open=1 \
          --numjobs="$nj" --group_reporting --output-format=json --output="$fdir/$name.json" \
        || log "fio $name failed (see $fdir/$name.json)"
      samplers_stop
    else
      extra=()
      [[ $rw == randrw ]] && extra+=(--rwmixread=70)
      log "fio: $name (rw=$rw bs=$bs iodepth=$qd numjobs=$nj size=$SIZE)"
      samplers_start "$name" "$RAMP" "$RUNTIME"
      fio --name="$name" --directory="$wdir" --filename_format='nfsbench.$jobnum' \
          --rw="$rw" --bs="$bs" --iodepth="$qd" --numjobs="$nj" --size="$SIZE" \
          --ioengine=libaio --direct=1 --invalidate=1 --fallocate=none --randrepeat=0 \
          --time_based --runtime="$RUNTIME" --ramp_time="$RAMP" --group_reporting \
          "${extra[@]}" --output-format=json --output="$fdir/$name.json" \
        || log "fio $name failed (see $fdir/$name.json)"
    fi

    wait
    if ! ((LOCAL)); then
      cp /proc/self/mountstats "$cdir/$name.mountstats.after"
      [[ -n $SERVER_SSH ]] && srv cat /proc/fs/nfsd/pool_stats > "$sdir/$name.pool_stats.after" 2>&1
    fi
  done
  log "fio suite done. Test files left in $wdir (remove with: rm -rf $wdir)"
}

cmd_local() {   # on the NAS: storage maximum without NFS
  local label=$1 dir=$2
  LOCAL=1 SERVER_SSH=""
  local fs; fs=$(findmnt -no FSTYPE --target "$dir" 2>/dev/null)
  [[ $fs == nfs* ]] && die "$dir is on NFS; 'local' runs on the NAS against the exported dataset"
  local mem_k jobs bytes
  mem_k=$(awk '/MemTotal/{print $2}' /proc/meminfo)
  bytes=$(numfmt --from=iec "${SIZE%B}" 2>/dev/null || echo 0)
  jobs=4   # sequential tests' numjobs
  if (( bytes * jobs < mem_k * 1024 )); then
    log "warning: $jobs x SIZE=$SIZE is less than RAM ($((mem_k / 1048576)) GiB); reads will come from cache."
    log "         For a storage maximum use e.g. SIZE=$(( (mem_k / 1048576 + jobs - 1) / jobs * 2 ))G (total about 2x RAM)."
  fi
  [[ $fs == zfs ]] && log "note: before ZFS 2.3, O_DIRECT does not bypass the ARC; only a data set larger than the ARC measures the disks"
  cmd_env "$label" server
  cmd_fio "$label" "$dir"
  log "done. Compare with an NFS run: python3 nfs_report.py $RESULTS/<nfs-run> $RESULTS/$label"
}

cmd_check() {
  local t missing=0
  for t in fio mpstat iperf3 ib_write_bw ib_read_bw ib_read_lat ibstat ibv_devinfo findmnt nfsstat; do
    command -v "$t" >/dev/null || { echo "missing: $t"; missing=1; }
  done
  [[ $missing == 0 ]] && echo "all client-side tools present"
  if command -v fio >/dev/null; then
    local e eng; eng=$(fio --enghelp 2>/dev/null)
    for e in filecreate filestat filedelete; do
      grep -qw "$e" <<< "$eng" || echo "fio $(fio --version) lacks the $e engine: the meta_* tests will be skipped"
    done
  fi
  [[ -n $IBDEV ]] && echo "RDMA device: $IBDEV, IPoIB: ${IPOIB_IF:-none}" || echo "missing: no RDMA device found"
  local id="" like="" ver=""
  [[ -r /etc/os-release ]] && { id=$(. /etc/os-release; echo "${ID:-}"); like=$(. /etc/os-release; echo "${ID_LIKE:-}"); ver=$(. /etc/os-release; echo "${VERSION_ID:-}"); }
  case " $id $like " in
    *" ubuntu "*|*" debian "*) echo "packages: apt-get install fio sysstat iperf3 perftest infiniband-diags ibverbs-utils nfs-common" ;;
    *) local pm=dnf; [[ ${ver%%.*} == 7 ]] && pm=yum
       echo "packages: $pm install fio sysstat iperf3 perftest infiniband-diags libibverbs-utils nfs-utils" ;;
  esac
  echo "the NFS server also needs sysstat (mpstat, iostat) for server-side capture"
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
  local)    [[ $# -eq 3 ]] || die "usage: $0 local <label> <directory>";   cmd_local "$2" "$3" ;;
  fabric)   [[ $# -eq 2 ]] || die "usage: $0 fabric <label>";              cmd_fabric "$2" ;;
  env)      [[ $# -ge 3 ]] || die "usage: $0 env <label> <server|client> [mountpoint]"
            cmd_env "$2" "$3" "${4:-}" ;;
  envprint) envprint "${2:-client}" "${3:-}" ;;
  check)    cmd_check ;;
  *)        sed -n '2,/^$/p' "$0"; exit 1 ;;
esac

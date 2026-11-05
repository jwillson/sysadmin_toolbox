#!/usr/bin/env bash
# nfs-rdma-preflight.sh — read-only dry run of the NFS-over-RDMA migration on a NAS.
#
# Changes nothing: no modprobe, no config edits, no service restarts, no network
# changes, no exportfs. It discovers the host (distribution, platform, CPU,
# storage behind the exports, HCA model, driver and PCIe slot, IPoIB and the tool
# that configures it, NFS config style), flags blockers, works out the values for
# this host, and prints the exact commands for each step, split into what can be
# done live and what needs the maintenance window.
#
# Supported: EL7, EL8, EL9, EL10 (RHEL, Rocky, Alma, Springdale, CentOS) and
# Ubuntu Server 24.04 / 26.04. Other systemd distributions get the same checks
# with an "untested" warning.
#
# Writes only:  $OUT/preflight-<host>-<timestamp>/
#                 report.txt                  everything printed to the screen
#                 nfs.conf.orig / .proposed   current and planned /etc/nfs.conf
#                   (EL7: sysconfig-nfs.orig / .proposed for /etc/sysconfig/nfs)
#                 nfs-clients.txt             hosts currently connected over TCP 2049
#
# Usage:  ./nfs-rdma-preflight.sh [sample_seconds]
#   sample_seconds  seconds to sample nfsd thread pressure (default 30, 0 = skip)
#
# Settings (environment):
#   OUT=/root/nfs-tuning   TARGET_IB_MTU=4096   RDMA_PORT=20049
#   THREADS=               override the computed nfsd thread count
#   IPOIB_IF=              IPoIB interface (default: first one found)
#   Testing only: NFS_CONF=/etc/nfs.conf  SYSCONFIG_NFS=/etc/sysconfig/nfs
#                 NFSD_PROC=/proc/fs/nfsd  NFS_STYLE=nfsconf|sysconfig

set -uo pipefail
export LC_ALL=C

SAMPLE=${1:-30}
[[ $SAMPLE =~ ^[0-9]+$ ]] || { echo "usage: $0 [sample_seconds]" >&2; exit 1; }
OUT=${OUT:-/root/nfs-tuning}
TARGET_IB_MTU=${TARGET_IB_MTU:-4096}
RDMA_PORT=${RDMA_PORT:-20049}
NFS_CONF=${NFS_CONF:-/etc/nfs.conf}
SYSCONFIG_NFS=${SYSCONFIG_NFS:-/etc/sysconfig/nfs}
NFSD_PROC=${NFSD_PROC:-/proc/fs/nfsd}
HOST=$(hostname -s)
DIR="$OUT/preflight-$HOST-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DIR" || { echo "cannot create $DIR" >&2; exit 1; }
exec > >(tee "$DIR/report.txt") 2>&1

NPASS=0 NWARN=0 NFAIL=0
LIVE=() WINDOW=() OPTIONAL=() VERIFY=() PROFILE=()
pass()    { printf '  [ OK ] %s\n' "$*"; NPASS=$((NPASS + 1)); }
warn()    { printf '  [WARN] %s\n' "$*"; NWARN=$((NWARN + 1)); }
fail()    { printf '  [FAIL] %s\n' "$*"; NFAIL=$((NFAIL + 1)); }
info()    { printf '  [info] %s\n' "$*"; }
head1()   { printf '\n== %s ==\n' "$*"; }
have()    { command -v "$1" >/dev/null 2>&1; }
live()    { LIVE+=("$1"); }
window()  { WINDOW+=("$1"); }
optional() { OPTIONAL+=("$1"); }
verify()  { VERIFY+=("$1"); }
profile() { PROFILE+=("$(printf '%-9s %s' "$1:" "$2")"); }
mtu_code() { case $1 in 256) echo 1;; 512) echo 2;; 1024) echo 3;; 2048) echo 4;; 4096) echo 5;; *) echo "";; esac; }
rd()      { local v; { read -r v < "$1"; } 2>/dev/null && printf '%s' "$v"; }   # first line of a sysfs file
modfile() {   # modfile <kernel> <module>: module file or builtin entry exists
  find "/lib/modules/$1" \( -name "$2.ko" -o -name "$2.ko.*" \) 2>/dev/null | grep -q . ||
    grep -qs "/$2.ko\$" "/lib/modules/$1/modules.builtin"
}

echo "NFS over RDMA preflight (read-only) — $HOST — $(date '+%Y-%m-%d %H:%M %Z')"
echo "Report directory: $DIR"

# ------------------------------------------------------------------ host
head1 "Host"
OS_ID="" OS_LIKE="" OS_VER="" OSNAME="unknown OS"
if [[ -r /etc/os-release ]]; then
  eval "$(. /etc/os-release; printf 'OS_ID=%q OS_LIKE=%q OS_VER=%q OSNAME=%q' \
          "${ID:-}" "${ID_LIKE:-}" "${VERSION_ID:-}" "${PRETTY_NAME:-unknown OS}")"
fi
case " $OS_ID $OS_LIKE " in
  *" ubuntu "*|*" debian "*)            FAMILY=deb ;;
  *" rhel "*|*" centos "*|*" fedora "*) FAMILY=el ;;
  *)                                    FAMILY=other ;;
esac
MAJOR=${OS_VER%%.*}
EL7=0; [[ $FAMILY == el && $MAJOR == 7 ]] && EL7=1
case $FAMILY in
  el)  PKG=$([[ $EL7 == 1 ]] && echo yum || echo dnf)
       [[ $MAJOR =~ ^(7|8|9|10)$ ]] && pass "$OSNAME (EL$MAJOR, supported)" \
                                    || warn "$OSNAME: EL$MAJOR is untested; checks use EL defaults" ;;
  deb) PKG=apt-get
       [[ $OS_ID == ubuntu && $OS_VER =~ ^(24|26)\.04$ ]] && pass "$OSNAME (supported)" \
                                    || warn "$OSNAME is untested; checks use Ubuntu defaults" ;;
  *)   PKG="" ; warn "$OSNAME is untested; checks use generic paths" ;;
esac
info "kernel $(uname -r)"
profile OS "$OSNAME, kernel $(uname -r)"
[[ $EUID -eq 0 ]] || warn "not running as root: subnet manager, export, netplan and firewall checks will be incomplete"

vendor=$(rd /sys/class/dmi/id/sys_vendor); product=$(rd /sys/class/dmi/id/product_name)
bios=$(rd /sys/class/dmi/id/bios_version)
info "platform: ${vendor:-?} ${product:-?}, BIOS ${bios:-?}"
profile Platform "${vendor:-?} ${product:-?}"

logical=$(nproc --all)
lsc=$(lscpu 2>/dev/null)
sockets=$(awk -F: '/^Socket\(s\)/{gsub(/ /,"",$2);print $2;exit}' <<<"$lsc")
cps=$(awk -F: '/^Core\(s\) per socket/{gsub(/ /,"",$2);print $2;exit}' <<<"$lsc")
model=$(awk -F: '/^Model name/{sub(/^ +/,"",$2);print $2;exit}' <<<"$lsc")
numa=$(awk -F: '/^NUMA node\(s\)/{gsub(/ /,"",$2);print $2;exit}' <<<"$lsc")
physical=$(( ${sockets:-1} * ${cps:-1} ))
ramgib=$(awk '/MemTotal/{printf "%.0f", $2/1048576}' /proc/meminfo)
info "CPU: ${model:-?}; ${sockets:-?} socket(s), $physical cores, $logical logical CPUs, ${numa:-?} NUMA node(s)"
info "RAM: $ramgib GiB"
profile CPU "${sockets:-?} x ${model:-?}; $logical logical CPUs, ${numa:-?} NUMA node(s), $ramgib GiB RAM"

# ------------------------------------------------------------------ storage
head1 "Storage behind the exports"
EXPORTS=""
have exportfs && EXPORTS=$(exportfs -s 2>/dev/null)
mapfile -t EXPORT_PATHS < <(awk 'NF{print $1}' <<<"$EXPORTS" | sort -u)
uses_zfs=0
backends=""
if ((${#EXPORT_PATHS[@]})); then
  backends=$(for p in "${EXPORT_PATHS[@]}"; do
               findmnt -no FSTYPE,SOURCE -T "$p" 2>/dev/null | head -1
             done | awk '{t = $1; s = $2; if (t == "zfs") sub(/\/.*/, "", s); print t, s}' | sort | uniq -c)
  while read -r n t s; do
    [[ -n $t ]] || continue
    info "$n export(s) on $t ($s)"
    [[ $t == zfs ]] && uses_zfs=1
  done <<<"$backends"
  profile Storage "$(awk '{printf "%s%s on %s", (NR > 1 ? "; " : ""), $2, $3}' <<<"$backends")"
else
  info "no exports listed (not root, or nothing exported); storage checks cover what is present"
fi

if have zpool && [[ -n $(zpool list -H -o name 2>/dev/null) ]]; then
  ((${#EXPORT_PATHS[@]})) || uses_zfs=1
  st=$(zpool status -x 2>&1)
  if [[ $st == "all pools are healthy" ]]; then pass "ZFS: all pools healthy"
  else fail "ZFS pool status: $(head -3 <<<"$st" | tr '\n' ' ')— resolve or account for this before the window"; fi
  while read -r n s a h; do [[ -n $n ]] && info "pool $n: size $s, allocated $a, $h"; done \
    < <(zpool list -H -o name,size,alloc,health 2>/dev/null)
  info "ZFS $(rd /sys/module/zfs/version), ARC max $(awk '$1=="c_max"{printf "%.0f GiB", $3/1073741824}' /proc/spl/kstat/zfs/arcstats 2>/dev/null)"
elif ((uses_zfs)); then
  warn "exports are on ZFS but zpool is not available to this user"
fi

if grep -qs '^md' /proc/mdstat; then
  deg=$(awk '/^md/{d = $1} /\[[U_]+\]$/{ if ($NF ~ /_/) print d }' /proc/mdstat | paste -sd' ')
  [[ -n $deg ]] && fail "degraded md array(s): $deg — resolve before the window" \
                || pass "md arrays healthy ($(grep -c '^md' /proc/mdstat))"
fi

if have lspci; then
  while read -r c; do [[ -n $c ]] && info "storage controller: $c"; done \
    < <(lspci 2>/dev/null | sed -n -E 's/^[0-9a-f:.]+ (RAID bus controller|Serial Attached SCSI controller): //p' | sort -u)
fi
for cli in perccli64 perccli storcli64 storcli; do
  have "$cli" || continue
  vds=$("$cli" /call/vall show 2>/dev/null | awk '$1 ~ /^[0-9]+\/[0-9]+$/ {print $1, $2, $3}')
  if [[ -n $vds ]]; then
    bad=$(awk '$3 != "Optl"' <<<"$vds")
    [[ -n $bad ]] && fail "RAID virtual drive(s) not optimal ($cli): $(paste -sd';' <<<"$bad")" \
                  || pass "RAID virtual drives optimal ($(wc -l <<<"$vds"), $cli)"
  fi
  break
done

# ------------------------------------------------------------------ packages
head1 "Packages"
missing=()
case $FAMILY in
  el)  pkgs=(rdma-core nfs-utils infiniband-diags libibverbs-utils perftest) ;;
  deb) pkgs=(rdma-core nfs-kernel-server infiniband-diags ibverbs-utils perftest) ;;
  *)   pkgs=() ; info "unknown package manager: check rdma-core, NFS server, infiniband-diags, ibverbs utilities and perftest by hand" ;;
esac
for p in "${pkgs[@]}"; do
  if [[ $FAMILY == el ]] && rpm -q "$p" >/dev/null 2>&1; then
    pass "$p $(rpm -q --qf '%{VERSION}-%{RELEASE}' "$p")"
  elif [[ $FAMILY == deb ]] && dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'ok installed'; then
    pass "$p $(dpkg-query -W -f='${Version}' "$p")"
  else
    warn "$p not installed"; missing+=("$p")
  fi
done
((${#missing[@]})) && live "Install missing packages (no service impact)
    $PKG install -y ${missing[*]}"
have ofed_info && info "vendor OFED installed: $(ofed_info -s 2>/dev/null) — NFS/RDMA modules must come from it"

# ------------------------------------------------------------------ hca / pcie
head1 "HCA and PCIe slot"
declare -A HCA_NAME=([0x1003]="ConnectX-3" [0x1007]="ConnectX-3 Pro" [0x1011]="Connect-IB"
  [0x1013]="ConnectX-4" [0x1015]="ConnectX-4 Lx" [0x1017]="ConnectX-5" [0x1019]="ConnectX-5 Ex"
  [0x101b]="ConnectX-6" [0x101d]="ConnectX-6 Dx" [0x101f]="ConnectX-6 Lx" [0x1021]="ConnectX-7"
  [0x1023]="ConnectX-8")
declare -A PCIE_GBPS=() IBDEV_DRV=() IBDEV_HCA=()
IB_MODS=()
nhca=0
for d in /sys/bus/pci/devices/*; do
  [[ $(rd "$d/vendor") == 0x15b3 ]] || continue
  cls=$(rd "$d/class"); [[ $cls == 0x0207* || $cls == 0x0200* ]] || continue
  [[ -e $d/physfn ]] && continue                       # SR-IOV virtual function
  nhca=$((nhca + 1))
  pci=${d##*/}; devid=$(rd "$d/device"); name=${HCA_NAME[$devid]:-"Mellanox device $devid"}
  drv=""; [[ -L $d/driver ]] && drv=$(basename "$(readlink "$d/driver")")
  ibd=$(ls "$d/infiniband" 2>/dev/null | head -1)
  fw=""; [[ -n $ibd ]] && fw=$(rd "/sys/class/infiniband/$ibd/fw_ver")
  info "$pci $name: driver ${drv:-none}, RDMA device ${ibd:-none}, firmware ${fw:-?}, NUMA node $(rd "$d/numa_node")"
  if [[ -z $drv ]]; then
    if [[ $FAMILY == el && $MAJOR -ge 10 && ( $devid == 0x1003 || $devid == 0x1007 ) ]]; then
      fail "$pci $name has no driver: EL10 removed mlx4 (ConnectX-3). Use EL9 or older, Ubuntu, or a ConnectX-4 or newer HCA"
    else
      fail "$pci $name has no driver bound"
    fi
    continue
  fi
  case $drv in mlx5_core) IB_MODS+=(mlx5_ib) ;; mlx4_core) IB_MODS+=(mlx4_ib) ;; esac
  [[ -n $ibd ]] && { IBDEV_DRV[$ibd]=$drv; IBDEV_HCA[$ibd]=$name; }
  cs=$(rd "$d/current_link_speed"); cw=$(rd "$d/current_link_width")
  ms=$(rd "$d/max_link_speed");     mw=$(rd "$d/max_link_width")
  if [[ -n $cs && -n $cw ]]; then
    gbps=$(awk -v s="${cs%% *}" -v w="$cw" 'BEGIN { printf "%.0f", s * w * (s >= 8 ? 128 / 130 : 0.8) }')
    [[ -n $ibd ]] && PCIE_GBPS[$ibd]=$gbps
    if [[ ${cw:-0} -lt ${mw:-0} || ${cs%% *} != "${ms%% *}" ]]; then
      info "$pci runs at PCIe ${cs%% *} GT/s x$cw (about $gbps Gb/s); the card supports ${ms%% *} GT/s x$mw (fine if that still exceeds the IB link rate; checked below)"
    else
      info "$pci PCIe ${cs%% *} GT/s x$cw, about $gbps Gb/s usable"
    fi
  fi
done
((nhca)) || fail "no Mellanox/NVIDIA HCA found on the PCI bus"
mapfile -t IB_MODS < <(printf '%s\n' "${IB_MODS[@]}" | sort -u | sed '/^$/d')

# ------------------------------------------------------------------ infiniband
head1 "InfiniBand ports"
ipoib=()
for n in /sys/class/net/*; do [[ $(rd "$n/type") == 32 ]] && ipoib+=("${n##*/}"); done
IF=${IPOIB_IF:-${ipoib[0]:-}}
((${#ipoib[@]} > 1)) && [[ -z ${IPOIB_IF:-} ]] && info "IPoIB interfaces: ${ipoib[*]}; using $IF (set IPOIB_IF= to choose)"
ibdev="" ipport=""
if [[ -n $IF ]]; then
  ibdev=$(ls "/sys/class/net/$IF/device/infiniband" 2>/dev/null | head -1)
  # IPoIB sets dev_port (dev_id on older kernels) to the HCA port number minus 1
  n=$(rd "/sys/class/net/$IF/dev_port"); n=${n:-0}
  di=$(rd "/sys/class/net/$IF/dev_id")
  [[ $n == 0 && $di =~ ^0x[0-9a-fA-F]+$ ]] && n=$((di))
  ipport=$((n + 1))
fi
cur_mtu="" ib_rate="" srv_lid=""
ndev=0
for d in /sys/class/infiniband/*; do
  [[ -e $d ]] || continue
  dev=${d##*/}
  for p in "$d"/ports/*; do
    [[ -e $p ]] || continue
    ndev=$((ndev + 1)); port=${p##*/}
    ll=$(rd "$p/link_layer"); state=$(rd "$p/state"); rate=$(rd "$p/rate")
    dvi=$(ibv_devinfo -d "$dev" -i "$port" 2>/dev/null)
    amtu=$(awk '/active_mtu/{print $2;exit}' <<<"$dvi"); mmtu=$(awk '/max_mtu/{print $2;exit}' <<<"$dvi")
    tag=""; [[ $dev == "$ibdev" && $port == "$ipport" ]] && tag=" (carries $IF)"
    info "$dev port $port$tag: $ll, $state, $rate, MTU active ${amtu:-?} / max ${mmtu:-?}"
    [[ $dev == "$ibdev" || -z $ibdev ]] || continue
    if [[ -n $ibdev && $port != "$ipport" ]]; then info "$dev port $port does not carry $IF; not checked"; continue; fi
    [[ -n $ibdev ]] && srv_lid=$(rd "$p/lid")
    if [[ $ll == InfiniBand ]]; then pass "$dev port $port is in InfiniBand mode (RDMA available)"
    else fail "$dev port $port link layer is $ll; set LINK_TYPE_P$port=1 with mstconfig and reboot"; fi
    [[ $state == *ACTIVE* ]] && pass "$dev port $port is ACTIVE" || fail "$dev port $port is not ACTIVE ($state)"
    cur_mtu=${amtu:-$cur_mtu}
    [[ -n $mmtu && $mmtu -lt $TARGET_IB_MTU ]] && fail "$dev max MTU $mmtu is below the $TARGET_IB_MTU target"
    r=${rate%% *}
    if [[ $state == *ACTIVE* && $r =~ ^[0-9.]+$ ]]; then
      ib_rate=${ib_rate:-$rate}
      pg=${PCIE_GBPS[$dev]:-}
      if [[ -n $pg ]] && awk -v p="$pg" -v r="$r" 'BEGIN { exit !(p < 0.95 * r) }'; then
        warn "$dev: the PCIe slot gives about $pg Gb/s, below the $r Gb/s link; NFS/RDMA throughput tops out near $pg Gb/s"
      fi
    fi
  done
done
((ndev)) || fail "no InfiniBand devices found under /sys/class/infiniband"
# Two IB MTUs matter. The port's active_mtu is negotiated per link and can already read 4096.
# IPoIB is capped by its partition's broadcast group MTU, which the subnet manager sets.
port_mtu=$cur_mtu part_mtu="" part_src=""
if [[ -n $IF ]]; then
  pk=$(rd "/sys/class/net/$IF/pkey"); pk=${pk#0x}; [[ $pk =~ ^[0-9a-fA-F]+$ ]] || pk=ffff
  bc=$(printf 'ff12:401b:%x::ffff:ffff' $((16#$pk | 0x8000)))   # IPv4 broadcast group of this P_Key
  if have saquery; then
    v=$(saquery -g 2>/dev/null | awk -v bc="$bc" '{v=$0; sub(/^[[:space:]]*[A-Za-z]+\.+/, "", v)}
          /MGID/ {g=tolower(v)} /Mtu/ && g==bc {print v; exit}')
    [[ $v =~ ^0x[0-9a-fA-F]+$ ]] && part_mtu=$((128 << (v & 63))) && part_src="broadcast group $bc"
  fi
  if [[ -z $part_mtu ]]; then
    m=$(rd "/sys/class/net/$IF/mtu"); md=$(rd "/sys/class/net/$IF/mode")
    if [[ $md == datagram && $m =~ ^[0-9]+$ ]] && ((m + 4 < ${port_mtu:-0})); then
      part_mtu=$((m + 4)); part_src="inferred from $IF datagram MTU $m; saquery -g as root confirms it"
    fi
  fi
fi
# NFS over RDMA uses the path MTU between the two ports (set by the ports' MTU), not the partition MTU.
if [[ -n $port_mtu ]]; then
  if ((port_mtu >= TARGET_IB_MTU)); then pass "IB port MTU $port_mtu: NFS over RDMA can use it, whatever the partition MTU"
  else warn "IB port MTU is $port_mtu, so RDMA connections run at $port_mtu; check that the HCA (max_mtu) and switch ports support $TARGET_IB_MTU"; fi
fi
sm_needed=0
if [[ -n $part_mtu ]]; then
  if ((part_mtu >= TARGET_IB_MTU)); then pass "partition MTU $part_mtu ($part_src)"
  else warn "partition MTU is $part_mtu ($part_src): IPoIB stays at $((part_mtu - 4)) until the subnet manager raises it; this affects IPoIB/TCP traffic only, not NFS over RDMA (optional Plan C)"; sm_needed=1; fi
elif [[ -n $IF ]]; then
  info "could not read the partition MTU (needs saquery from infiniband-diags, as root)"
  [[ -n $port_mtu ]] && ((port_mtu < TARGET_IB_MTU)) && sm_needed=1
fi
hdev=${ibdev:-$(ls /sys/class/infiniband 2>/dev/null | head -1)}; hdev=${hdev:-none}
profile HCA "${IBDEV_HCA[$hdev]:-?} ($hdev, ${IBDEV_DRV[$hdev]:-?}), ${ib_rate:-link down}, IB MTU port ${port_mtu:-?} / partition ${part_mtu:-?}"

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
  if [[ -z $pf ]]; then
    [[ $FAMILY == deb ]] && pf=/etc/opensm/partitions.conf || pf=/etc/rdma/partitions.conf
  fi
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
  ((sm_needed)) && optional "Raise the partition MTU at the subnet manager (cluster-wide IPoIB rejoin; do the same on any standby SM)
    cp -a $pf $pf.pre-rdma 2>/dev/null
    $sedcmd
    grep -E '^[[:space:]]*Default' $pf      # expect mtu=$code ($TARGET_IB_MTU)
    systemctl restart opensm"
else
  info "opensm is not running on this host"
  ((sm_needed)) && optional "Raise the partition MTU at the subnet manager on \"${smdesc:-the SM node}\" (cluster-wide IPoIB rejoin)
    OpenSM host: set mtu=$code on the Default line of its partitions file, then systemctl restart opensm
    Managed switch / UFM: set the Default partition MTU to 4K per the vendor's procedure
    Apply the same change on every standby SM"
fi

# ------------------------------------------------------------------ ipoib
head1 "IPoIB${IF:+ ($IF)}"
addr=""
if [[ -z $IF ]]; then
  fail "no IPoIB interface found"
  profile IPoIB "none"
else
  mode=$(rd "/sys/class/net/$IF/mode"); mtu=$(rd "/sys/class/net/$IF/mtu")
  addr=$(ip -4 -o addr show dev "$IF" 2>/dev/null | awk '{print $4; exit}')
  info "mode ${mode:-?}, MTU ${mtu:-?}, address ${addr:-none}"
  [[ -n $addr ]] && pass "IPoIB has an address (RDMA mounts resolve the server through it)" \
                 || fail "$IF has no IPv4 address; NFS/RDMA needs one to resolve the server"

  # Which tool owns the interface: netplan > NetworkManager > ifcfg > systemd-networkd
  netcfg="" np_file="" con="" nd_file=""
  for f in /etc/netplan/*.yaml; do
    [[ -r $f ]] && grep -Eq "^[[:space:]]+$IF:" "$f" && { np_file=$f; break; }
  done
  if have nmcli; then
    con=$(nmcli -g GENERAL.CONNECTION device show "$IF" 2>/dev/null); [[ $con == "--" ]] && con=""
  fi
  for f in /etc/systemd/network/*.network; do
    [[ -r $f ]] && grep -Eq "^[[:space:]]*Name=.*\b$IF\b" "$f" && { nd_file=$f; break; }
  done
  if   [[ -n $np_file ]]; then netcfg=netplan;  info "configured by netplan: $np_file"
  elif [[ -n $con ]];     then netcfg=nm;       info "NetworkManager connection: \"$con\""
  elif [[ -r /etc/sysconfig/network-scripts/ifcfg-$IF ]]; then netcfg=ifcfg; info "configured by ifcfg-$IF"
  elif [[ -n $nd_file ]]; then netcfg=networkd; info "configured by systemd-networkd: $nd_file"
  else netcfg=unknown; warn "could not tell which tool configures $IF (netplan/NetworkManager/ifcfg/networkd)"
       [[ $FAMILY == deb && $EUID -ne 0 ]] && info "netplan files are readable only by root"
  fi
  profile IPoIB "$IF ${mode:-?} MTU ${mtu:-?}, managed by $netcfg"

  drv=${IBDEV_DRV[${ibdev:-none}]:-}
  case $drv in
    mlx4_core) info "ConnectX-3 (mlx4): no Enhanced IPoIB, so connected mode (MTU 65520) is available; datagram 4092 stays the recommendation for a uniform subnet" ;;
    mlx5_core)
      enh=""
      for m in ib_ipoib mlx5_ib; do modinfo -F parm "$m" 2>/dev/null | grep -q '^ipoib_enhanced' && enh=$m; done
      if [[ -n $enh ]]; then info "mlx5 Enhanced IPoIB; connected mode possible via '$enh ipoib_enhanced=0' (gives up its offloads)"
      else info "mlx5 Enhanced IPoIB: datagram mode only (runbook option A)"; fi ;;
  esac

  tgt=$((TARGET_IB_MTU - 4))
  if [[ $mode == datagram && ${mtu:-0} -lt $tgt ]]; then
    case $netcfg in
      netplan)  cmd="# in $np_file, under $IF: set  mtu: $tgt  (and  infiniband-mode: datagram)
    netplan try                     # reverts after 120 s unless confirmed" ;;
      nm)       cmd="nmcli con mod \"$con\" infiniband.transport-mode datagram infiniband.mtu $tgt
    nmcli con up \"$con\"" ;;
      ifcfg)    cmd="set MTU=$tgt in /etc/sysconfig/network-scripts/ifcfg-$IF, then: ifdown $IF; ifup $IF" ;;
      networkd) cmd="set MTUBytes=$tgt under [Link] in $nd_file, then: networkctl reload; networkctl reconfigure $IF" ;;
      *)        cmd="ip link set $IF mtu $tgt    # and persist it in whatever configures $IF" ;;
    esac
    optional "After the SM change: IPoIB MTU $tgt on this host (brief IPoIB drop), and the same on EVERY host in the IPoIB subnet
    $cmd
    cat /sys/class/net/$IF/mtu      # expect $tgt"
  fi
fi

# ------------------------------------------------------------------ reboot safety
head1 "Reboot safety"
bootk=""
if have grubby; then bootk=$(grubby --default-kernel 2>/dev/null | sed 's|^/boot/vmlinuz-||')
elif [[ -e /boot/vmlinuz ]]; then bootk=$(readlink -f /boot/vmlinuz | sed 's|^/boot/vmlinuz-||'); fi
need=()
((uses_zfs)) && need+=(zfs)
need+=("${IB_MODS[@]}" ib_ipoib)
if [[ -z $bootk ]]; then
  info "could not determine the default boot kernel"
elif [[ $bootk == "$(uname -r)" ]]; then
  pass "default boot kernel is the running kernel"
else
  warn "default boot kernel is $bootk, not the running $(uname -r); a reboot in the window changes kernels"
  rpc=rpcrdma; modfile "$bootk" rpcrdma || { modfile "$bootk" svcrdma && rpc=svcrdma; }
  for m in "${need[@]}" "$rpc"; do
    if modfile "$bootk" "$m"; then pass "$m module present for $bootk"
    else
      case $m in
        zfs) hint="build ZFS for it (dkms status), or keep the current kernel" ;;
        *)   hint=$([[ $FAMILY == deb ]] && echo "apt-get install linux-modules-extra-$bootk, or keep the current kernel" || echo "keep the current kernel") ;;
      esac
      setk=$([[ $FAMILY == el ]] && echo "grubby --set-default /boot/vmlinuz-$(uname -r)" || echo "set GRUB_DEFAULT to $(uname -r)")
      fail "no $m module for $bootk: $hint ($setk)"
    fi
  done
fi

# ------------------------------------------------------------------ rdma modules
head1 "NFS/RDMA kernel support"
if modinfo rpcrdma >/dev/null 2>&1 || modinfo svcrdma >/dev/null 2>&1; then
  pass "NFS/RDMA module available ($(modinfo -F filename svcrdma 2>/dev/null || modinfo -F filename rpcrdma 2>/dev/null))"
else
  hint=""; [[ $FAMILY == deb ]] && hint=" — try: apt-get install linux-modules-extra-$(uname -r)"
  fail "no rpcrdma/svcrdma module for $(uname -r): this kernel/OFED build has no NFS over RDMA$hint"
fi
lsmod 2>/dev/null | grep -Eq '^(rpcrdma|svcrdma)' && pass "NFS/RDMA module loaded" || info "NFS/RDMA module not loaded yet"
if ((EL7)); then
  if grep -Eqs '^[[:space:]]*SVCRDMA_LOAD=yes' /etc/rdma/rdma.conf; then pass "SVCRDMA_LOAD=yes in /etc/rdma/rdma.conf (loads at boot)"
  else warn "svcrdma is not loaded at boot"
       live "Load svcrdma at boot (no impact)
    grep -q '^SVCRDMA_LOAD=' /etc/rdma/rdma.conf && sed -i 's/^SVCRDMA_LOAD=.*/SVCRDMA_LOAD=yes/' /etc/rdma/rdma.conf || echo SVCRDMA_LOAD=yes >> /etc/rdma/rdma.conf"
  fi
elif grep -Eqs '^[[:space:]]*svcrdma' /etc/rdma/modules/*.conf /etc/modules-load.d/*.conf /etc/modules; then
  pass "svcrdma listed for loading at boot"
else
  warn "svcrdma is not loaded at boot"
  live "Load svcrdma at boot (no impact)
    echo svcrdma > /etc/modules-load.d/nfs-rdma-server.conf"
fi

# ------------------------------------------------------------------ nfs server
head1 "NFS server"
systemctl is-active -q nfs-server 2>/dev/null && pass "nfs-server active" || warn "nfs-server not active"
threads=$(rd "$NFSD_PROC/threads")
portlist=$(paste -sd',' "$NFSD_PROC/portlist" 2>/dev/null)
vers=$(rd "$NFSD_PROC/versions")
info "threads: ${threads:-?}; listeners: ${portlist:-?}; versions: ${vers:-?}"
info "sunrpc pool_mode: $(rd /sys/module/sunrpc/parameters/pool_mode || echo '?')"

# Clients mount vers=4.2. Enabling it needs nfsd stopped, so it is a window step.
need42=0
if [[ -z $vers ]]; then
  info "cannot read $NFSD_PROC/versions"
elif [[ " $vers " == *" +4.2 "* ]]; then
  pass "server offers NFSv4.2"
elif [[ " $vers " == *" -4.2 "* ]]; then
  fail "NFSv4.2 is disabled on the server; clients mount vers=4.2 (the plan enables it)"
  need42=1
else
  fail "this kernel's nfsd has no NFSv4.2; clients mount vers=4.2 — update the kernel first"
fi

# Thread count: max(64, logical CPUs rounded up to 16); 128 or more once 20+ clients are
# connected, because jobs spanning many nodes send bursts far above the average load.
ceil16=$(( (logical + 15) / 16 * 16 ))
T=$(( ceil16 > 64 ? ceil16 : 64 ))
rule="max(64, $logical logical CPUs rounded up to 16)"
nconn=0
have ss && nconn=$(ss -Htn state established '( sport = :2049 )' 2>/dev/null \
  | awk '{p = $4; sub(/:[0-9]+$/, "", p); print p}' | sort -u | wc -l)
if (( nconn >= 20 && T < 128 )); then
  T=128; rule="$nconn NFS clients connected (20 or more: start at 128)"
fi
if [[ -n ${THREADS:-} ]]; then
  T=$THREADS; info "planned nfsd threads: $T (THREADS= override)"
elif [[ ${threads:-0} -gt $T ]]; then
  info "planned nfsd threads: keep $threads (already above $rule = $T)"
  T=$threads
else
  info "planned nfsd threads: $T ($rule; override with THREADS=)"
fi

if [[ " ${portlist//,/ } " == *"rdma $RDMA_PORT"* ]]; then
  pass "RDMA listener already on port $RDMA_PORT"
else
  live "Load the RDMA server transport and add the RDMA listener to the running server (TCP clients unaffected)
    modprobe svcrdma
    echo 'rdma $RDMA_PORT' > $NFSD_PROC/portlist
    cat $NFSD_PROC/portlist          # expect rdma $RDMA_PORT alongside tcp 2049"
fi
if [[ ${threads:-0} -lt $T ]]; then
  live "Raise nfsd threads on the running server (immediate, no restart)
    echo $T > $NFSD_PROC/threads
    cat $NFSD_PROC/threads"
fi

# Persistent config: nfs.conf where nfs-utils has nfsconf (EL8+, Ubuntu), /etc/sysconfig/nfs on EL7
if [[ -n ${NFS_STYLE:-} ]]; then style=$NFS_STYLE
elif have nfsconf; then style=nfsconf
elif [[ -e $SYSCONFIG_NFS ]]; then style=sysconfig
else style=nfsconf; fi
if [[ $style == sysconfig ]]; then CFG=$SYSCONFIG_NFS; TAG=sysconfig-nfs; else CFG=$NFS_CONF; TAG=nfs.conf; fi
profile NFS "nfsd ${threads:-?} threads, ${vers:-?}; config in $CFG"
ORIG="$DIR/$TAG.orig" PROP="$DIR/$TAG.proposed"
if [[ -s $CFG ]]; then cp -a "$CFG" "$ORIG"; else : > "$ORIG"; info "$CFG missing or empty; proposing a minimal one"; fi

if [[ $style == sysconfig ]]; then
  info "active settings in $CFG:"
  grep -E '^[[:space:]]*RPCNFSD' "$ORIG" | sed 's/^/           /'
  awk -v T="$T" -v P="$RDMA_PORT" -v V42="$need42" '
    function addtok(s, t) { return index(" " s " ", " " t " ") ? s : (s == "" ? t : s " " t) }
    function args(v) {
      if (v !~ /--rdma/ && v !~ /(^| )-r( |$)/) v = addtok(v, "--rdma=" P)
      if (V42) { gsub(/-N[[:space:]]*4\.2/, "", v); gsub(/  +/, " ", v); sub(/^ /, "", v)
                 if (v !~ /-V[[:space:]]*4\.2/) v = addtok(v, "-V 4.2") }
      return "RPCNFSDARGS=\"" v "\"" }
    /^[[:space:]]*RPCNFSDCOUNT[[:space:]]*=/ { if (!c++) print "RPCNFSDCOUNT=" T; next }
    /^[[:space:]]*RPCNFSDARGS[[:space:]]*=/ { v = $0; sub(/^[^=]*=[[:space:]]*/, "", v)
                                            gsub(/^["\047]|["\047][[:space:]]*$/, "", v)
                                            if (!a++) print args(v); next }
    { print }
    END { if (!c) print "RPCNFSDCOUNT=" T; if (!a) print args("") }
  ' "$ORIG" > "$PROP"
  ok_parse=0
  stage="cmp -s $CFG $ORIG && cp -a $CFG $CFG.pre-rdma && cp $PROP $CFG
    systemctl restart nfs-config       # regenerates /run/sysconfig/nfs-utils; nfsd keeps running"
  verify "grep RPCNFSD $CFG: RPCNFSDCOUNT=$T and --rdma=$RDMA_PORT in RPCNFSDARGS"
else
  info "active [nfsd] lines in $CFG:"
  awk '/^[[:space:]]*\[/{s=$0; gsub(/[][[:space:]]/,"",s); sec=tolower(s); next}
       sec=="nfsd" && /^[[:space:]]*[A-Za-z][^=]*=/ {print "           " $0}' "$ORIG"
  awk -v T="$T" -v P="$RDMA_PORT" -v V42="$need42" '
    BEGIN { n = split("threads tcp rdma rdma-port" (V42 ? " vers4.2" : ""), order, " ")
            want["threads"] = T; want["tcp"] = "y"; want["rdma"] = "y"; want["rdma-port"] = P; want["vers4.2"] = "y" }
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
                        if (k in want && (k != "vers4.2" || V42)) { if (!(k in done)) print k "=" want[k]; done[k] = 1; next } }
    { print }
    END { if (!has) { print ""; print "[nfsd]"; for (i = 1; i <= n; i++) print order[i] "=" want[order[i]] } }
  ' "$ORIG" "$ORIG" > "$PROP"
  # Drop-ins in nfs.conf.d are read after nfs.conf and override it.
  for f in "$CFG.d"/*.conf; do
    [[ -r $f ]] || continue
    ov=$(awk '/^[[:space:]]*\[/{s=$0; gsub(/[][[:space:]]/,"",s); sec=tolower(s); next}
              sec=="nfsd" && /^[[:space:]]*[A-Za-z][^=]*=/ { k=$0; sub(/=.*/,"",k); gsub(/[[:space:]]/,"",k)
                if (k ~ /^(threads|tcp|rdma|rdma-port|vers4\.2)$/) printf "%s%s", (n++ ? ", " : ""), $0 }' "$f")
    [[ -n $ov ]] && warn "$f overrides $CFG with [nfsd] $ov — make the same change there or remove those lines"
  done
  ok_parse=0
  if have nfsconf && [[ $(nfsconf --file "$PROP" --get nfsd rdma 2>/dev/null) == y ]]; then ok_parse=1; fi
  stage="cmp -s $CFG $ORIG && cp -a $CFG $CFG.pre-rdma && cp $PROP $CFG"
  verify "nfsconf --dump shows threads=$T, rdma=y, rdma-port=$RDMA_PORT under [nfsd] (includes nfs.conf.d overrides)"
fi
grep -qs '^[[:space:]]*RPCNFSDCOUNT' /etc/sysconfig/nfs && [[ $style == nfsconf ]] &&
  warn "/etc/sysconfig/nfs sets $(grep -m1 '^[[:space:]]*RPCNFSDCOUNT' /etc/sysconfig/nfs); this nfs-utils reads $CFG — remove it so the two can't disagree"

if cmp -s <(awk 1 "$ORIG") "$PROP"; then
  pass "$CFG already has the planned settings"
else
  info "proposed change to $CFG:"
  diff -u "$ORIG" "$PROP" | tail -n +3 | sed 's/^/           /'
  if ((ok_parse)); then pass "nfsconf parses the proposed file (nfsd rdma=y)"
  elif [[ $style == nfsconf ]] && have nfsconf; then warn "nfsconf could not confirm the proposed file; check it by eye"; fi
  live "Stage $CFG so the settings persist (read at the next nfs-server start; nothing changes now)
    $stage"
fi

# nfsd thread pressure: share of arrivals that did not wake an idle thread = (arrived - woken) / arrived
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
    pct=$(awk -v a="$da" -v w="$dw" 'BEGIN{p = 100 * (a - w) / a; printf "%.2f", p < 0 ? 0 : p}')
    msg="$(( da / SAMPLE )) arrivals/s; ${pct}% found no idle nfsd thread (${threads:-?} threads)"
    if awk -v p="$pct" 'BEGIN{exit !(p < 0.5)}'; then pass "$msg"
    else warn "$msg — under current load the server needs more threads"; fi
  else
    info "no NFS traffic during the sample; run again under load for a thread-pressure reading"
  fi
fi

# ------------------------------------------------------------------ exports
head1 "Exports"
first_export=${EXPORT_PATHS[0]:-}
if ! have exportfs; then
  warn "exportfs not found"
elif [[ -z $EXPORTS ]]; then
  warn "no exports listed (not root, or nothing exported)"
else
  noins=()
  while read -r path specs; do
    [[ -z $path ]] && continue
    for s in $specs; do
      opts=${s#*(}; opts=${opts%)}
      [[ ,$opts, == *,insecure,* ]] || noins+=("$path ${s%%(*}")
    done
  done <<<"$EXPORTS"
  info "$(wc -l <<<"$EXPORTS") export line(s)"
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
    /etc/exports (and /etc/exports.d/*.exports) entries: add insecure to the client options, then: exportfs -ra${zcmds}
    exportfs -s | grep -v insecure     # expect no output"
  else
    pass "all exports allow unreserved ports (insecure)"
  fi
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
elif have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
  if ufw status 2>/dev/null | grep -Eq "^$RDMA_PORT(/tcp)?[[:space:]].*ALLOW"; then pass "ufw allows $RDMA_PORT/tcp"
  else
    info "ufw active, $RDMA_PORT not open (RDMA bypasses netfilter; opening it keeps the rules honest)"
    live "Open the NFS/RDMA port in ufw (no impact)
    ufw allow $RDMA_PORT/tcp"
  fi
else
  info "no active firewalld or ufw"
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
    dnf install -y rdma-core nfs-utils      # Ubuntu: apt-get install -y rdma-core nfs-common; EL7: yum
    modprobe xprtrdma
    mkdir -p /mnt/rdmatest
    mount -t nfs -o proto=rdma,port=$RDMA_PORT,vers=4.2,hard ${ip_only:-<NAS IPoIB address>}:${first_export:-<export>} /mnt/rdmatest
    grep -A4 ' /mnt/rdmatest ' /proc/self/mountstats | grep xprt    # expect: xprt: rdma
    # optional: ./nfsbench.sh fio pilot /mnt/rdmatest ; then umount /mnt/rdmatest"

((${#OPTIONAL[@]})) && optional "Confirm the new MTU everywhere (IPoIB only reaches $((TARGET_IB_MTU - 4)) once the partition is $TARGET_IB_MTU)
    cat /sys/class/net/${IF:-ib0}/mtu                          # this host: $((TARGET_IB_MTU - 4))
    pdsh -a 'cat /sys/class/net/ib0/mtu' | dshbak -c   # every node: $((TARGET_IB_MTU - 4)); $((TARGET_IB_MTU / 2 - 4)) means the partition is still $((TARGET_IB_MTU / 2))"
if ((need42)); then
  window "Restart nfs-server to turn on NFSv4.2 and load the staged config (NFSv4 clients pause for the grace period)
    systemctl restart nfs-server
    cat $NFSD_PROC/versions $NFSD_PROC/portlist $NFSD_PROC/threads    # expect +4.2, rdma $RDMA_PORT, $T"
fi
window "Move the remaining clients to RDMA (update fstab/autofs per runbook step 6, then remount), in the order of nfs-clients.txt.
    On Slurm, clients can instead be moved before the window a group at a time by draining them (runbook step 6)"
if ((!need42)); then
  window "Optional: prove the staged config survives a restart (NFSv4 clients pause for the grace period)
    systemctl restart nfs-server
    cat $NFSD_PROC/portlist $NFSD_PROC/threads"
fi

verify "Re-run this script: every [WARN] above should be gone (the partition MTU warning stays if you skip Plan C)"
[[ -n $srv_lid ]] && verify "From a client, as root, confirm the path MTU the RDMA connections use (Mtu ending in 5 = 4096, 4 = 2048):
    saquery -p --src-to-dst <client LID from ibstat>:$((srv_lid)) | grep -i mtu"
verify "On a client: nfsstat -m shows proto=rdma,vers=4.2; then capture the after-run with nfsbench.sh"
verify "dmesg -T | grep -iE 'rpcrdma|svcrdma' on the NAS and a client: no errors"

printf '\n== Discovered ==\n'
printf '  %s\n' "${PROFILE[@]}"
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
((${#OPTIONAL[@]})) && printplan "Plan C: optional, its own cluster-wide window: raise the IPoIB MTU (IPoIB/TCP traffic only; NFS over RDMA does not need it)" "${OPTIONAL[@]}"
printplan "Verify" "${VERIFY[@]}"
printf '\nNothing was changed on this host. Report: %s/report.txt\n' "$DIR"

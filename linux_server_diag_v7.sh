# Production-safety posture:
# - Read-only collection only (no config changes)
# - Bounded command runtime with forced SIGKILL escalation (timeout -k)
# - Low CPU priority + idle-class I/O scheduling (ionice -c3) when available
# - Lockless LVM reads (--nolocking) to reduce risk of contention
# - Full log capture disabled by default; enable only when needed
#
# Why v7 exists:
# - Fixes the dmesg pattern summary quoting bug (no shell expansion of awk $0)
# - Replaces deprecated egrep usage with grep -E
# - Produces explicit placeholder outputs when tools are missing (better comparisons)
#
# Usage:
#   sudo bash linux_server_diag_v7.sh
#   sudo bash linux_server_diag_v7.sh --outdir /var/tmp
#   sudo bash linux_server_diag_v7.sh --sample-seconds 5
#   sudo bash linux_server_diag_v7.sh --cmd-timeout 20
#   sudo bash linux_server_diag_v7.sh --include-full-logs
#
# Output:
#   Creates a timestamped report directory and tar.gz bundle.

set -u
set -o pipefail
umask 077
export LC_ALL=C
PATH=/usr/sbin:/usr/bin:/sbin:/bin

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="v7"
HOST="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
TS="$(date +%Y%m%d_%H%M%S)"

OUTBASE="/var/tmp"
SAMPLE_SECONDS=5
CMD_TIMEOUT=20
MAX_LOG_LINES=2000
INCLUDE_FULL_LOGS=0
SKIP_DMIDECODE=0

REPORT_DIR=""
TAR_PATH=""

usage() {
  cat <<'EOF'
Usage: linux_server_diag_v7.sh [options]

Options:
  --outdir DIR            Base output directory (default: /var/tmp)
  --sample-seconds N      Passive sample duration for vmstat/iostat/mpstat/sar if available (default: 5)
                          Set to 0 to skip time-based samples.
  --cmd-timeout N         Per-command timeout seconds (default: 20)
  --max-log-lines N       Max lines for bounded log outputs (default: 2000)
  --include-full-logs     Also collect full dmesg output (default: off)
  --skip-dmidecode        Skip dmidecode collection (default: off)
  -h, --help              Show this help
EOF
}

is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
have() { command -v "$1" >/dev/null 2>&1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --outdir) OUTBASE="${2:-}"; shift 2 ;;
    --sample-seconds) SAMPLE_SECONDS="${2:-}"; shift 2 ;;
    --cmd-timeout) CMD_TIMEOUT="${2:-}"; shift 2 ;;
    --max-log-lines) MAX_LOG_LINES="${2:-}"; shift 2 ;;
    --include-full-logs) INCLUDE_FULL_LOGS=1; shift ;;
    --skip-dmidecode) SKIP_DMIDECODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if ! is_uint "$SAMPLE_SECONDS"; then
  echo "ERROR: --sample-seconds must be a non-negative integer." >&2; exit 1
fi
if ! is_uint "$CMD_TIMEOUT" || [[ "$CMD_TIMEOUT" -lt 1 ]]; then
  echo "ERROR: --cmd-timeout must be a positive integer." >&2; exit 1
fi
if ! is_uint "$MAX_LOG_LINES" || [[ "$MAX_LOG_LINES" -lt 1 ]]; then
  echo "ERROR: --max-log-lines must be a positive integer." >&2; exit 1
fi

mkdir -p "$OUTBASE" || { echo "ERROR: cannot create output base directory: $OUTBASE" >&2; exit 1; }

REPORT_DIR="$OUTBASE/${HOST}_serverdiag_${TS}"
mkdir -p "$REPORT_DIR"/{00_meta,10_os,20_cpu,30_memory,40_storage,50_network,60_kernel,70_services,80_limits,90_errors,99_summary} || {
  echo "ERROR: cannot create report directory: $REPORT_DIR" >&2; exit 1
}

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$REPORT_DIR/00_meta/run.log"; }

note() {
  local outfile="$1"; shift
  { echo "$@"; echo; } >> "$outfile"
}

# Wrapper: run command low-priority; enforce timeout with SIGKILL escalation.
exec_wrapped() {
  local rc=0
  if have ionice; then
    if have timeout; then
      ionice -c3 nice -n 19 timeout -k 5s "${CMD_TIMEOUT}s" "$@"
      rc=$?
    else
      ionice -c3 nice -n 19 "$@"
      rc=$?
    fi
  else
    if have timeout; then
      nice -n 19 timeout -k 5s "${CMD_TIMEOUT}s" "$@"
      rc=$?
    else
      nice -n 19 "$@"
      rc=$?
    fi
  fi
  return $rc
}

run_cmd() {
  local outfile="$1"; shift
  {
    echo "### COMMAND: $*"
    echo "### TIME: $(date '+%F %T %z')"
    echo "### CMD_TIMEOUT_SECONDS: $CMD_TIMEOUT (with 5s SIGKILL escalation)"
    echo "### PRIORITY: nice -n 19, ionice -c3 when available"
    echo
    exec_wrapped "$@" 2>&1
    rc=$?
    echo
    if [[ $rc -eq 124 ]] || [[ $rc -eq 137 ]]; then
      echo "### RESULT: timed out or forcibly killed after ${CMD_TIMEOUT} seconds"
    else
      echo "### EXIT_CODE: $rc"
    fi
  } > "$outfile"
}

run_shell() {
  local outfile="$1"
  local cmd="$2"
  {
    echo "### SHELL: $cmd"
    echo "### TIME: $(date '+%F %T %z')"
    echo "### CMD_TIMEOUT_SECONDS: $CMD_TIMEOUT (with 5s SIGKILL escalation)"
    echo "### PRIORITY: nice -n 19, ionice -c3 when available"
    echo
    exec_wrapped bash -lc "$cmd" 2>&1
    rc=$?
    echo
    if [[ $rc -eq 124 ]] || [[ $rc -eq 137 ]]; then
      echo "### RESULT: timed out or forcibly killed after ${CMD_TIMEOUT} seconds"
    else
      echo "### EXIT_CODE: $rc"
    fi
  } > "$outfile"
}

section() { log "Collecting: $1"; }

cap_file() {
  local src="$1"; local dst="$2"
  [[ -r "$src" ]] || return 0
  cp "$src" "$dst" 2>/dev/null || {
    { echo "### FILE: $src"; echo "### TIME: $(date '+%F %T %z')"; echo; cat "$src" 2>&1; } > "$dst"
  }
}

capture_pressure_or_note() {
  local resource="$1"; local outfile="$2"
  if [[ -r "/proc/pressure/$resource" ]]; then
    run_cmd "$outfile" cat "/proc/pressure/$resource"
  else
    note "$outfile" "PSI not available: /proc/pressure/$resource is absent on this host/kernel build."
  fi
}

write_dmesg_awk() {
  local awkfile="$1"
  cat > "$awkfile" <<'AWK'
BEGIN{
  IGNORECASE=1;
  pats[1]="blocked for more than";
  pats[2]="hung task";
  pats[3]="soft lockup";
  pats[4]="hard lockup";
  pats[5]="oom|out of memory";
  pats[6]="call trace";
  pats[7]="I/O error|buffer i/o error|blk_update_request";
  pats[8]="reset";
  pats[9]="link down|tx timeout|NETDEV WATCHDOG";
  pats[10]="xfs.*error|ext4.*error";
  pats[11]="nvme.*abort|scsi.*error";
  pats[12]="bond.*fail|mlx|ixgbe|bnxt|ena";
  pats[13]="tcp: too many orphaned";
  pats[14]="page allocation failure";
  pats[15]="rcu.*stall";

  labels[1]="blocked_for_more_than";
  labels[2]="hung_task";
  labels[3]="soft_lockup";
  labels[4]="hard_lockup";
  labels[5]="oom_or_out_of_memory";
  labels[6]="call_trace";
  labels[7]="storage_io_error";
  labels[8]="reset";
  labels[9]="network_link_or_watchdog";
  labels[10]="filesystem_error";
  labels[11]="nvme_or_scsi_error";
  labels[12]="driver_or_bond_issue";
  labels[13]="tcp_orphaned";
  labels[14]="page_allocation_failure";
  labels[15]="rcu_stall";
}
{
  for (i=1; i<=15; i++) {
    if ($0 ~ pats[i]) count[labels[i]]++;
  }
}
END{
  for (i=1; i<=15; i++) printf "%s=%d\n", labels[i], (count[labels[i]]+0);
}
AWK
}

collect_meta() {
  section "meta"
  {
    echo "script_name=$SCRIPT_NAME"
    echo "script_version=$SCRIPT_VERSION"
    echo "hostname=$HOST"
    echo "timestamp=$TS"
    echo "report_dir=$REPORT_DIR"
    echo "user=$(id -un 2>/dev/null || true)"
    echo "uid=$(id -u 2>/dev/null || true)"
    echo "sample_seconds=$SAMPLE_SECONDS"
    echo "cmd_timeout=$CMD_TIMEOUT"
    echo "max_log_lines=$MAX_LOG_LINES"
    echo "include_full_logs=$INCLUDE_FULL_LOGS"
    echo "skip_dmidecode=$SKIP_DMIDECODE"
    echo "kernel=$(uname -r 2>/dev/null || true)"
    echo "cmdline=$0 $*"
  } > "$REPORT_DIR/00_meta/meta.env"

  run_cmd "$REPORT_DIR/00_meta/id.txt" id
  run_cmd "$REPORT_DIR/00_meta/date.txt" date
  run_cmd "$REPORT_DIR/00_meta/uname_a.txt" uname -a
  run_shell "$REPORT_DIR/00_meta/environment.txt" 'env | sort'

  run_shell "$REPORT_DIR/00_meta/tool_presence.txt" '
for x in timeout ionice nice hostnamectl dmidecode lspci lscpu mpstat vmstat iostat sar numactl ethtool ss netstat nft iptables-save nmcli networkctl chronyc ntpq tuned-adm systemctl journalctl grubby rpm dnf yum tc nstat tar; do
  if command -v "$x" >/dev/null 2>&1; then
    printf "%-14s present (%s)\n" "$x" "$(command -v "$x")"
  else
    printf "%-14s absent\n" "$x"
  fi
done'
}

collect_os() {
  section "os"
  cap_file /etc/os-release "$REPORT_DIR/10_os/os-release.txt"
  cap_file /etc/redhat-release "$REPORT_DIR/10_os/redhat-release.txt"
  cap_file /etc/oracle-release "$REPORT_DIR/10_os/oracle-release.txt"

  run_cmd "$REPORT_DIR/10_os/hostnamectl.txt" hostnamectl
  run_cmd "$REPORT_DIR/10_os/uptime.txt" uptime
  run_cmd "$REPORT_DIR/10_os/who_b.txt" who -b
  run_cmd "$REPORT_DIR/10_os/who_r.txt" who -r
  run_cmd "$REPORT_DIR/10_os/last_reboot.txt" last reboot
  run_cmd "$REPORT_DIR/10_os/lsmod.txt" lsmod
  run_cmd "$REPORT_DIR/10_os/cmdline.txt" cat /proc/cmdline
  run_cmd "$REPORT_DIR/10_os/systemd_detect_virt.txt" systemd-detect-virt
  run_cmd "$REPORT_DIR/10_os/timedatectl.txt" timedatectl
  run_cmd "$REPORT_DIR/10_os/timedatectl_show.txt" bash -lc 'timedatectl show -p NTPSynchronized -p NTPService -p CanNTP -p Timezone -p TimeUSec 2>/dev/null || true'

  run_shell "$REPORT_DIR/10_os/sysfs_dmi.txt" '
for f in /sys/class/dmi/id/*; do
  [[ -r "$f" ]] || continue
  printf "## %s\n" "$f"
  cat "$f" 2>/dev/null
  echo
done'

  if [[ "$SKIP_DMIDECODE" -eq 0 ]] && have dmidecode; then
    run_cmd "$REPORT_DIR/10_os/dmidecode.txt" dmidecode -t system -t bios -t processor -t memory
  else
    note "$REPORT_DIR/10_os/dmidecode.txt" "Skipped dmidecode collection (command absent or --skip-dmidecode used)."
  fi

  if have chronyc; then
    run_cmd "$REPORT_DIR/10_os/chronyc_tracking.txt" chronyc tracking
    run_cmd "$REPORT_DIR/10_os/chronyc_sources.txt" chronyc sources -v
  else
    note "$REPORT_DIR/10_os/chronyc_tracking.txt" "chronyc not available."
    note "$REPORT_DIR/10_os/chronyc_sources.txt" "chronyc not available."
  fi

  if have ntpq; then
    run_cmd "$REPORT_DIR/10_os/ntpq_p.txt" ntpq -p
  else
    note "$REPORT_DIR/10_os/ntpq_p.txt" "ntpq not available."
  fi

  if have sestatus; then
    run_cmd "$REPORT_DIR/10_os/selinux.txt" sestatus
  else
    note "$REPORT_DIR/10_os/selinux.txt" "sestatus not available."
  fi

  if have lspci; then
    run_cmd "$REPORT_DIR/10_os/lspci_nnk.txt" lspci -nnk
  else
    note "$REPORT_DIR/10_os/lspci_nnk.txt" "lspci not available."
  fi

  if have rpm; then
    run_shell "$REPORT_DIR/10_os/package_versions.txt" "rpm -qa | grep -E '^(kernel|kernel-uek|systemd|tuned|irqbalance|NetworkManager|chrony|open-vm-tools|ethtool|sysstat|lvm2|device-mapper|xfsprogs|iproute|dracut|grub2)' | sort"
  elif have dpkg-query; then
    run_shell "$REPORT_DIR/10_os/package_versions.txt" "dpkg-query -W 2>/dev/null | grep -E '^(linux-image|systemd|tuned|irqbalance|network-manager|chrony|open-vm-tools|ethtool|sysstat|lvm2|xfsprogs|iproute2|dracut|grub)' | sort"
  else
    note "$REPORT_DIR/10_os/package_versions.txt" "No supported package manager query tool found (rpm/dpkg-query absent)."
  fi

  if have grubby; then
    run_cmd "$REPORT_DIR/10_os/grubby_info_all.txt" grubby --info=ALL
    run_cmd "$REPORT_DIR/10_os/grubby_default_kernel.txt" grubby --default-kernel
  else
    note "$REPORT_DIR/10_os/grubby_info_all.txt" "grubby not available."
    note "$REPORT_DIR/10_os/grubby_default_kernel.txt" "grubby not available."
  fi
}

collect_cpu() {
  section "cpu"
  run_cmd "$REPORT_DIR/20_cpu/lscpu.txt" lscpu
  run_cmd "$REPORT_DIR/20_cpu/cpuinfo.txt" cat /proc/cpuinfo
  run_cmd "$REPORT_DIR/20_cpu/loadavg.txt" cat /proc/loadavg
  run_cmd "$REPORT_DIR/20_cpu/stat.txt" cat /proc/stat
  run_cmd "$REPORT_DIR/20_cpu/interrupts.txt" cat /proc/interrupts
  run_cmd "$REPORT_DIR/20_cpu/softirqs.txt" cat /proc/softirqs
  run_cmd "$REPORT_DIR/20_cpu/irq_default_affinity.txt" cat /proc/irq/default_smp_affinity

  cap_file /sys/devices/system/cpu/online "$REPORT_DIR/20_cpu/cpu_online.txt"
  cap_file /sys/devices/system/cpu/isolated "$REPORT_DIR/20_cpu/cpu_isolated.txt"
  cap_file /sys/devices/system/cpu/nohz_full "$REPORT_DIR/20_cpu/cpu_nohz_full.txt"
  cap_file /sys/devices/system/cpu/smt/control "$REPORT_DIR/20_cpu/smt_control.txt"
  cap_file /proc/sys/kernel/numa_balancing "$REPORT_DIR/20_cpu/numa_balancing.txt"

  run_shell "$REPORT_DIR/20_cpu/cpufreq.txt" '
for f in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor \
         /sys/devices/system/cpu/cpufreq/policy*/scaling_driver \
         /sys/devices/system/cpu/cpufreq/policy*/energy_performance_preference; do
  [[ -r "$f" ]] || continue
  echo "## $f"
  cat "$f"
  echo
done'

  if have numactl; then
    run_cmd "$REPORT_DIR/20_cpu/numactl_hardware.txt" numactl --hardware
  else
    note "$REPORT_DIR/20_cpu/numactl_hardware.txt" "numactl not available."
  fi

  if have mpstat; then
    if [[ "$SAMPLE_SECONDS" -gt 0 ]]; then
      run_cmd "$REPORT_DIR/20_cpu/mpstat_sample.txt" mpstat -P ALL 1 "$SAMPLE_SECONDS"
    else
      run_cmd "$REPORT_DIR/20_cpu/mpstat_once.txt" mpstat -P ALL 1 1
    fi
  else
    note "$REPORT_DIR/20_cpu/mpstat_sample.txt" "mpstat not available."
    note "$REPORT_DIR/20_cpu/mpstat_once.txt" "mpstat not available."
  fi

  if have sar && [[ "$SAMPLE_SECONDS" -gt 0 ]]; then
    run_cmd "$REPORT_DIR/20_cpu/sar_queue_sample.txt" sar -q 1 "$SAMPLE_SECONDS"
    run_cmd "$REPORT_DIR/20_cpu/sar_cpu_sample.txt" sar -u ALL 1 "$SAMPLE_SECONDS"
  else
    note "$REPORT_DIR/20_cpu/sar_queue_sample.txt" "sar not available or sampling disabled."
    note "$REPORT_DIR/20_cpu/sar_cpu_sample.txt" "sar not available or sampling disabled."
  fi

  capture_pressure_or_note cpu "$REPORT_DIR/20_cpu/psi_cpu.txt"
}

collect_memory() {
  section "memory"
  run_cmd "$REPORT_DIR/30_memory/free_h.txt" free -h
  run_cmd "$REPORT_DIR/30_memory/meminfo.txt" cat /proc/meminfo
  run_cmd "$REPORT_DIR/30_memory/vmstat_s.txt" vmstat -s
  if [[ "$SAMPLE_SECONDS" -gt 0 ]]; then
    run_cmd "$REPORT_DIR/30_memory/vmstat_sample.txt" vmstat -SM 1 "$SAMPLE_SECONDS"
  else
    run_cmd "$REPORT_DIR/30_memory/vmstat_once.txt" vmstat -SM
  fi
  run_cmd "$REPORT_DIR/30_memory/slabinfo.txt" cat /proc/slabinfo
  run_cmd "$REPORT_DIR/30_memory/zoneinfo.txt" cat /proc/zoneinfo
  run_cmd "$REPORT_DIR/30_memory/buddyinfo.txt" cat /proc/buddyinfo
  run_cmd "$REPORT_DIR/30_memory/pagetypeinfo.txt" cat /proc/pagetypeinfo

  cap_file /sys/kernel/mm/transparent_hugepage/enabled "$REPORT_DIR/30_memory/thp_enabled.txt"
  cap_file /sys/kernel/mm/transparent_hugepage/defrag "$REPORT_DIR/30_memory/thp_defrag.txt"
  cap_file /sys/kernel/mm/transparent_hugepage/shmem_enabled "$REPORT_DIR/30_memory/thp_shmem_enabled.txt"

  for k in \
    vm.swappiness \
    vm.dirty_ratio \
    vm.dirty_background_ratio \
    vm.dirty_bytes \
    vm.dirty_background_bytes \
    vm.overcommit_memory \
    vm.overcommit_ratio \
    vm.min_free_kbytes \
    vm.zone_reclaim_mode \
    vm.max_map_count \
    kernel.numa_balancing
  do
    run_cmd "$REPORT_DIR/30_memory/${k//./_}.txt" sysctl -n "$k"
  done

  if have sar && [[ "$SAMPLE_SECONDS" -gt 0 ]]; then
    run_cmd "$REPORT_DIR/30_memory/sar_memory_sample.txt" sar -r ALL 1 "$SAMPLE_SECONDS"
    run_cmd "$REPORT_DIR/30_memory/sar_swap_sample.txt" sar -S 1 "$SAMPLE_SECONDS"
  else
    note "$REPORT_DIR/30_memory/sar_memory_sample.txt" "sar not available or sampling disabled."
    note "$REPORT_DIR/30_memory/sar_swap_sample.txt" "sar not available or sampling disabled."
  fi

  capture_pressure_or_note memory "$REPORT_DIR/30_memory/psi_memory.txt"
}

collect_storage() {
  section "storage"
  run_cmd "$REPORT_DIR/40_storage/lsblk.txt" lsblk -e7 -o NAME,KNAME,MAJ:MIN,FSTYPE,TYPE,SIZE,RO,RM,MOUNTPOINT,UUID,MODEL,SERIAL,STATE,ROTA,SCHED
  run_cmd "$REPORT_DIR/40_storage/blkid.txt" blkid
  run_cmd "$REPORT_DIR/40_storage/df_hT.txt" df -hT
  run_cmd "$REPORT_DIR/40_storage/df_i.txt" df -i
  run_cmd "$REPORT_DIR/40_storage/mount.txt" mount
  run_cmd "$REPORT_DIR/40_storage/findmnt.txt" findmnt -A -o TARGET,SOURCE,FSTYPE,OPTIONS
  run_cmd "$REPORT_DIR/40_storage/fstab.txt" cat /etc/fstab
  run_cmd "$REPORT_DIR/40_storage/diskstats.txt" cat /proc/diskstats

  run_shell "$REPORT_DIR/40_storage/block_queue.txt" '
for dev in /sys/block/*; do
  b=$(basename "$dev")
  [[ "$b" == loop* || "$b" == ram* ]] && continue
  echo "## /sys/block/$b"
  for f in \
    queue/scheduler queue/rotational queue/read_ahead_kb queue/nr_requests \
    queue/rq_affinity queue/nomerges queue/wbt_lat_usec queue/io_poll \
    queue/io_poll_delay queue/discard_max_bytes queue/discard_granularity \
    queue/max_sectors_kb queue/max_hw_sectors_kb queue/logical_block_size \
    queue/physical_block_size queue/write_cache
  do
    [[ -r "/sys/block/$b/$f" ]] && printf "%s=" "$f" && cat "/sys/block/$b/$f"
  done
  echo
done'

  if have iostat; then
    if [[ "$SAMPLE_SECONDS" -gt 0 ]]; then
      run_cmd "$REPORT_DIR/40_storage/iostat_sample.txt" iostat -xz 1 "$SAMPLE_SECONDS"
    else
      run_cmd "$REPORT_DIR/40_storage/iostat_once.txt" iostat -xz 1 1
    fi
  else
    note "$REPORT_DIR/40_storage/iostat_sample.txt" "iostat not available."
    note "$REPORT_DIR/40_storage/iostat_once.txt" "iostat not available."
  fi

  if have pvs; then run_cmd "$REPORT_DIR/40_storage/pvs.txt" pvs -a -o +pv_used --nolocking; else note "$REPORT_DIR/40_storage/pvs.txt" "pvs not available."; fi
  if have vgs; then run_cmd "$REPORT_DIR/40_storage/vgs.txt" vgs -a -o +devices --nolocking; else note "$REPORT_DIR/40_storage/vgs.txt" "vgs not available."; fi
  if have lvs; then run_cmd "$REPORT_DIR/40_storage/lvs.txt" lvs -a -o +devices,seg_monitor --nolocking; else note "$REPORT_DIR/40_storage/lvs.txt" "lvs not available."; fi
  if have multipath; then run_cmd "$REPORT_DIR/40_storage/multipath_ll.txt" multipath -ll; else note "$REPORT_DIR/40_storage/multipath_ll.txt" "multipath not available."; fi
  if have mdadm; then run_cmd "$REPORT_DIR/40_storage/mdadm_detail_scan.txt" mdadm --detail --scan; else note "$REPORT_DIR/40_storage/mdadm_detail_scan.txt" "mdadm not available."; fi

  run_shell "$REPORT_DIR/40_storage/filesystem_tunables.txt" '
for dev in $(lsblk -pnro NAME,TYPE | awk "$2==\"part\" || $2==\"lvm\" || $2==\"disk\" {print \$1}"); do
  fs=$(blkid -o value -s TYPE "$dev" 2>/dev/null | head -n1)
  case "$fs" in
    xfs)
      echo "## xfs_info $dev"
      xfs_info "$dev" 2>/dev/null || true
      echo
      ;;
    ext2|ext3|ext4)
      echo "## tune2fs -l $dev"
      tune2fs -l "$dev" 2>/dev/null | grep -E -i "Filesystem volume name|Block count|Block size|Reserved block count|RAID stride|RAID stripe width|Filesystem features|Journal inode|Errors behavior|Filesystem state|Mount count|Maximum mount count|Last checked|Check interval" || true
      echo
      ;;
  esac
done'

  capture_pressure_or_note io "$REPORT_DIR/40_storage/psi_io.txt"
}

collect_network() {
  section "network"
  run_cmd "$REPORT_DIR/50_network/ip_br_addr.txt" ip -br addr
  run_cmd "$REPORT_DIR/50_network/ip_br_link.txt" ip -br link
  run_cmd "$REPORT_DIR/50_network/ip_addr.txt" ip addr
  run_cmd "$REPORT_DIR/50_network/ip_d_link.txt" ip -d link
  run_cmd "$REPORT_DIR/50_network/ip_link_stats.txt" ip -s link
  run_cmd "$REPORT_DIR/50_network/ip_route.txt" ip route show table all
  run_cmd "$REPORT_DIR/50_network/ip_rule.txt" ip rule show
  run_cmd "$REPORT_DIR/50_network/ip_neigh.txt" ip neigh show nud all
  run_cmd "$REPORT_DIR/50_network/ss_s.txt" ss -s
  run_cmd "$REPORT_DIR/50_network/ss_lntup.txt" ss -lntup
  run_shell "$REPORT_DIR/50_network/netstat_s.txt" 'netstat -s 2>/dev/null || ss -s'
  run_cmd "$REPORT_DIR/50_network/proc_net_dev.txt" cat /proc/net/dev
  run_cmd "$REPORT_DIR/50_network/proc_net_softnet_stat.txt" cat /proc/net/softnet_stat
  cap_file /etc/resolv.conf "$REPORT_DIR/50_network/resolv_conf.txt"
  cap_file /etc/nsswitch.conf "$REPORT_DIR/50_network/nsswitch.txt"

  run_shell "$REPORT_DIR/50_network/bonding.txt" '
for f in /proc/net/bonding/*; do
  [[ -e "$f" ]] || continue
  echo "## $f"
  cat "$f"
  echo
done'

  run_shell "$REPORT_DIR/50_network/nic_sysfs.txt" '
for n in $(ls /sys/class/net 2>/dev/null | grep -E -v "^(lo)$"); do
  echo "## $n"
  for f in mtu operstate speed duplex address tx_queue_len carrier carrier_changes carrier_up_count carrier_down_count ifindex iflink; do
    [[ -r "/sys/class/net/$n/$f" ]] && printf "%s=" "$f" && cat "/sys/class/net/$n/$f"
  done
  echo
done'

  run_shell "$REPORT_DIR/50_network/ethtool_all.txt" '
for n in $(ls /sys/class/net 2>/dev/null | grep -E -v "^(lo)$"); do
  echo "########## INTERFACE: $n ##########"
  ethtool "$n" 2>/dev/null || true
  echo
  ethtool -i "$n" 2>/dev/null || true
  echo
  ethtool -k "$n" 2>/dev/null || true
  echo
  ethtool -g "$n" 2>/dev/null || true
  echo
  ethtool -c "$n" 2>/dev/null || true
  echo
  ethtool -l "$n" 2>/dev/null || true
  echo
  ethtool -S "$n" 2>/dev/null || true
  echo
done'

  if have tc; then
    run_shell "$REPORT_DIR/50_network/tc_qdisc_stats.txt" '
for n in $(ls /sys/class/net 2>/dev/null | grep -E -v "^(lo)$"); do
  echo "########## INTERFACE: $n ##########"
  tc -s qdisc show dev "$n" 2>/dev/null || true
  echo
done'
  else
    note "$REPORT_DIR/50_network/tc_qdisc_stats.txt" "tc command not available."
  fi

  if have nstat; then
    run_cmd "$REPORT_DIR/50_network/nstat_az.txt" nstat -az
  else
    note "$REPORT_DIR/50_network/nstat_az.txt" "nstat command not available."
  fi

  run_shell "$REPORT_DIR/50_network/rp_filter_arp_policy.txt" '
printf "## global_and_default\n"
for k in \
  net.ipv4.conf.all.rp_filter \
  net.ipv4.conf.default.rp_filter \
  net.ipv4.conf.all.arp_filter \
  net.ipv4.conf.default.arp_filter \
  net.ipv4.conf.all.arp_ignore \
  net.ipv4.conf.default.arp_ignore \
  net.ipv4.conf.all.arp_announce \
  net.ipv4.conf.default.arp_announce \
  net.ipv4.conf.all.src_valid_mark \
  net.ipv4.conf.default.src_valid_mark
do
  printf "%s=" "$k"
  sysctl -n "$k" 2>/dev/null || echo "N/A"
done
echo
for n in $(ls /sys/class/net 2>/dev/null | grep -E -v "^(lo)$"); do
  echo "## interface=$n"
  for k in rp_filter arp_filter arp_ignore arp_announce src_valid_mark; do
    printf "net.ipv4.conf.%s.%s=" "$n" "$k"
    sysctl -n "net.ipv4.conf.$n.$k" 2>/dev/null || echo "N/A"
  done
  echo
done'

  if have nmcli; then
    run_cmd "$REPORT_DIR/50_network/nmcli_general_status.txt" nmcli general status
    run_cmd "$REPORT_DIR/50_network/nmcli_device_status.txt" nmcli device status
    run_cmd "$REPORT_DIR/50_network/nmcli_connections.txt" nmcli -f NAME,UUID,TYPE,DEVICE,STATE connection show
  else
    note "$REPORT_DIR/50_network/nmcli_general_status.txt" "nmcli not available."
    note "$REPORT_DIR/50_network/nmcli_device_status.txt" "nmcli not available."
    note "$REPORT_DIR/50_network/nmcli_connections.txt" "nmcli not available."
  fi

  if have networkctl; then
    run_cmd "$REPORT_DIR/50_network/networkctl_list.txt" networkctl list
  else
    note "$REPORT_DIR/50_network/networkctl_list.txt" "networkctl not available."
  fi

  for k in \
    net.core.somaxconn \
    net.core.netdev_max_backlog \
    net.core.rmem_default \
    net.core.rmem_max \
    net.core.wmem_default \
    net.core.wmem_max \
    net.ipv4.ip_local_port_range \
    net.ipv4.tcp_max_syn_backlog \
    net.ipv4.tcp_fin_timeout \
    net.ipv4.tcp_tw_reuse \
    net.ipv4.tcp_sack \
    net.ipv4.tcp_timestamps \
    net.ipv4.tcp_window_scaling \
    net.ipv4.tcp_mtu_probing \
    net.ipv4.tcp_rmem \
    net.ipv4.tcp_wmem \
    net.ipv4.tcp_synack_retries \
    net.ipv4.tcp_syn_retries \
    net.ipv4.tcp_keepalive_time \
    net.ipv4.tcp_keepalive_intvl \
    net.ipv4.tcp_keepalive_probes \
    net.ipv4.tcp_retries2 \
    net.ipv4.tcp_slow_start_after_idle \
    net.ipv4.tcp_abort_on_overflow \
    net.ipv4.ip_forward
  do
    run_cmd "$REPORT_DIR/50_network/${k//./_}.txt" sysctl -n "$k"
  done

  if have sar && [[ "$SAMPLE_SECONDS" -gt 0 ]]; then
    run_cmd "$REPORT_DIR/50_network/sar_dev_sample.txt" sar -n DEV 1 "$SAMPLE_SECONDS"
    run_cmd "$REPORT_DIR/50_network/sar_tcp_sample.txt" sar -n TCP,ETCP 1 "$SAMPLE_SECONDS"
  else
    note "$REPORT_DIR/50_network/sar_dev_sample.txt" "sar not available or sampling disabled."
    note "$REPORT_DIR/50_network/sar_tcp_sample.txt" "sar not available or sampling disabled."
  fi
}

collect_kernel() {
  section "kernel"
  run_cmd "$REPORT_DIR/60_kernel/sysctl_curated.txt" bash -lc '
for k in \
  kernel.pid_max kernel.threads-max kernel.sched_autogroup_enabled kernel.sched_rt_runtime_us \
  fs.file-max fs.aio-max-nr fs.inotify.max_user_instances fs.inotify.max_user_watches \
  vm.swappiness vm.zone_reclaim_mode vm.min_free_kbytes vm.max_map_count \
  vm.dirty_ratio vm.dirty_background_ratio vm.dirty_bytes vm.dirty_background_bytes \
  vm.overcommit_memory vm.overcommit_ratio \
  net.core.somaxconn net.core.netdev_max_backlog \
  net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.ip_local_port_range \
  net.ipv4.tcp_max_syn_backlog net.ipv4.tcp_fin_timeout net.ipv4.tcp_tw_reuse \
  net.ipv4.tcp_sack net.ipv4.tcp_timestamps net.ipv4.tcp_window_scaling \
  net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes \
  net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter \
  net.ipv4.conf.all.arp_filter net.ipv4.conf.default.arp_filter \
  net.ipv4.conf.all.arp_ignore net.ipv4.conf.default.arp_ignore \
  net.ipv4.conf.all.arp_announce net.ipv4.conf.default.arp_announce \
  net.ipv4.conf.all.src_valid_mark net.ipv4.conf.default.src_valid_mark
do
  printf "%s=" "$k"
  sysctl -n "$k" 2>/dev/null || echo "N/A"
done'

  run_shell "$REPORT_DIR/60_kernel/sysctl_conf.txt" '
for f in /etc/sysctl.conf /etc/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf /run/sysctl.d/*.conf; do
  [[ -r "$f" ]] || continue
  echo "## $f"
  sed -n "1,200p" "$f"
  echo
done'

  run_cmd "$REPORT_DIR/60_kernel/modules_loaded.txt" cat /proc/modules
  run_cmd "$REPORT_DIR/60_kernel/cgroup_membership.txt" cat /proc/self/cgroup

  run_shell "$REPORT_DIR/60_kernel/cgroup_mounts.txt" '
mount | grep -E "cgroup|cgroup2" || true
echo
cat /proc/cgroups 2>/dev/null || true
echo
[[ -r /sys/fs/cgroup/cgroup.controllers ]] && { echo "## /sys/fs/cgroup/cgroup.controllers"; cat /sys/fs/cgroup/cgroup.controllers; } || true'

  run_shell "$REPORT_DIR/60_kernel/cgroup_limits.txt" '
for f in \
  /sys/fs/cgroup/cpu.max /sys/fs/cgroup/cpu.weight /sys/fs/cgroup/cpuset.cpus /sys/fs/cgroup/cpuset.cpus.effective \
  /sys/fs/cgroup/cpu.stat /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.high /sys/fs/cgroup/memory.current \
  /sys/fs/cgroup/memory.stat /sys/fs/cgroup/pids.max /sys/fs/cgroup/system.slice/cpu.max \
  /sys/fs/cgroup/system.slice/cpu.stat /sys/fs/cgroup/system.slice/memory.max /sys/fs/cgroup/system.slice/memory.current; do
  [[ -r "$f" ]] || continue
  echo "## $f"
  cat "$f"
  echo
done'
}

collect_services() {
  section "services"
  if have systemctl; then
    run_cmd "$REPORT_DIR/70_services/failed_units.txt" systemctl --failed
    run_cmd "$REPORT_DIR/70_services/running_services.txt" systemctl list-units --type=service --state=running
    run_cmd "$REPORT_DIR/70_services/irqbalance_status.txt" systemctl status irqbalance
    run_cmd "$REPORT_DIR/70_services/tuned_status.txt" systemctl status tuned
    run_cmd "$REPORT_DIR/70_services/chronyd_status.txt" systemctl status chronyd
    run_cmd "$REPORT_DIR/70_services/NetworkManager_status.txt" systemctl status NetworkManager
    run_cmd "$REPORT_DIR/70_services/firewalld_status.txt" systemctl status firewalld
    run_cmd "$REPORT_DIR/70_services/multipathd_status.txt" systemctl status multipathd
    run_cmd "$REPORT_DIR/70_services/default_limits.txt" systemctl show --property=DefaultLimitNOFILE --property=DefaultLimitNPROC --property=DefaultTasksMax
  else
    note "$REPORT_DIR/70_services/failed_units.txt" "systemctl not available."
    note "$REPORT_DIR/70_services/running_services.txt" "systemctl not available."
  fi

  if have tuned-adm; then
    run_cmd "$REPORT_DIR/70_services/tuned_active.txt" tuned-adm active
    run_cmd "$REPORT_DIR/70_services/tuned_list.txt" tuned-adm list
  else
    note "$REPORT_DIR/70_services/tuned_active.txt" "tuned-adm not available."
    note "$REPORT_DIR/70_services/tuned_list.txt" "tuned-adm not available."
  fi

  if have firewall-cmd; then
    run_cmd "$REPORT_DIR/70_services/firewalld_runtime.txt" firewall-cmd --list-all
    run_cmd "$REPORT_DIR/70_services/firewalld_permanent.txt" firewall-cmd --permanent --list-all
  else
    note "$REPORT_DIR/70_services/firewalld_runtime.txt" "firewall-cmd not available."
    note "$REPORT_DIR/70_services/firewalld_permanent.txt" "firewall-cmd not available."
  fi

  if have nft; then
    run_cmd "$REPORT_DIR/70_services/nft_ruleset.txt" nft list ruleset
  else
    note "$REPORT_DIR/70_services/nft_ruleset.txt" "nft not available."
  fi

  if have iptables-save; then
    run_cmd "$REPORT_DIR/70_services/iptables_save.txt" iptables-save
  else
    note "$REPORT_DIR/70_services/iptables_save.txt" "iptables-save not available."
  fi
}

collect_limits() {
  section "limits"
  run_shell "$REPORT_DIR/80_limits/ulimit_current_shell.txt" 'ulimit -a'
  run_cmd "$REPORT_DIR/80_limits/file_nr.txt" cat /proc/sys/fs/file-nr
  run_cmd "$REPORT_DIR/80_limits/file_max.txt" cat /proc/sys/fs/file-max
  run_cmd "$REPORT_DIR/80_limits/pid_max.txt" cat /proc/sys/kernel/pid_max
  run_cmd "$REPORT_DIR/80_limits/threads_max.txt" cat /proc/sys/kernel/threads-max

  run_shell "$REPORT_DIR/80_limits/security_limits.txt" '
for f in /etc/security/limits.conf /etc/security/limits.d/*; do
  [[ -r "$f" ]] || continue
  echo "## $f"
  sed -n "1,200p" "$f"
  echo
done'

  run_shell "$REPORT_DIR/80_limits/login_defs.txt" 'sed -n "1,200p" /etc/login.defs 2>/dev/null || true'
}

collect_errors() {
  section "errors"
  if have dmesg; then
    run_shell "$REPORT_DIR/90_errors/dmesg_filtered.txt" \
      "dmesg -T 2>/dev/null | grep -E -i 'blocked for more than|hung task|soft lockup|hard lockup|oom|out of memory|call trace|I/O error|buffer i/o error|blk_update_request|reset|link down|tx timeout|NETDEV WATCHDOG|xfs.*error|ext4.*error|nvme.*abort|scsi.*error|bond.*fail|mlx|ixgbe|bnxt|ena|tcp: too many orphaned|page allocation failure|rcu.*stall' | tail -n ${MAX_LOG_LINES}"

    # Pattern summary: NO shell expansion. We write a standalone awk script and run awk -f.
    local awkfile="$REPORT_DIR/90_errors/dmesg_pattern_summary.awk"
    write_dmesg_awk "$awkfile"
    run_shell "$REPORT_DIR/90_errors/dmesg_pattern_summary.txt" "dmesg -T 2>/dev/null | awk -f '$awkfile'"

    if [[ "$INCLUDE_FULL_LOGS" -eq 1 ]]; then
      run_cmd "$REPORT_DIR/90_errors/dmesg_full.txt" dmesg -T
    else
      note "$REPORT_DIR/90_errors/dmesg_full.txt" "Skipped full dmesg by default for production hygiene. Use --include-full-logs to collect it."
    fi
  else
    note "$REPORT_DIR/90_errors/dmesg_filtered.txt" "dmesg not available."
    note "$REPORT_DIR/90_errors/dmesg_pattern_summary.txt" "dmesg not available."
    note "$REPORT_DIR/90_errors/dmesg_full.txt" "dmesg not available."
  fi

  if have journalctl; then
    run_cmd "$REPORT_DIR/90_errors/journal_kernel_warn_current_boot.txt" journalctl -k -b -p warning..alert --no-pager -n "$MAX_LOG_LINES"
    run_cmd "$REPORT_DIR/90_errors/journal_system_warn_current_boot.txt" journalctl -b -p warning..alert --no-pager -n "$MAX_LOG_LINES"
  else
    note "$REPORT_DIR/90_errors/journal_kernel_warn_current_boot.txt" "journalctl not available."
    note "$REPORT_DIR/90_errors/journal_system_warn_current_boot.txt" "journalctl not available."
  fi
}

extract_tuned_active() {
  local tf="$REPORT_DIR/70_services/tuned_active.txt"
  if [[ -r "$tf" ]]; then
    grep -E -i 'Current active profile|No current active profile' "$tf" 2>/dev/null | head -n 1
  else
    echo "tuned_active=unknown"
  fi
}

write_summary() {
  local f="$REPORT_DIR/99_summary/quick_flags.txt"
  : > "$f"

  {
    echo "Server diagnostic quick flags"
    echo "Generated: $(date '+%F %T %z')"
    echo "Host: $HOST"
    echo "Script version: $SCRIPT_VERSION"
    echo
  } >> "$f"

  local cpus load1 mem_avail_kb swap_total_kb swap_free_kb
  cpus="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo unknown)"
  load1="$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo unknown)"
  mem_avail_kb="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  swap_total_kb="$(awk '/SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  swap_free_kb="$(awk '/SwapFree:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"

  echo "- Online CPUs: $cpus" >> "$f"
  echo "- 1-minute load average: $load1" >> "$f"
  echo "- MemAvailable: ${mem_avail_kb} kB" >> "$f"
  echo "- SwapTotal: ${swap_total_kb} kB" >> "$f"
  echo "- SwapFree: ${swap_free_kb} kB" >> "$f"
  if [[ "$swap_total_kb" -gt 0 ]]; then
    echo "- SwapUsed: $((swap_total_kb - swap_free_kb)) kB" >> "$f"
  fi
  echo >> "$f"

  echo "[Time sync]" >> "$f"
  if have timedatectl; then
    local ntpsync ntpsvc tz
    ntpsync="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
    ntpsvc="$(timedatectl show -p NTPService --value 2>/dev/null || true)"
    tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    echo "Timezone=${tz:-unknown}" >> "$f"
    echo "NTPSynchronized=${ntpsync:-unknown}" >> "$f"
    echo "NTPService=${ntpsvc:-unknown}" >> "$f"
  else
    echo "timedatectl unavailable" >> "$f"
  fi
  echo >> "$f"

  echo "[Kernel]" >> "$f"
  echo "running_kernel=$(uname -r 2>/dev/null || echo unknown)" >> "$f"
  if have grubby; then
    local defk defver
    defk="$(grubby --default-kernel 2>/dev/null || true)"
    echo "default_kernel=${defk:-unknown}" >> "$f"
    defver="$(basename "$defk" 2>/dev/null | sed -E 's/^vmlinuz-//')"
    if [[ -n "$defver" ]] && [[ "$defver" != "$(uname -r 2>/dev/null)" ]]; then
      echo "WARNING: running kernel differs from default boot kernel (reboot will change kernel)." >> "$f"
    fi
  else
    echo "grubby unavailable" >> "$f"
  fi
  echo >> "$f"

  echo "[Tool coverage]" >> "$f"
  if have sar && have mpstat && have iostat; then
    echo "sysstat=present (sar/mpstat/iostat)" >> "$f"
  else
    echo "sysstat=partial_or_absent (sar=$(have sar && echo yes || echo no) mpstat=$(have mpstat && echo yes || echo no) iostat=$(have iostat && echo yes || echo no))" >> "$f"
  fi
  echo >> "$f"

  echo "[tuned]" >> "$f"
  echo "$(extract_tuned_active)" >> "$f"
  echo >> "$f"

  echo "[Pressure Stall Information]" >> "$f"
  local psi_found=0
  for p in cpu memory io; do
    if [[ -r "/proc/pressure/$p" ]]; then
      psi_found=1
      echo "## /proc/pressure/$p" >> "$f"
      cat "/proc/pressure/$p" >> "$f"
      echo >> "$f"
    fi
  done
  if [[ "$psi_found" -eq 0 ]]; then
    echo "PSI unavailable on this host/kernel build." >> "$f"
    echo >> "$f"
  fi

  echo "[Filesystems >= 85% used]" >> "$f"
  df -PTh 2>/dev/null | awk 'NR==1 || $6+0 >= 85' >> "$f" || true
  echo >> "$f"

  echo "[NIC RX/TX errors and drops]" >> "$f"
  awk '
    NR>2 {
      iface=$1; sub(/:/,"",iface);
      rx_err=$4; rx_drop=$5; tx_err=$12; tx_drop=$13;
      if (rx_err+rx_drop+tx_err+tx_drop > 0) {
        printf "%s rx_err=%s rx_drop=%s tx_err=%s tx_drop=%s\n", iface, rx_err, rx_drop, tx_err, tx_drop
      }
    }' /proc/net/dev 2>/dev/null >> "$f" || true
  echo >> "$f"

  echo "[Multi-homing + route hints]" >> "$f"
  local ifcount onlink32
  ifcount="$(ip -br addr 2>/dev/null | awk '$1!="lo"{c++} END{print c+0}')"
  echo "non_lo_interfaces=$ifcount" >> "$f"
  if [[ "$ifcount" -ge 2 ]]; then
    echo "WARNING: multi-homed host detected; validate rp_filter/ARP policy and route symmetry." >> "$f"
    onlink32="$(ip route show table main 2>/dev/null | awk '$1 ~ /\/32$/ && $0 !~ / via / {c++} END{print c+0}')"
    echo "onlink_host_routes_no_via_count=$onlink32" >> "$f"
    if [[ "$onlink32" -gt 0 ]]; then
      echo "Sample on-link /32 routes (up to 10):" >> "$f"
      ip route show table main 2>/dev/null | awk '$1 ~ /\/32$/ && $0 !~ / via / {print}' | head -n 10 >> "$f"
    fi
  fi
  echo >> "$f"

  echo "[rp_filter per-interface]" >> "$f"
  echo "NOTE: 0=disabled, 1=strict, 2=loose (recommended for asymmetric multi-homing when required by design)" >> "$f"
  for n in /sys/class/net/*; do
    [[ -d "$n" ]] || continue
    base=$(basename "$n")
    [[ "$base" == "lo" ]] && continue
    val=$(sysctl -n "net.ipv4.conf.$base.rp_filter" 2>/dev/null || echo "N/A")
    echo "$base rp_filter=$val" >> "$f"
  done
  echo >> "$f"

  echo "[THP state]" >> "$f"
  [[ -r /sys/kernel/mm/transparent_hugepage/enabled ]] && echo "enabled=$(cat /sys/kernel/mm/transparent_hugepage/enabled)" >> "$f"
  [[ -r /sys/kernel/mm/transparent_hugepage/defrag ]] && echo "defrag=$(cat /sys/kernel/mm/transparent_hugepage/defrag)" >> "$f"
  echo >> "$f"

  echo "[Selected sysctl flags]" >> "$f"
  for k in \
    vm.swappiness vm.zone_reclaim_mode kernel.numa_balancing \
    net.core.netdev_max_backlog net.core.somaxconn \
    net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter \
    net.ipv4.conf.all.arp_filter net.ipv4.conf.default.arp_filter \
    net.ipv4.conf.all.arp_ignore net.ipv4.conf.default.arp_ignore \
    net.ipv4.conf.all.arp_announce net.ipv4.conf.default.arp_announce \
    net.ipv4.conf.all.src_valid_mark net.ipv4.conf.default.src_valid_mark \
    net.ipv4.tcp_timestamps
  do
    printf "%s=" "$k" >> "$f"
    sysctl -n "$k" 2>/dev/null >> "$f" || echo "N/A" >> "$f"
  done
  echo >> "$f"

  echo "[nstat selected counters]" >> "$f"
  if have nstat; then
    nstat -az 2>/dev/null | awk '
      BEGIN{IGNORECASE=1}
      $1 ~ /^(IpInAddrErrors|IpInDiscards|IpInHdrErrors|IpReasmFails|TcpRetransSegs|TcpExtTCPTimeouts|TcpExtTCPSynRetrans|TcpExtListenDrops|TcpExtListenOverflows|TcpExtTCPLossFailures|TcpExtTCPBacklogDrop)$/ {print}
    ' >> "$f" || true
  else
    echo "nstat unavailable" >> "$f"
  fi
  echo >> "$f"

  echo "[Current boot warnings (tail)]" >> "$f"
  if have journalctl; then
    journalctl -k -b -p warning..alert --no-pager -n 50 2>/dev/null >> "$f" || true
  elif have dmesg; then
    dmesg -T 2>/dev/null | tail -n 50 >> "$f" || true
  fi
  echo >> "$f"

  echo "[dmesg pattern summary]" >> "$f"
  if [[ -r "$REPORT_DIR/90_errors/dmesg_pattern_summary.txt" ]]; then
    sed '/^### /d;/^$/d' "$REPORT_DIR/90_errors/dmesg_pattern_summary.txt" >> "$f" || true
  else
    echo "Unavailable." >> "$f"
  fi

  cat >> "$f" <<'EOF'

Interpretation hints:
- Idle snapshots are useful for configuration comparison, not proof of a runtime bottleneck.
- Swap configured is not the same as swap causing pain; look for swap-in/out and major faults.
- Non-zero NIC error/drop counters deserve explanation, but cumulative counters need time context.
- THP, swappiness, NUMA, MTU, offloads, rings, routes, rp_filter/ARP policy, and cgroup caps are comparison targets.
- Kernel warnings beat theory. Fix real transport, memory, storage, or lockup faults before tuning folklore.
EOF
}

make_readme() {
  cat > "$REPORT_DIR/README.txt" <<EOF
linux_server_diag_v7.sh output
==============================

Purpose
-------
Read-only server-side evidence collection for Linux application hosts.
No application log parsing. No synthetic tests. No config changes.

Safety posture
--------------
- Per-command timeout with SIGKILL escalation.
- Low CPU priority + idle-class I/O scheduling when available.
- Lockless LVM reads.
- Full dmesg disabled by default.

Notable v7 fixes
----------------
- dmesg pattern summary is executed via awk -f to avoid any shell expansion issues.
- deprecated egrep usage removed (grep -E is used).
- missing tools produce explicit placeholder notes for easier diffing.
EOF
}

bundle_report() {
  section "bundle"
  TAR_PATH="${REPORT_DIR}.tar.gz"
  if have tar; then
    exec_wrapped tar -C "$(dirname "$REPORT_DIR")" -czf "$TAR_PATH" "$(basename "$REPORT_DIR")" 2>/dev/null || true
  else
    note "$REPORT_DIR/00_meta/tar_note.txt" "tar not available; skipping bundle creation."
  fi
  { echo "REPORT_DIR=$REPORT_DIR"; echo "TAR_PATH=$TAR_PATH"; } > "$REPORT_DIR/00_meta/output_paths.txt"
  log "Report directory: $REPORT_DIR"
  [[ -f "$TAR_PATH" ]] && log "Tar bundle: $TAR_PATH"
}

main() {
  log "Starting ${SCRIPT_NAME} (${SCRIPT_VERSION}) on ${HOST}"
  make_readme
  collect_meta "$@"
  collect_os
  collect_cpu
  collect_memory
  collect_storage
  collect_network
  collect_kernel
  collect_services
  collect_limits
  collect_errors
  write_summary
  bundle_report
  log "Collection complete"
  echo
  echo "Done."
  echo "Report directory: $REPORT_DIR"
  [[ -f "$TAR_PATH" ]] && echo "Tar bundle: $TAR_PATH"
}

main "$@"

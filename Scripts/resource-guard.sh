#!/bin/bash
# Watches memory, swap, CPU load and free disk space of this machine (the test VM) and steps in
# before the machine freezes: a test run, a mutation run or a build that runs away can fill the
# memory, the swap or the disk until the VM no longer answers.
#
#   Scripts/resource-guard.sh install    run it in the background now and at every login (launchd)
#   Scripts/resource-guard.sh uninstall  stop it and remove it from launchd
#   Scripts/resource-guard.sh status     the last sample and the last alerts
#   Scripts/resource-guard.sh run        run it in the foreground (what launchd starts)
#
# Every sample (each AFM_GUARD_INTERVAL seconds, default 5) is written to the status file. A change
# of level is written to the log and shown as a notification once it has lasted 30 s (a short peak
# is not news); a change to critical, and each step taken, at once.
#
# Levels: warn when the memory pressure is "warn", free memory is under 20%, anything is in swap, the
# load is over 4 times the cores or less than 15 GiB of disk are free; critical when the
# pressure is "critical", free memory is under 8%, swap holds 1 GiB or more, the load is over
# 8 times the cores or less than 5 GiB of disk are free. The load is the 5-minute average: builds
# and parallel tests keep all cores busy (a load of 1.5 to 4 times the cores) without harm; what
# freezes the machine is memory, swap and disk, not a busy processor.
#
# Steps, only on development processes (tests, compiler, build, Muter, the gates' tools), never on
# anything else: at a critical load they are lowered to the least priority; at a critical memory,
# swap or disk level the largest of them by memory is ended (TERM, then KILL after 3 s), at most
# once every 20 s. AFM_GUARD_ACTION=notify only reports.
set -euo pipefail

label="com.afm.resource-guard"
plist="$HOME/Library/LaunchAgents/$label.plist"
log="$HOME/Library/Logs/afm-resource-guard.log"
status_file="$HOME/Library/Logs/afm-resource-guard.status"
interval="${AFM_GUARD_INTERVAL:-5}"
action="${AFM_GUARD_ACTION:-kill}"
# Process names (ps comm, last path component) the guard may lower or end.
guarded='^(xctest|swiftpm-testing-helper|swift-frontend|swift-build|swift-test|swift-driver|swift-package|swiftc|clang|ld|muter|swiftlint|swift-format|periphery|lizard|jscpd|semgrep|trivy|osv-scanner|codeql|java|leaks|xcodebuild|.*PackageTests.*|.*-fuzz.*|.*Stress.*)$'

note() {
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') $*"
  echo "$line" >>"$log"
  echo "$line" >&2
}

notify() {
  osascript -e "display notification \"$1\" with title \"Resource guard\" sound name \"Basso\"" \
    >/dev/null 2>&1 || true
}

# Prints "pid rss name" of the development processes, the largest by memory first.
guarded_processes() {
  ps -axo pid=,rss=,comm= | while read -r pid rss comm; do
    name="${comm##*/}"
    if [[ "$name" =~ $guarded ]] && [[ "$pid" != "$$" ]]; then
      echo "$pid $rss $name"
    fi
  done | sort -k2 -nr
}

end_largest() {
  local reason="$1" pid rss name
  read -r pid rss name < <(guarded_processes | head -1) || true
  if [[ -z "${pid:-}" ]]; then
    note "CRITICAL ($reason): no development process to end"
    return
  fi
  note "ENDING pid $pid $name ($((rss / 1024)) MiB) because $reason"
  notify "Ended $name ($((rss / 1024)) MiB): $reason"
  kill -TERM "$pid" 2>/dev/null || true
  for _ in 1 2 3; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 1
  done
  kill -KILL "$pid" 2>/dev/null || true
}

lower_priority() {
  local pid
  guarded_processes | while read -r pid _ _; do renice -n 20 -p "$pid" >/dev/null 2>&1 || true; done
}

run() {
  mkdir -p "$(dirname "$log")"
  local cores last_level="ok" last_end=0 seen_level="ok" seen_count=0
  cores="$(sysctl -n hw.ncpu)"
  note "started (interval ${interval}s, action $action, $cores cores)"
  while true; do
    local pressure free swap_mb load disk_gb level="ok" reasons="" crit_mem=""
    pressure="$(sysctl -n kern.memorystatus_vm_pressure_level)"
    free="$(sysctl -n kern.memorystatus_level)"
    swap_mb="$(sysctl -n vm.swapusage | sed -E 's/.*used = ([0-9.]+)M.*/\1/')"
    swap_mb="${swap_mb%.*}"
    load="$(sysctl -n vm.loadavg | awk '{print $3}')"
    disk_gb="$(df -k / | awk 'NR==2 {print int($4 / 1048576)}')"

    warn() { reasons+="$1; "; [[ "$level" == "ok" ]] && level="warn"; }
    crit() { reasons+="$1; "; level="critical"; }
    if ((pressure >= 4)); then crit "memory pressure critical"; crit_mem=1
    elif ((pressure >= 2)); then warn "memory pressure warn"; fi
    if ((free < 8)); then crit "free memory ${free}%"; crit_mem=1
    elif ((free < 20)); then warn "free memory ${free}%"; fi
    # macOS sizes its swap itself and cannot be told a limit; the guard keeps it under 1 GiB.
    if ((swap_mb >= 1024)); then crit "swap ${swap_mb} MiB"; crit_mem=1
    elif ((swap_mb > 0)); then warn "swap ${swap_mb} MiB"; fi
    if ((disk_gb < 5)); then crit "free disk ${disk_gb} GiB"; crit_mem=1
    elif ((disk_gb < 15)); then warn "free disk ${disk_gb} GiB"; fi
    local load_crit load_warn
    load_crit="$(awk -v l="$load" -v c="$cores" 'BEGIN {print (l > 8 * c) ? 1 : 0}')"
    load_warn="$(awk -v l="$load" -v c="$cores" 'BEGIN {print (l > 4 * c) ? 1 : 0}')"
    if ((load_crit)); then crit "load $load"
    elif ((load_warn)); then warn "load $load"; fi

    echo "$(date '+%H:%M:%S') $level | pressure $pressure, free ${free}%, swap ${swap_mb} MiB, load $load/$cores, disk ${disk_gb} GiB free${reasons:+ | $reasons}" >"$status_file"

    # A level counts once it has held for 6 samples; critical counts at once.
    if [[ "$level" == "$seen_level" ]]; then
      seen_count=$((seen_count + 1))
    else
      seen_level="$level"
      seen_count=1
    fi
    if [[ "$level" != "$last_level" ]] && { ((seen_count >= 6)) || [[ "$level" == "critical" ]]; }; then
      note "$(echo "$level" | tr '[:lower:]' '[:upper:]'): ${reasons:-back to normal} (free ${free}%, swap ${swap_mb} MiB, load $load, disk ${disk_gb} GiB)"
      [[ "$level" != "ok" ]] && notify "${level}: ${reasons}"
      last_level="$level"
    fi
    if [[ "$action" == "kill" && "$level" == "critical" ]]; then
      ((load_crit)) && lower_priority
      if [[ -n "$crit_mem" ]] && (($(date +%s) - last_end >= 20)); then
        end_largest "$reasons"
        last_end="$(date +%s)"
      fi
    fi
    sleep "$interval"
  done
}

install() {
  mkdir -p "$(dirname "$plist")" "$(dirname "$log")"
  local script
  script="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$script</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/afm-resource-guard.err</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
  echo "installed; log: $log, status: $status_file"
}

case "${1:-}" in
  run) run ;;
  install) install ;;
  uninstall)
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    rm -f "$plist"
    echo "removed"
    ;;
  status)
    cat "$status_file" 2>/dev/null || echo "no sample yet"
    tail -n 10 "$log" 2>/dev/null || true
    ;;
  *)
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac

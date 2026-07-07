#!/usr/bin/env bash
# Report current RAM and CPU load in one line.  Run this (via the Bash tool,
# whose approvals persist across turns) before any heavy build / LLM / VM /
# Docker work — per the global CLAUDE.md pacing rule.
#
#   bash tools/sysload.sh
#
# It shells out to PowerShell's CIM providers *internally*, so the whole check
# lives behind a single approvable `bash tools/sysload.sh` invocation — the
# nested PowerShell is a child of bash and does not prompt on its own.
set -u

ps=$(powershell -NoProfile -NonInteractive -Command '
  $os  = Get-CimInstance Win32_OperatingSystem
  $cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
  "{0} {1} {2}" -f $os.FreePhysicalMemory, $os.TotalVisibleMemorySize, [int]$cpu
' 2>/dev/null | tr -d '\r' | tr -s ' ')

free_kb=$(printf '%s' "$ps" | awk '{print $1}')
total_kb=$(printf '%s' "$ps" | awk '{print $2}')
cpu=$(printf '%s' "$ps" | awk '{print $3}')

if [ -n "${total_kb:-}" ] && [ "${total_kb:-0}" -gt 0 ] 2>/dev/null; then
  free_gb=$(awk "BEGIN{printf \"%.1f\", $free_kb/1048576}")
  total_gb=$(awk "BEGIN{printf \"%.1f\", $total_kb/1048576}")
  used_pct=$(awk "BEGIN{printf \"%.0f\", (1-$free_kb/$total_kb)*100}")
  echo "RAM: ${free_gb} GB free / ${total_gb} GB total (${used_pct}% used)   CPU: ${cpu:-?}% load"
else
  echo "sysload: could not read WMI load (PowerShell CIM returned nothing)"
fi

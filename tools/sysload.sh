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
#
# CPU IS MEASURED, NOT ASKED FOR (2026-09-26). This used to read
# Win32_Processor.LoadPercentage and print `[int]` of it. On this machine that property
# comes back EMPTY, and `[int]$null` is 0 -- so the tool printed "CPU: 0% load" for every
# sample it ever took, including during a --daily with two extra cores deliberately
# burning. Every "CPU 0%" it reported before that date was a fabricated value, and at
# least one argument in CLAUDE.md rested on it. Now: sum every process's CPU time, wait
# two seconds, sum again; the delta over (2 s x logical cores) is the utilisation. Any
# failure to measure prints `?`, never a number.
set -u

ps=$(powershell -NoProfile -NonInteractive -Command '
  $os  = Get-CimInstance Win32_OperatingSystem
  function Snap { $t = 0.0; foreach ($p in Get-Process) { try { $t += $p.TotalProcessorTime.TotalSeconds } catch {} }; $t }
  $cpu = "?"
  try {
    $n = [Environment]::ProcessorCount
    $a = Snap; $w = [Diagnostics.Stopwatch]::StartNew(); Start-Sleep -Milliseconds 2000; $b = Snap
    $secs = $w.Elapsed.TotalSeconds
    if ($n -gt 0 -and $secs -gt 0 -and $b -ge $a) { $cpu = [math]::Round(100 * ($b - $a) / ($secs * $n)) }
  } catch { $cpu = "?" }
  "{0} {1} {2}" -f $os.FreePhysicalMemory, $os.TotalVisibleMemorySize, $cpu
' 2>/dev/null | tr -d '\r' | tr -s ' ')

free_kb=$(printf '%s' "$ps" | awk '{print $1}')
total_kb=$(printf '%s' "$ps" | awk '{print $2}')
cpu=$(printf '%s' "$ps" | awk '{print $3}')

if [ -n "${total_kb:-}" ] && [ "${total_kb:-0}" -gt 0 ] 2>/dev/null; then
  free_gb=$(awk "BEGIN{printf \"%.1f\", $free_kb/1048576}")
  total_gb=$(awk "BEGIN{printf \"%.1f\", $total_kb/1048576}")
  used_pct=$(awk "BEGIN{printf \"%.0f\", (1-$free_kb/$total_kb)*100}")
  echo "RAM: ${free_gb} GB free / ${total_gb} GB total (${used_pct}% used)   CPU: ${cpu:-?}% load (measured over 2 s)"
else
  echo "sysload: could not read WMI load (PowerShell CIM returned nothing)"
fi

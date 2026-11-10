#!/usr/bin/env bash
# stuck_procs.sh -- REPORT ONLY: shell/tool processes that may be stuck, machine-wide.
#
#   bash tools/stuck_procs.sh            # flag orphans, and anything older than 2 h
#   bash tools/stuck_procs.sh --hours 6  # change the age threshold
#
# Two signals, because neither alone is enough:
#   ORPHAN  -- the process that started it is gone. A tool call that timed out kills
#              its shell, not the grep/zig/compiler the shell was waiting on, so the
#              child keeps running with nobody to read its output.
#   OLD     -- alive longer than the threshold. Legitimate for a --daily tier; worth
#              a look for anything else.
# Each row carries CPU-seconds, the average share of one core since it started (near
# 100% = spinning, near 0% = blocked), and OWNER: the first ancestor that is not a
# shell -- usually the claude.exe session or terminal that launched it.
#
# PARENTAGE COMES FROM TWO TABLES, and the first draft of this tool got that wrong.
# Git Bash starts a child by fork+exec, so Windows records the child's parent as an
# intermediate that has already exited: by Win32_Process alone EVERY pipeline stage
# looks orphaned (the first run called an active grep in another session an orphan).
# The MSYS table (`ps -l`) keeps the real parent and reparents a true orphan to PID 1,
# so an MSYS process is judged there; Windows' answer is used only above the
# top-level shell. Command lines still come from Win32_Process (`ps` truncates them).
#
# It kills nothing -- `tools/kill_orphans.sh` does that, scoped to this tree. A
# process from another project or session is its owner's call.
set -u
HOURS=2
while [ $# -gt 0 ]; do
  case "$1" in
    --hours) HOURS="$2"; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "stuck_procs: unknown argument '$1' (try --help)" >&2; exit 2 ;;
  esac
done

work=$(mktemp -d "${TMPDIR:-/tmp}/stuck_procs.XXXXXX")
trap 'rm -rf "$work"' EXIT
# winpid cygpid cygppid, one per MSYS process. `ps -l` may prefix a status letter.
ps -l | awk 'NR > 1 { if ($1 !~ /^[0-9]+$/) $1 = ""; $0 = $0; print $4, $1, $2 }' > "$work/msys.txt"
if [ "$(wc -l < "$work/msys.txt")" -lt 1 ]; then
  echo "stuck_procs: REFUSE -- the MSYS process table is empty (ps -l failed?), parentage would be guessed" >&2
  exit 2
fi
cat > "$work/scan.ps1" <<'EOF'
param([double]$Hours, [string]$MsysFile)
$now = Get-Date
$all = @(Get-CimInstance Win32_Process)
if ($all.Count -lt 20) { Write-Output "REFUSE: Win32_Process returned $($all.Count) processes -- the listing failed"; exit 2 }
$win = @{}; foreach ($p in $all) { $win[[int]$p.ProcessId] = $p }
$cygOf = @{}; $winOfCyg = @{}
foreach ($l in Get-Content $MsysFile) {
  $f = $l -split '\s+'; if ($f.Count -lt 3) { continue }
  $cygOf[[int]$f[0]] = @{ Pid = [int]$f[1]; PPid = [int]$f[2] }; $winOfCyg[[int]$f[1]] = [int]$f[0]
}
$shells = '^(bash|sh|cmd|conhost|timeout|env)\.exe$'
# Windows parent, valid only if it started before the child (PIDs are reused)
function WinParent($p) { $q = $win[[int]$p.ParentProcessId]; if ($q -and $q.CreationDate -le $p.CreationDate) { $q } else { $null } }
# The real parent: the MSYS one while there is one, Windows' above the top-level shell.
function Parent($p) {
  $c = $cygOf[[int]$p.ProcessId]
  if ($c -and $c.PPid -ne 1) { $w = $winOfCyg[$c.PPid]; if ($w) { return $win[$w] } }
  WinParent $p
}
$names = '^(bash|sh|grep|sed|awk|tail|head|sort|cut|find|xargs|timeout|sleep|python[0-9.]*|zig|zebra.*|lld-link|cmake|make|git)\.exe$'
$rows = foreach ($p in $all) {
  if ($p.Name -notmatch $names) { continue }
  $ageH = ($now - $p.CreationDate).TotalHours
  $c = $cygOf[[int]$p.ProcessId]
  # an MSYS child whose MSYS parent is alive is not an orphan, whatever Windows says
  $orphan = if ($c -and $c.PPid -ne 1) { -not $winOfCyg[$c.PPid] } else { -not (WinParent $p) }
  if (-not $orphan -and $ageH -lt $Hours) { continue }
  $o = Parent $p; $hops = 0
  while ($o -and $o.Name -match $shells -and $hops -lt 20) { $o = Parent $o; $hops++ }
  $owner = if ($o) { "$($o.Name -replace '\.exe$','') $($o.ProcessId)" } else { '(gone)' }
  $gp = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
  $cpu = if ($gp) { $gp.TotalProcessorTime.TotalSeconds } else { $null }
  $pct = if ($cpu -ne $null -and $ageH -gt 0) { [math]::Round(100 * $cpu / ($ageH * 3600)) } else { '?' }
  $cmd = ($p.CommandLine -replace '\s+', ' '); if (-not $cmd) { $cmd = '(command line not readable)' }
  [pscustomobject]@{
    Why = (@(if ($orphan) {'ORPHAN'}) + @(if ($ageH -ge $Hours) {'OLD'})) -join '+'
    PID = $p.ProcessId; AgeH = [math]::Round($ageH, 1)
    CPUs = if ($cpu -ne $null) { [math]::Round($cpu) } else { '?' }; 'Core%' = $pct; Owner = $owner
    Cmd = $cmd.Substring(0, [math]::Min(130, $cmd.Length))
  }
}
$rows = @($rows)
Write-Output ("stuck_procs: {0} processes ({1} MSYS), {2} flagged (orphan, or older than {3} h)" -f $all.Count, $cygOf.Count, $rows.Count, $Hours)
if ($rows.Count) { $rows | Sort-Object AgeH -Descending | Format-Table -AutoSize -Wrap | Out-String -Width 260 }
EOF
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$work/scan.ps1")" \
  -Hours "$HOURS" -MsysFile "$(cygpath -w "$work/msys.txt")"

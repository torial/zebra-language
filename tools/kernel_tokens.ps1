# kernel_tokens.ps1 -- how many kernel Token objects are alive, and how much paged
# pool they and their security companions hold. Report only; called by doctor.sh.
#
# WHY: every process started from Git Bash (the MSYS2/Cygwin runtime) leaks one
# kernel Token object until reboot (git-for-windows/git#6471, #6499;
# microsoft/terminal#20781). Measured 2026-11-02: ~0.7-1 per start on MSYS 3.6.5,
# none on MSYS 3.6.10 (Git 2.56.0.windows.4) -- but what leaked stays until reboot,
# and an older Git elsewhere still leaks. Our gates are bash scripts that start hundreds of
# thousands of processes, so the leak is ours to notice. On 2026-11-02, after 7
# days up, this machine held 2.29M tokens -- ~6 GB of paged pool that no process
# accounts for (Task Manager and System Informer showed 7 GB "missing") -- and
# smoke ran ~5x slow. A reboot reclaims all of it.
#
# HOW: NtQuerySystemInformation(SystemPoolTagInformation = 22), which needs no
# admin. Pool tags: Toke (the token), SeAt / SeTd / SeDt (its attributes, token
# defaults and dynamic part). Performance counters were not usable here: on this
# machine they had been broken until `lodctr /R`, and a reading that silently
# came back empty is the failure this script refuses rather than reports.
#
# OUTPUT: one line, `tokens=N pagedMB=X`. Exit 2 (with a reason on stderr) when
# it cannot measure: the call failed, the Toke tag is absent, or the count is
# zero -- a live system always has tokens, this script's own included.

$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class ZbrPoolTags {
    [DllImport("ntdll.dll")]
    public static extern int NtQuerySystemInformation(int cls, IntPtr buf, int len, out int ret);
}
"@
$len = 1MB
while ($true) {
    $buf = [Runtime.InteropServices.Marshal]::AllocHGlobal($len)
    $ret = 0
    $st = [ZbrPoolTags]::NtQuerySystemInformation(22, $buf, $len, [ref]$ret)
    if ($st -eq 0) { break }
    [Runtime.InteropServices.Marshal]::FreeHGlobal($buf)
    if ($st -ne -1073741820) {   # anything but STATUS_INFO_LENGTH_MISMATCH
        [Console]::Error.WriteLine(("NtQuerySystemInformation failed: 0x{0:X8}" -f $st)); exit 2
    }
    $len = [Math]::Max($ret, $len * 2)
}
# SYSTEM_POOLTAG_INFORMATION: ULONG Count; (pad to 8) SYSTEM_POOLTAG[Count]
# SYSTEM_POOLTAG (x64, 40 bytes): UCHAR Tag[4]; ULONG PagedAllocs; ULONG PagedFrees;
#   (pad) SIZE_T PagedUsed; ULONG NonPagedAllocs; ULONG NonPagedFrees; SIZE_T NonPagedUsed
$count = [Runtime.InteropServices.Marshal]::ReadInt32($buf, 0)
$tokens = -1
$paged = [int64]0
for ($i = 0; $i -lt $count; $i++) {
    $o = 8 + $i * 40
    $tb = New-Object byte[] 4
    [Runtime.InteropServices.Marshal]::Copy([IntPtr]($buf.ToInt64() + $o), $tb, 0, 4)
    $tag = [Text.Encoding]::ASCII.GetString($tb)
    if (@('Toke', 'SeAt', 'SeTd', 'SeDt') -contains $tag) {
        $paged += [Runtime.InteropServices.Marshal]::ReadInt64($buf, $o + 16)
        if ($tag -eq 'Toke') {
            $pa = [uint32][Runtime.InteropServices.Marshal]::ReadInt32($buf, $o + 4)
            $pf = [uint32][Runtime.InteropServices.Marshal]::ReadInt32($buf, $o + 8)
            # the counters are 32-bit and wrap on a long uptime; the difference mod 2^32 does not
            $tokens = ([int64]$pa - [int64]$pf + 4294967296) % 4294967296
        }
    }
}
[Runtime.InteropServices.Marshal]::FreeHGlobal($buf)
if ($tokens -lt 0) { [Console]::Error.WriteLine("pool tag 'Toke' not found among $count tags"); exit 2 }
if ($tokens -eq 0) { [Console]::Error.WriteLine("'Toke' reads 0 outstanding -- impossible on a live system"); exit 2 }
"tokens={0} pagedMB={1}" -f $tokens, [int64]($paged / 1MB)

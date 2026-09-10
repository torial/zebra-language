# Zebra installer for Windows (PowerShell 5+).
#   irm https://raw.githubusercontent.com/torial/zebra-language/main/install/install.ps1 | iex
# Downloads the latest release into %USERPROFILE%\.zebra and adds it to the user PATH.
# The release carries its own Zig (zebra\zig\), so nothing else is needed.
$ErrorActionPreference = 'Stop'
$repo = 'torial/zebra-language'
$tag = $env:ZEBRA_VERSION
if (-not $tag) {
  $tag = (Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest").tag_name
}
$ver = $tag.TrimStart('v')
$arch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'aarch64' } else { 'x86_64' }
$asset = "zebra-$ver-windows-$arch.zip"
$url = "https://github.com/$repo/releases/download/$tag/$asset"
$dest = if ($env:ZEBRA_HOME) { $env:ZEBRA_HOME } else { Join-Path $env:USERPROFILE '.zebra' }
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("zebra-install-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
Write-Host "downloading $asset ..."
Invoke-WebRequest -Uri $url -OutFile (Join-Path $tmp $asset)
try {
  $sums = (Invoke-WebRequest -Uri "https://github.com/$repo/releases/download/$tag/SHA256SUMS.txt").Content
  $want = ($sums -split "`n" | Where-Object { $_ -match "\s$([regex]::Escape($asset))$" } | ForEach-Object { ($_ -split '\s+')[0] })
  if ($want) {
    $got = (Get-FileHash (Join-Path $tmp $asset) -Algorithm SHA256).Hash.ToLower()
    if ($got -ne $want.ToLower()) { throw "checksum mismatch for $asset" }
  }
} catch { if ($_.Exception.Message -like '*checksum*') { throw } }
Expand-Archive -Path (Join-Path $tmp $asset) -DestinationPath $tmp -Force
New-Item -ItemType Directory -Path $dest -Force | Out-Null
$current = Join-Path $dest 'current'
if (Test-Path $current) { Remove-Item -Recurse -Force $current }
Move-Item (Join-Path $tmp "zebra-$ver-windows-$arch") $current
Remove-Item -Recurse -Force $tmp
Write-Host "installed zebra $ver to $current"
& (Join-Path $current 'zebra.exe') --version
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not ($userPath -split ';' | Where-Object { $_ -eq $current })) {
  [Environment]::SetEnvironmentVariable('Path', "$current;$userPath", 'User')
  Write-Host "added $current to your user PATH (open a new terminal to pick it up)"
}

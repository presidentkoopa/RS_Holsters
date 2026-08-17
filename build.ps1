# Packs this repo into RS_HardPoints.zip.
#
# ALWAYS DELETES THE OLD ZIP FIRST. `7z a` on an existing archive only adds
# and updates entries -- it never removes ones whose source file is gone.
# That silently left two deleted ZScript files sitting in RS_Main.zip the
# night this repo was split out, which is exactly the shape of bug that
# becomes a fatal duplicate-class crash the moment two pk3s both carry a copy
# of the same class. Delete-then-rebuild is the only version of this script
# that can't reintroduce that.
param(
  [string]$Dest = ''
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$out  = Join-Path $root 'RS_HardPoints.zip'
$sevenZip = 'C:\Program Files\7-Zip\7z.exe'

if (-not (Test-Path $sevenZip)) { throw "7-Zip not found at $sevenZip" }

if (Test-Path $out) { Remove-Item $out -Force }

& $sevenZip a -tzip -mx=0 $out "$root\*" -r `
    '-xr!.git' '-x!.gitattributes' '-x!.gitignore' '-x!build.ps1' '-x!RS_HardPoints.zip' '-xr!media' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "7-Zip failed with exit code $LASTEXITCODE" }

Write-Output ("built {0} ({1:N0} bytes)" -f $out, (Get-Item $out).Length)

if ($Dest -ne '') {
  Copy-Item $out $Dest -Force
  Write-Output "copied to $Dest"
}

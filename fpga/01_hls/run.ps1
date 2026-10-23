# ---------------------------------------------------------------------------
#  run.ps1 -- drive Vivado HLS 2019.1 from PowerShell, no GUI needed.
#
#  Usage:
#     .\run.ps1              # csim + csynth + export IP
#     .\run.ps1 csim         # C simulation only (fast)
#     .\run.ps1 csynth       # synthesis only
# ---------------------------------------------------------------------------
param(
    [ValidateSet('all', 'csim', 'csynth')]
    [string]$Stage = 'all'
)

$ErrorActionPreference = 'Stop'

$VivadoRoot = 'D:\vivado2019.1\VIVADO20191'
$HlsBat     = Join-Path $VivadoRoot 'Vivado\2019.1\bin\vivado_hls.bat'
if (-not (Test-Path $HlsBat)) { throw "vivado_hls.bat not found: $HlsBat" }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $here
try {
    $env:VHLS_STAGE = $Stage
    Write-Host "=== vivado_hls -f build.tcl  (stage=$Stage) ===" -ForegroundColor Cyan
    & cmd /c "`"$HlsBat`" -f build.tcl"
    $rc = $LASTEXITCODE
    Write-Host "=== exit code: $rc ===" -ForegroundColor $(if ($rc -eq 0) { 'Green' } else { 'Red' })
    exit $rc
}
finally {
    Pop-Location
}

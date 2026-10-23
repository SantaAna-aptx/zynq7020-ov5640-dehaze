# ============================================================================
#  sim.ps1  --  run the 04_camera self-checking testbenches
#
#  Two benches, deliberately independent so a failure points at one area:
#      sccb   ov5640_sccb + the generated ROM     wire-level SCCB protocol, with
#                                                 every register write decoded
#                                                 back off the bus and compared
#                                                 against the ROM contents
#      pipe   camera_pipe                          DVP byte pairing, warm-up
#                                                 gating, line buffer, burst
#                                                 splitting, ring addresses
#
#  Each bench prints PASS or FAIL and the script returns a non-zero exit code if
#  anything failed.
#
#  Usage:  powershell -ExecutionPolicy Bypass -File sim.ps1 [-Only sccb|pipe]
# ============================================================================
param([string]$Only = "")

$ErrorActionPreference = "Stop"

$VIVADO_BIN = "D:\vivado2019.1\VIVADO20191\Vivado\2019.1\bin"
$env:PATH   = "$VIVADO_BIN;" + $env:PATH

$HERE = Split-Path -Parent $MyInvocation.MyCommand.Path
$RTL  = Join-Path $HERE "rtl"
$TB   = Join-Path $HERE "tb"
$WORK = Join-Path $HERE "work"

if (Test-Path $WORK) { Remove-Item -Recurse -Force $WORK }
New-Item -ItemType Directory -Force -Path $WORK | Out-Null

# glbl is needed by the unisim primitives the reset synchronisers pull in
$GLBL = "D:\vivado2019.1\VIVADO20191\Vivado\2019.1\data\verilog\src\glbl.v"

$COMMON = @(
    (Join-Path $RTL "ov5640_init_rom.v"),
    (Join-Path $RTL "ov5640_sccb.v"),
    (Join-Path $RTL "ov5640_dvp_linebuf.v"),
    (Join-Path $RTL "ddr_line_writer.v"),
    (Join-Path $RTL "camera_pipe.v"),
    (Join-Path $RTL "axil_status.v"),
    (Join-Path $RTL "camera_top.v")
)

$BENCHES = @(
    @{ Name = "sccb"; Top = "tb_ov5640_sccb" },
    @{ Name = "pipe"; Top = "tb_camera_pipe" },
    @{ Name = "axil"; Top = "tb_axil_status" }
)

$failed = @()

foreach ($b in $BENCHES) {
    if ($Only -ne "" -and $Only -ne $b.Name) { continue }
    Write-Host ""
    Write-Host ("=== " + $b.Name + " (" + $b.Top + ") ===") -ForegroundColor Cyan

    Push-Location $WORK
    try {
        $log = Join-Path $WORK ($b.Name + ".log")

        & xvlog -nolog $COMMON $GLBL (Join-Path $TB ($b.Top + ".v")) 2>&1 |
            Tee-Object -FilePath ($b.Name + "_compile.log") | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "xvlog failed (see $($b.Name)_compile.log)" }

        & xelab -L unisims_ver -nolog -debug off $b.Top glbl -s ("sim_" + $b.Name) 2>&1 |
            Tee-Object -FilePath ($b.Name + "_elab.log") | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "xelab failed (see $($b.Name)_elab.log)" }

        $out = & xsim ("sim_" + $b.Name) -runall 2>&1 | Tee-Object -FilePath $log
        $out | Select-String -Pattern "PASS|FAIL|ERROR|AW 0x|pipe:|sccb:" |
            Select-Object -First 40 |
            ForEach-Object { "  " + $_.Line }
        if ($out -match "FAIL") { throw "testbench reported FAIL" }
        if (-not ($out -match "PASS")) { throw "testbench produced no PASS line" }
    } catch {
        Write-Host ("  " + $_.Exception.Message) -ForegroundColor Red
        $failed += $b.Name
    } finally {
        Pop-Location
    }
}

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host "ALL CAMERA TESTBENCHES PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host ("FAILED: " + ($failed -join ", ")) -ForegroundColor Red
    exit 1
}

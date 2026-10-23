# ---------------------------------------------------------------------------
#  build.ps1  --  cross-compile the board programs (no board needed)
#
#  Usage (from 03_linux):
#      powershell -ExecutionPolicy Bypass -File build.ps1
#
#  Builds three binaries:
#      dehaze_linux   file -> dehaze -> file (proves the core, no camera needed)
#      dehaze_cam     camera -> dehaze -> file (the full PL demo)
#      dehaze_web     camera -> dehaze -> live BMPs for the browser preview
#
#  Toolchain: the aarch32 linux-gnueabi gcc that ships with SDK 2019.1.
#  It carries glibc 2.28, which matches the board's PetaLinux 2019.1 rootfs
#  (this is the exact toolchain the YOLO project settled on after trial).
# ---------------------------------------------------------------------------
param(
    [string]$ToolchainRoot = 'D:\vivado2019.1\VIVADO20191\SDK\2019.1\gnu\aarch32\nt\gcc-arm-linux-gnueabi\bin'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$gcc  = Join-Path $ToolchainRoot 'arm-linux-gnueabihf-gcc.exe'

if (-not (Test-Path $gcc)) { throw "cross compiler not found: $gcc" }

$programs = @(
    @{ Src = 'src/dehaze_linux.c'; Out = 'dehaze_linux' },
    @{ Src = 'src/dehaze_cam.c';   Out = 'dehaze_cam'   },
    @{ Src = 'src/dehaze_web.c';   Out = 'dehaze_web'   }
)

Push-Location $here
try {
    foreach ($p in $programs) {
        Write-Host ("=== cross compiling " + $p.Out + " ===") -ForegroundColor Cyan
        $tmp = $p.Out + '.exe'
        & $gcc -O2 -Wall -Wextra -o $tmp $p.Src
        if ($LASTEXITCODE -ne 0) { throw ("compile failed for " + $p.Src + " (exit " + $LASTEXITCODE + ")") }

        # the board wants the bare name -- the .exe extension is cosmetic
        Move-Item -Force $tmp $p.Out
        $len = (Get-Item $p.Out).Length
        Write-Host ("OK: " + $p.Out + " ($len bytes)") -ForegroundColor Green
    }
    Write-Host "Next: copy them to the board (wget/scp), see run_on_board.sh"
}
finally {
    Pop-Location
}

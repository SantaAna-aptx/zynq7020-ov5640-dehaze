# ---------------------------------------------------------------------------
#  probe_size.ps1  --  where does the frame time actually go?
#
#  Runs mode 0 over a range of (W, H) and records the latency.  Fitting
#      t = a*W*H + b*H + c
#  separates the per-pixel cost (a), the per-row cost (b) and the fixed
#  per-invocation cost (c).  That is what tells us whether the ~124 ms floor
#  is per pixel, per row, or fixed.
#
#  The core clamps to 64..1025 x 64..720, so every size below is legal.
# ---------------------------------------------------------------------------
param([string]$Port = 'COM10')

$sizes = @(
    @(1025, 720),
    @(1025, 360),
    @(1025, 180),
    @( 512, 720),
    @( 256, 720),
    @( 128, 128)
)

$sp = New-Object System.IO.Ports.SerialPort $Port, 115200, None, 8, one
$sp.ReadTimeout = 400
$sp.Open()
Start-Sleep -Milliseconds 300
try { $sp.ReadExisting() | Out-Null } catch { }

function AskWait([string]$c, [string]$pattern, [int]$w = 60000) {
    $sp.Write($c + "`n")
    $o = ''
    $t = (Get-Date).AddMilliseconds($w)
    while ((Get-Date) -lt $t) {
        try { $o += $sp.ReadExisting() } catch { }
        if ($o -match $pattern) { break }
        Start-Sleep -Milliseconds 40
    }
    Start-Sleep -Milliseconds 80
    try { $o += $sp.ReadExisting() } catch { }
    return $o
}

Write-Host 'size probe (mode 0, divisor 6)'
Write-Host ('{0,12} {1,12} {2,12}' -f 'size', 'pixels', 'latency ms')

$rows = @()
foreach ($s in $sizes) {
    $w = $s[0]; $h = $s[1]
    $cmd = 'cd /home/root/dehaze; ./dehaze_linux fog_in.bin hw_out_cal.bin 0 ' + $w + ' ' + $h + '; echo SZ_$$'
    $r = AskWait $cmd 'SZ_\d+' 80000
    $lat = $null
    foreach ($l in ($r -split "`n")) {
        if ($l -match 'latency\s*=\s*([0-9.]+)\s*ms') { $lat = [double]$matches[1] }
    }
    if ($lat -ne $null) {
        Write-Host ('{0,12} {1,12} {2,12:N2}' -f ("$w x $h"), ($w * $h), $lat)
        $rows += ,@($w, $h, $lat)
    } else {
        Write-Host ('{0,12} FAILED' -f ("$w x $h"))
    }
}

Write-Host ''
if ($rows.Count -ge 3) {
    Write-Host '--- interpretation ---'
    $base = $rows[0][2]
    foreach ($r in $rows) {
        $frac = $r[2] / $base
        $pix  = ($r[0] * $r[1]) / (1025.0 * 720.0)
        Write-Host ('  {0,10}: {1,6:N2} ms  = {2,5:N1}% of full frame, while pixels are {3,5:N1}%' -f `
                    ("$($r[0])x$($r[1])"), $r[2], ($frac * 100), ($pix * 100))
    }
    Write-Host ''
    Write-Host '  If time tracks pixel count -> per-pixel bound.'
    Write-Host '  If halving H barely helps -> there is a large fixed per-invocation cost,'
    Write-Host '     which would point at pass setup / pipeline fill rather than compute.'
}
$sp.Close()

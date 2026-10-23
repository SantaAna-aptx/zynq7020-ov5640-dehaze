# ---------------------------------------------------------------------------
#  probe_clock.ps1  --  find out how fast the PL actually runs.
#
#  Runs mode 0 at several FCLK0 divisors and records BOTH the latency and the
#  output checksum.  The checksum is what tells us whether the clock is legal:
#  the design closes timing at ~58 MHz, so if a divisor makes it faster than
#  that the output goes wrong.
#
#     div 20 -> 0x00201400   baseline (believed to be 50 MHz)
#     div 10 -> 0x00200A00   2x the baseline
#     div 5  -> 0x00200500   4x the baseline
#     div 20 -> back to baseline
#
#  Reference checksum for mode 0 is 0x7D194413.
# ---------------------------------------------------------------------------
param(
    [string]$Port = 'COM10'
)

$sp = New-Object System.IO.Ports.SerialPort $Port, 115200, None, 8, one
$sp.ReadTimeout = 400
$sp.Open()
Start-Sleep -Milliseconds 300
try { $sp.ReadExisting() | Out-Null } catch { }

function AskWait([string]$c, [string]$pattern, [int]$w = 40000) {
    $sp.Write($c + "`n")
    $o = ''
    $t = (Get-Date).AddMilliseconds($w)
    while ((Get-Date) -lt $t) {
        try { $o += $sp.ReadExisting() } catch { }
        if ($o -match $pattern) { break }
        Start-Sleep -Milliseconds 40
    }
    Start-Sleep -Milliseconds 60
    try { $o += $sp.ReadExisting() } catch { }
    return $o
}

function ProbeRun([string]$label, [string]$divcfg) {
    $cmd = 'busybox devmem 0xF8000008 32 0xDF0D; busybox devmem 0xF8000170 32 ' + $divcfg +
           '; busybox devmem 0xF8000004 32 0x767B; cd /home/root/dehaze; ' +
           './dehaze_linux fog_in.bin hw_out_cal.bin 0; echo PRB_$$'
    $r = AskWait $cmd 'PRB_\d+' 60000

    $lat = 'n/a'; $ck = 'n/a'; $a = 'n/a'
    foreach ($line in ($r -split "`n")) {
        if ($line -match 'latency\s*=\s*([0-9.]+)\s*ms') { $lat = $matches[1] }
        if ($line -match 'checksum\s*=\s*0x([0-9a-fA-F]+)') { $ck = $matches[1] }
        if ($line -match 'A \(B,G,R\) = ([\d,]+)') { $a = $matches[1] }
    }
    $ok = if ($ck -eq '7d194413') { 'OK   ' } else { 'WRONG' }
    Write-Host ("{0,-20} cfg={1}  latency = {2,9} ms  checksum = 0x{3}  [{4}]  A={5}" -f `
                $label, $divcfg, $lat, $ck, $ok, $a)
    return $lat
}

Write-Host '=== FCLK0 probe (mode 0, reference checksum 0x7D194413) ==='
ProbeRun 'div 8'  '0x00200800' | Out-Null
ProbeRun 'div 5'  '0x00200500' | Out-Null
ProbeRun 'div 4'  '0x00200400' | Out-Null
ProbeRun 'div 6'  '0x00200600' | Out-Null

Write-Host ''
Write-Host 'Interpretation:'
Write-Host '  div 10 stays correct -> baseline clock is well under the ~58 MHz timing'
Write-Host '                          limit; the design is simply being clocked slow'
Write-Host '  div 10 goes WRONG    -> baseline is already near 50 MHz and the 2x gap'
Write-Host '                          vs the HLS estimate is memory stalls'
$sp.Close()

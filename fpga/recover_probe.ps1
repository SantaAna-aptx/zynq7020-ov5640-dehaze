# ---------------------------------------------------------------------------
#  recover_probe.ps1  -- clean up a hung core, then measure mode 0/1 at one
#                         FCLK0 divisor.
#
#  A timed-out dehaze_linux keeps spinning in its ap_done guard loop (2e8
#  uncached reads), which blocks the serial shell for a minute or more. This
#  script kills it, re-programs the PL (which resets the kernel FSM) and then
#  measures once.
#
#  Usage: powershell -ExecutionPolicy Bypass -File recover_probe.ps1 -Div 0x00200800
# ---------------------------------------------------------------------------
param(
    [string]$Port = 'COM10',
    [string]$Div  = '0x00200800'
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
    Start-Sleep -Milliseconds 80
    try { $o += $sp.ReadExisting() } catch { }
    return $o
}

Write-Host '=== 1. kill any stale app ==='
AskWait 'killall dehaze_linux 2>/dev/null; echo KL_$$' 'KL_\d+' 8000 | Out-Null
Start-Sleep -Seconds 2

Write-Host '=== 2. re-program the PL (resets the kernel FSM) ==='
$r = AskWait 'cp /home/root/dehaze/dehaze_top.bin /lib/firmware/; echo dehaze_top.bin > /sys/class/fpga_manager/fpga0/firmware; sleep 2; echo LOD_$$' 'LOD_\d+' 20000
if ($r -notmatch 'LOD_\d+') { Write-Host '!! PL reload did not complete'; $sp.Close(); exit 1 }

Write-Host '=== 3. idle probe (expect 0x00000004) ==='
$r = AskWait 'busybox devmem 0x43C00000 32; echo P_$$' 'P_\d+' 5000
foreach ($l in ($r -split "`n")) { if ($l -match '0x[0-9a-fA-F]{8}') { Write-Host ('   ap_ctrl = ' + $l.Trim()) } }

Write-Host ("=== 4. set FCLK0 divisor cfg {0} ===" -f $Div)
AskWait ('busybox devmem 0xF8000008 32 0xDF0D; busybox devmem 0xF8000170 32 ' + $Div +
         '; busybox devmem 0xF8000004 32 0x767B; echo C_$$') 'C_\d+' 6000 | Out-Null

foreach ($m in 0, 1) {
    Write-Host ("=== 5.{0} mode {0} ===" -f $m)
    $r = AskWait ('cd /home/root/dehaze; ./dehaze_linux fog_in.bin hw_out_mode' + $m +
                  '.bin ' + $m + '; echo R' + $m + '_$$') ('R' + $m + '_\d+') 60000
    $lat = 'n/a'; $ck = 'n/a'
    foreach ($l in ($r -split "`n")) {
        if ($l -match 'latency\s*=\s*([0-9.]+)\s*ms') { $lat = $matches[1] }
        if ($l -match 'checksum\s*=\s*0x([0-9a-fA-F]+)') { $ck = $matches[1] }
    }
    $ref = if ($m -eq 0) { '7d194413' } else { 'ecb8a61a' }
    $ok  = if ($ck -eq $ref) { 'OK   ' } else { 'WRONG' }
    Write-Host ("   mode {0}: latency = {1,8} ms   checksum = 0x{2}  [{3}]" -f $m, $lat, $ck, $ok)
    Start-Sleep -Seconds 1
}

$sp.Close()

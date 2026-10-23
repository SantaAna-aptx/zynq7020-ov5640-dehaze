# ---------------------------------------------------------------------------
#  board_run.ps1  --  catch U-Boot (or attach to a live shell), boot Linux, load
#                     the v1 dehaze bitstream through fpga_manager, run BOTH
#                     modes and print the verification numbers.
#
#  Works whether the board is still at U-Boot or already sitting at a shell.
#
#  Speed: every command returns as soon as it finishes.  The marker is
#  `DONE_$$`: the serial console echoes the command line literally as
#  "DONE_$$", while the shell prints "DONE_<pid>".  Matching DONE_\d+ therefore
#  ignores the echo and fires only on real output -- no "wait the full timeout"
#  stalls (that cost ~4 min in the first version).
#
#  Pure ASCII on purpose (non-ASCII in a .ps1 makes PowerShell report bogus
#  syntax errors -- lesson from the YOLO project).
# ---------------------------------------------------------------------------
param(
    [string]$Port    = 'COM10',
    [string]$HostIp  = '192.168.1.100',
    [string]$BoardIp = '192.168.1.50',
    [int]$HttpPort   = 8010,
    [int]$CatchSec   = 900,
    [string]$BitName = 'dehaze_top.bin',
    # -Live: instead of the batch camera run + the two file-mode runs, start the
    # browser preview (dehaze_web + busybox httpd on 8080) and leave the board
    # running. The URL is printed at the end.
    [switch]$Live,
    [int]$LiveMode = 1,
    # Reload the bitstream even if the PL already answers on 0x43C00000.
    [switch]$ForceBitstream,
    # FCLK0 = 500 MHz / DIVISOR0 (measured on this board).
    #   0x00200A00 -> divisor 10 ->  50 MHz -> XCLK 12.5 MHz -> PCLK ~43.75 MHz
    #   0x00200500 -> divisor  5 -> 100 MHz -> XCLK 25 MHz   -> PCLK ~87.5 MHz
    # The default matches camera.xdc. Pass the second value to check whether the
    # sensor's PLL needs a faster XCLK (it shows up as "probes: pclk=0" otherwise).
    [string]$FclkDiv = '0x00200A00'
)

$dir = 'D:\dehaze\fpga'
$log = Join-Path $dir ("board_run_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$sw  = New-Object System.IO.StreamWriter($log, $false)
$sw.AutoFlush = $true
$sp  = New-Object System.IO.Ports.SerialPort $Port, 115200, None, 8, one
$sp.ReadTimeout = 400
$script:buf = ''

function Raw {
    try { $d = $sp.ReadExisting() } catch { $d = '' }
    if ($d) { $script:buf += $d; $sw.Write($d) }
    return $d
}
function Drain([int]$ms) {
    $t = (Get-Date).AddMilliseconds($ms); $o = ''
    while ((Get-Date) -lt $t) { $o += (Raw); Start-Sleep -Milliseconds 20 }
    return $o
}
function Send([string]$s) { try { $sp.Write($s) } catch { } }
function Ask([string]$c, [int]$w = 3000) { Send ($c + "`n"); return (Drain $w) }

# send a command, return as soon as <pattern> shows up in the output
function AskWait([string]$c, [string]$pattern, [int]$w = 15000) {
    Send ($c + "`n")
    $o = ''
    $t = (Get-Date).AddMilliseconds($w)
    while ((Get-Date) -lt $t) {
        $o += (Raw)
        if ($o -match $pattern) { break }
        Start-Sleep -Milliseconds 40
    }
    Start-Sleep -Milliseconds 60
    $o += (Raw)
    return $o
}
function Show([string]$t, [string]$o, [int]$n = 20) {
    Write-Host "--- $t ---"
    ($o -split "`n") | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne '' -and $_ -notmatch '^(FET|LOD|ENV|NET|CLK|CAM|M0|M1|HTP)_\d+$' } |
        Select-Object -Last $n | ForEach-Object { Write-Host ('   ' + $_) }
}

# ---------------------------------------------------------------------------
#  Stage the artifacts and make sure they are actually downloadable.
#
#  The board pulls everything with wget, so a file missing from the PC's HTTP
#  directory shows up as a mysterious "wget failed" halfway through the boot.
#  Checking here, before touching the serial port, turns that into one clear
#  message with the exact command that fixes it.
# ---------------------------------------------------------------------------
$www = Join-Path $dir 'www'
if (-not (Test-Path $www)) { New-Item -ItemType Directory -Force -Path $www | Out-Null }

$artifacts = @(
    @{ Name = $BitName;       Src = '02_vivado\output\dehaze_top.bin' },
    @{ Name = 'dehaze_linux'; Src = '03_linux\dehaze_linux' },
    @{ Name = 'dehaze_cam';   Src = '03_linux\dehaze_cam' },
    @{ Name = 'dehaze_web';   Src = '03_linux\dehaze_web' },
    @{ Name = 'index.html';   Src = '03_linux\www\index.html' },
    @{ Name = 'set.cgi';      Src = '03_linux\www\set.cgi' },
    @{ Name = 'httpd.conf';   Src = '03_linux\www\httpd.conf' },
    @{ Name = 'fog_in.bin';   Src = '01_hls\tv\fog_in.bin' }
)
foreach ($a in $artifacts) {
    $p = Join-Path $dir $a.Src
    if (-not (Test-Path $p)) {
        Write-Host ('!! missing build artifact: ' + $p) -ForegroundColor Red
        Write-Host '   (run 02_vivado/build.tcl and 03_linux/build.ps1 first)'
        exit 4
    }
    Copy-Item -Force $p (Join-Path $www $a.Name)
}

$base = 'http://' + $HostIp + ':' + $HttpPort

# 1) Is a server actually running and serving these files? Probe through
#    loopback: that tests the server, not the Ethernet link.
$local = 'http://127.0.0.1:' + $HttpPort
$missing = @()
foreach ($a in $artifacts) {
    try {
        $null = Invoke-WebRequest -UseBasicParsing -Uri ($local + '/' + $a.Name) `
                                  -Method Head -TimeoutSec 4
    } catch {
        $missing += $a.Name
    }
}
if ($missing.Count -gt 0) {
    Write-Host ''
    Write-Host ('!! no HTTP server on port ' + $HttpPort + ' serving the artifacts') -ForegroundColor Red
    Write-Host ('   missing: ' + ($missing -join ', '))
    Write-Host ('   staged copies are in: ' + $www)
    Write-Host '   start a server there and re-run:'
    Write-Host ('      cd ' + $www + '; python -m http.server ' + $HttpPort)
    exit 5
}

# 2) Is the address the board will dial actually up? With the board powered off
#    the Ethernet link is down and 192.168.1.100 sits in "Tentative", so probing
#    it here would fail for the wrong reason -- and the board cannot be powered
#    on before this script starts waiting for it. Warn, do not abort.
$ipUp = $false
$addr = Get-NetIPAddress -IPAddress $HostIp -ErrorAction SilentlyContinue |
        Where-Object { $_.AddressState -eq 'Preferred' }
if ($addr) { $ipUp = $true }

if ($ipUp) {
    Write-Host ('=== artifacts staged in ' + $www + ', served on ' + $base + ' ===')
} else {
    Write-Host ('!! ' + $HostIp + ' is not up yet (Ethernet link down)') -ForegroundColor Yellow
    Write-Host '   the server is running, but the board cannot wget until the link is up.'
    Write-Host '   power the board on and plug in the Ethernet cable -- this script keeps'
    Write-Host '   waiting for U-Boot meanwhile; the fetch happens after the boot, by which'
    Write-Host '   time the link will normally have come up.'
}


Write-Host ("=== attaching on {0} ===" -f $Port)
try { $sp.Open() } catch {
    Write-Host ('!! cannot open ' + $Port + ' : ' + $_.Exception.Message)
    $sw.Close(); exit 2
}
# Do NOT touch DtrEnable / RtsEnable: asserting them makes this board stop
# answering U-Boot commands entirely.
Drain 600 | Out-Null
$script:buf = ''

# ---- already at a shell? (fast path) ----
$alreadyUp = $false
for ($i = 0; $i -lt 4; $i++) {
    if ((Ask 'echo SH_PROBE' 1200) -match 'SH_PROBE') { $alreadyUp = $true; break }
}

if ($alreadyUp) {
    Write-Host 'shell already alive -- skipping boot'
} else {
    Write-Host ("=== no shell; waiting for U-Boot (power the board on now; {0}s) ===" -f $CatchSec)
    $deadline = (Get-Date).AddSeconds($CatchSec); $caught = $false
    while ((Get-Date) -lt $deadline) {
        Send "`r"
        Raw | Out-Null
        if ($script:buf -match '(Zynq>|U-Boot>|U-Boot 2019)') { $caught = $true; break }
        if ($script:buf -match 'Starting kernel') { $script:buf = '' }
        Start-Sleep -Milliseconds 120
    }
    if (-not $caught) {
        Write-Host '!! never saw U-Boot -- power cycle and try again'
        $sw.Close(); $sp.Close(); exit 1
    }
    if ((Ask 'echo UB_PROBE' 2500) -notmatch 'UB_PROBE') {
        Write-Host '!! U-Boot seen but it does not answer (autoboot already past)'
        $sw.Close(); $sp.Close(); exit 1
    }
    Write-Host 'U-Boot caught'

    Write-Host ''
    Write-Host '=== boot Linux (recipe proven by the YOLO project) ==='
    Ask 'fatload mmc 0:1 0x01000000 image.ub' 5000 | Out-Null
    Ask 'setenv fdt_high 0xffffffff' 400 | Out-Null
    Ask 'setenv devicetree_load_address 0x01000000' 400 | Out-Null
    Ask 'setenv bootargs console=ttyPS0,115200 earlyprintk root=/dev/mmcblk0p2 rw rootfstype=ext4 rootwait init=/bin/sh mem=120M cma=48M' 700 | Out-Null
    Ask 'bootm 0x01000000' 1200 | Out-Null

    Write-Host '=== waiting for the kernel shell ==='
    $shellOk = $false
    for ($i = 0; $i -lt 60; $i++) {
        Send "echo SH_PROBE`n"
        if ((Drain 1500) -match 'SH_PROBE') { $shellOk = $true; break }
    }
    if (-not $shellOk) {
        Write-Host '!! kernel never reached a shell'
        Show 'tail' $script:buf 15
        Write-Host ('log: ' + $log)
        $sw.Close(); $sp.Close(); exit 3
    }
    Write-Host 'shell alive'
}

# ---- environment ----
AskWait 'export PATH=/sbin:/bin:/usr/sbin:/usr/bin; mount -t proc proc /proc 2>/dev/null; mount -t sysfs sysfs /sys 2>/dev/null; mount -t devtmpfs devtmpfs /dev 2>/dev/null; mkdir -p /lib/firmware /home/root/dehaze; echo ENV_$$' 'ENV_\d+' 6000 | Out-Null
Show 'kernel' (Ask 'uname -r' 1200) 2

AskWait ("ifconfig eth0 " + $BoardIp + " netmask 255.255.255.0 up 2>/dev/null; echo NET_$$") 'NET_\d+' 5000 | Out-Null

# ---- fetch artifacts ----
Write-Host ''
Write-Host '=== fetch artifacts ==='
$base = 'http://' + $HostIp + ':' + $HttpPort
# Built from $artifacts, not typed out by hand: the earlier hard-coded list
# silently skipped whatever had been added to the staging step, which showed up
# as "cp: cannot stat .../index.html" twenty seconds later.
$fetchCmds = ($artifacts | ForEach-Object {
    'wget -O ' + $_.Name + ' ' + $base + '/' + $_.Name + ' 2>/dev/null; '
}) -join ''
# wget cannot overwrite a binary that is being executed (ETXTBSY), and the
# previous run's dehaze_web is normally still alive at this point. Kill it first,
# otherwise the fetch silently keeps the old build -- which looks exactly like
# "my new code did nothing".
$fetch = 'cd /home/root/dehaze; ' +
         'for p in $(pidof dehaze_web); do kill -9 $p; done 2>/dev/null; sleep 1; ' +
         $fetchCmds +
         'chmod +x dehaze_linux dehaze_cam dehaze_web 2>/dev/null; ls -l; echo FET_$$'
Show 'fetch' (AskWait $fetch 'FET_\d+' 40000) 12

# ---- program the PL ----
# Each PL reload costs one of the ~6 `fpga_manager` loads this board allows
# between power cycles, and a bad one wedges the PCAP so hard that only a power
# cut recovers it. So before loading, ask the PL whether it is already ours.
#
# The test has to be a *counter that moves*, not "did some register answer":
#   * a design that is not ours (the QSPI-boot bitstream) does not decode this
#     address at all, and `devmem` then dies with an external abort whose message
#     happens to contain an 8-digit hex address -- which made the first version of
#     this check report "alive" and skip a load that was actually needed;
#   * 0x43C10010 is the free-running FCLK0 counter, so two reads a moment apart
#     must differ.
Write-Host ''
function Read-CamReg([string]$addr) {
    return (Ask ("busybox devmem " + $addr + " 32 2>&1") 1500)
}
function Get-CounterPair {
    $a = Read-CamReg '0x43C10010'
    $b = Read-CamReg '0x43C10010'
    return @($a, $b)
}
function Test-PlIsOurs($pair) {
    $pat = '(?m)^\s*(0x[0-9a-fA-F]{8})\s*$'
    foreach ($t in $pair) { if ($t -match 'fault|abort') { return $false } }
    $m1 = [regex]::Match($pair[0], $pat)
    $m2 = [regex]::Match($pair[1], $pat)
    if (-not $m1.Success -or -not $m2.Success) { return $false }
    return ($m1.Groups[1].Value -ne $m2.Groups[1].Value)     # counter must move
}

$plAlive = $false
if (-not $ForceBitstream) { $plAlive = Test-PlIsOurs (Get-CounterPair) }
if ($plAlive) {
    Write-Host '=== PL already holds this design (FCLK0 counter is running) -- skipping the bitstream load ===' -ForegroundColor Green
    Write-Host '    (pass -ForceBitstream to reload anyway)'
} else {
    Write-Host '=== program PL through fpga_manager ==='
    $load = 'cp ' + $BitName + ' /lib/firmware/; echo ' + $BitName +
            ' > /sys/class/fpga_manager/fpga0/firmware; sleep 2; cat /sys/class/fpga_manager/fpga0/state; echo LOD_$$'
    Show 'load' (AskWait $load 'LOD_\d+' 25000) 3
    if (-not (Test-PlIsOurs (Get-CounterPair))) {
        Write-Host '!! the PL still does not answer after the load -- the PCAP' -ForegroundColor Red
        Write-Host '   probably needs a power cycle (see fpga_manager DMA error notes)' -ForegroundColor Red
    }
}

# fpga_manager 'state' is a FALSE POSITIVE here: QSPI boot already put a
# bitstream in the PL, so it always reads 'operating'.  Only a register that
# exists in OUR design proves the load worked.
Show 'HLS probe' (Ask 'busybox devmem 0x43C00000 32' 1500) 2

# ---- clocks ----
Write-Host ''
Write-Host '=== FCLK0: divisor 10 (measured 50 MHz), AFI 32-bit on HP0..HP3 ==='
# MEASURED on this board (dehaze_cam reads the PL free-running counter):
#     FCLK0 = 500 MHz / DIVISOR0     DIVISOR0 = FPGA0_CLK_CTRL[13:8] @ 0xF8000170
#       divisor  5 -> 100.01 MHz (measured)     <-- 0x00200500 really is 100 MHz
#       divisor  6 ->  83 MHz  (from latency scaling)
#       divisor 10 ->  50 MHz  <-- what we use
# This corrects an earlier guess of 250/DIVISOR0, which was itself a correction of
# the YOLO project's "0x00201400 == 50.000 MHz" (that one is divisor 20 -> 25 MHz).
# The camera path depends on it: XCLK is 12 MHz from an MMCM (VCO 1200 MHz / 100),
# so PCLK = 3.5 x XCLK = 42 MHz, which is what camera.xdc is written against and
# what leaves the DDR line writer (26 us/line at 50 MHz) enough room inside a
# 45 us line. Running XCLK at 24 MHz asks the sensor for 84 MHz PCLK: the pixel
# domain is then on its timing edge and the picture comes out smeared.
#
# AFI: HP2 is the scratch master added in v2, HP3 is the camera ring. Forgetting
# an AFI write leaves that port at 64 bit while the PL master drives 32, which
# silently corrupts the guided-filter maps (mode 0 stays correct, mode 1 goes wrong).
$clkcmd = 'busybox devmem 0xF8000008 32 0xDF0D; busybox devmem 0xF8000170 32 DIVPLACEHOLDER; busybox devmem 0xF8008000 32 0x1; busybox devmem 0xF8008014 32 0x1; busybox devmem 0xF8009000 32 0x1; busybox devmem 0xF8009014 32 0x1; busybox devmem 0xF800A000 32 0x1; busybox devmem 0xF800A014 32 0x1; busybox devmem 0xF800B000 32 0x1; busybox devmem 0xF800B014 32 0x1; busybox devmem 0xF8000004 32 0x767B; echo -n "fclk="; busybox devmem 0xF8000170; echo -n "afi0="; busybox devmem 0xF8008000; echo -n "afi1="; busybox devmem 0xF8009000; echo -n "afi2="; busybox devmem 0xF800A000; echo -n "afi3="; busybox devmem 0xF800B000; echo CLK_$$'
$clkcmd = $clkcmd.Replace('DIVPLACEHOLDER', $FclkDiv)
Show 'clk+afi' (AskWait $clkcmd 'CLK_\d+' 8000) 6

# ---- live browser preview ------------------------------------------------
# Same power-on and PL-programming path as the batch run, but instead of the
# one-shot captures it starts `dehaze_web` and busybox httpd on the board and
# leaves them running, so the browser can watch the camera and the dehazed
# result directly. Nothing on the PC has to keep running afterwards.
if ($Live) {
    Write-Host ''
    Write-Host '=== LIVE: dehaze_web + busybox httpd on 8080 ==='
    # The BMPs are rewritten ~5 times a second (2 x 900 KB), so they go on a
    # tmpfs instead of the SD card: no wear, no write stalls. 16 MB out of the
    # board's 120 MB is plenty for two frames plus the page.
    #
    # `dehaze_web` is started through `sh -c 'trap "" HUP; exec ...'` on purpose:
    # with init=/bin/sh there is no job control, so a plain `&` job lands in the
    # console's process group and gets SIGHUP when this script closes the serial
    # port -- the stream would die the moment the PC stops looking.
    # busybox httpd does *not* rename itself, so `killall httpd` and `pidof httpd`
    # both miss it -- the process keeps the name "busybox". Instead of fighting
    # process names, walk up from 8090 and use the first port that binds. A stale
    # daemon from an earlier run then simply becomes irrelevant.
    $liveCmd = 'mkdir -p /www; mount -t tmpfs -o size=16M tmpfs /www 2>/dev/null; ' +
            'cp /home/root/dehaze/index.html /www/index.html; ' +
            'cp /home/root/dehaze/set.cgi    /www/set.cgi; ' +
            'cp /home/root/dehaze/httpd.conf /www/httpd.conf; ' +
            'for p in $(pidof dehaze_web); do kill -9 $p; done 2>/dev/null; ' +
            'sleep 1; ' +
            'PORT=0; for p in 8090 8091 8092 8093 8094 8095 8096; do ' +
            '  if busybox httpd -c /www/httpd.conf -p $p -h /www 2>/dev/null; then PORT=$p; break; fi; done; ' +
            'echo "port=$PORT"; ' +
            'cd /home/root/dehaze; ' +
            'sh -c ''trap "" HUP; exec ./dehaze_web /www LMODE'' > /www/web.log 2>&1 & ' +
            'sleep 5; echo -n "stats: "; cat /www/stats.txt 2>/dev/null; ' +
            'echo -n "log: "; cat /www/web.log 2>/dev/null; echo LIVE_$$'
    $liveCmd = $liveCmd.Replace('LMODE', [string]$LiveMode)
    $liveOut = AskWait $liveCmd 'LIVE_\d+' 35000
    Show 'live' $liveOut 14

    $livePort = 0
    $mp = [regex]::Match($liveOut, 'port=(\d+)')
    if ($mp.Success) { $livePort = [int]$mp.Groups[1].Value }
    if ($livePort -le 0) {
        Write-Host '!! the board could not bind a port for the viewer' -ForegroundColor Red
        $sw.Close(); $sp.Close(); exit 0
    }
    $liveUrl = 'http://' + $BoardIp + ':' + $livePort + '/'

    # Prove from the PC side that the board is really serving the page: a
    # "started" message on the serial console is not the same as a reachable URL.
    $pageOk  = $false
    for ($i = 0; $i -lt 6 -and -not $pageOk; $i++) {
        try {
            $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 6 -Uri $liveUrl
            if ($r.Content -match 'OV5640') { $pageOk = $true }
        } catch { Start-Sleep -Milliseconds 800 }
    }
    $statsOk = $false
    try {
        $s = Invoke-WebRequest -UseBasicParsing -TimeoutSec 6 -Uri ($liveUrl + 'stats.txt')
        $statsOk = ($s.Content -match 'fps=')
        if ($statsOk) { Write-Host ('   board stats: ' + $s.Content.Trim()) -ForegroundColor Green }
    } catch { }

    Write-Host ''
    if ($pageOk -and $statsOk) {
        Write-Host '=== LIVE VIEW READY ===' -ForegroundColor Green
        Write-Host ('   open:  ' + $liveUrl) -ForegroundColor Green
        Write-Host '   two panes: camera raw (left) and PL dehazed (right), ~2-3 fps'
        Write-Host '   stop:  serial console -> killall dehaze_web'
        Write-Host '   mode:  echo 0 > /www/mode.cfg  (0 = no refinement, 1 = guided filter)'
    } else {
        Write-Host '!! the board started the viewer but the page is not reachable' -ForegroundColor Red
        Write-Host ('   page=' + $pageOk + ' stats=' + $statsOk + '  url=' + $liveUrl)
        Write-Host '   check: ifconfig eth0 / cable / that busybox httpd is running'
    }
    Write-Host ''
    Write-Host ('log: ' + $log)
    Write-Host 'BOARD_RUN_DONE'
    $sw.Close()
    $sp.Close()
    exit 0
}

# ---- camera path ----
Write-Host ''
Write-Host '=== CAMERA: SCCB + capture + dehaze ==='
# Prints the measured FCLK0, the camera status word, the measured line width and
# the frame count. If it stops early the message says which of SCCB / XCLK / PCLK
# / line-buffer overflow was the problem, so there is no guessing from a black
# image.
Show 'cam' (AskWait './dehaze_cam hw_out_cam.bin 1; echo CAM_$$' 'CAM_\d+' 60000) 20

# ---- run both modes ----
Write-Host ''
# mode 2 (clock calibration) is deliberately NOT run: its early 'return' in the
# kernel leaves the ap_ctrl FSM with ap_start stuck at 1, and the NEXT run then
# never executes. The clock was characterised with probe_clock.ps1 instead.

Write-Host '=== RUN mode 0 (no refinement) ==='
Show 'mode0' (AskWait './dehaze_linux fog_in.bin hw_out_mode0.bin 0; echo M0_$$' 'M0_\d+' 20000) 8

Write-Host '=== RUN mode 1 (guided filter) ==='
Show 'mode1' (AskWait './dehaze_linux fog_in.bin hw_out_mode1.bin 1; echo M1_$$' 'M1_\d+' 40000) 8

# ---- expose results ----
AskWait 'busybox httpd -p 8080 -h /home/root/dehaze; echo HTP_$$' 'HTP_\d+' 5000 | Out-Null
Show 'files' (Ask 'ls -l /home/root/dehaze; echo LIST_OK' 2000) 8

# ---- pull the images back and turn them into one PNG ----
# Doing this here means a board session ends with a picture to look at instead of
# a list of files to fetch by hand. Both plates are the same 640x480 BGR888 dump
# the board wrote, so the side-by-side is hazy | dehazed.
Write-Host ''
Write-Host '=== fetch images from the board (httpd on 8080) ==='
$boardHttp = 'http://' + $BoardIp + ':8080/'
$gotHazy = $false
try {
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 -Uri ($boardHttp + 'hw_out_cam.bin.in.bgr') `
        -OutFile (Join-Path $www 'hw_in.bgr')
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 -Uri ($boardHttp + 'hw_out_cam.bin') `
        -OutFile (Join-Path $www 'hw_out.bgr')
    $gotHazy = $true
    Get-ChildItem (Join-Path $www 'hw_in.bgr'), (Join-Path $www 'hw_out.bgr') |
        Format-Table Name, Length -AutoSize | Out-String | Write-Host
} catch {
    Write-Host ('!! could not fetch the images: ' + $_.Exception.Message)
    Write-Host ('   the board''s httpd may not have started; files are in /home/root/dehaze')
}

if ($gotHazy) {
    $py = 'python'
    $png = Join-Path $www 'hw_compare.png'
    Write-Host '=== hazy | dehazed -> hw_compare.png ==='
    try {
        & $py (Join-Path $dir '00_tools\bin_to_png.py') --w 640 --h 480 --out $png `
              (Join-Path $www 'hw_in.bgr') (Join-Path $www 'hw_out.bgr')
    } catch {
        Write-Host ('!! png conversion failed: ' + $_.Exception.Message)
    }
    if (Test-Path $png) { Write-Host ('open: ' + $png) }
}

# ---- verdict ----
# After the camera step `dehaze_cam` prints one short machine-readable line:
#     sccb=1 cap=1 ddr=1 deh=1 px=640 nw=320 sent=320 st=0
# Short on purpose: the Linux console wraps at 80 columns, so anything longer
# cannot be matched reliably against the raw serial log. Each field is exactly
# one stage of the chain.
Write-Host ''
Write-Host '=== ACCEPTANCE CHECKLIST ==='
foreach ($item in @(
    @{ Name = 'SCCB accepted the 254-entry table'; Pattern = 'sccb=1 cap=1' },
    @{ Name = 'capture delivers 640 pixels/line';  Pattern = 'px=640' },
    @{ Name = 'writer idle at the end (not stuck)';Pattern = 'sent=320 st=0' },
    @{ Name = 'dehaze core ran on the live frame'; Pattern = 'ddr=1' }
)) {
    $ok = $false
    if (Test-Path $log) { $ok = (Select-String -Path $log -Pattern $item.Pattern -Quiet) }
    Write-Host ('  [' + $(if ($ok) { 'OK' } else { '??' }) + '] ' + $item.Name)
}
Write-Host '  (?? = that token is missing from the log; the printout above says why)'

Write-Host ''
Write-Host ('log: ' + $log)
Write-Host 'BOARD_RUN_DONE'
$sw.Close()
$sp.Close()

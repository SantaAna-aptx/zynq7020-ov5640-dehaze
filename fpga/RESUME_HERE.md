# 上板前状态（2026-10-24 00:20）—— 已验收 + 实时网页 + 去雾画质 v2

> 判断依据都来自板上实测，不是推断。总览见 `HANDOVER.md`，摄像头细节见 `04_camera/README.md`。

---

## 0. 去雾画质 v2（2026-10-23 深夜）

### 0.1 改了什么

v1 的大气光 A 取的是"dark-channel 直方图 top 0.1% 里 R+G+B 最大的**那一个像素**"的 RGB。
单像素估计会落在一个任意色偏的高光上（板上实测 A=(206,190,198)，通道差 16 级），
而 `J_c = (I_c-A_c)/t + A_c` 在 t≈0.3 时把 16 级的 A 差放成 **~40 级的通道偏移** ——
这就是"画面发绿、蓝通道被压死"的根因。

v2（`01_hls/src/dehaze_top.cpp`）：

1. **直方图每个 bin 里累积各通道的和**（`bin_sr/sg/sb`），A 改成 top band 的
   **平均色**，不再是单像素；
2. 新增 `acomp_q8` 寄存器（`0x58`，Q8）：把 A 往自身灰度拉，
   `256` = 保留估计值，`0` = 完全中性；
3. `mode` 寄存器因此后移一位：**`mode` 现在是 `0x60`**（HLS 按形参顺序分配，
   见 `01_hls/proj_dehaze/sol1/impl/ip/drivers/.../xdehaze_top_hw.h`）。

> ⚠ 三个用户态程序（`dehaze_cam/web/linux.c`）的 `R_ACOMP/R_MODE` 已同步改好，
> 旧的 `dehaze_cam` 二进制**不能**再往新位流里写（会把 acomp 写成 mode）。

### 0.2 板上实测的改善

| 量 | v1 | v2 |
|---|---|---|
| 估计出的 A(B,G,R) | 206,190,198（差 16 级） | **195,192,191（差 4 级）** |
| 白色物体去雾后的 G−R / G−B | +7.5 / +4.8（**算法自己加的色偏**） | **+2.1 / +0.2（白仍是白）** |
| 整帧均值（输入 110.7） | 99.8 | **106.3（更接近输入，不再整体压暗）** |
| 资源 | LUT 28.3%，BRAM 91，DSP 63 | LUT **30.5%**，BRAM **81.5**（反而少了），DSP **74** |
| 时序 | WNS +3.206 | **WNS +2.438 / WHS +0.043**，CDC clean |

HLS C 仿真：`[tb] PASS`，mode0 PSNR 42.3 dB、mode1 44.5 dB（对更新后的 Python 金模型）。
金模型 `00_tools/make_testvector.py` 的 `atmospheric_light_hist()` 已同步成 v2 算法；
A 的检查改成容差 ±3 级（边框处理不同导致 top band 的像素集合略有差异，属正常）。

### 0.3 页面上的调参（不用重烧位流）

预览页顶部新增 4 个滑块 + 3 个预设（弱/标准/强）：

| 参数 | 含义 | 默认 |
|---|---|---|
| `omega` | 去雾强度，Q8（0..256） | 176 (0.69) |
| `t0` | 透射率下限，Q8（1..256） | 72 (0.28) |
| `gain` | 输出增益，Q8（256=1.0） | 280 (1.09) |
| `acomp` | A 彩度保留，Q8（0=全灰） | 96 (0.375) |

拖动 → `GET /set.cgi?...` → 板子写 `/www/params.cfg` → `dehaze_web` 下一帧生效。
串口等价操作：`echo omega=160 > /www/params.cfg`。

### 0.4 还没做的画质项

* 透射率的下采样/引导滤波窗口是固定的（r=30），远景与近景用同一个 eps；
* 没有天空/高亮区保护，也没有 gamma 曲线（暗部仍偏暗）；
* 逐通道除法本质上会放大饱和度（实测 25% → 37%），若想更"自然"可在核里加
  最大饱和度限制或改用 luma 引导的单通道 t。

---

## 1. 实时预览（2026-10-23 晚新增）

一条命令，板子自己起网页服务，浏览器直连板子（不经过 PC）：

```powershell
cd D:\dehaze\fpga
powershell -ExecutionPolicy Bypass -File board_run.ps1 -HttpPort 8010 -Live -LiveMode 1
```

跑完会打印形如 `open: http://192.168.1.50:8090/` 的地址。页面里：

* 左 ① 摄像头原始帧，右 ② PL 去雾输出，**同一帧**并列；
* 顶栏：刷新 fps / 去雾核耗时 / 大气光 A(B,G,R) / 模式 / 分辨率 / ring 帧号；
* 换模式：板子串口上 `echo 0 > /www/mode.cfg`（0 = 不细化，1 = guided filter），下一帧生效；
* 停：`killall dehaze_web`。

实现：`03_linux/src/dehaze_web.c` + `03_linux/www/index.html`。
板子端每帧从 ring 取图 → 写成 `raw.bmp` → 跑 HLS 核 → 写 `out.bmp` + `stats.txt`
到 **tmpfs 上的 `/www`**，`busybox httpd` 直接发这些文件。
用 BMP 是因为 busybox rootfs 里没有 libjpeg/libpng，而 BMP 只是 54 字节头 + 像素。

两个已经踩过的坑（脚本已处理）：

* **`busybox httpd` 不会改进程名**，所以 `killall httpd` / `pidof httpd` 都找不到它；
  脚本改成从 8090 往上找第一个能 bind 的端口。若打印出 8091 而不是 8090，
  说明有旧 httpd 占着 8090，断电后就会恢复成 8090。
* **`dehaze_web` 必须挂住 SIGHUP**：`init=/bin/sh` 没有作业控制，脚本关串口时
  普通 `&` 后台进程会被 SIGHUP 杀掉。现在用 `sh -c 'trap "" HUP; exec ...'` 启动，
  所以 PC 关掉串口后网页照样在跑。

`-Live` 还会**先探测 PL 里是不是已经是我们这个设计**（读 `0x43C10010` 的自由运行计数器两次，
必须不同才算数），是就跳过位流加载 —— 避免白白消耗那 6 次 `fpga_manager` 额度。

---

## 1. 一句话

`OV5640 → DVP 采集 → 双时钟行缓存 → DDR ring → Linux 取帧 → HLS 去雾 → 回传 PNG`
**全部就绪并已上板验收通过**。这一轮修掉了一个真 bug（AXI 突发长度超过 AXI3 上限），
并且把"上板一次就能判断成败"的自检加进了硬件寄存器和两边的程序里。

---

## 2. 本轮改了什么（相对上一次交接）

### 2.1 关键 bug：AXI 突发 256 拍超过 AXI3 上限
`ddr_line_writer.v` 把一个 320 字（1280 字节）的行拆成 256 拍 + 64 拍的突发。
Zynq-7000 的 HP 口是 **AXI3，单次突发最多 16 拍**，256 拍要靠 BD 里的
`axi_protocol_converter` 去拆。板上抓到的现场是：

```
wphase=3  wvalid=1  wready=0  forever      ← 数据拍永远不被接收
n_words=320  sent=0                        ← 第一个突发就没发出去
awvalid=0  awready=0                       ← 地址其实已经握手过了
```

改成 **`MAX_CHUNK = 16`**：写手自己发 16 拍的突发（正好是 AXI3 的原生上限），
320 字的一行 = 20 个 16 拍突发。不再依赖 converter 拆长突发。
（旁证：HLS 去雾核的 m_axi 默认也是 16 拍，它一直是好的。）

仿真已覆盖这个路径：`tb_camera_pipe` 用 600 像素/行（300 字 → 19 个 16 拍突发），
逐字比对 ring 内容，`ALL CAMERA TESTBENCHES PASSED`。

### 2.2 软件侧新增"DDR 到底有没有被写"的自检
之前最危险的误判是：**采集全对、但写通路死了，读到的图是 DDR 里上次开机的残留**，
看起来却像一张"有点奇怪的图"。现在 `dehaze_cam` 会：

* 读帧前后各算一次 ring 的 FNV-1a 校验和 → 打印 `content CHANGED / UNCHANGED`；
* 打印新增帧数与 fps；
* 结束时打印一行**短的**机器可读结论（故意 <80 列，因为串口控制台会折行）：

```
sccb=1 cap=1 ddr=1 deh=1 px=640 nw=320 sent=320 st=0
  chip=56 frames=37 A=217,215,214 t=176.2ms
```

`ddr=0` 时会额外打印一段说明，明确写"下面写出的图是 DDR 残留，不是摄像头画面"。

### 2.3 `board_run.ps1` 一条命令跑完并自动验收
新增（在最后）：

* 从板子自带的 httpd（8080）拉回 `hw_out_cam.bin.in.bgr` 和 `hw_out_cam.bin`；
* 调 `00_tools/bin_to_png.py` 生成 **`www\hw_compare.png`（雾图 | 去雾图 并排）**；
* 打印 `ACCEPTANCE CHECKLIST`，用 4 个短 token 判定：
  `sccb=1 cap=1` / `px=640` / `sent=320 st=0` / `ddr=1`。

### 2.4 输出行长度全部缩短
串口控制台在 80 列折行，长句会被切断导致 PC 端匹配不到。
`dehaze_cam` 的所有诊断行都改短了（`sensor:` / `line:` / `writer:` / `axi:` / `burst:`）。

---

## 3. 当前构建状态（已验证）

| 项 | 值 |
|---|---|
| 位流 | `02_vivado/output/dehaze_top.bin`，2026-10-23 17:37，4 045 568 B |
| 时序 | **WNS +3.206 ns，WHS +0.034 ns**（FCLK0 = 50 MHz） |
| CDC | `no setup-required paths between cmos_pclk_clk and clk_fpga_0 (CDC clean)` |
| 资源 | LUT 15 056/53 200 = **28.3 %**，FF 12 207，BRAM 91/140 = **65 %**，DSP 63，MMCM 1 |
| `cam_top_0` 自身 | 633 LUT / 894 FF / 2×RAMB36 + 1×RAMB18 |
| 已暂存 | `www\dehaze_top.bin`、`www\dehaze_cam`、`www\dehaze_linux` 均为最新 |

---

## 4. 上板验收步骤（一条命令）

```powershell
# 0) 重要：先断电重上电。理由见 §6。
#    重上电后板子会停在 U-Boot，board_run.ps1 会自己抓 U-Boot 启 Linux。

# 1) 单独开一个窗口起 HTTP（给板子 wget 用）
cd D:\dehaze\fpga\www ; python -m http.server 8010

# 2) 主窗口：一键上板 + 自动验收
cd D:\dehaze\fpga
powershell -ExecutionPolicy Bypass -File board_run.ps1 -HttpPort 8010
```

跑完看三样东西：

1. 控制台最后的 **ACCEPTANCE CHECKLIST**，四个 `[OK]`；
2. `dehaze_cam` 打印的 `sccb=1 cap=1 ddr=1 deh=1 px=640 nw=320 sent=320 st=0`；
3. **`D:\dehaze\fpga\www\hw_compare.png`** —— 左边雾图、右边去雾图，能看出真实场景。

### 期望看到的数字（上一次实测）

```
sensor: lines/s=3500 pclk=13.2MHz fclk=50.0MHz
  line: 3783 pclk, 640 px (HTS in table=1892)
  writer: state=0
  burst: n_words=320 sent=320
ring: 2 new frames in 0.3 s (7.6 fps), content CHANGED -- the PL is writing DDR
dehaze mode 1: 640x480  A(B,G,R) = 217,215,214  latency = ~176 ms
```

* PCLK 13~19 MHz、行频 ~3.5 kHz、帧率 ~7 fps 都是**当前配置的正常值**：
  表里 `0x3035=0x91` 把 SYSCLK 分频到 10（厂家原表是 5），目的是让 PCLK
  落在像素域时序宽裕、写手跟得上的区间。**去雾核每帧 176 ms，本来就只有 5.7 fps，
  所以演示的瓶颈在核，不在相机。**
* `writer: state` 是采样瞬间的 FSM 状态，0 = 空闲、2 = 写数据阶段。只要没有
  `STUCK(>5ms)` 且 `frames` 在涨就是正常的。

---

## 5. 如果 `ddr=0` 还没通（备用方案，按顺序）

1. 先看 `axi:` 那行：`wv=1 wr=0` 说明数据拍仍不被接收；
   `awv=1 awr=0` 说明地址拍不被接收；
   `burst: n_words=320 sent=0` 说明连第一个突发都没完成。
2. **降到单拍写**：把 `ddr_line_writer.v` 的 `MAX_CHUNK` 改成 1（每个 32 位字一次
   AW/W/B 事务，320 次/行）。行周期 287 µs、单次事务约 10 拍 → 约 64 µs/行，够用。
   这是最保守的形态，任何 AXI 互联都支持。
3. **换 HP 口**：把 `02_vivado/create_bd.tcl` 里 `axi_pc_cam/M_AXI` 从 `S_AXI_HP3`
   改到别的空闲 HP 口（HP0/HP1/HP2 已被去雾核占用，可临时把 scratch 挪走腾一个）。
   `board_run.ps1` 的 AFI 写入已覆盖 HP0..HP3，不用改。
4. 最后手段：ring 写入改走 GP（AXI-Lite）通道 —— 带宽够（≈18 MB/s），但会占 PS 总线。

---

## 6. 为什么强调"先断电重上电"

* 位流是通过 `fpga_manager` 软加载的，**连续 load 6~7 次后必然出**
  `fpga_manager fpga0: DMA reported error ... Error while writing image data to FPGA`，
  之后只能断电。本次会话已经 load 了 6 次。
* 上一次排查里 HP3 上的写事务是**半途挂住**的。软重载位流不会清 PS 侧 AXI 互联的
  内部状态，只有断电才能保证干净。
* 断电后第一次 load 就是最可信的一次，正好用来验收。

---

## 7. 寄存器映射（`0x43C10000 +`）

```
0x00 RO 状态   { drop, entries[8:0], ovf, err, done, busy }
0x04 RO 最近一行写出的字数（2 像素/字，320 = 640 px）
0x08 RO 帧数（写侧，每帧行 0 加一）
0x0C RO 当前 ring 行号（0..479 循环）
0x10 RO 自由运行 aclk 计数（读两次算 FCLK0）
0x14 RW ctl（bit0 翻转重跑 SCCB 表）
0x18 RO 采集探针 { pclk_alive, vsync_edge, vhi, vlo, href, data, gate, line_end }
0x1C RO SCCB 回读 { 300A, 3035, 380C, 380D }
0x20 RO 回读状态 0/1/2
0x24 RO HREF 下降沿计数（行频分子）
0x28 RO 1024-PCLK 计数（PCLK 分子）
0x2C RO 恒 0（原 XCLK 计数，已删）
0x30 RO 最近一行的像素数（应为 640）
0x34 RO 最近一行的 PCLK 数（应 ≈ 3783 = 2×HTS）
0x38 RO 写手 { stuck, 3'b0, st }
0x3C RO AXI 握手快照 { stuck, st, wphase, bready, bvalid, wready, wvalid, awready, awvalid }
0x40 RO { n_words, sent }
```

---

## 8. 还没做的事（等验收通过再谈）

* 去雾画质：远景过亮、天空保护、ω 自适应 —— 走的是 `dehaze_linux` 那条已验证的通路。
* ~124 ms 与时钟无关的延迟地板（需要在核内加周期计数器才能拆）。
* PCLK 若想回到 42 MHz（30 fps）需要把 `0x3035` 从 `0x91` 改回 `0x41`；演示当前是
  核限速（176 ms/帧），改回去对观感没有提升，暂时不动。

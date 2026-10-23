# 04_camera — OV5640 采集子系统

纯 PL 的摄像头通路：**OV5640 (DVP) → 采集 → 双时钟行缓冲 → AXI 突发写 DDR ring**，
再由 `dehaze_cam` 把 ring 里的 RGB565 转成 BGR888 喂给 dehaze 核。

本目录只做“把摄像头接进 dehaze 系统”这一件事，不含 DPU、不含 YOLO。
摄像头的寄存器配置取自
`一份厂商 5640_sccb_hdmi 采集+显示例程`（米联客 5640_sccb_hdmi 例程，
该例程在本板上验证过），但**只取了寄存器数值**，RTL 全部是重新写的。

---

## 1. 文件

| 文件 | 作用 |
|---|---|
| `rtl/ov5640_sccb.v` | SCCB(I2C) 主机 + 寄存器表sequencer，复位后自动开跑；写 `0x3008=0x82` 后自动停 5 ms |
| `rtl/ov5640_init_rom.v` | **自动生成**的 512×24 块 RAM 寄存器表（251 条） |
| `rtl/ov5640_dvp_linebuf.v` | 纯 pclk 域：DVP 字节配对 → 32bit 字 → 行缓冲写口 + 行交班 toggle |
| `rtl/ddr_line_writer.v` | 纯 aclk 域：拿到一行 → 拆成 ≤256 beat 的 AXI4 突发写 DDR ring |
| `rtl/camera_pipe.v` | 双时钟块 RAM（写口 pclk / 读口 aclk）+ 上面两个模块 |
| `rtl/camera_top.v` | 顶层：XCLK 分频、SCCB、`camera_pipe`、`axil_status` |
| `rtl/axil_status.v` | 极简 AXI4-Lite 状态/控制从口（没有 JTAG，只能靠它定位问题） |
| `tools/ov5640_640x480_rgb565.reg` | 寄存器表正本（`0xRRRR 0xVV` 每行一条 + `RESOLUTION W H`） |
| `tools/gen_sccb_table.py` | .reg → ROM Verilog + hex |
| `tools/extract_ref_regs.py` | 一次性：从米联客 C 例程抽 (reg,value) 到 .reg |
| `tb/tb_ov5640_sccb.v` | SCCB 自检：把线上每一位解回来跟 ROM 逐条比对 |
| `tb/tb_camera_pipe.v` | 采集自检：字节配对、warm-up、突发拆分、ring 地址 |
| `tb/tb_axil_status.v` | 状态口自检：AW/W 分拍与同拍、全部寄存器回读 |
| `sim.ps1` | 跑上面三个 testbench |

## 2. 已验证 / 未验证

**已通过（xsim 自检，`sim.ps1` 全绿）**
- SCCB：251 条寄存器写，从 SDA/SCL 上逐位解码回来，与 ROM 内容**逐位一致**，
  没有 NACK，SCL 上升沿数 = 251×37。
- 采集：600×3 帧，第一帧被 warm-up 门丢弃，后两帧都落到 ring row 0..2（帧对齐）；
  300 字的行被拆成 256+44 两段突发；ring 地址、字内像素顺序、AWLEN/WLAST 全部核对通过。
- 状态口：AW 与 W **分拍**和**同拍**两种写时序都通过（分拍是 PS 经 smartconnect 的真实时序，
  同拍写法会让写通道死锁），6 个寄存器全部回读正确。
- 软件：`dehaze_cam` 交叉编译无警告。

**时序**：`clk_fpga_0` @50 MHz **WNS +3.367 ns**、`cmos_pclk_clk` @43.75 MHz 均 0 违例
（全设计 WHS +0.043 ns）；**跨时钟域 0 条需要满足单周期的路径**（build.tcl 里有硬门禁，
不满足直接 error 不出比特流）。

**资源**：整个摄像头子系统 `cam_top_0` = **373 LUT / 593 FF / 2×RAMB36 + 1×RAMB18 / 0 DSP**；
全设计 LUT 14,074 / 53,200 = **26.45%**。
（最初那版 AXI-Stream + 组合读 FIFO 是 26,457 LUT —— 全设计 79.95%，放不下。）

**未在板上验证过**：功能本地仿真全绿、比特流已生成且时序干净，但还没上过板。
上板时按第 5 节跑，`dehaze_cam` 的打印会直接指出卡在哪一环。

## 3. 关键设计决定（每条都是踩过的坑）

1. **不做 AXI-Stream + 异步 FIFO**。第一版手写格雷码 FIFO 组合读
   （`assign rdata = mem[addr]`），综合把 1024×18 展开成 ~6k LUT 的 mux 树，
   7020 直接放不下；第二版换 XPM `xpm_fifo_async`（FWFT），仿真里连续两次读
   返回**同一个字**，导致每个像素被复制一遍。最终改成**双时钟块 RAM + 行 toggle**：
   跨时钟只过一个 toggle 和（整行稳定的）字数，读写两端都是寄存器输出，
   稳定推断成 BRAM。
2. **行缓冲双 bank**。采集写 A bank，AXI 侧突发 B bank，一行永远不是“半可见”的。
   bank 被覆盖时置 `drop` 而不是写出一行撕裂数据。
3. **只按“完整一行”发突发**。这样 `awlen` 是已知的，`WLAST` 不可能和它不一致。
   早期版本想提前结束突发，AXI 不允许，直接死锁。行超过 256 beat 时分段发（300 字 → 256+44）。
4. **BRAM 读要 4 拍**：给地址 → 等数据 → 出示 beat → 等 wready。
   3 拍版本会晚一拍取数，整行数据错位一个字。
5. **warm-up 门在第几帧判定、然后整帧锁存**。写成连续判断 `vs_cnt >= WARMUP` 时，
   计数在第一帧中途就涨上去，第 0 帧（全黑）会漏过去。
6. **SCCB 的 `S_START → S_BIT` 必须把 `phase` 清 0**。不清的话 S_BIT 会多跑一次
   phase3，每字节吃掉一个 bit——寄存器地址/数据全部错位，而且“看起来还能跑”。
7. **寄存器表用块 RAM，不用 `case`**。251 条 ×24bit 的 `case` 是纯 LUT 逻辑，
   在已经很紧的 7020 上要吃掉约 1k LUT。
8. **`byte_sel`/`bc` 在 HREF 为低时清零**，所以每行重新对齐；HREF 上升的第一个
   周期就要采样，跳过它会整整错一个字节。
9. **XCLK = FCLK0 / XCLK_DIV**（默认 4）。FCLK0 = 50 MHz → XCLK 12.5 MHz，
   传感器内部 PLL 线性放大 3.5× → PCLK ≈ 43.75 MHz。
   PCLK 落在普通 IO 引脚上（D19 不是时钟专用脚），43.75 MHz 比米联客例程的 84 MHz
   保守得多，`CLOCK_DEDICATED_ROUTE FALSE` 仍然是必须的。
10. **跨时钟域的东西必须真的只有"能跨"的那些**。时序报告最初有 56 个
    pclk→aclk 违例端点，一半是约束没生效，另一半**是真 bug**：采集侧的 16 bit
    帧计数器和 overflow 标志被直接接进了 AXI-Lite 状态多路器，既没有同步、
    多位计数器也不可能逐位安全搬运。现在的做法：
    - 帧计数改由**写侧**统计（它本来就能看到每帧的第 0 行），不再跨域；
    - overflow 是粘滞位，进一个两级 `ASYNC_REG` 同步器；
    - 行交接（toggle + 字数/bank/首行标志）按异步握手处理；
    - `02_vivado/camera.xdc` 里的 false path 用 **RTL 实例名**匹配
      （`*u_pipe/u_wr*`、`*u_pipe/ovf_s1*`、`*u_pipe/prst_s*`），
      并且在匹配不到时**直接 error**，不允许静默生成比特流。
      为什么不能用 `set_clock_groups`：读 camera.xdc 时 PS7 的 `clk_fpga_0`
      还没定义，那条命令会静默变成空操作。
11. **AXI4-Lite 从口的 AW 和 W 必须独立接收**。写成"两个都 valid 才应答"
    在 PS 经 smartconnect 写时会死锁——它先给 AW、等 AWREADY，再给 W，
    结果 CPU 卡在写寄存器上。`tb_axil_status.v` 专门测这条。

## 4. 时钟/带宽

| 量 | 值 |
|---|---|
| FCLK0 | 50 MHz（`0xF8000170 = 0x00200500`，也是 ps7_init 默认值） |
| XCLK | 12.5 MHz（`XCLK_DIV=4`） |
| PCLK | ≈ 43.75 MHz（传感器 PLL，`0x3036=0x69`，`0x3037=0x13`，`0x3108=0x01`） |
| 分辨率 | 640×480 RGB565（`0x3808/09=1280`→这里改成 640，见 .reg 的 `RESOLUTION`） |
| HTS/VTS | 1892 / 740 → 43.75e6/(1892×740) ≈ 31 fps |
| 每行 | 1280 字节 = 320 个 32bit 字 |
| 突发带宽 | 2–3 AXI 拍/beat ⇒ 60–100 MB/s @50 MHz |
| 行周期 | 640×2/43.75e6 ≈ 29 µs，一次突发 ~1–2 µs |

`dehaze_cam` 会打印**实测** FCLK0（读 `0x10` 的自由计数寄存器两次），
所以不用猜 devmem 写了多少。

## 5. 上板流程

```powershell
# 1) 生成/校验寄存器表（改分辨率或换传感器时）
python 04_camera\tools\gen_sccb_table.py

# 2) 仿真自检
powershell -ExecutionPolicy Bypass -File 04_camera\sim.ps1

# 3) 综合实现（生成 .bit + fpga_manager 用的 .bin）
$env:VIVADO_STAGE="hdf"; cd 02_vivado; vivado -mode batch -source build.tcl

# 4) 交叉编译
powershell -ExecutionPolicy Bypass -File 03_linux\build.ps1

# 5) 一键上板（会抓 U-Boot、启 Linux、下 bit、设时钟、跑 camera 和两种 mode）
powershell -ExecutionPolicy Bypass -File board_run.ps1
```

板上单跑：

```
./dehaze_cam out.bin 1          # 640x480，guided filter
./dehaze_cam out.bin 0          # 640x480，不做细化
./dehaze_cam out.bin 1 640 480  # 显式给尺寸
```

程序会依次打印：实测 FCLK0、camera 状态字、实测行宽、帧数、dehaze 耗时。
早期退出时的提示直接对应故障点：

| 打印 | 含义 | 先查什么 |
|---|---|---|
| `SCCB got a NACK` | 从机不应答 | 模块 3.3 V、F19/F20 引脚、上拉、模块是否插反 |
| `SCCB did not finish` | 序列没跑完 | 同上；`entries` 会给出跑到第几条 |
| `no frame arrived` | 配置成功但没图像 | XCLK（示波器看 D20）、PCLK（D19）、VSYNC（C20）；见下面两条 |
| `line buffer overflowed` | 行太长/写太慢 | RESOLUTION 是否 > 2048 像素 |
| `writer dropped a line` | DDR 带宽不够 | FCLK0 是否被改小 |
| `measured line ... (expected 640)` | 传感器没在这个模式 | 表里 `0x3808/0x380A` 与 `RESOLUTION` 是否一致 |

两条针对性调整：

- **完全没有 PCLK** → 传感器 PLL 没锁。当前 XCLK = 12.5 MHz 时 VCO ≈ 328 MHz；
  如果这颗模块要求 VCO ≥ 400 MHz，把 `camera_top.v` 的 `XCLK_DIV` 默认值改成 2
  （XCLK 25 MHz，VCO ≈ 656 MHz，PCLK 87.5 MHz）再综合。
  代价只是引脚采样变紧，`CLOCK_DEDICATED_ROUTE FALSE` 已经在约束里了。
- **红蓝反了** → `0x4300` 的 bit0。表里现在是 `0x61`（RGB565，高 5 位是 R，
  与 `dehaze_cam.c` 的 `rgb565_to_bgr` 一致）。改成 `0x60` 即 BGR565。

## 6. 板上状态寄存器（0x43C10000）

| 偏移 | 方向 | 内容 |
|---|---|---|
| 0x00 | RO | bit0 SCCB busy, bit1 done, bit2 err, bit3 行缓冲溢出, bit4 丢行, bit12:4 已写条数 |
| 0x04 | RO | 上一行的字数（×2 = 像素） |
| 0x08 | RO | 已采集帧数 |
| 0x0C | RO | 当前 ring 行号 |
| 0x10 | RO | 自由运行的 aclk 计数器（两次采样算 FCLK0） |
| 0x14 | RW | bit0 翻转一次 → 重跑整个 SCCB 序列（不用断电） |

## 7. DDR ring 布局

```
byte address = 0x2000_0000 + (row % 1024) * 2048 * 4 + word * 4
word         = { pixel[2k+1], pixel[2k] }        # 先到的像素在低半字
```
行写满就翻 bank，ring 深度 1024 行 > 480 行一帧，所以软件读 `row 0..479`
总能拿到一帧完整图像（滚动覆盖时可能有一条水平接缝）。

## 8. 改分辨率 / 换 sensor

只改 `tools/ov5640_640x480_rgb565.reg` 里的 `RESOLUTION 640 480`，然后重跑
`gen_sccb_table.py` + 综合。注意传感器侧还有几个“窗口”寄存器
（`0x3800-0x3807`、`0x3813`）是按 VGA 窗口给的；`0x5001=0x83` 打开了 ISP 缩放器，
所以改 `0x3808/0x380A` 就够了，内部窗口不用动。

`HALF`（每个 bank 的字数，默认 1024 = 2048 像素）决定单行上限；
真要 1920 宽就把它改成 2048 并同步 `camera_pipe`/`ddr_line_writer` 的参数。

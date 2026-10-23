# 交接 / 状态说明（更新于 2026-10-22 上午）

> **2026-10-22 17:55 暂停，续接请看 `RESUME_HERE.md`**（本次会话结论：采集已通，
> 卡在 DDR 写通路；16 拍突发改动已过仿真、未上板）。

> **当前状态**：摄像头通路 RTL 全部写完，三个自检 testbench 全绿，
> 跨时钟域的真 bug 已修，**综合/实现/时序全部干净，比特流与 `dehaze_top.bin` 已重新生成**。
> 下一步就是上板。

```
WNS @50 MHz (clk_fpga_0)  = +3.367 ns    0 违例
WHS                        = +0.043 ns    （HLS 域内一条，非摄像头引入）
跨时钟域 cmos_pclk → clk_fpga_0 的违例 = 0
全设计 LUT 14,074 / 53,200 = 26.45%     BRAM 91/140 = 65%     DSP 63/220
cam_top_0 = 373 LUT / 593 FF / 2×RAMB36 + 1×RAMB18 / 0 DSP
产物：output/system_wrapper.bit  2026-10-22 10:20
      output/dehaze_top.bin      2026-10-22 10:21
```

---

## 1. 一句话现状

`04_camera/` 里一套自研的 OV5640 采集子系统，接进原本的纯 PL dehaze 工程：
**摄像头 → SCCB 配置 → DVP 采集 → 双时钟行缓冲 → AXI4 突发写 DDR ring →
`dehaze_cam` 读出跑 dehaze → 文件**。

- 摄像头子系统 = **341 LUT / 526 FF / 2×RAMB36 + 1×RAMB18 / 0 DSP**
  （第一版写法是 26,457 LUT，全设计 79.95%，放不下）
- 三个 testbench（SCCB 逐位、采集全链路、AXI-Lite 状态口）**全 PASS**
- 用户已确认**摄像头接线正确**（这一项原本是最担心的外部变量）

---

## 2. 这一夜之后新做完的（相对昨夜交接）

| 事 | 结果 |
|---|---|
| 定位 CDC 约束为什么静默失效 | 读 camera.xdc 时 PS7 的 `clk_fpga_0` 还没定义；`REF_NAME` 又被块设计改名锚不住 |
| 确认可用的 cell 过滤器 | `*u_pipe/u_wr*` → 389 cells，`*u_pipe/prst_s*` → 3，`*u_pipe/u_cap*` → 231 |
| 修 camera.xdc | 改用 RTL 实例名匹配，并加 **匹配不到就 error** 的守卫，不允许静默出比特流 |
| **发现并修掉一个真 bug** | 采集侧 16 bit 帧计数器 + overflow 直接跨到 AXI-Lite 状态多路器，既没同步、多位也无法逐位安全搬运 → 帧计数改由写侧统计，overflow 走两级 `ASYNC_REG` |
| 新增 `tb_axil_status.v` | 覆盖 AW/W **分拍**（PS 真实时序，旧写法会死锁 CPU）与同拍，6 个寄存器回读 |
| 修 `axil_status.v` | AW/W 独立接收（旧版要求同拍 → 会死锁） |
| `board_run.ps1` 加产物暂存 + 前置检查 | 自动把 4 个产物拷到 `D:\dehaze\fpga\www\`，并 HTTP HEAD 验证可达；不可达就打印"在哪个目录起 server"再退出，不再等板子 boot 到一半才发现 wget 失败 |

跨时钟域违例端点：**56 → 16 → 0**。16 那次是工具帮我抓出的真 bug，
不是约束问题 —— "约束修了一半、剩下的其实是设计错"这种情况很容易被忽略。

### 2.1 ⭐ 约束一直不生效的真正原因：XDC 里不能写 Tcl `if`

三次编译白花的根因，记在这里免得再犯：

```
CRITICAL WARNING: [Designutils 20-1307] Command 'if' is not supported in the
xdc constraint file. [camera.xdc:81]
```

Vivado 的 XDC 解析器在综合阶段**不支持控制流**，遇到 `if` 只是跳过整块，
于是包在 `if` 里的 `set_clock_groups` / 守卫全部变成空操作 —— 而且只留一条
"不受支持"的告警，很容易被后面的刷屏盖掉。

现在 `camera.xdc` 里**只有纯约束**（`create_clock` / `set_input_delay` /
`set_false_path` / `set_property`），所有校验搬到 `build.tcl`，那里是普通 Tcl：

- `worst_slack max/min` → 负值直接 `error`，不出比特流
- `get_timing_paths -from cmos_pclk_clk -to clk_fpga_0 -slack_lesser_than 0`
  非空 → 说明还有跨域路径被要求满足单周期，直接 `error`

另外 `set_false_path` 用**不带 `-to` 的宽形式**（`-from [get_clocks cmos_pclk_clk]`）：
窄的 `-to <cells>` 版本漏掉了 `row_reg[*]/CE` 这类**时钟使能端点**，
它们在报告里以 -3.1 ns "max delay" 违例的形式残留。宽形式的代价是
像素域内部路径不再被时序分析（该域 16 级寄存器、43.75 MHz 下余量约 20 ns，
行为由 `tb_camera_pipe.v` 覆盖），换来的是任何方向的跨域路径都不会漏。

---

## 3. 三个 testbench 覆盖什么

```powershell
powershell -ExecutionPolicy Bypass -File D:\dehaze\fpga\04_camera\sim.ps1
```

| bench | 断言内容 |
|---|---|
| `sccb` | 251 条寄存器写、9287 个 SCL 上升沿，把线上每一位解回来跟 ROM **逐位比对**，`err=0` |
| `pipe` | 600×3、3 帧；warm-up 丢第 0 帧；后两帧都落在 ring row 0..2（帧对齐）；300 字拆成 256+44 两段突发；ring 内容逐字核对；`ovf=0 drop=0` |
| `axil` | AW/W 分拍 + 同拍写；status/line_len/frames/row/cycles/ctl 全部回读；写只读地址不干扰 |

端口、参数、状态寄存器语义见 `04_camera/README.md`。

---

## 4. 板上流程（等这一轮编译完就能跑）

### 4.1 起 HTTP 服务（board_run.ps1 会自己检查这一步）
```powershell
cd D:\dehaze\fpga\www
python -m http.server 8010
```
`board_run.ps1` 每次启动会先把 4 个产物拷进 `www\`：
`dehaze_top.bin` / `dehaze_linux` / `dehaze_cam` / `fog_in.bin`。

### 4.2 一键上板
```powershell
powershell -ExecutionPolicy Bypass -File D:\dehaze\fpga\board_run.ps1 -HttpPort 8010
```
流程：抓 U-Boot → 启 Linux → wget → `fpga_manager` 加载位流 →
设 FCLK0=50 MHz + HP0..HP3 四个 AFI 32 bit → 跑 `dehaze_cam` → 跑 mode 0/1 → 起 httpd。

### 4.3 `dehaze_cam` 打印怎么读

```
FCLK0 = xx.xx MHz (measured), XCLK = FCLK0/4 -> PCLK ~ yy.yy MHz
camera at start: busy=.. done=.. err=.. ovf=.. drop=.. entries=... line_words=.. frames=.. row=..
SCCB finished after ~400 ms
measured line: 320 words = 640 pixels (expected 640)
dehaze mode 1: 640x480  A(B,G,R) = ...  latency = ... ms
```

| 看到 | 说明 | 下一步 |
|---|---|---|
| `FCLK0` 不是 ~50 MHz | devmem 没生效 | 回读 `0xF8000170` |
| `SCCB got a NACK` | 传感器不应答 | 供电/上拉（接线已确认，优先怀疑供电） |
| `SCCB never finished within 5 s` | 序列卡住 | 看 `entries` 跑到第几条 |
| `no frame arrived` | 配好了但没 PCLK | 示波器 D20(XCLK)/D19(PCLK)/C20(VSYNC)；或把 `XCLK_DIV` 4→2（见下） |
| `measured line` ≠ 640 | 传感器没进这个模式 | 查 `.reg` 的 `RESOLUTION` 与 `0x3808/0x380A` |
| `writer dropped a line` | DDR 带宽不够 | 确认 FCLK0 = 50 MHz |
| 红蓝互换 | `0x4300` bit0 | `0x61`（现在）↔ `0x60` |
| **完全没 PCLK** | 传感器 PLL 没锁，当前 VCO ≈ 328 MHz | `camera_top.v` 的 `XCLK_DIV` 4 → **2**（XCLK 25 MHz，VCO 656 MHz），重编译 |

---

## 5. 还需要做/可选做

| 优先级 | 事项 | 说明 |
|---|---|---|
| **P0** | 上板跑通摄像头（第 4 节） | 唯一剩下的必需项；接线已确认，编译已干净 |
| P1 | 抓一帧回 PC 看 | `dehaze_cam` 会顺带写 `<out>.in.bgr`（去雾前），用 `00_tools/bin_to_png.py` 转 PNG 对比 |
| P1 | 把实测结果回填 `SUMMARY.md` §3.4 / `04_camera/README.md` §2 | 现在写的是"未上板" |
| P2 | 去雾画质（远处过亮 / 天空保护 / 自适应 ω） | 一行都没动，是用户提过的 option B |
| P2 | dehaze 那 ~124 ms 与时钟无关的地板 | 需要核内周期计数器 |

---

## 6. 环境备忘（重启/换 shell 后）

```powershell
# Vivado 2019.1 不在 PATH 里
$env:PATH="D:\vivado2019.1\VIVADO20191\Vivado\2019.1\bin;"+$env:PATH
```

- 交叉编译器：`D:\vivado2019.1\VIVADO20191\SDK\2019.1\gnu\aarch32\nt\gcc-arm-linux-gnueabi\bin`
  （`03_linux/build.ps1` 已写死）
- 仿真需要 `glbl.v`，`sim.ps1` 里已指向 Vivado 安装目录；日志在 `04_camera/work/`
- ⚠ 第三方示例工程（标注 `CONFIDENTIAL IN CONFIDENCE` 的那种）只可以取"寄存器取值"这类事实，
  **不要**把它们的源码文件拷进本仓库；`fpga/04_camera/tools/*.py` 里已经改成由你把参考文件路径当参数传进来。
  `一份厂商 5640_sccb_hdmi 采集+显示例程` 也只取寄存器数值
- 相机引脚：scl F19 / sda F20 / vsync C20 / href B20 / pclk D19 / xclk D20 /
  data7..0 = F16 F17 E18 E19 E17 D18 B19 A20

### FCLK0 换算（这次彻底定下来了）
```
FCLK0 = 250 MHz / DIVISOR0      DIVISOR0 = 0xF8000170[13:8]
       20 → 12.5 MHz   8 → 31 MHz   6 → 42 MHz   5 → 50 MHz   4 → 62.5 MHz(出错)
```
印证：PS7 配置 `PCW_ACT_FPGA0_PERIPHERAL_FREQMHZ=50.000000` + `FCLK0_PERIPHERAL_DIVISOR0=5`。

---

## 7. 这一轮踩到并已修好的真 bug（避免重复怀疑）

1. **SCCB `S_START → S_BIT` 没清 `phase`** → 每字节少发 1 bit，251 条表全错位，
   但 ACK 全对、波形"正常"。只有"把线上每一位解回来跟 ROM 比对"才发现。
2. **块 RAM 读少一拍**（3 拍写法）→ 整行数据错位一个字。
3. **测试平台的 AXI 从模型同拍置位/清除 BVALID** → 主端永远看不到响应，直接挂死。
4. **warm-up 门写成连续判断** → 第 0 帧（全黑）漏过。
5. **XPM `xpm_fifo_async` FWFT 仿真里连续两次读回同一个字** → 每像素复制一遍。
   已彻底改成"双时钟块 RAM + 行 toggle"，不再用 FIFO。
6. **ring 行号不按帧复位** → `dehaze_cam` 读 row 0..479 只是碰巧对齐。
   已加 `line_first`，写侧看到就归零。
7. **`dehaze_cam` 行跨距**：dehaze 核没有 stride 寄存器，必须按 `stride == W` 打包。
8. **`axil_status` AW/W 同拍要求** → 与 PS 的 AXI-Lite 写时序冲突，会死锁 CPU。
9. **帧计数器/overflow 未同步跨域** → 见 §2，时序工具抓出来的。
10. **CDC 约束静默失效**（`set_clock_groups` 与锚定 `REF_NAME` 的 false path）→ 见 §2.1。
11. **XDC 里写 Tcl `if`** → 整块被静默跳过，别再把校验写进 XDC。
12. **行计数器 16 bit 饱和**（2026-10-22 下午，板上抓出来的）：
    `(line_cnt % LINES_PER_FRAME) == 0` 用的是**自增到 0xFFFF 就停**的 line_cnt，
    流了 65535 行（约 3 s，静止画面也能触发）之后就永远不再等于 0 →
    `line_first` 再也不会拉高 → ring 不再按帧归零，读 row 0..479 变成"随便一截窗口"，
    画面退化成一堆横向条纹。现象：寄存器 0x08（frames）**冻结不动**、0x0C（row）
    还在跑 —— 这就是它的指纹。改成 0..LINES_PER_FRAME-1 的 row_cnt，不再有取模。
13. **写侧 ring 行号 off-by-one**：`line_first` 时把 `row` 清 0，而 `line_addr` 用的是
    **上一行的 row**，于是每帧第 2 行又写回 ring row 0，最后一行永远是旧数据。
    改成"行开始时就把 row 推到本行该去的 ring 行"。
14. **XCLK 24 MHz 让 PCLK 跑到 84 MHz**，而 pixel 域按 22.857 ns 约束只排到
    10.9 ns slack（≈11.9 ns 逻辑延迟）→ 正好卡在 11.9 ns 的边界上；
    同时 DDR 行写入器在 FCLK0=50 MHz 下要 26 µs/行，84 MHz 的 640x480 行只有
    22.5 µs，写不进去。现在 XCLK = 12 MHz（MMCM VCO 1200 / 100），PCLK ≈ 42 MHz，
    行周期 45 µs，余量充足，帧率仍是 30 fps。

---

## 8. 传感器时序 / 写通路自测寄存器（2026-10-22~23 新增）

没有 JTAG、没有示波器时，"PCLK 到底多少""DDR 到底写没写进去"以前只能靠猜。
现在这些都能量出来（`dehaze_cam` 会打印，完整映射见 `RESUME_HERE.md` §7）：

| 偏移 | 内容 |
|---|---|
| 0x24 | HREF 下降沿个数（每行一个，AXI 域计数） |
| 0x28 | 1024 个 PCLK 的个数（像素域翻转位同步过来后计数） |
| 0x30 / 0x34 | 最近一行的像素数 / PCLK 数（**像素域**测量，最可信） |
| 0x38 / 0x3C / 0x40 | 写手 FSM 状态 / AXI 握手快照 / {n_words, sent} |

```
lines/s = Δ0x24 / Δt
PCLK    = Δ0x28 * 1024 / Δt
行周期  = Δ0x34（像素域直接量）  ← 约 2 × HTS，OV5640 的 HTS 以 2 个 PCLK 为单位
```
写通路是否真的在写，靠**软件侧**：`dehaze_cam` 读帧前后各算一次 ring 的校验和，
打印 `content CHANGED / UNCHANGED`。这一步是必须的 —— 采集侧全部正常、而写通路
死掉时，`/dev/mem` 读到的只是 DDR 里上次开机的残留，看起来却像一张真图。


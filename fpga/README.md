# 纯 PL 暗通道去雾（MZ7X / Zynq-7020）

不用 DPU、不用摄像头、不用 PetaLinux、不用网络 —— 一块 Z7020 的 PL 里跑完整条
暗通道先验去雾流水线，PS 侧只做"把图灌进 DDR、等它算完、把结果读回来"。

这是 `../dehaze.py`（Python 浮点参考）的硬件版本，定点实现与浮点参考在
1025×720 测试图上 **PSNR 49.13 dB**、大气光 A **逐位相同**。

> 之所以选"纯 PL 顶替 YOLO"，是因为原 YOLO 工程里 DPU 已经吃掉了 Z7020 的
> Slice 98.17% / DSP 96.36% / BRAM 88.21%，**没有余量再塞一条图像流水线**。
> 拿掉 DPU 之后资源立刻宽裕（本设计只用了 LUT 13.6%、BRAM 15%、DSP 7.7%）。

---

## 1. 目录结构

```
fpga/
├── 00_tools/
│   ├── make_testvector.py    fog.jpg -> 1025x720 RGB888 字流 + Python 参考结果
│   ├── gen_lut.py            生成 1/t 倒数表头文件（HLS 当 ROM 用）
│   └── make_report.py        三联对比图 + PSNR
├── 01_hls/
│   ├── src/dehaze_top.cpp    ★ 定点硬件实现
│   ├── src/dehaze_top.h
│   ├── src/invt_lut.h        自动生成
│   ├── tb/dehaze_tb.cpp      C testbench（对比 Python 参考）
│   ├── tv/                   测试向量（生成物，可删）
│   ├── build.tcl             HLS 工程（csim / csynth / export）
│   ├── run.ps1               PowerShell 包装
│   └── proj_dehaze/          HLS 工作目录（生成物）
├── 02_vivado/
│   ├── extract_ps7.py        从参考工程只读抽取 PS7 配置
│   ├── ps7_props.tcl         自动生成：DDR3 / MIO / FCLK
│   ├── create_bd.tcl         ★ Block Design
│   ├── build.tcl             工程 + 综合 + 实现 + 比特流 + .hdf
│   └── output/               bit / hdf / 报告（生成物）
├── 03_baremetal/          【路线 B：JTAG】裸机
│   ├── src/main.c
│   ├── build_bsp.tcl         xsct：建 BSP + 编 ELF
│   └── run_jtag.tcl          xsct：下载 bit/ELF/图片 -> 跑 -> 回读
├── 03_linux/              【路线 A：无 JTAG，推荐】Linux 用户态
│   ├── src/dehaze_linux.c    mmap /dev/mem 直接打寄存器
│   ├── build.ps1             交叉编译
│   └── run_on_board.sh       板端：fpga_manager 加载 + 设 FCLK0 + 跑
└── output/                   对比图（生成物）
```

---

## 2.5 两条上板路线（JTAG 坏了也能跑）

板子本身是 **SD 卡启动 + U-Boot + Linux**，而且 `fpga_manager` 是可用的
（原 YOLO 工程里就是 `echo dpu.bin > /sys/class/fpga_manager/fpga0/firmware`）。
所以 **JTAG 不是必需的**。

| | 路线 A：Linux + fpga_manager | 路线 B：JTAG 裸机 |
|---|---|---|
| 需要 JTAG | **不需要** | 需要 |
| 需要 Linux | 需要（现成的 PetaLinux 镜像） | 不需要 |
| 需要重建 BOOT.BIN | **不需要** | 不需要 |
| 比特流加载 | `echo dehaze_top.bin > /sys/class/fpga_manager/fpga0/firmware` | `fpga -file *.bit` |
| 程序形态 | `03_linux/dehaze_linux`（8.7 KB） | `03_baremetal/.../dehaze_app.elf` |
| 数据进出 | 板端文件系统（wget / SD） | JTAG `dow` / `mrd` |
| 现状 | **推荐，代码已就绪** | 下载器有故障，暂不可用 |

路线 A 完全复用了你已验证过的那套东西（SD 启动、U-Boot、HTTP wget、fpga_manager、
交叉编译链），新增成本只有"把裸机 main.c 改成 mmap 版本"。

---

## 2. 环境

| 项 | 值 |
|---|---|
| 板卡 | 米兰科 MZ7X，XC7Z020-2CLG400（1 GiB DDR3，MT41K256M16 RE-125） |
| Vivado / Vivado HLS | 2019.1，`D:\vivado2019.1\VIVADO20191` |
| XSCT | `D:\vivado2019.1\VIVADO20191\SDK\2019.1\bin\xsct.bat` |
| 裸机编译器 | `...\SDK\2019.1\gnu\aarch32\nt\gcc-arm-none-eabi` |
| PL 时钟 | FCLK0 = 50 MHz（IO PLL 1000 ÷ 5 ÷ 4） |
| 串口 | UART1，MIO48/49，115200 |

PS7 的 DDR 颗粒、MIO 分配、分频全部来自 `02_vivado/ps7_props.tcl`，
后者由 `extract_ps7.py` 从已在板上跑通的 `一份已在板上跑通的参考工程 BD 脚本`
**只读抽取**（不修改、不复制该工程的其它文件）。DDR 时序参数手抄必错，不要手改。

---

## 3. 快速开始

```powershell
# 0) 生成测试向量（把 fog.jpg 变成 1025x720 RGB888 字流 + Python 参考）
cd D:\dehaze\fpga\00_tools
python make_testvector.py

# 1) HLS：C 仿真（对比 Python）+ 综合 + 导出 IP
cd ..\01_hls
$env:VHLS_STAGE='all'
& cmd /c '"D:\vivado2019.1\VIVADO20191\Vivado\2019.1\bin\vivado_hls.bat" -f build.tcl'

#    ⚠ 2019.1 已知缺陷：IP 打包用的 revision 是 YYMMDDHHMM 时间戳，
#      2022 年以后必然溢出 int32，导致 export_design 报
#      "bad lexical cast ... core_revision"。修补办法见 §7.1。

# 2) Vivado：BD + 综合 + 实现 + 比特流 + .hdf
cd ..\02_vivado
$env:VIVADO_STAGE='hdf'
& cmd /c '"D:\vivado2019.1\VIVADO20191\Vivado\2019.1\bin\vivado.bat" -mode batch -source build.tcl'

# 3a) 【路线 A，无 JTAG】交叉编译 Linux 用户态程序
cd ..\03_linux
powershell -ExecutionPolicy Bypass -File build.ps1
#    -> 03_linux/dehaze_linux（8.7 KB，arm-linux-gnueabihf，glibc 2.28）
#    然后把 dehaze_top.bin / dehaze_linux / fog_in.bin 放到 PC 的 HTTP 目录，
#    板端执行 03_linux/run_on_board.sh（见 §2.5 与 §6.5）

# 3b) 【路线 B，需要 JTAG】裸机 BSP + ELF
cd ..\03_baremetal
& cmd /c '"D:\vivado2019.1\VIVADO20191\SDK\2019.1\bin\xsct.bat" build_bsp.tcl'
& cmd /c '"D:\vivado2019.1\VIVADO20191\SDK\2019.1\bin\xsct.bat" run_jtag.tcl'

# 4) 出对比图（两条路线产出的文件名一致）
cd ..\00_tools
python make_report.py --board
```

---

## 4. 已验证的结果（PC 侧，尚未上板）

| 指标 | 值 | 说明 |
|---|---|---|
| 定点 vs 浮点 PSNR | **49.13 dB** | 最大单像素偏差 5 |
| 大气光 A | **217,215,214** | 与 Python 逐位一致 |
| LUT | 7,244 / 53,200 | 13.6% |
| FF | 4,822 / 106,400 | 4.5% |
| BRAM | 42 × 18K（21 tiles）/ 140 | 15% |
| DSP | 17 / 220 | 7.7% |
| 时序估计 | 17.5 ns @ 20 ns 约束 | ≈ 57 MHz，50 MHz 有余量 |
| 单帧延迟 | ~3.8 M cycles ≈ **77 ms** | ≈ 13 fps @ 50 MHz |
| 吞吐瓶颈 | 第 1 遍直方图循环 II=2 | 其余热循环均 II=1 |

Vivado 实现后（whole design，含 PS7 与互联）：

| 指标 | 值 |
|---|---|
| Slice | 2,328 / 13,300 = **17.5%**（原 YOLO 工程是 98.17%） |
| Slice LUTs | 6,540 / 53,200 = 12.3% |
| Slice Registers | 5,785 / 106,400 = 5.4% |
| Block RAM | 20 / 140 = 14.3% |
| DSP48E1 | 16 / 220 = 7.3% |
| WNS @ 50 MHz | **+3.957 ns**（等效 ~62 MHz） |
| 比特流 | `02_vivado/output/system_wrapper.bit`（3.95 MB） |
| 裸机 ELF | `03_baremetal/ws/dehaze_app/Debug/dehaze_app.elf`（312 KB） |

**已验证**：
- HLS C 仿真、综合、实现、时序收敛、比特流生成、.hdf 导出、裸机 ELF 编译
- **Linux + fpga_manager 上板实跑（2026-10-20 21:42，MZ7X，QSPI 启动 → SD rootfs）**

### 4.1 上板实测结果

| 项 | 板端实测 | PC 端 C 仿真 | 结论 |
|---|---|---|---|
| 大气光 A (B,G,R) | **217,215,214** | 217,215,214 | 逐位一致 |
| 输出稀疏校验和 | **0x7D194413** | 0x7D194413 | **逐位一致** |
| 与 Python 浮点参考 PSNR | **49.13 dB** | 49.13 dB | 完全相同 |
| **与 PC 端 C 仿真逐字节对比** | **完全相同（max diff = 0）** | — | **位流无差异** |
| 最大单像素偏差 | 5 | 5 | 完全相同 |
| 单帧延迟 | 593 ms | （HLS 估计 77 ms） | 见下方分析 |

位流加载的判定用了 **`devmem 0x43C00000` → `0x00000004`**（ap_idle=1），
而不是 `/sys/class/fpga_manager/fpga0/state` —— 后者在 QSPI 启动的板子上
**恒为 `operating`（假阳性）**，因为 FSBL 已经把 DPU 位流写进 PL 了。

完整串口日志：`board_run_20261020_214206.log`。

### 4.2 实测延迟 593 ms 与估计 77 ms 的差距（8×）

功能正确、时序收敛，但比 HLS 估计慢 8 倍。两个候选原因，尚未区分：

1. **AXI 突发效率**。有效带宽只有 ~25 MB/s（3 遍扫描共 14.8 MB），而 50 MHz × 32 bit
   理论上限是 200 MB/s。横向循环里的**边界钳位索引**（`cx = clamp(j-7)`）让 HLS
   无法证明地址连续，很可能退化成了单拍传输（~8 周期/拍）。
   → 修法：把左右边界拆到循环外，中间段用连续索引；或把 `m_axi` 加宽到 64 bit。
2. **FCLK0 实际频率**。3.83 M 周期 / 593 ms ≈ 6.5 MHz，恰好接近 50 MHz 的 1/8。
   虽然回读 `0xF8000170 = 0x00201400` 与预期一致，但值得用一次
   「降到 25 MHz 看时间是否翻倍」的对照实验确认。

两者都会随像素数线性缩放，所以要用"减少一次 src 读取"这类实验来区分。
**这不影响交付，是 v1 的性能优化项。**

### 4.3 v1（引导滤波）结果

`mode` 寄存器选择是否对透射率做引导滤波细化，两条路径共用同一个比特流。

**板端实测（2026-10-21 08:57，MZ7X，QSPI 启动 → SD rootfs）**

| 项 | mode 0 | mode 1 |
|---|---|---|
| 大气光 A (B,G,R) | **217,215,214** | **217,215,214** |
| 稀疏校验和（板端打印） | **`0x7D194413`** | **`0xECB8A61A`** |
| 与参考值比对 | 一致 | 一致 |
| 与 PC 端 C 仿真逐字节对比 | **max diff = 0** | **max diff = 0** |
| 与 Python 浮点参考 PSNR | **49.13 dB** | **49.07 dB** |
| 单帧延迟 | **845 ms** | **1397 ms** |

**资源与时序（整个设计）**

| 指标 | v0 | v1 |
|---|---|---|
| Slice | 2,328 (17.5%) | 4,242 (31.9%) |
| Slice LUTs | 6,540 (12.3%) | 12,629 (23.7%) |
| Block RAM | 20 (14.3%) | 73.5 (52.5%) |
| WNS @ 50 MHz | +3.957 ns | **+3.555 ns** |

代价与收益：

- 资源大约翻倍，但 Z7020 仍有充足余量（Slice 32%、BRAM 53%）；
- **mode 0 本身也从 593 ms 变慢到 845 ms（+42%）** —— 因为 `src` 和 `scratch`
  共用 `gmem0` 这一条 AXI 主口，新增端口让原路径的突发效率下降。
  这是 v2 要解决的第一个问题（把 scratch 拆到独立主口 / HP2）；
- mode 1 在 mode 0 之上再加 552 ms（写 t 图 + 读写 (a,b) 图，两趟额外 DDR 扫描）。

中间结果可逐级验证，工具在 `00_tools/`：

```powershell
python debug_maps.py              # 对比 t / a / b 三级映射（需要 csim 的 dump）
python check_stageb.py            # 用硬件自己的 abmap 在 Python 里复算
python compare_modes.py --board   # 四联图 + 双模式 PSNR（板端 bin / csim u8 都支持）
```

### 4.4 v2：性能（scratch 独立主口 + 边界拆出热循环）

**改动**

| # | 改动 | 原因 |
|---|---|---|
| 1 | `scratch` 从 `gmem0` 拆到独立 `gmem2` → PS7 `S_AXI_HP2` | v1 里它和 `src` 共用一条主口，多一个地址寄存器就吃掉了 42% 带宽 |
| 2 | 两处 15 抽头横向最小值的**边界钳位拆成三个循环**（左 7 / 中间 W / 右 7） | 中间段 `src[base+x]` 变成严格连续地址，HLS 才能推断突发 |

**板端实测**（2026-10-21 13:27，断电重启后的干净环境）

| | v1 | v2 @ div 20 | v2 @ div 8 | **v3 @ div 6（当前默认）** |
|---|---|---|---|---|
| mode 0 | 845 ms | 423 ms | 226.7 ms | **199.3 ms** |
| mode 1 | 1397 ms | 692 ms | 362.3 ms | **299.2 ms** |
| 校验和 | 正确 | 正确 | 正确 | **正确**（`0x7D194413` / `0xECB8A61A`） |
| PSNR vs Python | 49.13 / 49.07 dB | — | — | **49.13 / 49.07 dB** |
| 板端 vs C 仿真 | 逐字节相同 | — | — | **逐字节相同** |

相对 v1 总共 **4.2× / 4.7×**；最慢的 mode 1 也比最初的 v0 mode 0（593 ms）快 2 倍。

### 4.4.1 v3：两个被证否的假设（负面结果，但很重要）

v3 做了两处改动想把 ~124 ms 的"地板"压下去，**结果完全无效**：

| 改动 | 预期 | 实测 |
|---|---|---|
| 消除 pass 1 里第二次 `src` 读（加一行 `R+G+B` 缓冲） | 少 2.95 MB/帧 | **226.7 → 226.4 ms（无变化）** |
| 消除 pass 2c 里同一地址的重复读 | 少 2.95 MB/帧 | 同上 |
| 把 `ap_done` 轮询改成每 100 µs 一次 | 减少 AXI-Lite 争用 | **226.4 → 226.5 ms（无变化）** |

结论：

1. **不是带宽受限** —— 减少 21% 的 DDR 流量完全没有收益；
2. **不是 CPU 轮询争用** —— 轮询频率降到原来的几百分之一也没用。

而时钟扫描显示明显的地板：`t ≈ 12.8 × divisor + 124 ms`，在 div 6 时那 124 ms 已经占了 62%。

**下一步必须先装一个核内周期计数器**（RTL 改动 + 一个可读寄存器），才能知道这 124 ms 到底花在
哪一趟、是 ALU 空转还是 AXI 停顿。在此之前继续盲改没有意义。

> 另一个发现：v3 的 div 4 会出错（v2 时还能跑），因为 WNS 从 2.703 收紧到 2.683。
> 这正好印证了"div 4 本来就在时序边缘"，所以默认值定在 div 6（33% 余量）。

**⚠ 一个必须记住的硬件坑：HP2 也要设 AFI 宽度**

启用 HP2 后，若只写了 HP0/HP1 的 32 位使能，HP2 仍停在 64 位，
而 PL 主口是 32 位 —— 结果是 **mode 0 完全正确、mode 1 悄悄错**（校验和从
`0xECB8A61A` 变成 `0xDCEBCE1A`）。诊断入口是 `ps7_init.c` 里的 `AFI2 REGISTERS` 段：

```
0xF800A000[0] = 1     # AFI2 = S_AXI_HP2, n32BitEn
0xF800A014[0] = 1
```

### 4.5 ⭐ FCLK0 的真相：0x00201400 不是 50 MHz

YOLO 工程里 `devmem 0xF8000170 32 0x00201400` 被注释成"IO_PLL 1000 MHz ÷ 20
= 精确 50.000 MHz"。**在这个板上它不是 50 MHz。** 用 `probe_clock.ps1` 扫不同分频
（只改 SLCR、不动比特流）得到：

| 分频 | 耗时（mode 0） | 输出 |
|---|---|---|
| 20（`0x00201400`） | 423.2 ms | ✅ |
| 10 | 261.9 ms | ✅ |
| 8 | 226.7 ms | ✅ |
| 5 | 187.3 ms | ✅（但另一次运行挂死 → 处在时序边缘） |
| **4** | **171.6 ms** | ✅ |
| **3** | 158.6 ms | ❌ 校验和错 |

div 4 能跑、div 3 不能，与 Vivado 报的 **Fmax ≈ 57.8 MHz** 完全吻合。
反推 baseline：**`0x00201400` 实际只有 ~12–14 MHz**，比标称的 50 MHz 低了约 4 倍。

也就是说此前所有"比 HLS 估计慢 8 倍"的分析里，**有一半是时钟设低了**，不是设计慢。

拟合出的耗时模型：`t ≈ 13.8 × divisor + 110 ms`，其中
- `13.8 × divisor` 是 PL 的周期开销（随时钟线性缩放）；
- **~110 ms 是时钟无关的固定开销**（AXI 事务延迟 × 事务数 / outstanding）。
  这是下一步要打的：现在它已经占了一帧的 65%。

**结论**：`board_run.ps1` 默认改用 **divisor 8**（约 30–35 MHz，比 div 4 留 ~40% 时序余量）。
div 5 曾经一次成功、一次挂死，**不要用**。

---

## 5. 算法与硬件映射

### 5.1 两遍扫描

```
第 1 遍  src ──> 15x15 最小值(可分离) ──> 256 bin 直方图 ──> 阈值 T ──> A
第 2 遍  src ──> min_c(I_c/A_c) ──> 15x15 最小值 ──> t ──> J=(I-A)/max(t,t0)+A ──> *gain ──> dst
```

- **大气光 A 用直方图法**，不用全排序：每个 bin 记 `max(R+G+B)` 和对应像素下标，
  从 255 往下累加到 0.1% 得到阈值 T，再在 `v>=T` 的 bin 里取最大者。
  一遍出结果，不需要第二趟遍历，也不需要比较器阵列。
- **最小值滤波可分离**：先横向 15 抽头、再纵向 15 抽头，O(1)/像素。
- **行缓冲**：16 行 × 1025 × 16 bit，按行完全分区（`ARRAY_PARTITION ... dim=1`），
  每像素 15 个并行读口；16 是为了用 `& 15` 做掩码，避开 15 取模。

### 5.2 定点约定

| 量 | 格式 | 说明 |
|---|---|---|
| I, A | 8 bit 整数 0..255 | 图像原值 |
| I/A, dark, t | Q8（值×256） | |
| ω, gain | Q8 | 0.95→243，1.05→269 |
| 1/A | Q16，每帧算一次 | 3 个除法，一次性开销 |
| 1/t | **257 项 ROM**（`invt_lut.h`） | t 只取 0..256 的整数值，表查比除法便宜 |

复原的核心一步是

```
J = (I - A) * (65536 / t_q8) >> 8 + A
```

注意是 `>> 8` 而不是 `>> 16` —— `t_q8` 本身已经是 Q8，这一位算错会得到
"所有像素都被拉向大气光"的结果（PSNR 3 dB 级的典型症状，本项目踩过）。

### 5.3 接口

| 端口 | 类型 | 用途 |
|---|---|---|
| `s_axi_ctrl` | AXI4-Lite | 参数：src/dst 基地址、宽高、ω、t0、gain、mode |
| `m_axi_gmem0` | AXI4 Master | 读 src |
| `m_axi_gmem1` | AXI4 Master | 写 dst |
| `ap_clk` / `ap_rst_n` | — | 50 MHz |

返回值 = 打包的 A 字（`R<<16 | G<<8 | B`），板端打印出来便于和 PC 对照。

---

## 6. Block Design

```
PS7 M_AXI_GP0 --[smartconnect, 2 个从口]--> dehaze_top/s_axi_ctrl   @ 0x43C00000
                                        \-> cam_top/s_axi          @ 0x43C10000
dehaze_top/m_axi_gmem0 --[axi_protocol_converter AXI4->AXI3]--> PS7 S_AXI_HP0  (读 src)
dehaze_top/m_axi_gmem1 --[axi_protocol_converter AXI4->AXI3]--> PS7 S_AXI_HP1  (写 dst)
dehaze_top/m_axi_gmem2 --[axi_protocol_converter AXI4->AXI3]--> PS7 S_AXI_HP2  (scratch)
cam_top/m_axi          --[axi_protocol_converter AXI4->AXI3]--> PS7 S_AXI_HP3  (摄像头 ring)
cam_top/aclk <- FCLK_CLK0      cam_top/cam_pclk <- 外部 PCLK（独立时钟域）
```

- 单时钟域，全部 50 MHz（`cam_pclk` 例外，它是传感器的像素时钟，异步）。
- **协议转换器是必需的**：Vivado HLS / 我们的 RTL 都只生成 AXI4 主口，而 Zynq-7000 的 HP 口只有 AXI3。
- **四个 HP 口数据宽度都必须改成 32**（`PCW_S_AXI_HP0..3_DATA_WIDTH 32`），否则和 32 位主口对不上。
- `cam_top` 的 AXI4-Lite 从口是摄像头唯一的观测窗口（本板没有 JTAG），详见 `04_camera/README.md` §6。

内存布局：

| 地址 | 裸机 (03_baremetal) | Linux (03_linux) | 用途 | 大小 |
|---|---|---|---|---|
| `0x0800_0000` | — | src | 输入图（32 bit/像素） | 2 MB |
| `0x0C00_0000` | — | dst | 输出图 | 2 MB |
| `0x1000_0000` | src | scratch | mode 1 工作区（裸机为输入图） | 2.95 MB |
| `0x1200_0000` | dst | — | 输出图（裸机） | 2.95 MB |
| `0x1300_0000` | 结果块 | — | magic / A / cycles / checksum | 64 B |
| `0x2000_0000` | — | 摄像头 ring | 1024 行 × 2048 字 | 8 MB |

> Linux 路线把缓冲区放在 0x0800_0000 起，是因为内核对内存的 `mem=120M` 只覆盖低 120 MB，
> 用 `0x0800_0000`（128 MB）可以避开内核自用区域。原 YOLO 工程的摄像头缓冲正好也在
> `0x0800_0000`，证明 `/dev/mem` 在这个板子上能访问到那里。

---

## 6.4 摄像头通路（可选，纯 PL）

`04_camera/` 里是一套完整的 OV5640 采集子系统，接到上面的 block design 里就是
“摄像头 → dehaze → 文件”的完整演示。细节见 `04_camera/README.md`，这里只列要点：

- **数据流**：OV5640 DVP → 字节配对成 32bit 字 → 双时钟行缓冲（pclk 写 / aclk 读）
  → AXI4 突发写 DDR ring @ `0x2000_0000` → `dehaze_cam` 读 ring 转 BGR888 → dehaze 核。
- **不用 VDMA**：YOLO 工程已经证明这个 AXIS 喂不进 VDMA；这里自己发突发。
- **时钟**：XCLK = FCLK0/4 = 12.5 MHz，传感器 PCLK ≈ 43.75 MHz。
  所以**摄像头版本必须让 FCLK0 = 50 MHz**（`0xF8000170 = 0x00200500`，也是 ps7_init 默认值），
  不要再用 §4.5 里那个 div 6 的写法。`dehaze_cam` 会把实测 FCLK0 打出来。
- **配置表**：寄存器数值取自 `一份厂商 5640_sccb_hdmi 采集+显示例程`（米联客例程），
  但只取了 (reg, value) 数值；SCCB/采集/写 DDR 的 RTL 全部重写，正本表在
  `04_camera/tools/ov5640_640x480_rgb565.reg`，改分辨率只改一行 `RESOLUTION`。
- **分辨率**：640×480 RGB565，和 dehaze 的输入尺寸一致。

---

## 6.5 无 JTAG 上板步骤（路线 A）

**PC 侧**

```powershell
# 1. 确认三个产物都在
#    02_vivado/output/dehaze_top.bin   4,045,568 B  (bootgen 生成，供 fpga_manager)
#    03_linux/dehaze_linux             8,760 B
#    01_hls/tv/fog_in.bin              2,952,000 B

# 2. 起一个 HTTP 服务，把这三个文件放到它能看到的目录
cd D:\dehaze\fpga\02_vivado\output      # 或者拷贝到一个统一的 pub 目录
python -m http.server 8000
```

**板端**（串口 `COM10 @115200`，`init=/bin/sh` 即可）

```sh
cd /home/root
wget -O dehaze_top.bin http://192.168.1.100:8000/dehaze_top.bin
wget -O dehaze_linux   http://192.168.1.100:8000/dehaze_linux
wget -O fog_in.bin     http://192.168.1.100:8000/fog_in.bin
chmod +x dehaze_linux

# 加载比特流（和 YOLO 工程里加载 dpu.bin 是同一招）
cp dehaze_top.bin /lib/firmware/dehaze_top.bin
echo dehaze_top.bin > /sys/class/fpga_manager/fpga0/firmware
cat /sys/class/fpga_manager/fpga0/state      # 期望 "operating"

# ⚠ 必须确认 FCLK0 = 50 MHz
#    比特流只配置 PL，不改 PS 时钟；FCLK0 是开机时 FSBL 设的。
#    我们的设计只能跑到 ~62 MHz，如果 FCLK0 是 200 MHz 会时序违例、输出乱码。
devmem 0xF8000170 32 0x00201400      # IO_PLL/20 = 50.000 MHz
devmem 0xF8000170                     # 回读确认

# 每个 mode 都跑一遍（v1 的 mode 1 需要一段 scratch 区，程序已内置）
./dehaze_linux fog_in.bin hw_out_mode0.bin 0
./dehaze_linux fog_in.bin hw_out_mode1.bin 1
# 期望输出：
#   mode 0: A (B,G,R) = 217,215,214   latency = xxx ms   checksum = 0x7d194413
#   mode 1: A (B,G,R) = 217,215,214   latency = xxx ms   checksum = 0xecb8a61a
# 校验和与上面 4.3 表里的参考值一致，就说明比特流逐位正确。
```

**取回结果**

板端没有网络服务的话，用 `cat`/串口太慢（3 MB）。两个办法：

1. 板端起个简易 HTTP：`busybox httpd -p 80 -h /home/root`，PC 上 `wget http://<board>/hw_out_board.bin`；
2. 或直接把 `/home/root/hw_out_board.bin` 拷到 SD 卡的 FAT 分区，拔卡在 PC 上读。

拿到文件后：

```powershell
cd D:\dehaze\fpga\00_tools
Copy-Item <取回的路径>\hw_out_mode0.bin ..\01_hls\tv\ -Force
Copy-Item <取回的路径>\hw_out_mode1.bin ..\01_hls\tv\ -Force
python compare_modes.py --board
# -> output/hw_compare_mode1.png（四联：原图 | mode0 | mode1 | Python 参考）
# -> 打印两个 mode 的 PSNR
```

**判据**：
- 两个 mode 的 A 都必须是 `217,215,214`
- 校验和：mode 0 = `0x7D194413`，mode 1 = `0xECB8A61A`
- PSNR 应 ≥ 45 dB（PC 端 C 仿真分别是 49.13 / 49.07 dB）
- 板上 A 对、校验和对 → 比特流逐位正确，可以继续看画面了

---

## 7. 踩坑记录

### 7.1 HLS 2019.1 导出 IP 失败（`core_revision` 溢出）
现象：`export_design` 报 `bad lexical cast: source type value could not be interpreted as target`，
日志里是 `rdi::set_property core_revision 2610201935`。

原因：HLS 用 `YYMMDDHHMM` 生成 revision，2022 年起就是 2.2e9 以上，超过 int32。

修补：`proj_dehaze/sol1/impl/ip/run_ippack.tcl` 里把 `set Revision "<时间戳>"` 改成一个小整数，
然后在该目录手动重跑一次打包：

```powershell
cd 01_hls\proj_dehaze\sol1\impl\ip
(Get-Content run_ippack.tcl -Raw) -replace 'set Revision    "\d+"', 'set Revision    "1"' | Set-Content run_ippack.tcl -Encoding ASCII
& cmd /c '"D:\vivado2019.1\VIVADO20191\Vivado\2019.1\bin\vivado.bat" -mode batch -source run_ippack.tcl -nojournal -log ipack.log'
# 成功的判据：本目录出现 component.xml
```

### 7.2 其它

| 现象 | 原因 | 处理 |
|---|---|---|
| `connect_bd_intf_net ... s_axi_control` 找不到 | HLS 的 bundle 名是 `ctrl`，端口叫 `s_axi_ctrl` | 用 `s_axi_ctrl` |
| AXI 协议不兼容 | HLS 出 AXI4，PS7 HP 是 AXI3 | 插 `axi_protocol_converter` |
| `DATA_WIDTH does not match (64 vs 32)` | HP 口默认 64 位 | `PCW_S_AXI_HP0_DATA_WIDTH 32` |
| `set_property` 改地址报 "does not conform" | `get_bd_addr_segs -of_objects <cell>` 会连主口映射段一起返回 | 用 `get_bd_addr_segs <cell>/s_axi_ctrl/Reg` 精确定位 |
| Tcl 报 `invalid command name "CONFIG..."` | PS7 配置块里有一行只有反斜杠的续行，追加内容会破坏续行 | 覆盖项用第二个 `set_property` 单独下发 |
| Tcl 脚本第一行报奇怪错误 | PowerShell `Set-Content -Encoding UTF8` 加了 BOM | 用无 BOM 的 UTF-8 写 |
| `.ps1` 无法运行 | 执行策略 | `powershell -ExecutionPolicy Bypass -File xxx.ps1` |
| `xsct` 报 `ambiguous command name "app"` | 纯 xsct 只有 `createapp`，`app create` 是 xsdk 的形式 | 用 `createapp` |
| `xparameters_ps.h: No such file` | 不带 `-bsp` 时 `createapp` 会另建一个未生成的 `<app>_bsp`，其 `include/` 里只有 `xparameters.h` | `createapp -bsp dehaze_bsp ...`，并先 `projects -build -type bsp -name dehaze_bsp`（编译 BSP 才会填充 include/） |
| `invalid project name` | `projects` 即使带 `-type` 也必须带 `-name` | 逐个项目指定 |
| **HLS 驱动的函数带 `_V`** | 端口在 RTL 里叫 `src_V`，驱动因此生成 `XDehaze_top_Set_src_V()` | 照 BSP 里的 `xdehaze_top.h` 写，别照文档猜 |
| `max_write_burst_length should be same for one bundle` | `src` 和 `scratch` 共用 `gmem0`，但只有后者写了 burst 参数 | 同一 bundle 的所有端口必须用**完全相同**的 burst/outstanding 参数 |

### 7.3 v1（引导滤波）调试中踩的四个数值坑

这四个都是"代码能跑、结果全错"的类型，靠 `debug_maps.py` + `check_stageb.py`
逐级对比才定位出来。记下来供后续改算法时参考：

| # | 现象 | 根因 | 定位方法 |
|---|---|---|---|
| 1 | 全图错，PSNR 6 dB | 61 列滑动窗减错了端：应减最老的 `hw[60]`，写成了最新的 `hw[0]`，窗口和持续漂移 | 对比 a/b 映射的均值（hw 是期望的 2 倍） |
| 2 | a/b 映射对、输出仍错 | abmap **打包用 [21:10]，解包用 [11:0]**，字段错位 | `check_stageb.py`：用硬件自己的 abmap 在 Python 里复算，得到 44.7 dB → 说明映射对、stage B 错 |
| 3 | 输出偏亮、细节丢失 | `mA` 是「均值的 Q8」= a×65536，不是 a×256；`q8` 因此是 Q8，最后一步应 `>>16` 而我写成了 `>>8` | 手算单个像素的 t 与期望值对比 |
| 4 | 边界条带异常 | 61 行窗用「行号 clamp + 循环多跑 60 行预灌」来复刻 `BORDER_REPLICATE`，少跑就变成零填充 | 只看边界 30 像素的误差 |

**经验**：定点流水线一定要能**逐级 dump 中间结果**。这次如果没有 `t / a / b` 三个中间映射的对比，
仅凭最终 PSNR 是没法区分"传输率错"还是"引导滤波错"的。

---

## 8. 还没做的

| # | 项 | 说明 |
|---|---|---|
| 1 | **上板实测** | 路线 A（Linux）代码已就绪但未跑过。比 JTAG 路线简单得多：加载比特流、设 FCLK0、跑一个 8.7 KB 的程序 |
| 2 | **引导滤波细化（mode 1）** | 现在是无细化版本，边缘有块状伪影（见 `output/hw_compare_mode0.png`）。加 61 行行缓冲 + 两次盒式滤波，预估 +28~56 BRAM tiles、+3~5k LUT，Z7020 完全放得下 |
| 3 | 性能 | 第 1 遍直方图 II=2；第 2 遍 src 被读两次（可加一行缓冲省一次）。理论上可到 ~55 ms/帧 |
| 4 | 摄像头 | 接 OV5640 后可直接复用 `frame_writer` 的滚动写 DDR 思路，dehaze 插在写入前 |
| 5 | 4K / 更高帧率 | 现在 BRAM 只用了 15%，多像素/时钟还有很大空间 |

### 8.1 如果哪天想把"路线 A"变成真正的裸机（仍然不用 JTAG）

`03_linux` 是用户态 + Linux，严格说不算裸机。若确实需要裸机启动，还有一条
**SD 卡 BOOT.BIN** 的路，也完全不需要 JTAG：

```
FSBL(来自同一个 .hdf) + system_wrapper.bit + app.elf  --bootgen-->  BOOT.BIN
                                                     --写进 SD 卡 FAT 分区-->
板子启动模式拨到 SD --上电--> 裸机程序直接跑
```

代价：要在 SDK 里建 FSBL 工程、生成 BOOT.BIN、把启动模式拨码切到 SD；
而且没有 JTAG 之后，结果的回读只能靠 `xilffs` 写 SD 卡或者串口吐（3 MB @115200 约 4.5 分钟，
提高到 921600 约 35 秒）。相比之下路线 A 的成本低一个数量级，所以没有先做这条。

---

## 9. 与 Python 参考的对应关系

| `dehaze.py` | 硬件 |
|---|---|
| `dark_channel(img, 15)` | 第 1 遍：横向 15 + 纵向 15 最小值 |
| `atmospheric_light()`（全排序） | 第 1 遍：256 bin 直方图 + bin 内 argmax |
| `transmission_estimate(w=0.95)` | 第 2 遍：`t = 256 - (243*dark_q8)>>8` |
| `guided_filter(r=60)` | **未实现**（v1） |
| `recover(t0=0.1)` | 第 2 遍：查表倒数 + `>>8` |
| 结尾 `* 1.05` | `gain_q8 = 269` |

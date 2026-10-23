# -*- coding: utf-8 -*-
"""从一份已经在板上跑通的 Vivado 工程脚本里「只读」抽取 PS7(Processing System 7) 的配置块。

为什么要这么做：
    MZ7X 是第三方板，DDR3 颗粒(MT41K256M16 RE-125)、MIO 分配、FCLK 分频
    都是板级相关的。手抄容易错，而 DDR 时序参数抄错会导致裸机根本跑不起来。
    这里直接复用已在板上跑通的 PS7 配置，保证 DDR 训练/UART/MIO 与原来一致。

用法：
    python extract_ps7.py path/to/reference_bd.tcl
    （或设环境变量 REF_BD；参考工程不随本仓库分发）
输出：02_vivado/ps7_props.tcl
"""
import os
import re
import sys

SRC = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("REF_BD", "")
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "ps7_props.tcl")

# 我们显式补上的项（原工程靠 IP 默认值，这里写死以免不同 Vivado 版本默认值变化）
EXTRA = [
    'CONFIG.PCW_USE_M_AXI_GP0 {1}',
    # 本设计只用 HP0(读) / HP1(写)，其余两个关掉，避免未连接的 AXI 口
    'CONFIG.PCW_USE_S_AXI_HP2 {1}',
    'CONFIG.PCW_USE_S_AXI_HP3 {1}',
    # HLS 的 m_axi 是 32 bit，HP 口默认 64 bit，必须对齐
    'CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {32}',
    'CONFIG.PCW_S_AXI_HP1_DATA_WIDTH {32}',
    'CONFIG.PCW_S_AXI_HP2_DATA_WIDTH {32}',
    'CONFIG.PCW_S_AXI_HP3_DATA_WIDTH {32}',
]


def main():
    if not os.path.exists(SRC):
        sys.exit(f"source not found: {SRC}")

    with open(SRC, "r", encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines()

    try:
        i_ps7 = next(i for i, l in enumerate(lines)
                     if "create_bd_cell" in l and "processing_system7" in l)
    except StopIteration:
        sys.exit("processing_system7 create_bd_cell not found")

    try:
        i_start = next(i for i in range(i_ps7, len(lines))
                       if lines[i].lstrip().startswith("set_property -dict [")
                       and "list" in lines[i])
    except StopIteration:
        sys.exit("set_property -dict [list not found after PS7 creation")

    i_end = None
    for i in range(i_start, len(lines)):
        if re.search(r"\]\s*\$processing_system7_0\s*$", lines[i]):
            i_end = i
            break
    if i_end is None:
        sys.exit("end of PS7 property block not found")

    block = lines[i_start:i_end + 1]
    # 原样保留抽取到的 -dict 列表；覆盖项用第二个 set_property 单独下发，
    # 避免去改动原列表的续行结构（原文件里有一行只有反斜杠的续行）。
    overrides = " \\\n   ".join(EXTRA)
    block.append("")
    block.append("set_property -dict [list \\")
    block.append("   " + overrides + " \\")
    block.append("] $processing_system7_0")

    hdr = [
        "# ===========================================================================",
        "#  ps7_props.tcl -- PS7(Zynq-7000) 配置块",
        "#",
        "#  由 02_vivado/extract_ps7.py 从一份已在板上跑通的参考工程的 BD 脚本抽取（只读）。",
        "#  内容是 PS7 的属性取值（DDR3 时序、MIO、FCLK 分频）—— 都是从器件/板子手册来的",
        "#  事实，不是谁的源码；参考工程本身不随本仓库分发。",
        "#  请勿手改；要改请改抽取脚本后重新生成。",
        "#",
        "#  用法（在 Block Design 里，PS7 cell 已创建之后）：",
        "#      source ps7_props.tcl",
        "# ===========================================================================",
        "",
        "set processing_system7_0 [get_bd_cells processing_system7_0]",
        "",
    ]

    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(hdr) + "\n")
        f.write("\n".join(block) + "\n")

    # 摘要，方便核对
    keys = ("PCW_UIPARAM_DDR_PARTNO", "PCW_UIPARAM_DDR_MEMORY_TYPE",
            "PCW_DDR_RAM_HIGHADDR", "PCW_CLK0_FREQ", "PCW_USE_S_AXI_HP0",
            "PCW_UART1_UART1_IO")
    print(f"[ok] wrote {OUT}  ({len(block)} lines)")
    for k in keys:
        for b in block:
            if k in b:
                print("     " + b.strip().rstrip("\\").strip())


if __name__ == "__main__":
    main()

# -*- coding: utf-8 -*-
"""
破坏性实验:故意弄坏算法的每个环节,观察结果怎么崩
用法: python experiments.py images\fog.jpg
注意: 每做完一个实验弹一个窗口,关掉当前窗口才会做下一个
"""
import cv2
import numpy as np
import os
import sys
import matplotlib.pyplot as plt

plt.rcParams['font.sans-serif'] = ['Microsoft YaHei', 'SimHei', 'sans-serif']
plt.rcParams['axes.unicode_minus'] = False

# 复用 dehaze.py 里已经写好的五个函数
from dehaze import dark_channel, atmospheric_light, transmission_estimate, guided_filter, recover


def run_pipeline(I, img, patch=15, w=0.95, t0=0.1, r=60, use_guide=True):
    """带开关的完整流水线,实验用"""
    dark = dark_channel(I, patch)
    A = atmospheric_light(I, dark)
    t = transmission_estimate(I, A, patch, w)
    if use_guide:
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY).astype(np.float32) / 255.0
        t = np.clip(guided_filter(gray, t, r, 1e-4), 0, 1)
    J = recover(I, t, A, t0)
    return J, t, dark


def to_rgb(x):
    """float[0,1] -> uint8, matplotlib显示用"""
    u8 = (np.clip(x, 0, 1) * 255).astype(np.uint8)
    return u8 if x.ndim == 2 else cv2.cvtColor(u8, cv2.COLOR_BGR2RGB)


def plot_grid(items, title, save_path):
    """items: [(子标题, 图), ...] 自动拼网格"""
    n = len(items)
    cols = min(n, 4)
    rows = (n + cols - 1) // cols
    fig, axes = plt.subplots(rows, cols, figsize=(5.2 * cols, 4.2 * rows))
    for ax in np.atleast_1d(axes).ravel()[len(items):]:
        ax.axis('off')
    fig.suptitle(title, fontsize=15)
    for ax, (sub, im) in zip(np.atleast_1d(axes).ravel(), items):
        ax.imshow(to_rgb(im), cmap='gray' if im.ndim == 2 else None)
        ax.set_title(sub, fontsize=11)
        ax.axis('off')
    fig.tight_layout(rect=[0, 0, 1, 0.94])
    fig.savefig(save_path, dpi=130, bbox_inches='tight')
    plt.show()
    plt.close(fig)


def main(path):
    img = cv2.imread(path)
    if img is None:
        raise FileNotFoundError(f"读不到图片: {path}")
    I = img.astype(np.float32) / 255.0
    out = os.path.join("output", "experiments")
    os.makedirs(out, exist_ok=True)

    # ============ 实验1: 关掉引导滤波 ============
    J_no,  t_no,  _ = run_pipeline(I, img, use_guide=False)
    J_yes, t_yes, _ = run_pipeline(I, img, use_guide=True)
    plot_grid(
        [("粗透射率(方块感明显)", t_no), ("引导滤波细化后(平滑贴边)", t_yes),
         ("无细化的结果(边缘块状伪影)", J_no), ("细化后的结果(干净)", J_yes)],
        "实验1: 引导滤波到底干了什么",
        f"{out}/exp1_引导滤波.png")

    # ============ 实验2: 去雾力度 ω ============
    items = []
    for w in (0.6, 0.95, 1.0):
        J, _, _ = run_pipeline(I, img, w=w)
        items.append((f"ω={w}", J))
    plot_grid(items, "实验2: 去雾力度旋钮 ω",
              f"{out}/exp2_omega.png")

    # ============ 实验3: 窗口大小 patch ============
    items = []
    for p in (3, 15, 51):
        J, _, dark = run_pipeline(I, img, patch=p)
        items += [(f"patch={p} 暗通道", dark), (f"patch={p} 结果", J)]
    plot_grid(items, "实验3: 统计窗口大小的影响",
              f"{out}/exp3_patch.png")

    # ============ 实验4: 透射率下限 t0 ============
    items = []
    for t0 in (0.01, 0.1, 0.3):
        J, _, _ = run_pipeline(I, img, t0=t0)
        items.append((f"t₀={t0}", J))
    plot_grid(items, "实验4: 透射率下限 t₀ 的保护作用",
              f"{out}/exp4_t0.png")

    print(f"全部实验图已存到 {out}/ 文件夹")


if __name__ == "__main__":
    p = sys.argv[1] if len(sys.argv) > 1 else "images/fog.jpg"
    main(p)

# -*- coding: utf-8 -*-
"""
暗通道先验去雾 —— 单页对比展示版
论文: He Kaiming et al., "Single Image Haze Removal Using Dark Channel Prior", CVPR 2009
"""
import cv2
import numpy as np
import os
import matplotlib.pyplot as plt

# 中文显示配置(Windows自带微软雅黑;Mac用户改成 ['PingFang SC','Arial Unicode MS'])
plt.rcParams['font.sans-serif'] = ['Microsoft YaHei', 'SimHei', 'sans-serif']
plt.rcParams['axes.unicode_minus'] = False


# ---------- 1. 暗通道: 论文式(1) ----------
def dark_channel(img, patch=15):
    min_channel = np.min(img, axis=2)
    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (patch, patch))
    return cv2.erode(min_channel, kernel)


# ---------- 2. 大气光估计: 论文 Sec 4.4 ----------
def atmospheric_light(img, dark, top_ratio=0.001):
    h, w = img.shape[:2]
    n = max(int(h * w * top_ratio), 1)
    flat_idx = np.argsort(dark.ravel())[::-1][:n]
    candidates = img.reshape(-1, 3)[flat_idx]
    brightest = candidates[np.argmax(candidates.sum(axis=1))]
    return np.maximum(brightest, 0.01)


# ---------- 3. 粗透射率: 论文式(12) ----------
def transmission_estimate(img, A, patch=15, w=0.95):
    norm = img / A
    return 1.0 - w * dark_channel(norm, patch)


# ---------- 4. 引导滤波细化 ----------
def guided_filter(guide, src, r=60, eps=1e-4):
    mean_I  = cv2.boxFilter(guide, -1, (r, r))
    mean_p  = cv2.boxFilter(src,  -1, (r, r))
    mean_Ip = cv2.boxFilter(guide * src, -1, (r, r))
    cov_Ip  = mean_Ip - mean_I * mean_p
    mean_II = cv2.boxFilter(guide * guide, -1, (r, r))
    var_I   = mean_II - mean_I * mean_I
    a = cov_Ip / (var_I + eps)
    b = mean_p - a * mean_I
    return cv2.boxFilter(a, -1, (r, r)) * guide + cv2.boxFilter(b, -1, (r, r))


# ---------- 5. 复原: 论文式(16) ----------
def recover(img, t, A, t0=0.1):
    t = np.maximum(t, t0)[..., None]
    return np.clip((img - A) / t + A, 0, 1)


# ---------- 单页对比展示 ----------
def show_comparison(I, dark, t_ref, J, path, save_path):
    # matplotlib用RGB, OpenCV读的是BGR, 转一下; 灰度图转uint8
    I_rgb = cv2.cvtColor((np.clip(I, 0, 1) * 255).astype(np.uint8), cv2.COLOR_BGR2RGB)
    J_rgb = cv2.cvtColor((np.clip(J, 0, 1) * 255).astype(np.uint8), cv2.COLOR_BGR2RGB)
    dark_u8 = (dark * 255).astype(np.uint8)
    t_u8 = (t_ref * 255).astype(np.uint8)

    fig, axes = plt.subplots(2, 2, figsize=(13, 8))
    fig.suptitle(f'暗通道先验去雾全流程 — {os.path.basename(path)}', fontsize=15)

    axes[0, 0].imshow(I_rgb)
    axes[0, 0].set_title('① 原图(有雾)', fontsize=12)
    axes[0, 1].imshow(dark_u8, cmap='gray')
    axes[0, 1].set_title('② 暗通道图:越亮=雾越浓', fontsize=12)
    axes[1, 0].imshow(t_u8, cmap='gray')
    axes[1, 0].set_title('③ 透射率图:越暗=透射率越低(越远雾越厚)', fontsize=12)
    axes[1, 1].imshow(J_rgb)
    axes[1, 1].set_title('④ 去雾结果', fontsize=12)

    for ax in axes.flat:
        ax.axis('off')
    fig.tight_layout(rect=[0, 0, 1, 0.95])
    fig.savefig(save_path, dpi=150, bbox_inches='tight')   # 顺便存一份
    plt.show()


# ---------- 主流程 ----------
def dehaze(path, patch=15, w=0.95, t0=0.1, r=60, eps=1e-4, save_dir="output"):
    img = cv2.imread(path)
    if img is None:
        raise FileNotFoundError(f"读不到图片: {path}(检查路径是否含中文)")
    I = img.astype(np.float32) / 255.0

    dark  = dark_channel(I, patch)                          # 步骤1
    A     = atmospheric_light(I, dark)                      # 步骤2
    t     = transmission_estimate(I, A, patch, w)           # 步骤3
    gray  = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY).astype(np.float32) / 255.0
    t_ref = np.clip(guided_filter(gray, t, r, eps), t0, 1.0)# 步骤4
    J     = np.clip(recover(I, t_ref, A, t0) * 1.05, 0, 1)  # 步骤5

    os.makedirs(save_dir, exist_ok=True)
    base = os.path.splitext(os.path.basename(path))[0]
    cv2.imwrite(f"{save_dir}/{base}_dark.jpg", (dark * 255).astype(np.uint8))
    cv2.imwrite(f"{save_dir}/{base}_t.jpg", (t_ref * 255).astype(np.uint8))
    cv2.imwrite(f"{save_dir}/{base}_dehazed.jpg", (J * 255).astype(np.uint8))

    print(f"大气光A(BGR) = {A}")
    show_comparison(I, dark, t_ref, J, path, f"{save_dir}/{base}_compare.png")
    print(f"全部结果已存到 {save_dir}/ 文件夹")


if __name__ == "__main__":
    import sys
    p = sys.argv[1] if len(sys.argv) > 1 else "images/fog.jpg"
    dehaze(p)

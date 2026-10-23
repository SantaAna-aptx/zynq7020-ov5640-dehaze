# -*- coding: utf-8 -*-
"""
鐢熸垚 FPGA 娴嬭瘯鍚戦噺 + Python 鍙傝€冪粨鏋溿€?
杈撳嚭锛堝叏閮ㄥ啓鍒?01_hls/tv/ 涓嬶級:
  fog_in.bin        1025*720 涓?little-endian uint32锛屾瘡瀛?= (R<<16)|(G<<8)|B
                    鍐呭瓨閲屽瓧鑺傚簭姝ｅソ鏄?B,G,R,0 鈥斺€?鍜?OpenCV 鐨?BGR 涓€鑷?  fog_in.png        鍚屼竴寮犲浘鐨勯瑙堬紙RGB888锛?  fog_ref_mode0.npy 鍙傝€冪粨鏋?float32 [H,W,3]锛孊GR锛岃寖鍥?0..1
  fog_ref_mode0.png 鍙傝€冪粨鏋滈瑙?  meta.json         灏哄銆丄銆佸弬鏁?渚?tb 璇诲彇

Python 鍙傝€冪畻娉曚笌 dehaze.py 淇濇寔鍚屼竴濂楀叕寮?鍙湁涓€澶勫埢鎰忕殑宸埆:
  澶ф皵鍏?A 鐢?鐩存柟鍥炬硶"(涓?RTL 瀹炵幇涓€鑷?,鑰屼笉鏄?np.argsort 鍏ㄦ帓搴忋€?杩欐牱 PSNR 姣旇緝鏃?宸紓鍙潵鑷畾鐐瑰寲,鑰屼笉鏄潵鑷?A 鐨勫彇娉曚笉鍚屻€?
鐢ㄦ硶: python make_testvector.py [--w 1025] [--h 720] [--src ../../images/fog.jpg]
"""
import argparse
import json
import os

import cv2
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))          # D:\dehaze
TV_DIR = os.path.abspath(os.path.join(HERE, "..", "01_hls", "tv"))


# ---------- 绠楁硶(涓?dehaze.py 鍚屾簮) ----------
def dark_channel(img, patch=15):
    min_channel = np.min(img, axis=2)
    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (patch, patch))
    return cv2.erode(min_channel, kernel)


def atmospheric_light_hist(img, patch=15, top_ratio=0.001, acomp=0.35):
    """Atmospheric light from the dark-channel histogram -- must match the RTL.

    v1 used the RGB of the single pixel with the largest R+G+B inside the top
    0.1 % of the dark-channel histogram. One pixel is a bad estimator: it can
    land on a specular highlight with an arbitrary channel spread (measured on
    the board: A = 206,190,198), and J_c = (I_c - A_c)/t + A_c amplifies that
    16-level difference into a ~40-level channel shift once t drops to 0.3, so
    the blue channel gets crushed and the picture goes green.

    v2 accumulates the per-channel SUM inside each bin and uses the mean colour
    of the top band as A, then pulls A towards its own grey level by `acomp`
    (1.0 = keep the estimate, 0.0 = perfectly neutral).
    """
    dark = dark_channel(img, patch)
    h, w = img.shape[:2]
    n_top = max(int(h * w * top_ratio), 1)

    d8 = np.clip(np.round(dark * 255.0), 0, 255).astype(np.int32)
    flat_d = d8.ravel()

    # 8-bit 鍩熼噷绱姞锛屽拰 RTL 鐨勬暣鏁扮疮鍔犲櫒涓€涓€瀵瑰簲
    q = np.round(np.clip(img.reshape(-1, 3), 0.0, 1.0) * 255.0)
    bin_cnt = np.bincount(flat_d, minlength=256).astype(np.int64)
    bin_s = np.stack([np.bincount(flat_d, weights=q[:, c], minlength=256)
                      for c in range(3)], axis=1)

    acc = 0
    T = 255
    for b in range(255, -1, -1):
        cnt = int(bin_cnt[b])
        if cnt == 0:
            continue
        acc += cnt
        T = b
        if acc >= n_top:
            break

    sel_cnt = float(bin_cnt[T:].sum())
    if sel_cnt <= 0:
        A8 = np.array([128.0, 128.0, 128.0])
    else:
        A8 = bin_s[T:].sum(axis=0) / sel_cnt

    grey = float(A8.mean())
    A8 = grey + (A8 - grey) * acomp
    A8 = np.clip(A8, 1.0, 255.0)
    return A8 / 255.0, T, n_top


def transmission(img, A, patch=15, w=0.95):
    return 1.0 - w * dark_channel(img / A, patch)


def recover(img, t, A, t0=0.1):
    t = np.maximum(t, t0)[..., None]
    return np.clip((img - A) / t + A, 0, 1)


def guided_filter(guide, src, r=30, eps=1e-4):
    """He's guided filter, radius r -> (2r+1)x(2r+1) box windows.

    NOTE: dehaze.py used boxFilter ksize=(60,60), i.e. an even window. The
    hardware uses a centred 61x61 window, so the reference is regenerated with
    the odd window to keep the HW/float comparison meaningful. The visual
    difference between the two is negligible.
    """
    k = 2 * r + 1
    mean_I  = cv2.boxFilter(guide, -1, (k, k), borderType=cv2.BORDER_REPLICATE)
    mean_p  = cv2.boxFilter(src,   -1, (k, k), borderType=cv2.BORDER_REPLICATE)
    corr_I  = cv2.boxFilter(guide * guide, -1, (k, k), borderType=cv2.BORDER_REPLICATE)
    corr_Ip = cv2.boxFilter(guide * src,   -1, (k, k), borderType=cv2.BORDER_REPLICATE)

    var_I  = corr_I - mean_I * mean_I
    cov_Ip = corr_Ip - mean_I * mean_p

    a = cov_Ip / (var_I + eps)
    b = mean_p - a * mean_I

    mean_a = cv2.boxFilter(a, -1, (k, k), borderType=cv2.BORDER_REPLICATE)
    mean_b = cv2.boxFilter(b, -1, (k, k), borderType=cv2.BORDER_REPLICATE)
    return mean_a * guide + mean_b


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--w", type=int, default=1025)
    ap.add_argument("--h", type=int, default=720)
    ap.add_argument("--src", default=os.path.join(ROOT, "images", "fog.jpg"))
    ap.add_argument("--patch", type=int, default=15)
    ap.add_argument("--omega", type=float, default=0.95)
    ap.add_argument("--t0", type=float, default=0.1)
    ap.add_argument("--gain", type=float, default=1.05)
    ap.add_argument("--acomp", type=float, default=0.35)   # A 彩色保留度: 1=原样, 0=全灰
    ap.add_argument("--gf-r", type=int, default=30)
    ap.add_argument("--gf-eps", type=float, default=1e-4)
    args = ap.parse_args()

    os.makedirs(TV_DIR, exist_ok=True)

    src = cv2.imread(args.src)
    if src is None:
        raise SystemExit(f"璇讳笉鍒板浘鐗? {args.src}")
    img = cv2.resize(src, (args.w, args.h), interpolation=cv2.INTER_AREA)
    I = img.astype(np.float32) / 255.0

    # ---- 鍙傝€冩祦绋?mode 0: 鏃犲紩瀵兼护娉? ----
    A, T, n_top = atmospheric_light_hist(I, args.patch, acomp=args.acomp)
    t = transmission(I, A, args.patch, args.omega)
    J0 = np.clip(recover(I, t, A, args.t0) * args.gain, 0, 1)

    # ---- 鍙傝€冩祦绋?mode 1: 寮曞婊ゆ尝缁嗗寲) ----
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY).astype(np.float32) / 255.0
    t_ref = np.clip(guided_filter(gray, t, args.gf_r, args.gf_eps), 0.0, 1.0)
    J1 = np.clip(recover(I, t_ref, A, args.t0) * args.gain, 0, 1)

    # ---- 钀界洏 ----
    b = (img[:, :, 0].astype(np.uint32))          # B
    g = (img[:, :, 1].astype(np.uint32)) << 8     # G
    r = (img[:, :, 2].astype(np.uint32)) << 16    # R
    words = (r | g | b).astype("<u4")
    words.tofile(os.path.join(TV_DIR, "fog_in.bin"))

    cv2.imwrite(os.path.join(TV_DIR, "fog_in.png"), img)
    for tag, Jm in (("mode0", J0), ("mode1", J1)):
        np.save(os.path.join(TV_DIR, f"fog_ref_{tag}.npy"), Jm.astype(np.float32))
        u8 = (Jm * 255.0 + 0.5).astype(np.uint8)
        cv2.imwrite(os.path.join(TV_DIR, f"fog_ref_{tag}.png"), u8)
        u8.tofile(os.path.join(TV_DIR, f"fog_ref_{tag}.u8"))   # 缁?C++ tb 鐩存帴璇?
    cpu_A = np.round(A * 255.0).astype(int).tolist()
    meta = {
        "width": args.w,
        "height": args.h,
        "patch": args.patch,
        "omega_q8": int(round(args.omega * 256)),
        "t0_q8": int(round(args.t0 * 256)),
        "gain_q8": int(round(args.gain * 256)),
        "acomp_q8": int(round(args.acomp * 256)),
        "A_q8": cpu_A,
        "dark_threshold": int(T),
        "n_top": int(n_top),
        "in_bytes": int(words.nbytes),
    }
    with open(os.path.join(TV_DIR, "meta.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2, ensure_ascii=False)

    # constants for the C++ testbench
    hdr = os.path.join(TV_DIR, "tv_params.h")
    with open(hdr, "w", encoding="utf-8") as f:
        f.write("// 鐢?make_testvector.py 鑷姩鐢熸垚,璇峰嬁鎵嬫敼\n")
        f.write("#pragma once\n")
        f.write(f'#define TV_DIR "{TV_DIR.replace(os.sep, "/")}"\n')
        f.write(f"#define TV_W {args.w}\n")
        f.write(f"#define TV_H {args.h}\n")
        f.write(f"#define TV_PATCH {args.patch}\n")
        f.write(f"#define TV_OMEGA_Q8 ({int(round(args.omega * 256))})\n")
        f.write(f"#define TV_T0_Q8 ({int(round(args.t0 * 256))})\n")
        f.write(f"#define TV_GAIN_Q8 ({int(round(args.gain * 256))})\n")
        f.write(f"#define TV_ACOMP_Q8 ({int(round(args.acomp * 256))})\n")
        f.write(f"#define TV_A_B {cpu_A[0]}\n")
        f.write(f"#define TV_A_G {cpu_A[1]}\n")
        f.write(f"#define TV_A_R {cpu_A[2]}\n")
        f.write(f"#define TV_THRESHOLD {int(T)}\n")
        f.write(f"#define TV_NTOP {int(n_top)}\n")
        f.write(f"#define TV_GF_R {args.gf_r}\n")
        f.write(f"#define TV_GF_EPS_X1E6 {int(round(args.gf_eps * 1e6))}\n")

    print(f"[ok] {args.w}x{args.h}  patch={args.patch} omega={args.omega} "
          f"t0={args.t0} gain={args.gain} gf_r={args.gf_r} gf_eps={args.gf_eps}")
    print(f"[ok] A(BGR,0..255) = {cpu_A}   dark_threshold={T}  n_top={n_top}")
    print(f"[ok] fog_in.bin = {words.nbytes} bytes -> {os.path.join(TV_DIR, 'fog_in.bin')}")
    print(f"[ok] mode0 -> {os.path.join(TV_DIR, 'fog_ref_mode0.png')}")
    print(f"[ok] mode1 -> {os.path.join(TV_DIR, 'fog_ref_mode1.png')}")


if __name__ == "__main__":
    main()

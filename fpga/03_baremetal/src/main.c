// ============================================================================
//  main.c  --  bare-metal driver for the pure-PL dehaze demo (MZ7X / Z7020)
//
//  Data flow (no camera, no PetaLinux, no network):
//
//     PC --xsct dow--> 0x10000000 [W*H words, BGR in low 24 bits]
//                              |
//                              v
//                    dehaze_top_0 (HLS IP, PL)
//                              |
//                              v
//                     0x12000000 [W*H words]
//                              |
//     PC <--xsct mrd----------+
//
//  Handshake: this app writes a result block at RES_ADDR; the host script
//  polls it for MAGIC_DONE before reading the image back.
//
//  Cache coherency: the CPU writes src through its D-cache and the PL writes
//  dst bypassing it, so we flush src before start and invalidate dst after.
// ============================================================================
#include <stdio.h>

#include "xparameters.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xil_types.h"
#include "xtime_l.h"

#include "xdehaze_top.h"

// ---- memory map (must match 03_baremetal/run_jtag.tcl) ----
#define SRC_ADDR   0x10000000U
#define DST_ADDR   0x12000000U
#define RES_ADDR   0x13000000U

#define IMG_W      1025
#define IMG_H      720
#define IMG_WORDS  (IMG_W * IMG_H)
#define IMG_BYTES  (IMG_WORDS * 4)

#define OMEGA_Q8   243      // 0.95
#define T0_Q8      26       // 0.10
#define GAIN_Q8    269      // 1.05

#define MAGIC_DONE 0xD0DE0001U
#define MAGIC_FAIL 0xD0DEBAD0U

#ifndef XPAR_DEHAZE_TOP_0_DEVICE_ID
#define XPAR_DEHAZE_TOP_0_DEVICE_ID 0
#endif

static u32 simple_checksum(const volatile u32* p, u32 n) {
    u32 s = 0;
    for (u32 i = 0; i < n; i += 97) {      // sparse sum: cheap, still catches corruption
        s = (s << 1) ^ p[i];
    }
    return s;
}

int main(void) {
    XDehaze_top inst;
    XDehaze_top_Config* cfg;
    volatile u32* res = (volatile u32*)RES_ADDR;

    res[0] = 0;                            // clear the handshake first

    xil_printf("\r\n=== PYNQ-free dehaze demo (bare metal) ===\r\n");
    xil_printf("image %dx%d, %d words (%d bytes)\r\n", IMG_W, IMG_H, IMG_WORDS, IMG_BYTES);

    cfg = XDehaze_top_LookupConfig(XPAR_DEHAZE_TOP_0_DEVICE_ID);
    if (cfg == NULL) {
        xil_printf("ERROR: LookupConfig failed\r\n");
        res[0] = MAGIC_FAIL;
        return 1;
    }
    if (XDehaze_top_CfgInitialize(&inst, cfg) != XST_SUCCESS) {
        xil_printf("ERROR: CfgInitialize failed\r\n");
        res[0] = MAGIC_FAIL;
        return 1;
    }

    XDehaze_top_Set_src_V(&inst, SRC_ADDR);
    XDehaze_top_Set_dst_V(&inst, DST_ADDR);
    XDehaze_top_Set_width_V(&inst, IMG_W);
    XDehaze_top_Set_height_V(&inst, IMG_H);
    XDehaze_top_Set_omega_q8_V(&inst, OMEGA_Q8);
    XDehaze_top_Set_t0_q8_V(&inst, T0_Q8);
    XDehaze_top_Set_gain_q8_V(&inst, GAIN_Q8);
    XDehaze_top_Set_mode_V(&inst, 0);

    // make sure the PL sees what the CPU wrote
    Xil_DCacheFlushRange(SRC_ADDR, IMG_BYTES);

    XTime t0, t1;
    XTime_GetTime(&t0);
    XDehaze_top_Start(&inst);
    while (!XDehaze_top_IsDone(&inst)) {
        // poll; a frame takes ~77 ms at 50 MHz
    }
    XTime_GetTime(&t1);

    Xil_DCacheInvalidateRange(DST_ADDR, IMG_BYTES);

    u32 A = XDehaze_top_Get_return(&inst);
    u64 cycles = (u64)(t1 - t0);
    u32 ms = (u32)((cycles * 1000ULL) / (u64)COUNTS_PER_SECOND);

    u32 ck = simple_checksum((const volatile u32*)DST_ADDR, IMG_WORDS);

    xil_printf("A (B,G,R) = %d,%d,%d\r\n", (int)(A & 0xFF),
               (int)((A >> 8) & 0xFF), (int)((A >> 16) & 0xFF));
    xil_printf("elapsed   = %d ms (%d cycles)\r\n", (int)ms, (int)cycles);
    xil_printf("checksum  = 0x%08x\r\n", ck);

    res[1] = A;
    res[2] = (u32)(cycles & 0xFFFFFFFF);
    res[3] = (u32)(cycles >> 32);
    res[4] = ck;
    res[5] = 0;
    res[0] = MAGIC_DONE;                   // publish last, so the host sees a complete block

    xil_printf("DONE, waiting for the host to read back 0x12000000\r\n");
    while (1) {
        // stay alive so JTAG can dump memory
    }
    return 0;
}

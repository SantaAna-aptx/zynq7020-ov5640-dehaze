// ============================================================================
//  dehaze_top.h  --  Dark Channel Prior dehazing core, HLS interface
//
//  Target : xc7z020clg400-2 (MZ7X board), 50 MHz FCLK0
//
//  mode 0 : dark channel + transmission + recover            (no refinement)
//  mode 1 : + guided filter refinement of the transmission   (He et al.)
//
//  Pixel word layout: bits[7:0]=B, bits[15:8]=G, bits[23:16]=R
//  (the same byte order as OpenCV's BGR buffer in memory)
//
//  scratch: a flat DDR workspace for the intermediate maps used by mode 1.
//      [0 .. W*H/4)                      transmission map, 4 pixels per word
//      [TMAP_WORDS .. TMAP_WORDS+W*H)    (a,b) map, one word per pixel
//  Layout is 32-bit words; see the TMAP_*/ABMAP_* macros in the .cpp.
// ============================================================================
#pragma once

#include "ap_int.h"

#define DEHAZE_MAX_W 1025
#define DEHAZE_MAX_H 720

ap_uint<32> dehaze_top(
    ap_uint<32>* src,        // in : W*H words
    ap_uint<32>* dst,        // out: W*H words
    ap_uint<32>* scratch,    // in : DDR workspace for mode 1
    ap_uint<16> width,
    ap_uint<16> height,
    ap_uint<16> omega_q8,    // dehaze strength  omega, Q8 (0.95 -> 243)
    ap_uint<16> t0_q8,       // transmission floor t0, Q8 (0.10 -> 26)
    ap_uint<16> gain_q8,     // output gain,        Q8 (1.05 -> 269)
    ap_uint<16> acomp_q8,    // A chroma retention, Q8 (256 = keep, 0 = grey)
    ap_uint<8>  mode);

// k78_stream_neon.c — Freestanding AArch64 high-speed E-Ink display stream decoder
// for Likebook Ares Note K78W (1872x1404 native EBC / KOReader BB8).
// Compiled freestanding (-nostdlib -shared -O3) -> k78_ko/libs/libk78stream.so (~3 KB).

typedef unsigned char      uint8_t;
typedef signed char        int8_t;
typedef unsigned short     uint16_t;
typedef unsigned int       uint32_t;
typedef unsigned long long uint64_t;
typedef unsigned long      size_t;

// PackBits RLE decoder with optional in-place XOR delta mode.
// When xor_mode != 0 and a zero-run occurs, simply skips ahead (O(1) per 128 unchanged bytes!).
int k78_packbits_decode(uint8_t * __restrict dst, size_t dst_cap,
                        const uint8_t * __restrict src, size_t src_len,
                        int xor_mode) {
    size_t si = 0, di = 0;
    while (si < src_len) {
        int8_t h = (int8_t)src[si++];
        if (h >= 0) {
            size_t cnt = (size_t)h + 1;
            if (si + cnt > src_len || di + cnt > dst_cap) return -1;
            if (xor_mode) {
                for (size_t k = 0; k < cnt; k++) dst[di + k] ^= src[si + k];
            } else {
                for (size_t k = 0; k < cnt; k++) dst[di + k] = src[si + k];
            }
            si += cnt;
            di += cnt;
        } else if (h != -128) {
            size_t cnt = (size_t)(1 - (int)h);
            if (si >= src_len || di + cnt > dst_cap) return -1;
            uint8_t val = src[si++];
            if (xor_mode) {
                if (val != 0) {
                    for (size_t k = 0; k < cnt; k++) dst[di + k] ^= val;
                }
            } else {
                for (size_t k = 0; k < cnt; k++) dst[di + k] = val;
            }
            di += cnt;
        }
    }
    return (int)di;
}

void k78_apply_raw(uint8_t * __restrict dst, const uint8_t * __restrict src, size_t n, int xor_mode) {
    if (xor_mode) {
        for (size_t i = 0; i < n; i++) dst[i] ^= src[i];
    } else {
        for (size_t i = 0; i < n; i++) dst[i] = src[i];
    }
}

// Fast 1-bit packed monochrome (MSB first, 1=white 0xFF, 0=black 0x00) -> 8-bit grayscale BB8.
// Processes 8 pixels per single 64-bit store (~0.5 ms for full 1872x1404 screen on RK3368!).
void k78_unpack_1bit_to_bb8(uint8_t * __restrict bb_dst,
                            const uint8_t * __restrict bits,
                            int width, int y1, int y2) {
    static uint64_t lut[256];
    static int lut_ready = 0;
    if (!lut_ready) {
        for (int b = 0; b < 256; b++) {
            uint64_t v = 0;
            for (int bit = 0; bit < 8; bit++) {
                if (b & (0x80 >> bit)) {
                    v |= ((uint64_t)0xFFu) << (bit * 8);
                }
            }
            lut[b] = v;
        }
        lut_ready = 1;
    }

    int row_bytes = width >> 3; // 1872 / 8 = 234 (exact multiple of 8)
    for (int y = y1; y < y2; y++) {
        uint64_t * __restrict out64 = (uint64_t *)(bb_dst + (size_t)y * (size_t)width);
        const uint8_t * __restrict in = bits + (size_t)y * (size_t)row_bytes;
        for (int i = 0; i < row_bytes; i++) {
            out64[i] = lut[in[i]];
        }
    }
}

// Fast 4-bit packed 16-level grayscale (hi nibble = left pixel, lo = right pixel) -> BB8.
// Processes 2 pixels per 16-bit store (~1.0 ms for full 1872x1404 screen on RK3368!).
void k78_unpack_4bit_to_bb8(uint8_t * __restrict bb_dst,
                            const uint8_t * __restrict nibs,
                            int width, int y1, int y2) {
    static uint16_t lut[256];
    static int lut_ready = 0;
    if (!lut_ready) {
        for (int b = 0; b < 256; b++) {
            uint16_t p0 = (uint16_t)((b >> 4) * 17);
            uint16_t p1 = (uint16_t)((b & 0x0F) * 17);
            lut[b] = (uint16_t)(p0 | (p1 << 8));
        }
        lut_ready = 1;
    }

    int row_bytes = width >> 1; // 1872 / 2 = 936
    for (int y = y1; y < y2; y++) {
        uint16_t * __restrict out16 = (uint16_t *)(bb_dst + (size_t)y * (size_t)width);
        const uint8_t * __restrict in = nibs + (size_t)y * (size_t)row_bytes;
        for (int i = 0; i < row_bytes; i++) {
            out16[i] = lut[in[i]];
        }
    }
}

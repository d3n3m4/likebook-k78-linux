// Ultra-fast AArch64 NEON converter: KOReader 8-bit grayscale (0x00..0xff)
// -> Rockchip RK3368 /dev/ebc 5-bit even grayscale (0x00..0x1e, step 2).
// Compiled freestanding (-nostdlib -shared) for zero libc ABI dependencies.

typedef unsigned char uint8_t;
typedef unsigned long size_t;
typedef uint8_t v16u8 __attribute__((vector_size(16)));

void bb8_to_ebc5(uint8_t * __restrict dst, const uint8_t * __restrict src, size_t n) {
    const v16u8 mask = {
        0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e,
        0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e
    };
    size_t i = 0;
    for (; i + 64 <= n; i += 64) {
        v16u8 a, b, c, d;
        __builtin_memcpy(&a, src + i,      16);
        __builtin_memcpy(&b, src + i + 16, 16);
        __builtin_memcpy(&c, src + i + 32, 16);
        __builtin_memcpy(&d, src + i + 48, 16);
        a = (a >> 3) & mask;
        b = (b >> 3) & mask;
        c = (c >> 3) & mask;
        d = (d >> 3) & mask;
        __builtin_memcpy(dst + i,      &a, 16);
        __builtin_memcpy(dst + i + 16, &b, 16);
        __builtin_memcpy(dst + i + 32, &c, 16);
        __builtin_memcpy(dst + i + 48, &d, 16);
    }
    for (; i < n; i++) {
        dst[i] = (uint8_t)((src[i] >> 3) & 0x1e);
    }
}

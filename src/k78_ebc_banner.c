// Freestanding AArch64 /dev/ebc banner drawer for Likebook K78W (1872x1404 8-bit grayscale)
#include <stdint.h>

#define SYS_openat 56
#define SYS_close  57
#define SYS_write  64
#define SYS_ioctl  29
#define SYS_mmap   222
#define SYS_munmap 215
#define SYS_exit   93

#define AT_FDCWD   -100
#define O_RDWR     2
#define PROT_RW    3
#define MAP_SHARED 1

#define EBC_GET_BUFFER  0x7000
#define EBC_SEND_BUFFER 0x7001
#define EPD_FULL_GC16   2

struct ebc_buf_info {
    int offset;
    int epd_mode;
    int height;
    int width;
    int panel_color;
    int win_x1;
    int win_y1;
    int win_x2;
    int win_y2;
    int width_mm;
    int height_mm;
};

static inline long sc1(long n, long a0) {
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a0;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8) : "memory");
    return x0;
}
static inline long sc2(long n, long a0, long a1) {
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a0;
    register long x1 __asm__("x1") = a1;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1) : "memory");
    return x0;
}
static inline long sc3(long n, long a0, long a1, long a2) {
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a0;
    register long x1 __asm__("x1") = a1;
    register long x2 __asm__("x2") = a2;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory");
    return x0;
}
static inline long sc4(long n, long a0, long a1, long a2, long a3) {
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a0;
    register long x1 __asm__("x1") = a1;
    register long x2 __asm__("x2") = a2;
    register long x3 __asm__("x3") = a3;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3) : "memory");
    return x0;
}
static inline long sc6(long n, long a0, long a1, long a2, long a3, long a4, long a5) {
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a0;
    register long x1 __asm__("x1") = a1;
    register long x2 __asm__("x2") = a2;
    register long x3 __asm__("x3") = a3;
    register long x4 __asm__("x4") = a4;
    register long x5 __asm__("x5") = a5;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5) : "memory");
    return x0;
}

// Minimal 5x7 uppercase + digit + symbol font (bit 4..0 = left..right per row)
static const uint8_t *glyph(char c) {
    static const uint8_t sp[7] = {0,0,0,0,0,0,0};
    static const uint8_t gA[7] = {0x0e,0x11,0x11,0x1f,0x11,0x11,0x11};
    static const uint8_t gB[7] = {0x1e,0x11,0x11,0x1e,0x11,0x11,0x1e};
    static const uint8_t gC[7] = {0x0e,0x11,0x10,0x10,0x10,0x11,0x0e};
    static const uint8_t gD[7] = {0x1c,0x12,0x11,0x11,0x11,0x12,0x1c};
    static const uint8_t gE[7] = {0x1f,0x10,0x10,0x1e,0x10,0x10,0x1f};
    static const uint8_t gF[7] = {0x1f,0x10,0x10,0x1e,0x10,0x10,0x10};
    static const uint8_t gG[7] = {0x0e,0x11,0x10,0x17,0x11,0x11,0x0e};
    static const uint8_t gH[7] = {0x11,0x11,0x11,0x1f,0x11,0x11,0x11};
    static const uint8_t gI[7] = {0x0e,0x04,0x04,0x04,0x04,0x04,0x0e};
    static const uint8_t gK[7] = {0x11,0x12,0x14,0x18,0x14,0x12,0x11};
    static const uint8_t gL[7] = {0x10,0x10,0x10,0x10,0x10,0x10,0x1f};
    static const uint8_t gM[7] = {0x11,0x1b,0x15,0x11,0x11,0x11,0x11};
    static const uint8_t gN[7] = {0x11,0x19,0x15,0x13,0x11,0x11,0x11};
    static const uint8_t gO[7] = {0x0e,0x11,0x11,0x11,0x11,0x11,0x0e};
    static const uint8_t gP[7] = {0x1e,0x11,0x11,0x1e,0x10,0x10,0x10};
    static const uint8_t gR[7] = {0x1e,0x11,0x11,0x1e,0x14,0x12,0x11};
    static const uint8_t gS[7] = {0x0f,0x10,0x10,0x0e,0x01,0x01,0x1e};
    static const uint8_t gT[7] = {0x1f,0x04,0x04,0x04,0x04,0x04,0x04};
    static const uint8_t gU[7] = {0x11,0x11,0x11,0x11,0x11,0x11,0x0e};
    static const uint8_t gV[7] = {0x11,0x11,0x11,0x11,0x11,0x0a,0x04};
    static const uint8_t gW[7] = {0x11,0x11,0x11,0x11,0x15,0x1b,0x11};
    static const uint8_t gX[7] = {0x11,0x11,0x0a,0x04,0x0a,0x11,0x11};
    static const uint8_t g0[7] = {0x0e,0x11,0x13,0x15,0x19,0x11,0x0e};
    static const uint8_t g1[7] = {0x04,0x0c,0x04,0x04,0x04,0x04,0x0e};
    static const uint8_t g2[7] = {0x0e,0x11,0x01,0x06,0x08,0x10,0x1f};
    static const uint8_t g3[7] = {0x1e,0x01,0x01,0x0e,0x01,0x01,0x1e};
    static const uint8_t g4[7] = {0x02,0x06,0x0a,0x12,0x1f,0x02,0x02};
    static const uint8_t g5[7] = {0x1f,0x10,0x1e,0x01,0x01,0x11,0x0e};
    static const uint8_t g6[7] = {0x06,0x08,0x10,0x1e,0x11,0x11,0x0e};
    static const uint8_t g7[7] = {0x1f,0x01,0x02,0x04,0x08,0x08,0x08};
    static const uint8_t g8[7] = {0x0e,0x11,0x11,0x0e,0x11,0x11,0x0e};
    static const uint8_t g9[7] = {0x0e,0x11,0x11,0x0f,0x01,0x02,0x0c};
    static const uint8_t gDot[7]  = {0,0,0,0,0,0x0c,0x0c};
    static const uint8_t gCol[7]  = {0,0x0c,0x0c,0,0x0c,0x0c,0};
    static const uint8_t gDash[7] = {0,0,0,0x1f,0,0,0};
    static const uint8_t gSlash[7]= {0x01,0x02,0x02,0x04,0x08,0x08,0x10};
    static const uint8_t gAt[7]   = {0x0e,0x11,0x17,0x15,0x17,0x10,0x0e};
    if (c >= 'a' && c <= 'z') c = (char)(c - 32);
    switch (c) {
        case 'A': return gA; case 'B': return gB; case 'C': return gC; case 'D': return gD;
        case 'E': return gE; case 'F': return gF; case 'G': return gG; case 'H': return gH;
        case 'I': return gI; case 'K': return gK; case 'L': return gL; case 'M': return gM;
        case 'N': return gN; case 'O': return gO; case 'P': return gP; case 'R': return gR;
        case 'S': return gS; case 'T': return gT; case 'U': return gU; case 'V': return gV;
        case 'W': return gW; case 'X': return gX;
        case '0': return g0; case '1': return g1; case '2': return g2; case '3': return g3;
        case '4': return g4; case '5': return g5; case '6': return g6; case '7': return g7;
        case '8': return g8; case '9': return g9;
        case '.': return gDot; case ':': return gCol; case '-': return gDash;
        case '/': return gSlash; case '@': return gAt;
        default: return sp;
    }
}

// Portrait coords (px in 0..1403, py in 0..1871) mapped onto native 1872x1404 (hwrotation=90)
static void put_px(uint8_t *buf, int w, int h, int px, int py, uint8_t v) {
    int nx = py;
    int ny = (h - 1) - px;
    if (nx >= 0 && nx < w && ny >= 0 && ny < h) {
        buf[ny * w + nx] = v;
    }
}

static void draw_str(uint8_t *buf, int w, int h, int x0, int y0, int scale, const char *s) {
    int x = x0;
    for (; *s; s++) {
        const uint8_t *g = glyph(*s);
        for (int r = 0; r < 7; r++) {
            for (int c = 0; c < 5; c++) {
                if (g[r] & (1 << (4 - c))) {
                    for (int dy = 0; dy < scale; dy++)
                        for (int dx = 0; dx < scale; dx++)
                            put_px(buf, w, h, x + c * scale + dx, y0 + r * scale + dy, 0x00);
                }
            }
        }
        x += 6 * scale;
    }
}

static void log_str(const char *s) {
    long n = 0;
    while (s[n]) n++;
    sc3(SYS_write, 1, (long)s, n);
}

void main_entry(void) {
    long fd = sc4(SYS_openat, AT_FDCWD, (long)"/dev/ebc", O_RDWR, 0);
    if (fd < 0) { log_str("k78_ebc_banner: open /dev/ebc failed\n"); sc1(SYS_exit, 2); }

    struct ebc_buf_info info;
    uint8_t *ip = (uint8_t *)&info;
    for (unsigned i = 0; i < sizeof(info); i++) ip[i] = 0;

    if (sc3(SYS_ioctl, fd, EBC_GET_BUFFER, (long)&info) < 0) {
        log_str("k78_ebc_banner: EBC_GET_BUFFER failed\n");
        sc1(SYS_exit, 3);
    }
    int w = info.width > 0 ? info.width : 1872;
    int h = info.height > 0 ? info.height : 1404;
    long map_len = 4L * w * h;
    long addr = sc6(SYS_mmap, 0, map_len, PROT_RW, MAP_SHARED, fd, 0);
    if (addr < 0 && addr >= -4095) {
        log_str("k78_ebc_banner: mmap failed\n");
        sc1(SYS_exit, 4);
    }

    uint8_t *buf = (uint8_t *)addr + info.offset;
    for (int i = 0; i < w * h; i++) buf[i] = 0xff;

    // Border rectangle in portrait coordinates (1404x1872)
    for (int x = 60; x < 1344; x++) {
        for (int t = 0; t < 6; t++) {
            put_px(buf, w, h, x, 120 + t, 0x00);
            put_px(buf, w, h, x, 1752 - t, 0x00);
        }
    }
    for (int y = 120; y < 1752; y++) {
        for (int t = 0; t < 6; t++) {
            put_px(buf, w, h, 60 + t, y, 0x00);
            put_px(buf, w, h, 1344 - t, y, 0x00);
        }
    }

    draw_str(buf, w, h, 120, 360, 8, "LIKEBOOK K78W");
    draw_str(buf, w, h, 120, 480, 7, "LINUX PUR OK");
    draw_str(buf, w, h, 120, 680, 5, "ALPINE 3.20 AARCH64");
    draw_str(buf, w, h, 120, 780, 5, "KERNEL 4.4.103");
    draw_str(buf, w, h, 120, 880, 5, "/DEV/EBC DIRECT OK");
    draw_str(buf, w, h, 120, 1080, 5, "SSH: ROOT@192.168.7.2");
    draw_str(buf, w, h, 120, 1180, 4, "PASS: K78");

    info.epd_mode = EPD_FULL_GC16;
    info.win_x1 = 0; info.win_y1 = 0;
    info.win_x2 = w; info.win_y2 = h;
    long sr = sc3(SYS_ioctl, fd, EBC_SEND_BUFFER, (long)&info);
    if (sr < 0) {
        log_str("k78_ebc_banner: EBC_SEND_BUFFER failed\n");
    } else {
        log_str("k78_ebc_banner: rendered OK\n");
    }

    sc2(SYS_munmap, addr, map_len);
    sc1(SYS_close, fd);
    sc1(SYS_exit, sr < 0 ? 5 : 0);
}

__asm__(
    ".global _start\n"
    "_start:\n"
    "  bl main_entry\n"
);

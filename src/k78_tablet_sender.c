// k78_tablet_sender.c — Ultra-low-latency 120Hz Wacom EMR + Trackpad + ExpressKeys server
// for Likebook Ares Note K78W -> Linux host k78_tablet_host.py.
// Listens on TCP 0.0.0.0:19782 (Linux USB host connects outbound -> zero firewall config!)
// and local UDP 127.0.0.1:19783 (Trackpad / ExpressKeys / live config from KOReader Lua apps).
// Freestanding AArch64 (-nostdlib -static): ~5 KB, <0.3 ms latency over USB RNDIS.
//
// Usage: k78_tablet_sender <wacom_en:0|1> <orient:0=port|1=land_ccw|2=land_cw> <pad_ymin_permille>

#include <stdint.h>
#include <stddef.h>

#define SYS_openat      56
#define SYS_close       57
#define SYS_read        63
#define SYS_ppoll       73
#define SYS_exit_group  94
#define SYS_socket      198
#define SYS_bind        200
#define SYS_listen      201
#define SYS_sendto      206
#define SYS_recvfrom    207
#define SYS_setsockopt  208
#define SYS_accept4     242

#define AT_FDCWD        -100
#define O_RDONLY        0
#define O_NONBLOCK      04000
#define AF_INET         2
#define SOCK_STREAM     1
#define SOCK_DGRAM      2
#define SOCK_NONBLOCK   04000
#define SOL_SOCKET      1
#define SO_REUSEADDR    2
#define IPPROTO_TCP     6
#define TCP_NODELAY     1
#define MSG_NOSIGNAL    0x4000

#define POLLIN          0x0001
#define POLLERR         0x0008
#define POLLHUP         0x0010

#define TCP_PORT        19782
#define LOCAL_UDP_PORT  19783

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
static inline long sc5(long n, long a0, long a1, long a2, long a3, long a4) {
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a0;
    register long x1 __asm__("x1") = a1;
    register long x2 __asm__("x2") = a2;
    register long x3 __asm__("x3") = a3;
    register long x4 __asm__("x4") = a4;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4) : "memory");
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

struct input_event {
    int64_t  tv_sec;
    int64_t  tv_usec;
    uint16_t type;
    uint16_t code;
    int32_t  value;
};

struct sockaddr_in {
    uint16_t sin_family;
    uint16_t sin_port;
    uint32_t sin_addr;
    uint8_t  sin_zero[8];
};

struct pollfd {
    int32_t fd;
    int16_t events;
    int16_t revents;
};

static inline uint16_t bswap16(uint16_t v) {
    return (uint16_t)((v >> 8) | ((v & 0xffu) << 8));
}

static int parse_int(const char *s) {
    int v = 0;
    while (*s >= '0' && *s <= '9') { v = v * 10 + (*s - '0'); s++; }
    return v;
}

static inline int clamp_i(int v, int lo, int hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

static void zero_mem(void *p, size_t n) {
    volatile uint8_t *b = (volatile uint8_t *)p;
    for (size_t i = 0; i < n; i++) b[i] = 0;
}

static int send_framed(long cli_fd, const uint8_t *pkt, int len) {
    if (cli_fd < 0 || len <= 0 || len > 120) return -1;
    uint8_t buf[128];
    buf[0] = (uint8_t)len;
    for (int i = 0; i < len; i++) buf[1 + i] = pkt[i];
    int total = 1 + len;
    int off = 0;
    while (off < total) {
        long w = sc6(SYS_sendto, cli_fd, (long)(buf + off), (long)(total - off), MSG_NOSIGNAL, 0, 0);
        if (w <= 0) return -1;
        off += (int)w;
    }
    return 0;
}

void main_entry(long *sp) {
    int argc = (int)sp[0];
    char **argv = (char **)(sp + 1);

    int wacom_en = (argc >= 2) ? parse_int(argv[1]) : 1;
    int orient   = (argc >= 3) ? parse_int(argv[2]) : 1;
    int ymin_pm  = (argc >= 4) ? parse_int(argv[3]) : 280;
    if (ymin_pm < 0) ymin_pm = 0;
    if (ymin_pm > 800) ymin_pm = 800;

    int pad_ymin = (15818 * ymin_pm) / 1000;
    int pad_yspan = 15818 - pad_ymin;
    if (pad_yspan < 100) pad_yspan = 100;

    long ev_fd = sc4(SYS_openat, AT_FDCWD, (long)"/dev/input/event0", O_RDONLY | O_NONBLOCK, 0);
    if (ev_fd < 0) sc1(SYS_exit_group, 1);

    // 1. TCP server on 0.0.0.0:19782 (Linux host connects outbound!)
    long srv_fd = sc3(SYS_socket, AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
    if (srv_fd < 0) sc1(SYS_exit_group, 2);
    int one = 1;
    sc5(SYS_setsockopt, srv_fd, SOL_SOCKET, SO_REUSEADDR, (long)&one, (long)sizeof(one));

    struct sockaddr_in sa;
    zero_mem(&sa, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = bswap16(TCP_PORT);
    sa.sin_addr = 0; // INADDR_ANY
    if (sc3(SYS_bind, srv_fd, (long)&sa, (long)sizeof(sa)) < 0) sc1(SYS_exit_group, 3);
    if (sc2(SYS_listen, srv_fd, 4) < 0) sc1(SYS_exit_group, 4);

    // 2. Local UDP control/bridge socket on 127.0.0.1:19783 (for Lua Trackpad & ExpressKeys)
    long udp_fd = sc3(SYS_socket, AF_INET, SOCK_DGRAM | SOCK_NONBLOCK, 0);
    if (udp_fd >= 0) {
        sc5(SYS_setsockopt, udp_fd, SOL_SOCKET, SO_REUSEADDR, (long)&one, (long)sizeof(one));
        struct sockaddr_in ua;
        zero_mem(&ua, sizeof(ua));
        ua.sin_family = AF_INET;
        ua.sin_port = bswap16(LOCAL_UDP_PORT);
        ua.sin_addr = 0x0100007Fu; // 127.0.0.1 in network byte order
        if (sc3(SYS_bind, udp_fd, (long)&ua, (long)sizeof(ua)) < 0) {
            sc1(SYS_close, udp_fd);
            udp_fd = -1;
        }
    }

    long cli_fd = -1;
    int rx = 0, ry = 0, press = 0, dist = 0, tx = 0, ty = 0;
    int in_range = 0, touch = 0, rubber = 0, btn1 = 0, btn2 = 0;
    int active_out = 0;

    struct input_event evs[16];
    uint8_t ubuf[128];

    for (;;) {
        struct pollfd pfds[4];
        pfds[0].fd = (int32_t)ev_fd;   pfds[0].events = POLLIN; pfds[0].revents = 0;
        pfds[1].fd = (int32_t)srv_fd;  pfds[1].events = POLLIN; pfds[1].revents = 0;
        pfds[2].fd = (int32_t)udp_fd;  pfds[2].events = (udp_fd >= 0) ? POLLIN : 0; pfds[2].revents = 0;
        pfds[3].fd = (int32_t)cli_fd;  pfds[3].events = (cli_fd >= 0) ? POLLIN : 0; pfds[3].revents = 0;

        long pr = sc5(SYS_ppoll, (long)pfds, 4, 0, 0, 0);
        if (pr < 0) continue;

        // Accept new Linux host connection
        if (pfds[1].revents & POLLIN) {
            long nc = sc4(SYS_accept4, srv_fd, 0, 0, SOCK_NONBLOCK);
            if (nc >= 0) {
                if (cli_fd >= 0) sc1(SYS_close, cli_fd);
                cli_fd = nc;
                sc5(SYS_setsockopt, cli_fd, IPPROTO_TCP, TCP_NODELAY, (long)&one, (long)sizeof(one));
                active_out = 0;
            }
        }

        // Detect host disconnect cleanly
        if (cli_fd >= 0 && (pfds[3].revents & (POLLIN | POLLHUP | POLLERR))) {
            uint8_t tmp[16];
            long nr = sc3(SYS_read, cli_fd, (long)tmp, (long)sizeof(tmp));
            if (nr <= 0) {
                sc1(SYS_close, cli_fd);
                cli_fd = -1;
                active_out = 0;
            }
        }

        // Local UDP bridge from KOReader Lua app (Trackpad / ExpressKeys / PING / Config)
        if (udp_fd >= 0 && (pfds[2].revents & POLLIN)) {
            for (;;) {
                struct sockaddr_in from;
                uint32_t flen = (uint32_t)sizeof(from);
                long nr = sc6(SYS_recvfrom, udp_fd, (long)ubuf, (long)sizeof(ubuf), 0, (long)&from, (long)&flen);
                if (nr <= 0) break;
                if (nr >= 2 && ubuf[0] == 0x4B) {
                    if (ubuf[1] == 4) {
                        // Status PING -> reply KPONG if host connected, else KWAIT
                        const char *rep = (cli_fd >= 0) ? "KPONG" : "KWAIT";
                        sc6(SYS_sendto, udp_fd, (long)rep, 5, 0, (long)&from, (long)flen);
                    } else if (ubuf[1] == 5 && nr >= 4) {
                        // Live config update: ['K', 5, wacom_en, orient]
                        wacom_en = ubuf[2] ? 1 : 0;
                        orient = (int)ubuf[3];
                        if (!wacom_en && active_out && cli_fd >= 0) {
                            uint8_t lift[15];
                            zero_mem(lift, 15);
                            lift[0] = 0x4B; lift[1] = 1;
                            if (send_framed(cli_fd, lift, 15) < 0) {
                                sc1(SYS_close, cli_fd); cli_fd = -1;
                            }
                            active_out = 0;
                        }
                    } else if (cli_fd >= 0) {
                        // Forward MOUSE (2) or KEY (3) directly to Linux host
                        if (send_framed(cli_fd, ubuf, (int)nr) < 0) {
                            sc1(SYS_close, cli_fd);
                            cli_fd = -1;
                        }
                    }
                }
            }
        }

        // Raw 120 Hz Wacom EMR digitizer events
        if (pfds[0].revents & POLLIN) {
            for (;;) {
                long nr = sc3(SYS_read, ev_fd, (long)evs, (long)sizeof(evs));
                if (nr <= 0) break;
                int n = (int)(nr / (long)sizeof(struct input_event));
                for (int i = 0; i < n; i++) {
                    uint16_t t = evs[i].type;
                    uint16_t c = evs[i].code;
                    int32_t  v = evs[i].value;

                    if (t == 3) {
                        if (c == 0) rx = v;
                        else if (c == 1) ry = v;
                        else if (c == 24) press = v;
                        else if (c == 25) dist = v;
                        else if (c == 26) { int s = v > 32767 ? v - 65536 : v; tx = clamp_i(s / 100, -90, 90); }
                        else if (c == 27) { int s = v > 32767 ? v - 65536 : v; ty = clamp_i(s / 100, -90, 90); }
                    } else if (t == 1) {
                        if (c == 320) { in_range = v ? 1 : 0; if (v) rubber = 0; else { touch = 0; press = 0; } }
                        else if (c == 321) { in_range = v ? 1 : 0; if (v) rubber = 1; else { touch = 0; press = 0; } }
                        else if (c == 330) { touch = v ? 1 : 0; if (!v) press = 0; }
                        else if (c == 331) btn1 = v ? 1 : 0;
                        else if (c == 332) btn2 = v ? 1 : 0;
                    } else if (t == 0 && c == 0) {
                        if (!wacom_en || cli_fd < 0) continue;
                        int in_pad = in_range && (ry >= pad_ymin);
                        if (!in_pad && !active_out) continue;

                        uint8_t pkt[15];
                        pkt[0] = 0x4B;
                        pkt[1] = 1;
                        uint8_t flags = 0;
                        int ox = 0, oy = 0, otx = tx, oty = ty;

                        if (in_pad) {
                            active_out = 1;
                            flags = 0x01
                                  | (touch  ? 0x02 : 0)
                                  | (rubber ? 0x04 : 0)
                                  | (btn1   ? 0x08 : 0)
                                  | (btn2   ? 0x10 : 0)
                                  | (orient ? 0x20 : 0);
                            if (orient == 1) {
                                ox = clamp_i(((ry - pad_ymin) * 15818) / pad_yspan, 0, 15818);
                                oy = clamp_i(11864 - rx, 0, 11864);
                                otx = ty;
                                oty = -tx;
                            } else if (orient == 2) {
                                ox = clamp_i(((15818 - ry) * 15818) / pad_yspan, 0, 15818);
                                oy = clamp_i(rx, 0, 11864);
                                otx = -ty;
                                oty = tx;
                            } else {
                                ox = clamp_i((rx * 15818) / 11864, 0, 15818);
                                oy = clamp_i(((ry - pad_ymin) * 11864) / pad_yspan, 0, 11864);
                            }
                        } else {
                            active_out = 0;
                            flags = 0;
                        }

                        uint16_t ux = (uint16_t)ox;
                        uint16_t uy = (uint16_t)oy;
                        uint16_t up = (uint16_t)clamp_i(press, 0, 4095);
                        uint16_t ud = (uint16_t)clamp_i(dist, 0, 255);
                        int16_t  itx = (int16_t)clamp_i(otx, -90, 90);
                        int16_t  ity = (int16_t)clamp_i(oty, -90, 90);

                        pkt[2]  = flags;
                        pkt[3]  = ux & 0xff;        pkt[4]  = (ux >> 8) & 0xff;
                        pkt[5]  = uy & 0xff;        pkt[6]  = (uy >> 8) & 0xff;
                        pkt[7]  = up & 0xff;        pkt[8]  = (up >> 8) & 0xff;
                        pkt[9]  = ud & 0xff;        pkt[10] = (ud >> 8) & 0xff;
                        pkt[11] = itx & 0xff;       pkt[12] = (itx >> 8) & 0xff;
                        pkt[13] = ity & 0xff;       pkt[14] = (ity >> 8) & 0xff;

                        if (send_framed(cli_fd, pkt, 15) < 0) {
                            sc1(SYS_close, cli_fd);
                            cli_fd = -1;
                            active_out = 0;
                        }
                    }
                }
            }
        }
    }
}

__asm__(
    ".global _start\n"
    "_start:\n"
    "  mov x0, sp\n"
    "  bl main_entry\n"
);

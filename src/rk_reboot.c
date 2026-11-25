// Freestanding AArch64 Linux reboot helper supporting Rockchip reboot reasons
// Usage: rk_reboot [loader|recovery|bootloader|poweroff|normal]
#include <stdint.h>

#define SYS_sync   81
#define SYS_exit   93
#define SYS_reboot 142

#define LINUX_REBOOT_MAGIC1      0xfee1dead
#define LINUX_REBOOT_MAGIC2      672274793
#define LINUX_REBOOT_CMD_RESTART  0x01234567
#define LINUX_REBOOT_CMD_POWER_OFF 0x4321fedc
#define LINUX_REBOOT_CMD_RESTART2 0xa1b2c3d4

static inline long sc0(long n) {
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0");
    __asm__ volatile("svc #0" : "=r"(x0) : "r"(x8) : "memory");
    return x0;
}

static inline long sc1(long n, long a0) {
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a0;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8) : "memory");
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

static int streq(const char *a, const char *b) {
    while (*a && *b && *a == *b) { a++; b++; }
    return *a == 0 && *b == 0;
}

void main_entry(long *sp) {
    long argc = sp[0];
    const char **argv = (const char **)(sp + 1);
    sc0(SYS_sync);
    if (argc >= 2 && streq(argv[1], "poweroff")) {
        sc4(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2, LINUX_REBOOT_CMD_POWER_OFF, 0);
    } else if (argc >= 2 && !streq(argv[1], "normal")) {
        sc4(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2, LINUX_REBOOT_CMD_RESTART2, (long)argv[1]);
    } else {
        sc4(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2, LINUX_REBOOT_CMD_RESTART, 0);
    }
    sc1(SYS_exit, 1);
}

__asm__(
    ".global _start\n"
    "_start:\n"
    "  mov x0, sp\n"
    "  bl main_entry\n"
);

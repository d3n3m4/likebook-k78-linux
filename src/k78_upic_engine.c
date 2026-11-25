// k78_upic_engine.c — Real-time Polyphonic Xenakis UPIC / GENDYN Audio Engine
// for Likebook Ares Note K78W (RK3368 ARM64, Wolfson WM8904 ALSA DAC, 48kHz stereo).
// Freestanding AArch64 (-nostdlib): zero external library dependencies.

#include <stdint.h>
#include <stddef.h>

// ---- Linux AArch64 syscalls ----
#define SYS_openat      56
#define SYS_close       57
#define SYS_read        63
#define SYS_write       64
#define SYS_ioctl       29
#define SYS_ftruncate   46
#define SYS_nanosleep   101
#define SYS_mmap        222
#define SYS_munmap      215
#define SYS_exit_group  94

#define AT_FDCWD        -100
#define O_RDONLY        0
#define O_WRONLY        1
#define O_RDWR          2
#define O_CREAT         0100
#define O_TRUNC         01000
#define PROT_RW         3
#define MAP_SHARED      1

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

void *memset(void *p, int c, size_t n) {
    volatile uint8_t *b = (volatile uint8_t *)p;
    for (size_t i = 0; i < n; i++) b[i] = (uint8_t)c;
    return p;
}

static void zero_mem(void *p, size_t n) {
    memset(p, 0, n);
}

static void log_s(const char *s) {
    size_t n = 0;
    while (s[n]) n++;
    sc3(SYS_write, 2, (long)s, (long)n);
}

static void log_num(const char *prefix, long v) {
    log_s(prefix);
    char buf[32];
    int i = 0;
    if (v < 0) { log_s("-"); v = -v; }
    if (v == 0) buf[i++] = '0';
    else { while (v > 0) { buf[i++] = (char)('0' + (v % 10)); v /= 10; } }
    for (int j = i - 1; j >= 0; j--) sc3(SYS_write, 2, (long)&buf[j], 1);
    log_s("\n");
}

static void sleep_ms(long ms) {
    struct { long tv_sec; long tv_nsec; } ts;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (ms % 1000) * 1000000L;
    sc2(SYS_nanosleep, (long)&ts, 0);
}

// ---- ALSA 64-bit Linux kernel ABI (verified on K78W 4.4.103) ----
#define SNDRV_CTL_IOCTL_ELEM_WRITE    0xc4c85513UL
#define SNDRV_PCM_IOCTL_HW_PARAMS     0xc2604111UL
#define SNDRV_PCM_IOCTL_SW_PARAMS     0xc0884113UL
#define SNDRV_PCM_IOCTL_PREPARE       0x4140UL
#define SNDRV_PCM_IOCTL_START         0x4142UL
#define SNDRV_PCM_IOCTL_DROP          0x4143UL
#define SNDRV_PCM_IOCTL_WRITEI_FRAMES 0x40184150UL

#define SNDRV_PCM_HW_PARAM_ACCESS      0
#define SNDRV_PCM_HW_PARAM_FORMAT      1
#define SNDRV_PCM_HW_PARAM_SUBFORMAT   2
#define SNDRV_PCM_HW_PARAM_CHANNELS    10
#define SNDRV_PCM_HW_PARAM_RATE        11
#define SNDRV_PCM_HW_PARAM_PERIOD_SIZE 13
#define SNDRV_PCM_HW_PARAM_PERIODS     15
#define SNDRV_PCM_HW_PARAM_BUFFER_SIZE 17
#define SNDRV_PCM_HW_PARAM_FIRST_INTERVAL 8
#define SNDRV_PCM_ACCESS_RW_INTERLEAVED 3
#define SNDRV_PCM_FORMAT_S16_LE        2

struct snd_mask { uint32_t bits[8]; };
struct snd_interval {
    uint32_t min, max;
    uint32_t flags; // openmin:1, openmax:1, integer:1, empty:1
};
struct snd_pcm_hw_params {
    uint32_t flags;
    struct snd_mask masks[8];        // offset 4..259
    struct snd_interval intervals[21]; // offset 260..511
    uint32_t rmask;                  // offset 512
    uint32_t cmask;
    uint32_t info;
    uint32_t msbits;
    uint32_t rate_num;
    uint32_t rate_den;
    uint64_t fifo_size;
    uint8_t  reserved[64];
}; // sizeof = 608

struct snd_pcm_sw_params {
    int32_t  tstamp_mode;
    uint32_t period_step;
    uint32_t sleep_min;
    uint32_t _pad0;
    uint64_t avail_min;
    uint64_t xfer_align;
    uint64_t start_threshold;
    uint64_t stop_threshold;
    uint64_t silence_threshold;
    uint64_t silence_size;
    uint64_t boundary;
    uint32_t proto;
    uint32_t tstamp_type;
    uint8_t  reserved[56];
}; // sizeof = 136

struct snd_xferi {
    int64_t  result;
    void    *buf;
    uint64_t frames;
}; // sizeof = 24

struct snd_ctl_elem_id {
    uint32_t numid;
    int32_t  iface;
    uint32_t device;
    uint32_t subdevice;
    uint8_t  name[44];
    uint32_t index;
}; // sizeof = 64

struct snd_ctl_elem_value {
    struct snd_ctl_elem_id id; // 0..63
    uint32_t indirect;         // 64..67
    uint32_t _pad;             // 68..71
    int64_t  ival[128];        // 72..1095
    uint8_t  reserved[128];    // 1096..1223
}; // sizeof = 1224

static void ctl_set2(int cfd, uint32_t numid, int64_t v0, int64_t v1) {
    struct snd_ctl_elem_value ev;
    zero_mem(&ev, sizeof(ev));
    ev.id.numid = numid;
    ev.ival[0] = v0;
    ev.ival[1] = v1;
    sc3(SYS_ioctl, cfd, SNDRV_CTL_IOCTL_ELEM_WRITE, (long)&ev);
}

static void wm8904_set_mixer(int vol_pct) {
    long cfd = sc4(SYS_openat, AT_FDCWD, (long)"/dev/snd/controlC0", O_RDWR, 0);
    if (cfd < 0) return;
    if (vol_pct < 0) vol_pct = 0;
    if (vol_pct > 100) vol_pct = 100;
    int64_t hp_v = (int64_t)(vol_pct * 57 / 100);  // 57 = 0 dB on WM8904 (0..63)
    int64_t ln_v = (int64_t)(vol_pct * 60 / 100);  // Line/Speaker output (0..63)
    // Route DAC to HP and Line outputs (numids verified on K78W)
    ctl_set2((int)cfd, 29, 0, 0);        // DACL Mux = Left
    ctl_set2((int)cfd, 30, 1, 0);        // DACR Mux = Right
    ctl_set2((int)cfd, 33, 0, 0);        // HPL Mux = DAC
    ctl_set2((int)cfd, 34, 0, 0);        // HPR Mux = DAC
    ctl_set2((int)cfd, 35, 0, 0);        // LINEL Mux = DAC
    ctl_set2((int)cfd, 36, 0, 0);        // LINER Mux = DAC
    ctl_set2((int)cfd, 10, 96, 96);      // Digital Playback Volume = 0dB (96/96)
    ctl_set2((int)cfd, 11, hp_v, hp_v);  // Headphone Volume
    ctl_set2((int)cfd, 12, 1, 1);        // Headphone Switch ON
    ctl_set2((int)cfd, 14, ln_v, ln_v);  // Line Output Volume (Speaker)
    ctl_set2((int)cfd, 15, 1, 1);        // Line Output Switch ON
    sc1(SYS_close, cfd);
}

static void hw_set_mask(struct snd_pcm_hw_params *p, int param, int bit) {
    zero_mem(&p->masks[param], sizeof(struct snd_mask));
    p->masks[param].bits[bit >> 5] = 1u << (bit & 31);
}
static void hw_set_int(struct snd_pcm_hw_params *p, int param, uint32_t lo, uint32_t hi) {
    struct snd_interval *iv = &p->intervals[param - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL];
    iv->min = lo;
    iv->max = hi;
    iv->flags = 4; // integer
}

static int alsa_open_pcm(uint32_t *out_rate, uint32_t *out_period) {
    long fd = sc4(SYS_openat, AT_FDCWD, (long)"/dev/snd/pcmC0D0p", O_RDWR, 0);
    if (fd < 0) { log_num("upic: open pcm failed ", fd); return -1; }

    struct snd_pcm_hw_params hw;
    zero_mem(&hw, sizeof(hw));
    // Fill all masks with 0xffffffff and all intervals with [0..0xffffffff]
    for (int i = 0; i < 8; i++)
        for (int j = 0; j < 8; j++) hw.masks[i].bits[j] = 0xffffffffu;
    for (int i = 0; i < 21; i++) {
        hw.intervals[i].min = 0;
        hw.intervals[i].max = 0xffffffffu;
        hw.intervals[i].flags = 0;
    }
    hw.rmask = 0xffffffffu;
    hw_set_mask(&hw, SNDRV_PCM_HW_PARAM_ACCESS, SNDRV_PCM_ACCESS_RW_INTERLEAVED);
    hw_set_mask(&hw, SNDRV_PCM_HW_PARAM_FORMAT, SNDRV_PCM_FORMAT_S16_LE);
    hw_set_mask(&hw, SNDRV_PCM_HW_PARAM_SUBFORMAT, 0);
    hw_set_int(&hw, SNDRV_PCM_HW_PARAM_CHANNELS, 2, 2);
    hw_set_int(&hw, SNDRV_PCM_HW_PARAM_RATE, 48000, 48000);
    hw_set_int(&hw, SNDRV_PCM_HW_PARAM_PERIOD_SIZE, 256, 256);
    hw_set_int(&hw, SNDRV_PCM_HW_PARAM_PERIODS, 4, 4);
    hw_set_int(&hw, SNDRV_PCM_HW_PARAM_BUFFER_SIZE, 1024, 1024);

    long r = sc3(SYS_ioctl, fd, SNDRV_PCM_IOCTL_HW_PARAMS, (long)&hw);
    if (r < 0) {
        log_num("upic: HW_PARAMS failed ", r);
        sc1(SYS_close, fd);
        return -1;
    }
    uint32_t rate = hw.intervals[SNDRV_PCM_HW_PARAM_RATE - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].min;
    uint32_t period = hw.intervals[SNDRV_PCM_HW_PARAM_PERIOD_SIZE - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].min;
    uint32_t bufsz = hw.intervals[SNDRV_PCM_HW_PARAM_BUFFER_SIZE - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].min;
    *out_rate = rate ? rate : 48000;
    *out_period = (period >= 64 && period <= 1024) ? period : 256;

    struct snd_pcm_sw_params sw;
    zero_mem(&sw, sizeof(sw));
    sw.tstamp_mode = 0;
    sw.period_step = 1;
    sw.avail_min = *out_period;
    sw.xfer_align = 1;
    sw.start_threshold = *out_period;
    sw.stop_threshold = bufsz ? bufsz : 2048;
    sw.silence_threshold = 0;
    sw.silence_size = 0;
    sw.boundary = (uint64_t)sw.stop_threshold << 20;
    r = sc3(SYS_ioctl, fd, SNDRV_PCM_IOCTL_SW_PARAMS, (long)&sw);
    if (r < 0) log_num("upic: SW_PARAMS warn ", r);

    r = sc3(SYS_ioctl, fd, SNDRV_PCM_IOCTL_PREPARE, 0);
    if (r < 0) { log_num("upic: PREPARE failed ", r); sc1(SYS_close, fd); return -1; }
    return (int)fd;
}

// ---- Shared-Memory Control Block (/tmp/k78_upic.shm) ----
#define UPIC_MAGIC    0x43495055u
#define UPIC_WT_SIZE  256
#define UPIC_MAX_ARCS 48
#define UPIC_COLS     256

struct upic_arc {
    int32_t active;
    int32_t wave_bank;         // 0=Custom drawn, 1=Sine, 2=Organ/Saw, 3=GENDYN stochastic
    int32_t t_start;           // 0..255
    int32_t t_end;             // 0..255
    float   pan;               // -1..+1
    float   gain;              // 0..1
    float   pitch[UPIC_COLS];  // 0..1 (55 Hz .. 1760 Hz log)
    float   amp[UPIC_COLS];    // 0..1 (stylus pressure)
};

struct upic_shm {
    uint32_t magic;
    volatile int32_t quit;         // 1 = exit engine cleanly
    volatile int32_t playing;      // 1 = playhead moving
    volatile int32_t loop;         // 1 = loop playback
    volatile float   duration_sec; // 2.0 .. 32.0 seconds per page
    volatile float   playhead;     // 0.0 .. 1.0 (written by engine, or seekable)
    volatile float   seek_req;     // >= 0.0 triggers playhead jump, engine resets to -1.0
    volatile int32_t volume;       // 0..100 (hardware WM8904 + master gain)
    volatile float   reverb_mix;   // 0.0 .. 0.75 stereo echo/space
    volatile int32_t gendyn_chaos; // 1..100 stochastic walk intensity
    volatile int32_t live_on;      // 1 = stylus currently sounding (touch or hover!)
    volatile int32_t live_wave;    // 0=Custom(A<->B morph), 1=Sine, 2=Organ, 3=GENDYN
    volatile float   live_pitch;   // 0..1
    volatile float   live_amp;     // 0..1
    volatile float   live_morph;   // 0..1 morph between custom_wt (A) and custom_wt_b (B)
    volatile float   live_filter;  // 0.05..1.0 low-pass brightness
    volatile float   live_pan;     // -1..+1 stereo pan
    volatile int32_t export_req;   // 1 = render WAV to export_path, engine sets 2 (done) or -1 (err)
    char             export_path[128];
    float            custom_wt[UPIC_WT_SIZE];   // Wave A (-1..+1)
    float            custom_wt_b[UPIC_WT_SIZE]; // Wave B (-1..+1)
    struct upic_arc  arcs[UPIC_MAX_ARCS];
};

// ---- Fast freestanding math ----
static inline float fast_exp2f(float x) {
    if (x < -20.0f) return 0.0f;
    if (x > 20.0f) x = 20.0f;
    int32_t n = (int32_t)x;
    if (x < (float)n) n--;
    float f = x - (float)n;
    // Minimax polynomial for 2^f on [0, 1)
    float p = 1.0f + f * (0.6931472f + f * (0.2402265f + f * (0.0555041f + f * 0.0096181f)));
    union { uint32_t u; float f; } u;
    u.u = (uint32_t)(n + 127) << 23;
    return p * u.f;
}

static inline float fast_tanhf(float x) {
    if (x > 3.0f) return 1.0f;
    if (x < -3.0f) return -1.0f;
    float x2 = x * x;
    return x * (27.0f + x2) / (27.0f + 9.0f * x2);
}

static float sine_wt[UPIC_WT_SIZE];
static float organ_wt[UPIC_WT_SIZE];

static inline float fast_sin_unit(float ph) {
    // ph in [0, 1) -> sin(2*pi*ph) accurate to ~0.001
    float x = ph * 2.0f - 1.0f; // [-1, 1)
    float y = -4.0f * x * (1.0f - (x < 0.0f ? -x : x));
    return 0.225f * (y * (y < 0.0f ? -y : y) - y) + y;
}

static void init_builtin_waves(void) {
    for (int i = 0; i < UPIC_WT_SIZE; i++) {
        float ph = (float)i / (float)UPIC_WT_SIZE;
        sine_wt[i] = fast_sin_unit(ph);
        // Rich harmonic additive timbre (Xenakis brass/string-like spectrum)
        float s = 0.55f * fast_sin_unit(ph)
                + 0.28f * fast_sin_unit((ph * 2.0f) - (int)(ph * 2.0f))
                + 0.16f * fast_sin_unit((ph * 3.0f) - (int)(ph * 3.0f))
                + 0.10f * fast_sin_unit((ph * 4.0f) - (int)(ph * 4.0f))
                + 0.06f * fast_sin_unit((ph * 5.0f) - (int)(ph * 5.0f))
                + 0.04f * fast_sin_unit((ph * 7.0f) - (int)(ph * 7.0f));
        organ_wt[i] = s * 0.85f;
    }
}

static inline float sample_wt(const float *wt, float ph) {
    float idx = ph * (float)UPIC_WT_SIZE;
    int i0 = (int)idx & (UPIC_WT_SIZE - 1);
    int i1 = (i0 + 1) & (UPIC_WT_SIZE - 1);
    float frac = idx - (float)((int)idx);
    return wt[i0] + (wt[i1] - wt[i0]) * frac;
}

// ---- Xenakis GENDYN (Dynamic Stochastic Synthesis) ----
#define GENDYN_NODES 12
struct gendyn_state {
    uint32_t rng;
    float y[GENDYN_NODES];
    float x[GENDYN_NODES]; // normalized segment positions 0..1
    float prev_ph;
};

static inline float rng_f(uint32_t *s) {
    uint32_t x = *s;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *s = x;
    return ((float)(x & 0xffff) / 32768.0f) - 1.0f; // [-1, +1)
}

static void gendyn_init(struct gendyn_state *g, uint32_t seed) {
    g->rng = seed ? seed : 0x12345678u;
    g->prev_ph = 0.0f;
    for (int i = 0; i < GENDYN_NODES; i++) {
        g->x[i] = (float)i / (float)GENDYN_NODES;
        g->y[i] = fast_sin_unit(g->x[i]) * 0.6f;
    }
}

static float gendyn_sample(struct gendyn_state *g, float ph, float chaos) {
    if (ph < g->prev_ph) {
        // New cycle: stochastic random walk on breakpoint amplitudes & spacing (elastic barriers!)
        float step_y = 0.02f + 0.14f * chaos;
        float step_x = 0.004f + 0.025f * chaos;
        for (int i = 0; i < GENDYN_NODES; i++) {
            float ny = g->y[i] + rng_f(&g->rng) * step_y;
            if (ny > 0.95f) ny = 1.90f - ny;
            if (ny < -0.95f) ny = -1.90f - ny;
            g->y[i] = ny;
            if (i > 0) {
                float base = (float)i / (float)GENDYN_NODES;
                float nx = g->x[i] + rng_f(&g->rng) * step_x;
                float lo = base - 0.035f, hi = base + 0.035f;
                if (nx < lo) nx = lo;
                if (nx > hi) nx = hi;
                g->x[i] = nx;
            }
        }
    }
    g->prev_ph = ph;
    // Linear interpolation between breakpoints
    int idx = GENDYN_NODES - 1;
    for (int i = 0; i < GENDYN_NODES - 1; i++) {
        if (ph < g->x[i + 1]) { idx = i; break; }
    }
    float x0 = g->x[idx];
    float x1 = (idx == GENDYN_NODES - 1) ? 1.0f : g->x[idx + 1];
    float y0 = g->y[idx];
    float y1 = (idx == GENDYN_NODES - 1) ? g->y[0] : g->y[idx + 1];
    float span = x1 - x0;
    float t = (span > 1e-5f) ? ((ph - x0) / span) : 0.0f;
    return y0 + (y1 - y0) * t;
}

// ---- Stereo Space Delay Line (24,000 samples = 0.50 s @ 48kHz) ----
#define DELAY_LEN 24576
static float delay_l[DELAY_LEN];
static float delay_r[DELAY_LEN];
static int   delay_pos = 0;

// ---- Oscillator runtime state ----
static float arc_phase[UPIC_MAX_ARCS];
static float arc_env[UPIC_MAX_ARCS];
static struct gendyn_state arc_gd[UPIC_MAX_ARCS];
static float live_phase = 0.0f;
static float live_env = 0.0f;
static float live_pitch_s = 0.5f;
static float live_lpf_z = 0.0f;
static float mix_lpf_l = 0.0f, mix_lpf_r = 0.0f;
static struct gendyn_state live_gd;

static inline float pitch_to_hz(float y) {
    if (y < 0.0f) y = 0.0f;
    if (y > 1.0f) y = 1.0f;
    // 5 octaves: 55 Hz (A1) .. 1760 Hz (A6)
    return 55.0f * fast_exp2f(5.0f * y);
}

static void render_block(struct upic_shm *shm, int16_t *out, int frames, float sr, int offline) {
    float inv_sr = 1.0f / sr;
    float dur = shm->duration_sec;
    if (dur < 1.0f) dur = 1.0f;
    if (dur > 60.0f) dur = 60.0f;
    float ph_step = inv_sr / dur;
    float chaos = (float)shm->gendyn_chaos * 0.01f;
    if (chaos < 0.02f) chaos = 0.02f;
    if (chaos > 1.0f) chaos = 1.0f;
    float rev = shm->reverb_mix;
    if (rev < 0.0f) rev = 0.0f;
    if (rev > 0.75f) rev = 0.75f;
    float master = (float)shm->volume * 0.01f;
    if (master < 0.0f) master = 0.0f;
    if (master > 1.0f) master = 1.0f;
    if (offline) master = 0.90f;

    float morph = shm->live_morph;
    if (morph < 0.0f) morph = 0.0f;
    if (morph > 1.0f) morph = 1.0f;
    float filt = shm->live_filter;
    if (filt < 0.04f) filt = 0.04f;
    if (filt > 1.0f) filt = 1.0f;
    float lpf_a = filt * filt; // musical exponential cutoff response
    if (lpf_a < 0.015f) lpf_a = 0.015f;

    int playing = offline ? 1 : shm->playing;
    float playhead = shm->playhead;

    for (int f = 0; f < frames; f++) {
        float mix_l = 0.0f;
        float mix_r = 0.0f;

        // 1. Score polyphonic arcs
        float col_f = playhead * (float)(UPIC_COLS - 1);
        int c0 = (int)col_f;
        if (c0 < 0) c0 = 0;
        if (c0 >= UPIC_COLS - 1) c0 = UPIC_COLS - 2;
        int c1 = c0 + 1;
        float cfrac = col_f - (float)c0;

        for (int a = 0; a < UPIC_MAX_ARCS; a++) {
            struct upic_arc *arc = &shm->arcs[a];
            float target_amp = 0.0f;
            float hz = 220.0f;
            if (playing && arc->active && c0 >= arc->t_start && c0 <= arc->t_end) {
                float p0 = arc->pitch[c0];
                float p1 = (c1 <= arc->t_end) ? arc->pitch[c1] : p0;
                float a0 = arc->amp[c0];
                float a1 = (c1 <= arc->t_end) ? arc->amp[c1] : a0;
                hz = pitch_to_hz(p0 + (p1 - p0) * cfrac);
                target_amp = (a0 + (a1 - a0) * cfrac) * arc->gain;
            }
            // Smooth 6 ms anti-click envelope
            arc_env[a] += (target_amp - arc_env[a]) * 0.0045f;
            if (arc_env[a] > 0.0004f) {
                float ph = arc_phase[a] + hz * inv_sr;
                if (ph >= 1.0f) ph -= (float)((int)ph);
                arc_phase[a] = ph;
                float s;
                int wb = arc->wave_bank;
                if (wb == 0) {
                    float sa = sample_wt(shm->custom_wt, ph);
                    if (morph > 0.001f) {
                        float sb = sample_wt(shm->custom_wt_b, ph);
                        s = sa + (sb - sa) * morph;
                    } else {
                        s = sa;
                    }
                }
                else if (wb == 1) s = sample_wt(sine_wt, ph);
                else if (wb == 2) s = sample_wt(organ_wt, ph);
                else              s = gendyn_sample(&arc_gd[a], ph, chaos);
                float v = s * arc_env[a] * 0.28f;
                float pan = arc->pan;
                mix_l += v * (0.7f - 0.3f * pan);
                mix_r += v * (0.7f + 0.3f * pan);
            }
        }

        // 2. Live stylus voice (touch OR hover Theremin!)
        if (!offline) {
            float lt = shm->live_on ? shm->live_amp : 0.0f;
            live_env += (lt - live_env) * (lt > live_env ? 0.018f : 0.005f);
            live_pitch_s += (shm->live_pitch - live_pitch_s) * 0.018f;
            if (live_env > 0.0004f) {
                float hz = pitch_to_hz(live_pitch_s);
                float ph = live_phase + hz * inv_sr;
                if (ph >= 1.0f) ph -= (float)((int)ph);
                live_phase = ph;
                float s;
                int wb = shm->live_wave;
                if (wb == 0) {
                    float sa = sample_wt(shm->custom_wt, ph);
                    if (morph > 0.001f) {
                        float sb = sample_wt(shm->custom_wt_b, ph);
                        s = sa + (sb - sa) * morph;
                    } else {
                        s = sa;
                    }
                }
                else if (wb == 1) s = sample_wt(sine_wt, ph);
                else if (wb == 2) s = sample_wt(organ_wt, ph);
                else              s = gendyn_sample(&live_gd, ph, chaos);
                // Expressive lowpass brightness filter
                live_lpf_z += (s - live_lpf_z) * lpf_a;
                float v = live_lpf_z * live_env * 0.42f;
                float lp = shm->live_pan;
                if (lp < -1.0f) lp = -1.0f; else if (lp > 1.0f) lp = 1.0f;
                mix_l += v * (0.7f - 0.3f * lp);
                mix_r += v * (0.7f + 0.3f * lp);
            } else {
                live_lpf_z *= 0.95f;
            }
        }

        // Gentle master warmth filter when filter < 0.98
        if (lpf_a < 0.96f) {
            mix_lpf_l += (mix_l - mix_lpf_l) * lpf_a;
            mix_lpf_r += (mix_r - mix_lpf_r) * lpf_a;
            mix_l = mix_lpf_l;
            mix_r = mix_lpf_r;
        } else {
            mix_lpf_l = mix_l;
            mix_lpf_r = mix_r;
        }

        // 3. Stereo ping-pong Space Delay (Xenakis studio resonance)
        if (rev > 0.01f) {
            int rl = (delay_pos - 11520 + DELAY_LEN) % DELAY_LEN; // 240 ms
            int rr = (delay_pos - 16800 + DELAY_LEN) % DELAY_LEN; // 350 ms
            float dl = delay_l[rl];
            float dr = delay_r[rr];
            delay_l[delay_pos] = mix_l + dr * (0.42f * rev);
            delay_r[delay_pos] = mix_r + dl * (0.42f * rev);
            mix_l = mix_l * (1.0f - 0.35f * rev) + dl * rev;
            mix_r = mix_r * (1.0f - 0.35f * rev) + dr * rev;
        } else {
            delay_l[delay_pos] = 0.0f;
            delay_r[delay_pos] = 0.0f;
        }
        delay_pos = (delay_pos + 1) % DELAY_LEN;

        // 4. Analog-style soft saturation + master gain
        float ol = fast_tanhf(mix_l * 1.4f) * master;
        float or_ = fast_tanhf(mix_r * 1.4f) * master;
        int32_t il = (int32_t)(ol * 32000.0f);
        int32_t ir = (int32_t)(or_ * 32000.0f);
        if (il > 32767) il = 32767; else if (il < -32768) il = -32768;
        if (ir > 32767) ir = 32767; else if (ir < -32768) ir = -32768;
        out[f * 2]     = (int16_t)il;
        out[f * 2 + 1] = (int16_t)ir;

        // 5. Advance playhead
        if (playing) {
            playhead += ph_step;
            if (playhead >= 1.0f) {
                if (!offline && shm->loop) {
                    playhead -= 1.0f;
                } else {
                    playhead = offline ? 1.0f : 0.0f;
                    playing = 0;
                    if (!offline) shm->playing = 0;
                }
            }
        }
    }
    shm->playhead = playhead;
}

static void export_wav(struct upic_shm *shm, uint32_t sr) {
    const char *path = shm->export_path;
    if (!path[0]) { shm->export_req = -1; return; }
    long fd = sc4(SYS_openat, AT_FDCWD, (long)path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) { shm->export_req = -1; return; }

    float dur = shm->duration_sec;
    if (dur < 1.0f) dur = 8.0f;
    if (dur > 60.0f) dur = 60.0f;
    // Add 0.8 s reverb tail
    uint32_t total_frames = (uint32_t)((dur + (shm->reverb_mix > 0.01f ? 0.8f : 0.05f)) * (float)sr);
    uint32_t data_bytes = total_frames * 4;
    uint32_t riff_sz = 36 + data_bytes;

    uint8_t hdr[44];
    hdr[0]='R'; hdr[1]='I'; hdr[2]='F'; hdr[3]='F';
    hdr[4]=riff_sz&0xff; hdr[5]=(riff_sz>>8)&0xff; hdr[6]=(riff_sz>>16)&0xff; hdr[7]=(riff_sz>>24)&0xff;
    hdr[8]='W'; hdr[9]='A'; hdr[10]='V'; hdr[11]='E';
    hdr[12]='f'; hdr[13]='m'; hdr[14]='t'; hdr[15]=' ';
    hdr[16]=16; hdr[17]=0; hdr[18]=0; hdr[19]=0;
    hdr[20]=1; hdr[21]=0;   // PCM
    hdr[22]=2; hdr[23]=0;   // stereo
    hdr[24]=sr&0xff; hdr[25]=(sr>>8)&0xff; hdr[26]=(sr>>16)&0xff; hdr[27]=(sr>>24)&0xff;
    uint32_t br = sr * 4;
    hdr[28]=br&0xff; hdr[29]=(br>>8)&0xff; hdr[30]=(br>>16)&0xff; hdr[31]=(br>>24)&0xff;
    hdr[32]=4; hdr[33]=0;   // block align
    hdr[34]=16; hdr[35]=0;  // 16 bits
    hdr[36]='d'; hdr[37]='a'; hdr[38]='t'; hdr[39]='a';
    hdr[40]=data_bytes&0xff; hdr[41]=(data_bytes>>8)&0xff; hdr[42]=(data_bytes>>16)&0xff; hdr[43]=(data_bytes>>24)&0xff;
    sc3(SYS_write, fd, (long)hdr, 44);

    // Save state and render offline
    float saved_ph = shm->playhead;
    zero_mem(arc_phase, sizeof(arc_phase));
    zero_mem(arc_env, sizeof(arc_env));
    zero_mem(delay_l, sizeof(delay_l));
    zero_mem(delay_r, sizeof(delay_r));
    delay_pos = 0;
    shm->playhead = 0.0f;

    int16_t buf[512 * 2];
    uint32_t rem = total_frames;
    while (rem > 0) {
        uint32_t chunk = rem > 512 ? 512 : rem;
        render_block(shm, buf, (int)chunk, (float)sr, 1);
        sc3(SYS_write, fd, (long)buf, (long)(chunk * 4));
        rem -= chunk;
    }
    sc1(SYS_close, fd);
    shm->playhead = saved_ph;
    shm->export_req = 2;
}

void main_entry(void) {
    init_builtin_waves();
    for (int i = 0; i < UPIC_MAX_ARCS; i++) gendyn_init(&arc_gd[i], 0x9e3779b9u * (uint32_t)(i + 1));
    gendyn_init(&live_gd, 0x7f4a7c15u);

    // Open & size shared memory file
    long sfd = sc4(SYS_openat, AT_FDCWD, (long)"/tmp/k78_upic.shm", O_RDWR | O_CREAT, 0666);
    if (sfd < 0) { log_num("upic: shm open failed ", sfd); sc1(SYS_exit_group, 1); }
    size_t shm_sz = (sizeof(struct upic_shm) + 4095) & ~4095UL;
    sc2(SYS_ftruncate, sfd, (long)shm_sz);
    long addr = sc6(SYS_mmap, 0, (long)shm_sz, PROT_RW, MAP_SHARED, sfd, 0);
    if (addr < 0 && addr >= -4095) { log_num("upic: shm mmap failed ", addr); sc1(SYS_exit_group, 2); }
    struct upic_shm *shm = (struct upic_shm *)addr;

    if (shm->magic != UPIC_MAGIC) {
        zero_mem(shm, sizeof(*shm));
        shm->magic = UPIC_MAGIC;
        shm->duration_sec = 8.0f;
        shm->loop = 1;
        shm->volume = 78;
        shm->reverb_mix = 0.35f;
        shm->gendyn_chaos = 35;
        shm->live_filter = 1.0f;
        shm->live_morph = 0.0f;
        shm->live_pan = 0.0f;
        shm->seek_req = -1.0f;
        for (int i = 0; i < UPIC_WT_SIZE; i++) {
            shm->custom_wt[i] = sine_wt[i];
            shm->custom_wt_b[i] = organ_wt[i];
        }
    }

    int last_vol = shm->volume;
    wm8904_set_mixer(last_vol);

    uint32_t sr = 48000, period = 256;
    int pfd = alsa_open_pcm(&sr, &period);
    if (pfd < 0) { sc1(SYS_exit_group, 3); }
    log_num("upic: ALSA ready sr=", sr);
    log_num("upic: period=", period);

    int16_t pcm_buf[1024 * 2];
    if (period > 1024) period = 256;

    while (!shm->quit) {
        if (shm->volume != last_vol) {
            last_vol = shm->volume;
            wm8904_set_mixer(last_vol);
        }
        if (shm->seek_req >= 0.0f) {
            shm->playhead = shm->seek_req;
            shm->seek_req = -1.0f;
        }
        if (shm->export_req == 1) {
            export_wav(shm, sr);
        }

        render_block(shm, pcm_buf, (int)period, (float)sr, 0);

        struct snd_xferi xfer;
        xfer.result = 0;
        xfer.buf = pcm_buf;
        xfer.frames = period;
        long wr = sc3(SYS_ioctl, pfd, SNDRV_PCM_IOCTL_WRITEI_FRAMES, (long)&xfer);
        if (wr < 0) {
            // Underrun (-EPIPE = -32) or suspend (-ESTRPIPE = -86): re-prepare cleanly
            sc3(SYS_ioctl, pfd, SNDRV_PCM_IOCTL_PREPARE, 0);
            sleep_ms(5);
        }
    }

    sc3(SYS_ioctl, pfd, SNDRV_PCM_IOCTL_DROP, 0);
    sc1(SYS_close, pfd);
    sc2(SYS_munmap, addr, (long)shm_sz);
    sc1(SYS_close, sfd);
    sc1(SYS_exit_group, 0);
}

__asm__(
    ".global _start\n"
    "_start:\n"
    "  bl main_entry\n"
);

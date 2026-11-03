/* c26_haltscan.c — steady-state GSP memory map + staging-leftover scan (C26 step 2).
 *
 * One halted session does everything:
 *   1. try one RDM on the RUNNING core (if accepted, no halt is needed at all)
 *   2. otherwise STOP the core (reboot required afterwards)
 *   3. calibration reads (known container addresses, boundaries, WPR bounds)
 *   4. grid probe of the runtime region to find readable ranges
 *   5. dump readable ranges (spin-poll RDM, budget-capped) to raw files
 *   6. inline tag scan for the bindata descriptor/trailer constants and the
 *      0xf900 code-load pairs; zero-span detection for the C25 scratch target
 *
 * Only the known ICD register block is written (0x1113d0 CMD/ADDR/RDATA,
 * STOP through the same CMD register) — identical registers to the existing
 * icd_* tools. The core is left HALTED on exit so c25_writeprobe can run.
 *
 * usage: c26_haltscan <bdf> <outdir> [dump_mb=32]
 * env:   GRID_LO=0x90000000 GRID_HI=0xa8000000 GRID_STEP=0x100000
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <time.h>
#include <sys/mman.h>
#include <sys/stat.h>

static volatile uint32_t *g;
#define R(off) (g[(off) / 4])
#define CMD R(0x1113d0)
#define ADDR0 R(0x1113d4)
#define ADDR1 R(0x1113d8)
#define RDATA0 R(0x1113e4)
#define RDATA1 R(0x1113e8)
#define CPUCTL R(0x111388)

static uint64_t GRID_LO, GRID_HI, GRID_STEP;

static int issue(uint32_t cmd)
{
    CMD = cmd;
    __sync_synchronize();
    for (int i = 0; i < 200; i++) {           /* spin ~100-400us */
        uint32_t v = CMD;
        if (!(v & 0x8000)) return (int)v;
    }
    for (int i = 0; i < 20; i++) {            /* fallback 20ms */
        usleep(1000);
        uint32_t v = CMD;
        if (!(v & 0x8000)) return (int)v;
    }
    return -1;
}

static int rdm8(uint64_t addr, uint64_t *out)
{
    ADDR0 = (uint32_t)addr;
    ADDR1 = (uint32_t)(addr >> 32);
    __sync_synchronize();
    int v = issue(0x000100ca);
    if (v < 0) return -2;
    if (v & 0x4000) return -1;
    *out = ((uint64_t)RDATA1 << 32) | RDATA0;
    return 0;
}

static const uint8_t TAG_A1[12]  = {0x00,0x07,0x30,0xed, 0x00,0x70,0x30,0xee, 0x00,0x03,0x30,0xce};
static const uint8_t TAG_APP[12] = {0x63,0x62,0x60,0x60, 0x60,0x01,0x62,0x46, 0x28,0x66,0xa2,0x90};
static const uint8_t TAG_TRL[12] = {0x3d,0xf4,0x35,0x9f, 0x04,0xfe,0x49,0x01, 0x90,0x99,0x1c,0xbf};

static int memfind(const uint8_t *buf, size_t n, const uint8_t *needle, size_t m, size_t *pos)
{
    if (n < m) return 0;
    for (size_t i = 0; i + m <= n; i += 4) {
        if (!memcmp(buf + i, needle, m)) { *pos = i; return 1; }
    }
    return 0;
}

static void scan_tags(const char *name, uint8_t *buf, size_t n, uint64_t va)
{
    size_t p, off = 0;
    int hits = 0;
    while (hits < 24 && memfind(buf + off, n - off, TAG_A1, 12, &p)) {
        printf("TAG A1-sig   %s va=%#llx +%#zx\n", name, (unsigned long long)(va + off + p), off + p);
        off += p + 4; hits++;
    }
    off = 0;
    while (hits < 24 && memfind(buf + off, n - off, TAG_APP, 12, &p)) {
        printf("TAG app-desc %s va=%#llx +%#zx\n", name, (unsigned long long)(va + off + p), off + p);
        off += p + 4; hits++;
    }
    off = 0;
    while (hits < 24 && memfind(buf + off, n - off, TAG_TRL, 12, &p)) {
        printf("TAG trailer  %s va=%#llx +%#zx\n", name, (unsigned long long)(va + off + p), off + p);
        off += p + 4; hits++;
    }
    /* 0xf900 code-load pairs */
    for (size_t i = 0; i + 8 <= n && hits < 40; i += 4) {
        uint32_t a = *(uint32_t *)(buf + i), s = *(uint32_t *)(buf + i + 4);
        if (a == 0xF900 && s >= 0x8000 && s <= 0x20000) {
            printf("TAG 0xf900   %s va=%#llx size=%#x\n", name, (unsigned long long)(va + i), s);
            hits++;
        }
    }
}

static size_t zero_spans(uint8_t *buf, size_t n, uint64_t va)
{
    size_t run = 0, spans = 0;
    for (size_t i = 0; i < n; i += 8) {
        int z = 1;
        for (size_t k = 0; k < 8; k++) if (buf[i + k]) { z = 0; break; }
        if (z) run += 8;
        else {
            if (run >= 0x400 && spans < 8) {
                printf("ZERO span    va=%#llx len=%#zx (C25 scratch candidate)\n",
                       (unsigned long long)(va + i - run), run);
                spans++;
            }
            run = 0;
        }
    }
    return spans;
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc < 3) { fprintf(stderr, "usage: %s <bdf> <outdir> [dump_mb]\n", argv[0]); return 2; }
    const char *bdf = argv[1], *outdir = argv[2];
    size_t dump_budget = (argc > 3) ? (size_t)atoll(argv[3]) << 20 : 32u << 20;
    GRID_LO  = strtoull(getenv("GRID_LO")  ? getenv("GRID_LO")  : "0x90000000", NULL, 0);
    GRID_HI  = strtoull(getenv("GRID_HI")  ? getenv("GRID_HI")  : "0xa8000000", NULL, 0);
    GRID_STEP= strtoull(getenv("GRID_STEP")? getenv("GRID_STEP"): "0x100000", NULL, 0);

    char path[256];
    snprintf(path, sizeof path, "/sys/bus/pci/devices/%s/resource0", bdf);
    int fd = open(path, O_RDWR);
    if (fd < 0) { perror(path); return 1; }
    void *m = mmap(NULL, 0x1000000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (m == MAP_FAILED) { perror("mmap"); return 1; }
    g = (volatile uint32_t *)m;
    mkdir(outdir, 0755);

    printf("# c26_haltscan bdf=%s out=%s budget=%zuMB\n", bdf, outdir, dump_budget >> 20);
    printf("pre: CPUCTL=%08x CMD=%08x RPCmirror=%08x\n", CPUCTL, CMD, R(0x1113ec));

    uint64_t v;
    int rc = rdm8(0x01400000, &v);
    printf("first RDM 0x01400000: rc=%d val=%016llx\n", rc, (unsigned long long)v);
    if (rc == 0) {
        printf("RDM accepted without a new STOP (running core or already halted)\n");
    } else if (getenv("SKIP_STOP")) {
        printf("SKIP_STOP set but RDM refused (CPUCTL=%08x); aborting\n", CPUCTL);
        return 1;
    } else {
        uint32_t pre = CPUCTL;
        printf("issuing STOP... (CPUCTL pre=%08x)\n", pre);
        issue(0x00000000);
        int halted = 0;
        for (int i = 0; i < 500; i++) {
            usleep(1000);
            uint32_t c = CPUCTL;
            /* documented halt signature: 0x2a0 -> 0x380 (bit8 set, bit5 clear) */
            if (((c & 0x100) && !(c & 0x20)) || ((c >> 4) & 1)) {
                printf("halt signature after %d ms (CPUCTL %08x -> %08x)\n", i + 1, pre, c);
                halted = 1;
                break;
            }
        }
        printf("post-stop: CPUCTL=%08x RPCmirror=%08x\n", CPUCTL, R(0x1113ec));
        rc = rdm8(0x01400000, &v);
        printf("halted RDM 0x01400000: rc=%d val=%016llx\n", rc, (unsigned long long)v);
        if (rc != 0) {
            printf("STOP issued but RDM still refused; aborting (card may need reboot)\n");
            return 1;
        }
        (void)halted;
    }

    /* ---- calibration + boundary grid ---- */
    static const uint64_t fixed[] = {
        0x00000000, 0x00E70FF8, 0x00E71000, 0x01000000, 0x013A0000, 0x01400000,
        0x01800000, 0x01DCD000, 0x02018000, 0x02018F000, 0x02039000, 0x020393000,
        0x02039008, 0x03000000, 0x04000000, 0x04004000, 0x041A0FF8, 0x053E5FF8,
        0x06000000, 0x08000000, 0x10000000, 0x40000000, 0x7FFFFFF8, 0x80000000,
        0x88000000, 0x13EC00000ULL, 0x7DD580000ULL, 0x7E72E0000ULL, 0x7F42C0000ULL,
        0x7FFFFFFF8ULL
    };
    printf("== calibration/boundary ==\n");
    for (size_t i = 0; i < sizeof fixed / sizeof *fixed; i++) {
        rc = rdm8(fixed[i], &v);
        printf("  %#011llx %s %016llx\n", (unsigned long long)fixed[i],
               rc == 0 ? "OK  " : rc == -1 ? "ERR " : "BUSY", (unsigned long long)v);
    }

    /* ---- runtime-region grid ---- */
    printf("== runtime grid %#llx..%#llx step %#llx ==\n",
           (unsigned long long)GRID_LO, (unsigned long long)GRID_HI, (unsigned long long)GRID_STEP);
    size_t npts = (GRID_HI - GRID_LO) / GRID_STEP + 1;
    uint8_t *ok = calloc(npts, 1);
    uint64_t *vals = calloc(npts, 8);
    for (size_t i = 0; i < npts; i++) {
        rc = rdm8(GRID_LO + i * GRID_STEP, &v);
        ok[i] = (rc == 0);
        vals[i] = v;
        if (ok[i]) printf("  +%zu %#011llx OK  %016llx\n", i, (unsigned long long)(GRID_LO + i * GRID_STEP), (unsigned long long)v);
    }
    /* merge into ranges: >=2 consecutive OK */
    typedef struct { uint64_t lo, hi; } Range;
    Range ranges[64]; size_t nr = 0;
    for (size_t i = 0; i < npts; ) {
        if (!ok[i]) { i++; continue; }
        size_t j = i;
        while (j + 1 < npts && ok[j + 1]) j++;
        if (j > i && nr < 64) {
            ranges[nr].lo = GRID_LO + i * GRID_STEP;
            ranges[nr].hi = GRID_LO + j * GRID_STEP + GRID_STEP;
            nr++;
        }
        i = j + 1;
    }
    printf("== readable runtime ranges ==\n");
    for (size_t i = 0; i < nr; i++)
        printf("  %#llx..%#llx (%zu MB)\n", (unsigned long long)ranges[i].lo,
               (unsigned long long)ranges[i].hi, (size_t)(ranges[i].hi - ranges[i].lo) >> 20);

    /* fallback: if the runtime grid is empty, dump the known-good code window */
    if (nr == 0) {
        printf("runtime grid empty; falling back to the 04.4 code window dump\n");
        if (nr < 64) { ranges[nr].lo = 0x01000000; ranges[nr].hi = 0x01DCD000; nr++; }
    }

    /* ---- dump phase ---- */
    printf("== dumps ==\n");
    size_t dumped = 0;
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    size_t reads = 0;
    for (size_t r = 0; r < nr && dumped < dump_budget; r++) {
        size_t len = (size_t)(ranges[r].hi - ranges[r].lo);
        if (len > dump_budget - dumped) len = dump_budget - dumped;
        uint8_t *buf = malloc(len);
        size_t got = 0;
        for (uint64_t a = ranges[r].lo; a + 8 <= ranges[r].lo + len; a += 8) {
            if (rdm8(a, &v)) break;
            memcpy(buf + got, &v, 8); got += 8; reads++;
            if ((got & 0xFFFFF) == 0) printf("  ...%#llx +%#zx\n", (unsigned long long)a, got);
        }
        char fn[512];
        snprintf(fn, sizeof fn, "%s/dump_%09llx_%zx.bin", outdir,
                 (unsigned long long)ranges[r].lo, got);
        FILE *f = fopen(fn, "wb");
        if (f) { setvbuf(f, NULL, _IONBF, 0); fwrite(buf, 1, got, f); fclose(f); }
        printf("dumped %#llx..%#llx (%#zx bytes) -> %s\n",
               (unsigned long long)ranges[r].lo, (unsigned long long)(ranges[r].lo + got), got, fn);
        scan_tags(fn, buf, got, ranges[r].lo);
        zero_spans(buf, got, ranges[r].lo);
        free(buf);
        dumped += got;
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double secs = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    printf("== dump rate: %zu reads / %.1fs (%.0f reads/s), %zu MB total ==\n",
           reads, secs, reads ? reads / secs : 0.0, dumped >> 20);

    printf("\nDONE. Core is %s. If halted: reboot when finished", "HALTED-ON-PURPOSE");
    printf(" (c25_writeprobe can still run first).\n");
    return 0;
}

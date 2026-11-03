/* session_a_poll.c — multi-register BAR0 poller for Session A (C05/C06).
 *
 * Read-only.  Samples the FEAT bank, the fuse security words, the FSP core
 * block, and the GSP core state directly through resource0.  Re-maps BAR0 on
 * every sample so a mapping held across unbind/FLR/bind cannot go stale.
 *
 * usage: session_a_poll <bdf> <interval_ms> <count>
 * output: CSV on stdout, one header row, then one row per sample.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/mman.h>

struct reg {
    const char *name;
    uint32_t    off;
};

static const struct reg regs[] = {
    /* FEAT bank: gate, selectors, readout */
    { "feat_plm",     0x00823804u },
    { "ss0",          0x0082381cu },
    { "ss1",          0x00823820u },
    { "readout1",     0x00823818u },
    /* Fuse security / speed words (C05) */
    { "fuse_38c",     0x0082038cu },
    { "fuse_3f0",     0x008203f0u },
    { "fuse_0d0",     0x008200d0u },
    { "fuse_0d4",     0x008200d4u },
    { "fuse_0d8",     0x008200d8u },
    { "fuse_0dc",     0x008200dcu },
    { "fuse_0f8",     0x008200f8u },
    { "fuse_0fc",     0x008200fcu },
    { "fuse_040",     0x00820040u },
    { "fuse_084",     0x00820084u },
    { "fuse_7d8",     0x008207d8u },
    /* FSP core block (C06) */
    { "fsp_hwcfg",    0x008f0108u },
    { "fsp_scratch",  0x008f0320u },
    { "fsp_ver",      0x008f032cu },
    { "fsp_engine",   0x008f03c0u },
    { "fsp_blkplm",   0x008f03c4u },
    { "fsp_status",   0x008f0a58u },
    { "fsp_config",   0x008f0a5cu },
    { "fsp_coreplm",  0x008f0a90u },
    { "fsp_const",    0x008f0ab0u },
    /* GSP core: engine, reset PLM, host PC mirror (boot marker) */
    { "gsp_engine",   0x001103c0u },
    { "gsp_rstplm",   0x001103c4u },
    { "gsp_pc",       0x001113ecu },
};

#define NREGS (sizeof(regs) / sizeof(regs[0]))

static void die(const char *msg)
{
    fprintf(stderr, "%s\n", msg);
    exit(2);
}

int main(int argc, char **argv)
{
    char path[256];
    int interval_ms, count, k;
    struct timespec t0, t;

    if (argc != 4)
        die("usage: session_a_poll <bdf> <interval_ms> <count>");

    snprintf(path, sizeof(path),
             "/sys/bus/pci/devices/%s/resource0", argv[1]);
    interval_ms = atoi(argv[2]);
    count = atoi(argv[3]);
    if (interval_ms < 1) interval_ms = 1;
    if (count < 1) count = 1;

    clock_gettime(CLOCK_MONOTONIC, &t0);

    printf("t_ms,wall_ms");
    for (size_t i = 0; i < NREGS; i++)
        printf(",%s", regs[i].name);
    printf("\n");
    fflush(stdout);

    for (k = 0; k < count; k++) {
        int fd;
        void *bar = MAP_FAILED;
        long ms, wall_ms;

        clock_gettime(CLOCK_MONOTONIC, &t);
        ms = (t.tv_sec - t0.tv_sec) * 1000L
           + (t.tv_nsec - t0.tv_nsec) / 1000000L;
        clock_gettime(CLOCK_REALTIME, &t);
        wall_ms = t.tv_sec * 1000L + t.tv_nsec / 1000000L;

        fd = open(path, O_RDONLY);
        if (fd >= 0) {
            bar = mmap(NULL, 0x1000000, PROT_READ, MAP_SHARED, fd, 0);
        }

        printf("%ld,%ld", ms, wall_ms);
        for (size_t i = 0; i < NREGS; i++) {
            uint32_t v = 0xffffffffu;
            if (bar != MAP_FAILED)
                v = *(volatile uint32_t *)((volatile char *)bar + regs[i].off);
            printf(",%#010x", v);
        }
        printf("\n");
        fflush(stdout);

        if (bar != MAP_FAILED)
            munmap(bar, 0x1000000);
        if (fd >= 0)
            close(fd);

        if (k + 1 < count) {
            struct timespec ts;
            ts.tv_sec = interval_ms / 1000;
            ts.tv_nsec = (long)(interval_ms % 1000) * 1000000L;
            nanosleep(&ts, NULL);
        }
    }
    return 0;
}

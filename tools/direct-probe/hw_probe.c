/*
 * hw_probe.c - read-only BAR0 probes for the BF16 investigation.
 *
 * Modes:
 *   read <off> <count>
 *   fecs
 *   falcon <base> <count>
 *   fspemem <count> <origfile>
 *   cms2 <start> <count> <origfile>
 *   restore <origfile>
 *
 * All addresses are BAR0 dword offsets.  Pointer/control registers only:
 *   - NV_PFSP_EMEMC(i)   (FSP EMEM channel read pointer)
 *   - NV_POOBHUB_RCV_INDIRECT_CMS2_MEM_RD_ADDR
 *   - the caller-supplied control pair for `stream`
 * Each is saved to <origfile> before the first write and restored at the end.
 *
 * Build: gcc -O2 -Wall -o hw_probe hw_probe.c
 * Run as root; set BDF to the target device (default 0000:41:00.0).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define BAR_SIZE 0x1000000u

#define PFSP_EMEMC(i) (0x008f2ac0u + 8u * (unsigned)(i))
#define PFSP_EMEMD(i) (0x008f2ac4u + 8u * (unsigned)(i))
#define PFSP_EMEM_CHANNELS 8u
#define PFSP_EMEM_AINCR 0x02000000u

#define CMS2_ADDR 0x008aa374u
#define CMS2_DATA 0x008aa378u

static volatile uint32_t *bar;
static const char *bdf = "0000:41:00.0";

static uint32_t rd(uint32_t off)
{
    return bar[off >> 2];
}

static void wr(uint32_t off, uint32_t val)
{
    bar[off >> 2] = val;
    __sync_synchronize();
}

static int open_bar(void)
{
    char path[256];
    int fd;
    void *p;

    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/resource0", bdf);
    fd = open(path, O_RDWR);
    if (fd < 0) {
        fprintf(stderr, "open %s: %s\n", path, strerror(errno));
        return -1;
    }
    p = mmap(NULL, BAR_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) {
        fprintf(stderr, "mmap %s: %s\n", path, strerror(errno));
        close(fd);
        return -1;
    }
    bar = (volatile uint32_t *)p;
    close(fd);
    return 0;
}

static void print_range(uint32_t base, uint32_t count, const char *tag)
{
    uint32_t i;
    uint32_t nz = 0, sent = 0;

    printf("== %s base=%#010x count=%u ==\n", tag, base, count);
    for (i = 0; i < count; i++) {
        uint32_t off = base + 4u * i;
        uint32_t v = rd(off);
        printf("%08x %08x\n", off, v);
        if (v != 0)
            nz++;
        if ((v >> 16) == 0xbadfu)
            sent++;
    }
    printf("== %s summary: %u/%u nonzero, %u badf-sentinel ==\n", tag, nz, count, sent);
}

static void fecs(void)
{
    static const struct { uint32_t off; const char *name; } labels[] = {
        { 0x409000, "FECS block base" },
        { 0x409008, "FECS IRQSTAT?" },
        { 0x409044, "FECS 0x409044" },
        { 0x409108, "FECS HWCFG?" },
        { 0x409180, "FECS IMEMC/D?" },
        { 0x409184, "FECS IMEM data?" },
        { 0x4091c0, "FECS DMEMC/D?" },
        { 0x4091c4, "FECS DMEM data?" },
        { 0x4093c0, "FECS ENGINE?" },
        { 0x4093c4, "FECS PLM?" },
        { 0x409638, "FECS 0x409638" },
        { 0x409660, "FECS 0x409660 (feature)" },
        { 0x409664, "FECS 0x409664 (selector copy?)" },
        { 0x409668, "FECS 0x409668 (selector copy? = 0x9668)" },
        { 0x409800, "FECS 0x409800" },
        { 0x409ac0, "FECS EMEMC?" },
        { 0x409ac4, "FECS EMEMD?" },
        { 0x409b00, "FECS 0x409b00 (DP path?)" },
        { 0x409b04, "FECS 0x409b04" },
        { 0x409b78, "FECS 0x409b78 (DP path?)" },
        { 0x409b84, "FECS 0x409b84 (PLM?)" },
    };
    size_t i;

    print_range(0x409000, 0x400, "FECS 0x409000-0x409fff");
    printf("== FECS labelled registers ==\n");
    for (i = 0; i < sizeof(labels) / sizeof(labels[0]); i++)
        printf("%08x %08x  %s\n", labels[i].off, rd(labels[i].off), labels[i].name);
}

static void falcon(uint32_t base, uint32_t count)
{
    print_range(base, count, "Falcon/block range");
}

static void fspemem(uint32_t count, const char *origfile)
{
    uint32_t orig[PFSP_EMEM_CHANNELS];
    uint32_t i, k;
    FILE *of;

    of = fopen(origfile, "a");
    if (of == NULL) {
        fprintf(stderr, "open %s: %s\n", origfile, strerror(errno));
        return;
    }
    for (i = 0; i < PFSP_EMEM_CHANNELS; i++) {
        orig[i] = rd(PFSP_EMEMC(i));
        fprintf(of, "FSPEMEM %u %08x\n", i, orig[i]);
    }
    fflush(of);
    fclose(of);

    printf("== FSP EMEM saved EMEMC:");
    for (i = 0; i < PFSP_EMEM_CHANNELS; i++)
        printf(" ch%u=%08x", i, orig[i]);
    printf("\n");

    /* Non-RM channels first, active RM channel 0 last. */
    for (i = 1; i <= PFSP_EMEM_CHANNELS; i++) {
        uint32_t ch = i % PFSP_EMEM_CHANNELS;
        uint32_t nz = 0;
        uint32_t ctl0, ctl1;

        printf("== FSP EMEM channel %u (orig EMEMC=%08x) ==\n", ch, orig[ch]);
        wr(PFSP_EMEMC(ch), PFSP_EMEM_AINCR);
        ctl0 = rd(PFSP_EMEMC(ch));
        printf("   EMEMC armed=%08x (AINCR=%u)\n", ctl0, (ctl0 >> 25) & 1u);

        for (k = 0; k < count; k++) {
            uint32_t v = rd(PFSP_EMEMD(ch));
            printf("   [%3u] %08x\n", k, v);
            if (v != 0)
                nz++;
        }
        ctl1 = rd(PFSP_EMEMC(ch));
        printf("   EMEMC after reads=%08x  nonzero=%u/%u\n", ctl1, nz, count);

        wr(PFSP_EMEMC(ch), orig[ch]);
        printf("   EMEMC restored=%08x\n", rd(PFSP_EMEMC(ch)));
    }
}

static void cms2(uint32_t start, uint32_t count, const char *origfile)
{
    uint32_t orig, i, nz = 0;
    FILE *of;

    of = fopen(origfile, "a");
    if (of == NULL) {
        fprintf(stderr, "open %s: %s\n", origfile, strerror(errno));
        return;
    }
    orig = rd(CMS2_ADDR);
    fprintf(of, "CMS2 %08x\n", orig);
    fflush(of);
    fclose(of);

    printf("== CMS2 indirect read: orig ADDR=%08x, start=%#x count=%u ==\n",
           orig, start, count);
    for (i = 0; i < count; i++) {
        uint32_t addr = start + i;
        uint32_t v;

        wr(CMS2_ADDR, addr);
        __sync_synchronize();
        v = rd(CMS2_DATA);
        printf("%08x %08x\n", addr, v);
        if (v != 0)
            nz++;
    }
    wr(CMS2_ADDR, orig);
    printf("== CMS2 summary: nonzero=%u/%u, ADDR restored=%08x ==\n",
           nz, count, rd(CMS2_ADDR));
}

static void stream(uint32_t ctrlo, uint32_t datao, uint32_t count,
                   const char *origfile, const char *label)
{
    FILE *of;
    uint32_t orig, ctl0, ctl1, k, nz = 0;

    of = fopen(origfile, "a");
    if (of == NULL) {
        fprintf(stderr, "open %s: %s\n", origfile, strerror(errno));
        return;
    }
    orig = rd(ctrlo);
    fprintf(of, "CTRL %08x %08x\n", ctrlo, orig);
    fflush(of);
    fclose(of);

    printf("== %s stream ctrl=%#010x data=%#010x orig=%08x count=%u ==\n",
           label, ctrlo, datao, orig, count);
    wr(ctrlo, 0x02000000u);            /* AINCR, offset 0, block 0 */
    ctl0 = rd(ctrlo);
    printf("   ctrl armed=%08x (AINCR=%u)\n", ctl0, (ctl0 >> 25) & 1u);

    for (k = 0; k < count; k++) {
        uint32_t v = rd(datao);
        printf("   [%4u] %08x\n", k, v);
        if (v != 0)
            nz++;
    }

    ctl1 = rd(ctrlo);
    printf("   ctrl after reads=%08x nonzero=%u/%u\n", ctl1, nz, count);
    wr(ctrlo, orig);
    printf("   ctrl restored=%08x\n", rd(ctrlo));
}

static void restore(const char *origfile)
{
    FILE *f;
    char line[128];

    f = fopen(origfile, "r");
    if (f == NULL) {
        fprintf(stderr, "restore: open %s: %s\n", origfile, strerror(errno));
        return;
    }
    printf("== restore from %s ==\n", origfile);
    while (fgets(line, sizeof(line), f) != NULL) {
        unsigned ch, val, off;
        if (sscanf(line, "FSPEMEM %u %x", &ch, &val) == 2 && ch < PFSP_EMEM_CHANNELS) {
            wr(PFSP_EMEMC(ch), val);
            printf("   FSP EMEMC[%u] := %08x (readback %08x)\n",
                   ch, val, rd(PFSP_EMEMC(ch)));
        } else if (sscanf(line, "CMS2 %x", &val) == 1) {
            wr(CMS2_ADDR, val);
            printf("   CMS2 ADDR := %08x (readback %08x)\n", val, rd(CMS2_ADDR));
        } else if (sscanf(line, "CTRL %x %x", &off, &val) == 2) {
            wr(off, val);
            printf("   CTRL %08x := %08x (readback %08x)\n", off, val, rd(off));
        }
    }
    fclose(f);
}

int main(int argc, char **argv)
{
    const char *mode;
    const char *env;

    env = getenv("BDF");
    if (env != NULL && env[0] != '\0')
        bdf = env;

    if (argc < 2) {
        fprintf(stderr,
                "usage: %s read <off> <count> | fecs | falcon <base> <count>\n"
                "       %s fspemem <count> <origfile> | cms2 <start> <count> <origfile>\n"
                "       %s stream <ctrlo> <datao> <count> <origfile> <label>\n"
                "       %s restore <origfile>\n",
                argv[0], argv[0], argv[0], argv[0]);
        return 2;
    }
    mode = argv[1];

    if (strcmp(mode, "restore") == 0) {
        if (argc < 3) {
            fprintf(stderr, "restore needs <origfile>\n");
            return 2;
        }
        if (open_bar() < 0)
            return 1;
        restore(argv[2]);
        return 0;
    }

    if (open_bar() < 0)
        return 1;

    if (strcmp(mode, "read") == 0 && argc >= 4) {
        print_range((uint32_t)strtoul(argv[2], NULL, 0),
                    (uint32_t)strtoul(argv[3], NULL, 0), "read");
    } else if (strcmp(mode, "fecs") == 0) {
        fecs();
    } else if (strcmp(mode, "falcon") == 0 && argc >= 4) {
        falcon((uint32_t)strtoul(argv[2], NULL, 0),
               (uint32_t)strtoul(argv[3], NULL, 0));
    } else if (strcmp(mode, "fspemem") == 0 && argc >= 4) {
        fspemem((uint32_t)strtoul(argv[2], NULL, 0), argv[3]);
    } else if (strcmp(mode, "cms2") == 0 && argc >= 5) {
        cms2((uint32_t)strtoul(argv[2], NULL, 0),
             (uint32_t)strtoul(argv[3], NULL, 0), argv[4]);
    } else if (strcmp(mode, "stream") == 0 && argc >= 7) {
        stream((uint32_t)strtoul(argv[2], NULL, 0),
               (uint32_t)strtoul(argv[3], NULL, 0),
               (uint32_t)strtoul(argv[4], NULL, 0), argv[5], argv[6]);
    } else {
        fprintf(stderr, "bad mode/args\n");
        return 2;
    }
    return 0;
}

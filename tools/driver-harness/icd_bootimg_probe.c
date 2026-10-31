/* icd_bootimg_probe.c — E67-style post-boot GSP halt + boot-image RDM probe.
 *
 * The E67 halt (fully booted GSP-RM, core idle) is the only state in which
 * RDM has been observed to work.  This tool reproduces it and probes for the
 * decrypted GspRmBoot image seen executing at 0xefd00000 during boot
 * (0x47000 bytes, matching WprMeta bootloader size 290816).
 *
 * Address hypotheses:
 *   0xEFD00000   boot-image address as observed in the PC mirror (physical
 *                or identity VA)
 *   0x5DD00000   0xEFD00000 - 0x92000000 (GSP-RM relocation hypothesis)
 *   0x181D00000  0xEFD00000 + 0x92000000
 *   0x01000000   GSP-RM code segment: positive control (ELF magic)
 *   0x00000000   negative control
 *
 * THIS HALTS THE GSP.  The GPU needs a reboot afterwards.  If the core does
 * not halt, the probes are rejected (0xbadfbadf) and the machine is fine.
 *
 * usage: icd_bootimg_probe <bdf> [dumpfile]
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>

static volatile uint32_t *g;
#define R(off) (g[(off) / 4])

#define CMD      0x1113d0u
#define ADDR0    0x1113d4u
#define ADDR1    0x1113d8u
#define RDATA0   0x1113e4u
#define RDATA1   0x1113e8u
#define CPUCTL   0x111388u
#define PCMIRR   0x1113ecu

static int issue(uint32_t cmd, uint32_t *pcmd, int poll_ms)
{
    int i;
    uint32_t v;
    R(CMD) = cmd;
    __sync_synchronize();
    for (i = 0; i < poll_ms; i++) {
        usleep(1000);
        v = R(CMD);
        if (!(v & 0x8000u)) {
            if (pcmd) *pcmd = v;
            return (int)((v >> 14) & 1u);
        }
    }
    if (pcmd) *pcmd = R(CMD);
    return -1;
}

static int rdm(uint64_t addr, int size, uint64_t *val)
{
    int shift = (size == 8) ? 3 : (size == 4) ? 2 : (size == 2) ? 1 : 0;
    uint32_t cmd = 0x0au | ((uint32_t)shift << 6) | (1u << 16);
    uint32_t c = 0;
    int err;

    R(ADDR1) = (uint32_t)(addr >> 32);
    R(ADDR0) = (uint32_t)addr;
    __sync_synchronize();
    err = issue(cmd, &c, 50);
    if (val)
        *val = ((uint64_t)R(RDATA1) << 32) | R(RDATA0);
    return err;
}

int main(int argc, char **argv)
{
    const char *bdf;
    const char *dump_path;
    char path[256];
    int fd, i;
    void *m;
    uint32_t v = 0, cpuctl, pc;
    uint64_t rpc, ra, sp;
    static const struct { uint64_t a; const char *name; } probes[] = {
        { 0x00000000ULL, "negative control" },
        { 0x01000000ULL, "GSP-RM code (control)" },
        { 0xEFD00000ULL, "boot image, plain" },
        { 0xEFD00170ULL, "boot image, +0x170" },
        { 0xEFD40000ULL, "boot image, +0x40000" },
        { 0x5DD00000ULL, "boot image, -0x92000000" },
        { 0x5DD40000ULL, "boot image, -0x91c00000" },
        { 0x181D00000ULL, "boot image, +0x92000000" },
        { 0x04000000ULL, "GSP-RM data segment" },
        { 0x96000000ULL, "GSP-RM data runtime" },
    };
    uint64_t dump_base = 0;

    if (argc < 2) { fprintf(stderr, "usage: %s <bdf> [dumpfile]\n", argv[0]); return 2; }
    setvbuf(stdout, NULL, _IONBF, 0);
    bdf = argv[1];
    dump_path = (argc > 2) ? argv[2] : "postboot.bin";

    snprintf(path, sizeof path, "/sys/bus/pci/devices/%s/resource0", bdf);
    fd = open(path, O_RDWR);
    if (fd < 0) { perror(path); return 1; }
    m = mmap(NULL, 0x1000000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (m == MAP_FAILED) { perror("mmap"); return 1; }
    g = (volatile uint32_t *)m;

    printf("before: CPUCTL=0x%08x PC=0x%08x CMD=0x%08x\n",
           R(CPUCTL), R(PCMIRR), R(CMD));

    printf("issuing STOP...\n");
    (void)issue(0x00000000u, &v, 100);
    usleep(1000);
    cpuctl = R(CPUCTL);
    pc = R(PCMIRR);
    printf("stop:   CPUCTL=0x%08x (halt[4]=%u active[7]=%u) PC=0x%08x CMD=0x%08x\n",
           cpuctl, (cpuctl >> 4) & 1u, (cpuctl >> 7) & 1u, pc, R(CMD));

    (void)issue(0x00000012u, &v, 50);
    rpc = ((uint64_t)R(RDATA1) << 32) | R(RDATA0);
    (void)issue(0x00000108u, &v, 50);
    ra = ((uint64_t)R(RDATA1) << 32) | R(RDATA0);
    (void)issue(0x00000208u, &v, 50);
    sp = ((uint64_t)R(RDATA1) << 32) | R(RDATA0);
    printf("rpc=0x%016llx ra=0x%016llx sp=0x%016llx\n",
           (unsigned long long)rpc, (unsigned long long)ra,
           (unsigned long long)sp);

    printf("probes:\n");
    for (i = 0; i < (int)(sizeof(probes) / sizeof(probes[0])); i++) {
        uint64_t val = 0;
        int err = rdm(probes[i].a, 8, &val);
        printf("  0x%09llx %-26s err=%d val=0x%016llx%s\n",
               (unsigned long long)probes[i].a, probes[i].name, err,
               (unsigned long long)val,
               (!err && (val & 0xffffffffULL) == 0x464c457fULL) ? "  <ELF" : "");
        if (err == 0 && probes[i].a != 0x01000000ULL &&
            probes[i].a != 0x04000000ULL && probes[i].a != 0x96000000ULL &&
            dump_base == 0)
            dump_base = probes[i].a;
    }

    if (dump_base) {
        FILE *f = fopen(dump_path, "wb");
        uint64_t val;
        uint64_t off;
        int err = 0;

        if (!f) {
            perror(dump_path);
        } else {
            for (off = 0; off < 0x48000ULL; off += 8) {
                err = rdm(dump_base + off, 8, &val);
                if (err) break;
                fwrite(&val, 8, 1, f);
            }
            fclose(f);
            chmod(dump_path, 0644);
            printf("dump: base=0x%llx written=0x%llx err=%d -> %s\n",
                   (unsigned long long)dump_base, (unsigned long long)off,
                   err, dump_path);
        }
    } else {
        printf("dump: no working boot-image candidate\n");
    }

    printf("done; core halted. Reboot required.\n");
    return 0;
}

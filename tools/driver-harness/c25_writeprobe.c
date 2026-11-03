/* c25_writeprobe.c — ICD write-opcode probe (C25), run while the core is HALTED
 * by c26_haltscan (same session, before the reboot).
 *
 * Known opcodes: 0x00 STOP, 0x08 RREG, 0x0a RDM, 0x0e RSTAT, 0x12 RPC.
 * This probes the unassigned opcodes around them as write candidates: write a
 * marker into WDATA (RDATA regs), set ADDR to a zero-span scratch address,
 * issue the candidate, then RDM the address back. A landed marker is a
 * code/data-modification primitive at PL2; a refusal closes the port.
 *
 * usage: c25_writeprobe <bdf> <scratch_addr_hex>
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <sys/mman.h>

static volatile uint32_t *g;
#define CMD   g[0x1113d0 / 4]
#define ADDR0 g[0x1113d4 / 4]
#define ADDR1 g[0x1113d8 / 4]
#define RDATA0 g[0x1113e4 / 4]
#define RDATA1 g[0x1113e8 / 4]
#define CPUCTL g[0x111388 / 4]

static int issue(uint32_t cmd)
{
    CMD = cmd;
    __sync_synchronize();
    for (int i = 0; i < 200; i++) {
        uint32_t v = CMD;
        if (!(v & 0x8000)) return (int)v;
    }
    for (int i = 0; i < 20; i++) {
        usleep(1000);
        uint32_t v = CMD;
        if (!(v & 0x8000)) return (int)v;
    }
    return -1;
}

static int rdm8(uint64_t a, uint64_t *out)
{
    ADDR0 = (uint32_t)a; ADDR1 = (uint32_t)(a >> 32);
    __sync_synchronize();
    int v = issue(0x000100ca);
    if (v < 0 || (v & 0x4000)) return -1;
    *out = ((uint64_t)RDATA1 << 32) | RDATA0;
    return 0;
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc < 3) { fprintf(stderr, "usage: %s <bdf> <scratch_addr_hex>\n", argv[0]); return 2; }
    char path[256];
    snprintf(path, sizeof path, "/sys/bus/pci/devices/%s/resource0", argv[1]);
    int fd = open(path, O_RDWR);
    if (fd < 0) { perror(path); return 1; }
    void *m = mmap(NULL, 0x1000000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (m == MAP_FAILED) { perror("mmap"); return 1; }
    g = (volatile uint32_t *)m;
    uint64_t scratch = strtoull(argv[2], NULL, 16);

    if (!((CPUCTL >> 4) & 1)) {
        printf("WARNING: core does not report HALTED (CPUCTL=%08x); proceeding anyway\n", CPUCTL);
    }
    uint64_t before;
    if (rdm8(scratch, &before)) { printf("scratch read failed; abort\n"); return 1; }
    printf("scratch %#llx before=%016llx\n", (unsigned long long)scratch, (unsigned long long)before);
    if (before != 0)
        printf("WARNING: scratch is not zero; pick a ZERO-span address from haltscan\n");

    static const uint32_t cand[] = {
        0x0b, 0x0c, 0x0d, 0x0f, 0x10, 0x11, 0x13, 0x14,
        0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c,
        0x09, 0x07, 0x06, 0x05, 0x2a, 0x4a, 0x8a, 0xca
    };
    for (size_t i = 0; i < sizeof cand / sizeof *cand; i++) {
        uint64_t marker = 0xC25C25C25C250000ULL + i;
        ADDR0 = (uint32_t)scratch; ADDR1 = (uint32_t)(scratch >> 32);
        RDATA0 = (uint32_t)marker; RDATA1 = (uint32_t)(marker >> 32);
        __sync_synchronize();
        int v = issue((cand[i] | (3u << 6) | (1u << 16)));  /* size-8 variant + PARM */
        uint64_t after = 0;
        int rr = rdm8(scratch, &after);
        printf("op=%02x  status=%s  readback=%s %016llx%s\n", cand[i],
               v < 0 ? "BUSY" : (v & 0x4000) ? "ERR" : "OK",
               rr ? "?" : " ",
               (unsigned long long)after,
               (rr == 0 && after == marker) ? "   <<< WRITE LANDED" : "");
        if (rr == 0 && after == marker) {
            printf("WRITE PRIMITIVE at opcode %#x; restoring zero\n", cand[i]);
            RDATA0 = 0; RDATA1 = 0;
            __sync_synchronize();
            issue((cand[i] | (3u << 6) | (1u << 16)));
            rdm8(scratch, &after);
            printf("restored: %016llx\n", (unsigned long long)after);
        }
    }
    printf("done (core still halted; reboot when finished)\n");
    return 0;
}

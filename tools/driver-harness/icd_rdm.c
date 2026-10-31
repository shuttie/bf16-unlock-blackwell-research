/* icd_rdm.c — single PRISCV ICD RDM (debug memory read).
 *
 * Non-halting attempt: RDM may use the debug module's memory path and work
 * on a running core, or may require a halted hart (then ERROR is set and
 * RDATA returns the 0xbadfbadf sentinel, as RREG/RCSR did).
 *
 * Writes ADDR0/ADDR1, issues CMD once, polls BUSY, prints RDATA.
 * Restores only ADDR (safe latches). Never writes STOP.
 *
 * usage: icd_rdm <bdf> <addr_hex> <size 1|2|4|8> [base_hex=1113d0] [poll_ms=20]
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

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s <bdf> <addr_hex> <size 1|2|4|8> [base_hex] [poll_ms]\n", argv[0]);
        return 2;
    }
    const char *bdf = argv[1];
    uint64_t addr = strtoull(argv[2], NULL, 16);
    unsigned size = (unsigned)strtoul(argv[3], NULL, 0);
    uint32_t base = (argc > 4) ? (uint32_t)strtoul(argv[4], NULL, 16) : 0x1113d0u;
    int poll_ms   = (argc > 5) ? atoi(argv[5]) : 20;

    int shift;
    switch (size) {
        case 1: shift = 0; break;
        case 2: shift = 1; break;
        case 4: shift = 2; break;
        case 8: shift = 3; break;
        default: fprintf(stderr, "size must be 1,2,4,8\n"); return 2;
    }
    if (addr & (size - 1)) {
        fprintf(stderr, "address %#llx not aligned to size %u\n",
                (unsigned long long)addr, size);
        return 2;
    }

    char path[256];
    snprintf(path, sizeof path, "/sys/bus/pci/devices/%s/resource0", bdf);
    int fd = open(path, O_RDWR);
    if (fd < 0) { perror(path); return 1; }
    volatile uint8_t *bar = mmap(NULL, 0x1000000, PROT_READ | PROT_WRITE,
                                 MAP_SHARED, fd, 0);
    if (bar == MAP_FAILED) { perror("mmap"); close(fd); return 1; }

    volatile uint32_t *reg    = (volatile uint32_t *)bar;
    volatile uint32_t *cmdreg = reg + base / 4;
    volatile uint32_t *addr0  = reg + (base + 0x04) / 4;
    volatile uint32_t *addr1  = reg + (base + 0x08) / 4;
    volatile uint32_t *rdata0 = reg + (base + 0x14) / 4;
    volatile uint32_t *rdata1 = reg + (base + 0x18) / 4;

    uint32_t cmd = 0x0a | ((uint32_t)shift << 6) | (1u << 16);

    printf("RDM addr=%#llx size=%u -> CMD=%#010x (before CMD=%#010x)\n",
           (unsigned long long)addr, size, cmd, *cmdreg);

    *addr1 = (uint32_t)(addr >> 32);
    *addr0 = (uint32_t)addr;
    __sync_synchronize();
    *cmdreg = cmd;
    __sync_synchronize();

    for (int i = 0; i < poll_ms; i++) {
        usleep(1000);
        uint32_t v = *cmdreg;
        if (!(v & 0x8000)) {
            uint64_t val = ((uint64_t)*rdata1 << 32) | *rdata0;
            printf("  idle %dms CMD=%#010x BUSY=%u ERROR=%u RDATA=%#018llx%s\n",
                   i + 1, v, (v >> 15) & 1, (v >> 14) & 1,
                   (unsigned long long)val,
                   ((v >> 14) & 1) ? "  (rejected/sentinel)" : "");
            goto done;
        }
    }
    printf("  STILL BUSY after %d ms: CMD=%#010x\n", poll_ms, *cmdreg);

done:
    *addr0 = 0;
    *addr1 = 0;
    __sync_synchronize();
    munmap((void *)bar, 0x1000000);
    close(fd);
    return 0;
}

/* icd_cmd.c — single-shot PRISCV ICD command, no restore.
 *
 * Writes ICD_CMD once (restoring to 0 would be opcode STOP), then polls the
 * BUSY bit and dumps RDATA. Prints only; performs no other writes.
 *
 * usage: icd_cmd <bdf> <cmd_hex> [base_hex=1113d0] [poll_ms=20]
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
    if (argc < 3) {
        fprintf(stderr, "usage: %s <bdf> <cmd_hex> [base_hex] [poll_ms]\n", argv[0]);
        return 2;
    }
    const char *bdf = argv[1];
    uint32_t cmd  = (uint32_t)strtoul(argv[2], NULL, 16);
    uint32_t base = (argc > 3) ? (uint32_t)strtoul(argv[3], NULL, 16) : 0x1113d0u;
    int poll_ms   = (argc > 4) ? atoi(argv[4]) : 20;

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

    printf("base=%#x before: CMD=%#010x ADDR0=%#010x ADDR1=%#010x RDATA0=%#010x RDATA1=%#010x\n",
           base, *cmdreg, *addr0, *addr1, *rdata0, *rdata1);
    printf("issuing CMD=%#010x (OPC=%#x IDX=%u SZ=%u)\n",
           cmd, cmd & 0x1f, (cmd >> 8) & 0x1f, (cmd >> 6) & 3);

    *cmdreg = cmd;
    __sync_synchronize();

    for (int i = 0; i < poll_ms; i++) {
        usleep(1000);
        uint32_t v = *cmdreg;
        if (!(v & 0x8000)) {                     /* BUSY([15]) clear */
            printf("idle after %d ms: CMD=%#010x BUSY=%u ERROR=%u RDATA0=%#010x RDATA1=%#010x\n",
                   i + 1, v, (v >> 15) & 1, (v >> 14) & 1, *rdata0, *rdata1);
            goto done;
        }
    }
    printf("STILL BUSY after %d ms: CMD=%#010x (core may be hung)\n",
           poll_ms, *cmdreg);

done:
    printf("final: CMD=%#010x ADDR0=%#010x ADDR1=%#010x RDATA0=%#010x RDATA1=%#010x\n",
           *cmdreg, *addr0, *addr1, *rdata0, *rdata1);
    munmap((void *)bar, 0x1000000);
    close(fd);
    return 0;
}

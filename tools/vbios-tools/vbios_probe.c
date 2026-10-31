/*
 * vbios_probe.c - read-only probes of the vBIOS access path.
 *
 *  1. Reads the PBUS scratch register used for the global ERoT grant
 *     (NV_PBUS_SW_GLOBAL_EROT_GRANT = NV_PBUS_SW_SCRATCH(0) = 0x1400):
 *       bit 3 = VALID (an ERoT exists), bit 4 = REQUEST, bit 5 = ALLOW.
 *  2. Reads the PROM window head at NV_PROM_DATA(0) = 0x300000.
 *  3. Scans a BAR0 range for the 0xAA55 ROM signature and for the exact
 *     8-byte prefix of the dumped vBIOS.
 *
 * Everything is PROT_READ; nothing is written.
 *
 * Build: gcc -O2 -Wall -o vbios_probe vbios_probe.c
 * Usage: vbios_probe <bdf> [scan_start_hex] [scan_len_hex]
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define BAR0_SIZE 0x4000000UL

static const unsigned char magic[8] = {0x55, 0xaa, 0x7d, 0xeb, 0x4b, 0x37, 0x34, 0x30};

int main(int argc, char **argv)
{
    char path[256];
    volatile unsigned char *bar0;
    unsigned long start = 0x300000, len = 0x100000, off;
    int fd, hits = 0;

    if (argc < 2) {
        fprintf(stderr, "usage: %s <bdf> [scan_start_hex] [scan_len_hex]\n", argv[0]);
        return 2;
    }
    if (argc > 2)
        start = strtoul(argv[2], NULL, 16);
    if (argc > 3)
        len = strtoul(argv[3], NULL, 16);

    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/resource0", argv[1]);
    fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        fprintf(stderr, "open %s: %s\n", path, strerror(errno));
        return 1;
    }
    bar0 = mmap(NULL, BAR0_SIZE, PROT_READ, MAP_SHARED, fd, 0);
    if (bar0 == MAP_FAILED) {
        fprintf(stderr, "mmap %s: %s\n", path, strerror(errno));
        close(fd);
        return 1;
    }

    {
        uint32_t grant = *(volatile uint32_t *)(bar0 + 0x1400);
        printf("NV_PBUS_SW_GLOBAL_EROT_GRANT (0x1400) = %#010x  VALID=%u REQUEST=%u ALLOW=%u\n",
               grant, (grant >> 3) & 1, (grant >> 4) & 1, (grant >> 5) & 1);
    }

    printf("NV_PROM_DATA head:\n");
    for (off = 0; off < 0x20; off += 4)
        printf("  +%#06lx = %#010x\n", off, *(volatile uint32_t *)(bar0 + 0x300000 + off));

    printf("scan %#lx..%#lx step 4096 for 55AA / magic:\n", start, start + len);
    for (off = start; off + 32 <= start + len; off += 0x1000) {
        volatile unsigned char *p = bar0 + off;
        if (p[0] == 0x55 && p[1] == 0xaa) {
            printf("  55AA @ %#lx: %02x %02x %02x %02x %02x %02x %02x %02x\n",
                   off, p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7]);
            hits++;
        }
        if (memcmp((const void *)p, magic, sizeof(magic)) == 0) {
            printf("  MAGIC @ %#lx\n", off);
            hits++;
        }
    }
    printf("scan done, %d hit(s)\n", hits);

    munmap((void *)bar0, BAR0_SIZE);
    close(fd);
    return 0;
}

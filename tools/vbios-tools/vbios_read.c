/*
 * vbios_read.c - read-only dump of the vBIOS image in the BAR0 PROM aperture.
 *
 * The PCI expansion ROM BAR only exposes the images linked into the PCI ROM
 * chain (PciAt + EFI on GB202, 0x27A00 bytes). The flash itself is mapped at
 * NV_PROM_DATA(0) = BAR0 + 0x300000, 1 MB, but the vBIOS image does not start
 * at the aperture base: on GB202 it is at BAR0 + 0x338000 (a 0x38000 head).
 * If the given offset does not hold a 0x55AA signature the tool scans the
 * aperture and uses the first hit.
 *
 * Build:  gcc -O2 -Wall -o vbios_read vbios_read.c
 * Usage:  vbios_read <bdf> <outfile> [bar0_offset_hex] [size_hex]
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define PROM_BASE  0x00300000UL   /* NV_PROM_DATA(0) */
#define PROM_SIZE  0x00200000UL   /* measured: the flash runs past the 1 MB documented window */
#define VBIOS_OFF  0x00338000UL   /* vBIOS image start inside the aperture */
#define PROM_END   (PROM_BASE + PROM_SIZE)

static const unsigned char magic[8] = {0x55, 0xaa, 0x7d, 0xeb, 0x4b, 0x37, 0x34, 0x30};

int main(int argc, char **argv)
{
    char path[256];
    unsigned char *map;
    unsigned char *buf;
    unsigned long off = VBIOS_OFF;
    unsigned long size = 0x00100000UL;   /* driver's s_getBaseBiosMaxSize_TU102 */
    unsigned long a;
    uint32_t sum = 0;
    size_t i;
    int fd, out, found = 0;
    ssize_t n;

    if (argc < 3 || argc > 5) {
        fprintf(stderr, "usage: %s <bdf> <outfile> [bar0_offset_hex] [size_hex]\n"
                        "  default offset %#lx, size 0x100000 (max %#lx)\n",
                argv[0], VBIOS_OFF, PROM_END - VBIOS_OFF);
        return 2;
    }
    if (argc > 3)
        off = strtoul(argv[3], NULL, 16);
    if (argc > 4)
        size = strtoul(argv[4], NULL, 16);

    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/resource0", argv[1]);
    fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        fprintf(stderr, "open %s: %s\n", path, strerror(errno));
        return 1;
    }
    map = mmap(NULL, PROM_SIZE, PROT_READ, MAP_SHARED, fd, (off_t)PROM_BASE);
    if (map == MAP_FAILED) {
        fprintf(stderr, "mmap %s @%#lx: %s\n", path, PROM_BASE, strerror(errno));
        close(fd);
        return 1;
    }

    /* locate the vBIOS image if the requested offset does not hold one */
    if (!(map[off - PROM_BASE] == 0x55 && map[off - PROM_BASE + 1] == 0xaa)) {
        for (a = PROM_BASE; a + 32 <= PROM_END; a += 0x1000) {
            if (memcmp(map + (a - PROM_BASE), magic, sizeof(magic)) == 0) {
                printf("%s: no signature at %#lx, using %#lx\n", argv[1], off, a);
                off = a;
                found = 1;
                break;
            }
        }
        if (!found) {
            fprintf(stderr, "%s: no 0x55AA vBIOS image in the PROM aperture\n", argv[1]);
            munmap(map, PROM_SIZE);
            close(fd);
            return 1;
        }
    }

    if (off + size > PROM_END) {
        size = PROM_END - off;
        printf("%s: clamping size to %#lx (end of PROM aperture)\n", argv[1], size);
    }

    printf("%s: image at BAR0+%#lx, first bytes:", argv[1], off);
    for (i = 0; i < 16; i++)
        printf(" %02x", map[(off - PROM_BASE) + i]);
    printf("\n");

    buf = malloc(size);
    if (buf == NULL) {
        munmap(map, PROM_SIZE);
        close(fd);
        return 1;
    }
    memcpy(buf, map + (off - PROM_BASE), size);

    out = open(argv[2], O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (out < 0) {
        fprintf(stderr, "open %s: %s\n", argv[2], strerror(errno));
        free(buf);
        munmap(map, PROM_SIZE);
        close(fd);
        return 1;
    }
    n = write(out, buf, size);
    if (n != (ssize_t)size) {
        fprintf(stderr, "write %s: %s\n", argv[2], strerror(errno));
        close(out);
        free(buf);
        munmap(map, PROM_SIZE);
        close(fd);
        return 1;
    }
    fchmod(out, 0644);
    close(out);

    for (i = 0; i < size; i++)
        sum += buf[i];

    printf("%s: wrote %#lx bytes to %s (sum32=%#x)\n", argv[1], size, argv[2], sum);

    free(buf);
    munmap(map, PROM_SIZE);
    close(fd);
    return 0;
}

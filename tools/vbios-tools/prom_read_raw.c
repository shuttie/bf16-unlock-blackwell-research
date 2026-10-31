/*
 * prom_read_raw.c - read-only dump of an arbitrary range of the BAR0 PROM
 * aperture, without the vBIOS-signature relocation that vbios_read.c does.
 *
 * The aperture is NV_PROM_DATA(0) = BAR0 + 0x300000, measured to span 2 MiB.
 * The vBIOS image starts at +0x38000; the head (0x38000) and the tail past the
 * documented 1 MiB window have never been dumped.
 *
 * Usage:
 *   prom_read_raw <bdf> <outfile> [off_hex] [size_hex]
 *     off  absolute BAR0 offset (default 0x300000 = aperture base)
 *     size bytes to dump        (default 0x200000 = whole aperture)
 *
 * Read-only: opens resource0 O_RDONLY and mmaps PROT_READ.  No register writes.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define PROM_BASE  0x00300000UL
#define PROM_SIZE  0x00200000UL
#define PROM_END   (PROM_BASE + PROM_SIZE)

int main(int argc, char **argv)
{
    char path[256];
    unsigned char *map;
    unsigned long off = PROM_BASE;
    unsigned long size = PROM_SIZE;
    int fd, out;
    ssize_t n;

    if (argc < 3 || argc > 5) {
        fprintf(stderr,
                "usage: %s <bdf> <outfile> [off_hex] [size_hex]\n"
                "  default off 0x%lx (aperture base), size 0x%lx (whole aperture)\n",
                argv[0], PROM_BASE, PROM_SIZE);
        return 2;
    }
    if (argc > 3)
        off = strtoul(argv[3], NULL, 16);
    if (argc > 4)
        size = strtoul(argv[4], NULL, 16);

    if (off < PROM_BASE || off >= PROM_END) {
        fprintf(stderr, "offset %#lx outside PROM aperture %#lx..%#lx\n",
                off, PROM_BASE, PROM_END);
        return 1;
    }
    if (off + size > PROM_END) {
        size = PROM_END - off;
        fprintf(stderr, "clamping size to %#lx (end of aperture)\n", size);
    }

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

    out = open(argv[2], O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (out < 0) {
        fprintf(stderr, "open %s: %s\n", argv[2], strerror(errno));
        munmap(map, PROM_SIZE);
        close(fd);
        return 1;
    }
    n = write(out, map + (off - PROM_BASE), size);
    if (n != (ssize_t)size) {
        fprintf(stderr, "short write: %zd of %lu: %s\n", n, size, strerror(errno));
        close(out);
        munmap(map, PROM_SIZE);
        close(fd);
        return 1;
    }
    close(out);

    printf("%s: dumped %#lx bytes at BAR0+%#lx to %s (head %02x%02x)\n",
           argv[1], size, off, argv[2],
           map[off - PROM_BASE], map[off - PROM_BASE + 1]);

    munmap(map, PROM_SIZE);
    close(fd);
    return 0;
}

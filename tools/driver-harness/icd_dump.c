/* icd_dump.c — dump core memory via ICD RDM (8 bytes per command).
 * Requires a halted core. Aborts on the first ERROR (core not halted).
 *
 * usage: icd_dump <bdf> <addr_hex> <len_hex> <outfile>
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

static volatile uint32_t *g;
static int rdm8(uint64_t addr, uint64_t *out)
{
    g[0x1113d4 / 4] = (uint32_t)addr;
    g[0x1113d8 / 4] = (uint32_t)(addr >> 32);
    __sync_synchronize();
    g[0x1113d0 / 4] = 0x000100ca;          /* RDM, size 8, PARM=1 */
    __sync_synchronize();
    for (int i = 0; i < 10; i++) {
        usleep(1000);
        uint32_t v = g[0x1113d0 / 4];
        if (!(v & 0x8000)) {
            if (v & 0x4000) return -1;     /* ERROR */
            *out = ((uint64_t)g[0x1113e8 / 4] << 32) | g[0x1113e4 / 4];
            return 0;
        }
    }
    return -2;                             /* busy */
}

int main(int argc, char **argv)
{
    if (argc < 5) {
        fprintf(stderr, "usage: %s <bdf> <addr_hex> <len_hex> <outfile>\n", argv[0]);
        return 2;
    }
    setvbuf(stdout, NULL, _IONBF, 0);
    uint64_t addr = strtoull(argv[2], NULL, 16);
    uint64_t len  = strtoull(argv[3], NULL, 16);

    char path[256];
    snprintf(path, sizeof path, "/sys/bus/pci/devices/%s/resource0", argv[1]);
    int fd = open(path, O_RDWR);
    if (fd < 0) { perror(path); return 1; }
    void *m = mmap(NULL, 0x1000000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (m == MAP_FAILED) { perror("mmap"); return 1; }
    g = (volatile uint32_t *)m;

    FILE *f = fopen(argv[4], "wb");
    if (!f) { perror(argv[4]); return 1; }
    setvbuf(f, NULL, _IONBF, 0);

    printf("dump %#llx..%#llx -> %s\n",
           (unsigned long long)addr, (unsigned long long)(addr + len), argv[4]);
    uint64_t done = 0;
    for (uint64_t off = 0; off < len; off += 8) {
        uint64_t v;
        int rc = rdm8(addr + off, &v);
        if (rc) {
            printf("STOP at +%#llx (addr %#llx) rc=%d%s\n", (unsigned long long)off,
                   (unsigned long long)(addr + off), rc,
                   rc == -1 ? " (ERROR: core not halted?)" : " (busy)");
            break;
        }
        fwrite(&v, 8, 1, f);
        done += 8;
        if ((off & 0xff) == 0) printf("  +%#llx\n", (unsigned long long)off);
    }
    fclose(f);
    printf("wrote %llu bytes\n", (unsigned long long)done);
    return done ? 0 : 1;
}

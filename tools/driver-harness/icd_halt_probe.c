/* icd_halt_probe.c — deliberate ICD halt + state/memory read.
 *
 * THIS HALTS THE GSP RISC-V CORE. GSP-RM stops; the GPU needs an FLR or a
 * reboot afterwards. Output is unbuffered so it survives a driver hang.
 *
 * Sequence: STOP -> CPUCTL check -> RPC -> RREG x1/x2 -> RSTAT -> RDM at
 * known GSP-RM code words. No resume (none is documented).
 *
 * usage: icd_halt_probe <bdf>
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
#define R(off) (g[(off) / 4])

static int issue(uint32_t cmd, const char *name)
{
    R(0x1113d0) = cmd;
    __sync_synchronize();
    for (int i = 0; i < 50; i++) {
        usleep(1000);
        uint32_t v = R(0x1113d0);
        if (!(v & 0x8000)) {
            printf("%-16s CMD=%08x BUSY=%u ERROR=%u RDATA=%08x%08x\n",
                   name, v, (v >> 15) & 1, (v >> 14) & 1,
                   R(0x1113e8), R(0x1113e4));
            fflush(stdout);
            return (int)((v >> 14) & 1);
        }
    }
    printf("%-16s STILL BUSY CMD=%08x\n", name, R(0x1113d0));
    fflush(stdout);
    return -1;
}

int main(int argc, char **argv)
{
    if (argc < 2) { fprintf(stderr, "usage: %s <bdf>\n", argv[0]); return 2; }
    setvbuf(stdout, NULL, _IONBF, 0);

    char path[256];
    snprintf(path, sizeof path, "/sys/bus/pci/devices/%s/resource0", argv[1]);
    int fd = open(path, O_RDWR);
    if (fd < 0) { perror(path); return 1; }
    void *m = mmap(NULL, 0x1000000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (m == MAP_FAILED) { perror("mmap"); return 1; }
    g = (volatile uint32_t *)m;

    printf("before: CPUCTL=%08x CMD=%08x RPC(host)=%08x RDATA=%08x%08x\n",
           R(0x111388), R(0x1113d0), R(0x1113ec), R(0x1113e8), R(0x1113e4));

    printf("issuing STOP (CMD=0)...\n");
    issue(0x00000000, "STOP");

    for (int i = 0; i < 100; i++) {
        usleep(1000);
        if ((R(0x111388) >> 4) & 1) {
            printf("CPUCTL HALTED[4]=1 after %d ms: CPUCTL=%08x\n", i + 1, R(0x111388));
            break;
        }
        if (i == 99)
            printf("CPUCTL HALTED[4]=0 after 100 ms: CPUCTL=%08x\n", R(0x111388));
    }
    printf("post-stop: CPUCTL=%08x RPC(host)=%08x\n", R(0x111388), R(0x1113ec));

    issue(0x00000012, "RPC");
    issue(0x00000108, "RREG x1(ra)");
    issue(0x00000208, "RREG x2(sp)");
    issue(0x0000000e, "RSTAT idx0");
    issue(0x0000030e, "RSTAT idx3");

    R(0x1113d4) = 0x01400000; R(0x1113d8) = 0; __sync_synchronize();
    issue(0x000100ca, "RDM 1400000/8");

    R(0x1113d4) = 0x01404f64; R(0x1113d8) = 0; __sync_synchronize();
    issue(0x0001008a, "RDM 1404f64/4");

    R(0x1113d4) = 0x01404f66; R(0x1113d8) = 0; __sync_synchronize();
    issue(0x0001004a, "RDM 1404f66/2");

    printf("done; core is halted. Reboot/FLR required.\n");
    return 0;
}

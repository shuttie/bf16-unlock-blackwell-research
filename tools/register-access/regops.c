/*
 * regops.c - issue NV2080_CTRL_CMD_GPU_EXEC_REG_OPS from userspace.
 *
 * Read-only by default. The "write" mode is deliberately explicit: it is the
 * single-write test from the register-write experiments and must be run with a
 * stock boot entry.
 *
 * Build: gcc -O2 -Wall -o regops regops.c
 * Usage: regops <gpu_index> <bdf> [read|write]
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define NV_IOCTL_MAGIC    'F'
#define NV_ESC_RM_ALLOC   0x2B
#define NV_ESC_RM_CONTROL 0x2A
#define NV_ESC_REGISTER_FD (200 + 1)

#define NV01_ROOT_CLIENT 0x00000041u
#define NV01_DEVICE_0    0x00000080u
#define NV20_SUBDEVICE_0 0x00002080u
#define CMD_GPU_EXEC_REG_OPS 0x20800122u
#define CMD_GR_GET_SM_ISSUE_RATE_MODIFIER_V2 0x2080123cu
#define CMD_GR_GET_SM_ISSUE_THROTTLE_CTRL    0x2080123du

#define REG_OP_READ_32  0
#define REG_OP_WRITE_32 1
#define REG_TYPE_GLOBAL 0
/* ctrl2080gpu.h:654-663 */
#define REG_TYPE_GR_CTX       0x01
#define REG_TYPE_GR_CTX_TPC   0x02
#define REG_TYPE_GR_CTX_SM    0x04
#define REG_TYPE_GR_CTX_CROP  0x08
#define REG_TYPE_GR_CTX_ZROP  0x10
#define REG_TYPE_FB           0x20
#define REG_TYPE_GR_CTX_QUAD  0x40
#define REG_TYPE_DEVICE       0x80

/* NV0080_CTRL_GR_ROUTE_INFO, applied to every batch.  The header says the
 * route is mandatory for GR ops when SMC is enabled; the default is TYPE_NONE. */
static uint32_t g_route_flags = 0;
static uint64_t g_route_data  = 0;

typedef uint32_t NvHandle;
typedef uint64_t NvP64;

typedef struct {
    NvHandle hRoot, hObjectParent, hObjectNew;
    int32_t  hClass;
    NvP64    pAllocParms;
    uint32_t paramsSize;
    int32_t  status;
} nvos21_t;

typedef struct {
    NvHandle hClient, hObject;
    int32_t  cmd;
    uint32_t flags;
    NvP64    params;
    uint32_t paramsSize;
    int32_t  status;
} nvos54_t;

typedef struct {
    uint32_t deviceId;
    NvHandle hClientShare, hTargetClient, hTargetDevice;
    int32_t  flags;
    uint64_t vaSpaceSize, vaStartInternal, vaLimitInternal;
    int32_t  vaMode;
} nv0080_t;

typedef struct { uint32_t subDeviceId; } nv2080_t;

typedef struct {
    uint8_t  regOp, regType, regStatus, regQuad;
    uint32_t regGroupMask, regSubGroupMask, regOffset;
    uint32_t regValueHi, regValueLo, regAndNMaskHi, regAndNMaskLo;
} reg_op_t;

typedef struct { uint32_t flags; uint64_t route; } route_info_t;

typedef struct { uint32_t index, data; } nv_info_t;
typedef struct { uint32_t listSize; nv_info_t list[255]; } list_params_t;

typedef struct {
    NvHandle hClientTarget, hChannelTarget;
    uint32_t bNonTransactional;
    uint32_t reserved00[2];
    uint32_t regOpCount;
    NvP64    regOps;
    route_info_t grRouteInfo;
} exec_params_t;

static int rm_alloc(int fd, nvos21_t *p)
{
    return ioctl(fd, _IOC(_IOC_READ | _IOC_WRITE, NV_IOCTL_MAGIC,
                          NV_ESC_RM_ALLOC, sizeof(*p)), p);
}

static int rm_control(int fd, nvos54_t *p)
{
    return ioctl(fd, _IOC(_IOC_READ | _IOC_WRITE, NV_IOCTL_MAGIC,
                          NV_ESC_RM_CONTROL, sizeof(*p)), p);
}

/* Direct host BAR0 write/read/restore/read (no GSP involvement).
 * Tests the PL0 master, which is a different source from GSP-RM at PL2. */
static int bar_write_test(const char *bdf, uint32_t off, uint32_t newv, uint32_t orig)
{
    char path[256];
    int barfd;
    volatile uint8_t *bar;
    volatile uint32_t *p;

    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/resource0", bdf);
    barfd = open(path, O_RDWR);
    if (barfd < 0) {
        fprintf(stderr, "open %s: %s\n", path, strerror(errno));
        return 1;
    }
    bar = mmap(NULL, 0x1000000, PROT_READ | PROT_WRITE, MAP_SHARED, barfd, 0);
    if (bar == MAP_FAILED) {
        fprintf(stderr, "mmap %s: %s\n", path, strerror(errno));
        close(barfd);
        return 1;
    }
    p = (volatile uint32_t *)(bar + off);
    printf("  BAR0 %#010x before                 = %#010x\n", off, *p);
    *p = newv;
    __sync_synchronize();
    printf("  BAR0 %#010x after write %#010x   = %#010x\n", off, newv, *p);
    *p = orig;
    __sync_synchronize();
    printf("  BAR0 %#010x after restore %#010x = %#010x\n", off, orig, *p);
    munmap((void *)bar, 0x1000000);
    close(barfd);
    return 0;
}

/* Independent read of a BAR0 dword (no GSP involvement). Read-only. */
static int bar_read(const char *bdf, uint32_t off, int count)
{
    char path[256];
    int barfd, k;
    volatile uint8_t *bar;

    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/resource0", bdf);
    barfd = open(path, O_RDONLY);
    if (barfd < 0) {
        fprintf(stderr, "open %s: %s\n", path, strerror(errno));
        return 1;
    }
    bar = mmap(NULL, 0x1000000, PROT_READ, MAP_SHARED, barfd, 0);
    if (bar == MAP_FAILED) {
        fprintf(stderr, "mmap %s: %s\n", path, strerror(errno));
        close(barfd);
        return 1;
    }
    for (k = 0; k < count; k++) {
        uint32_t v = *(volatile uint32_t *)(bar + off + 4u * (uint32_t)k);
        printf("  BAR0 %#010x = %#010x\n", off + 4u * (uint32_t)k, v);
    }
    munmap((void *)bar, 0x1000000);
    close(barfd);
    return 0;
}

/* Poll the FEAT PLM and the two SS words directly through BAR0.
 * Read-only.  Used to measure the post-FLR window: the PLM is 0x80842bcf
 * (write mask L2+L3) until a GPU-side master re-locks it to 0xfffffb8f. */
static int bar_poll(const char *bdf, int interval_ms, int count)
{
    char path[256];
    struct timespec t0, t;
    int k;

    if (interval_ms < 1) interval_ms = 1;
    if (interval_ms > 1000) interval_ms = 1000;
    if (count < 1) count = 1;

    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/resource0", bdf);

    clock_gettime(CLOCK_MONOTONIC, &t0);
    printf("# t_ms wall_ms plm ss0 ss1 readout1 fusefmla32 engine resetplm pc\n");
    fflush(stdout);

    for (k = 0; k < count; k++) {
        long ms, wall_ms;
        uint32_t plm = 0xffffffffu, ss0 = 0xffffffffu, ss1 = 0xffffffffu;
        uint32_t r1 = 0xffffffffu, fuse = 0xffffffffu;
        uint32_t eng = 0xffffffffu, rplm = 0xffffffffu, pc = 0xffffffffu;
        int fd;
        volatile uint8_t *bar = MAP_FAILED;

        clock_gettime(CLOCK_MONOTONIC, &t);
        ms = (t.tv_sec - t0.tv_sec) * 1000L + (t.tv_nsec - t0.tv_nsec) / 1000000L;
        clock_gettime(CLOCK_REALTIME, &t);
        wall_ms = t.tv_sec * 1000L + t.tv_nsec / 1000000L;

        /* Re-map per sample: the bind re-enables the BAR and a mapping held
         * across it can go stale.  0xffffffff marks a failed sample. */
        fd = open(path, O_RDONLY);
        if (fd >= 0) {
            bar = mmap(NULL, 0x1000000, PROT_READ, MAP_SHARED, fd, 0);
            if (bar != MAP_FAILED) {
                plm  = *(volatile uint32_t *)(bar + 0x00823804u);
                ss0  = *(volatile uint32_t *)(bar + 0x0082381cu);
                ss1  = *(volatile uint32_t *)(bar + 0x00823820u);
                r1   = *(volatile uint32_t *)(bar + 0x00823818u);
                fuse = *(volatile uint32_t *)(bar + 0x008207d8u);
                /* GSP core state: ENGINE 0x1103c0, reset PLM 0x1103c4,
                 * host PC mirror 0x1113ec (0xbadf5620 while HS-blocked,
                 * 0xefd0xxxx = boot image, 0x9xxx/0x01xxxxxx = GSP-RM). */
                eng  = *(volatile uint32_t *)(bar + 0x001103c0u);
                rplm = *(volatile uint32_t *)(bar + 0x001103c4u);
                pc   = *(volatile uint32_t *)(bar + 0x001113ecu);
                munmap((void *)bar, 0x1000000);
            }
            close(fd);
        }
        printf("%ld %ld %#010x %#010x %#010x %#010x %#010x %#010x %#010x %#010x\n",
               ms, wall_ms, plm, ss0, ss1, r1, fuse, eng, rplm, pc);
        fflush(stdout);
        usleep((useconds_t)interval_ms * 1000u);
    }
    return 0;
}

static const char *type_name(unsigned t)
{
    switch (t) {
    case REG_TYPE_GLOBAL:      return "GLOBAL";
    case REG_TYPE_GR_CTX:      return "GR_CTX";
    case REG_TYPE_GR_CTX_TPC:  return "GR_CTX_TPC";
    case REG_TYPE_GR_CTX_SM:   return "GR_CTX_SM";
    case REG_TYPE_GR_CTX_CROP: return "GR_CTX_CROP";
    case REG_TYPE_GR_CTX_ZROP: return "GR_CTX_ZROP";
    case REG_TYPE_FB:          return "FB";
    case REG_TYPE_GR_CTX_QUAD: return "GR_CTX_QUAD";
    case REG_TYPE_DEVICE:      return "DEVICE";
    default:                   return "?";
    }
}

/* One NV2080_CTRL_GPU_EXEC_REG_OPS batch. Returns the RM status. */
static int exec_regops(int fd, NvHandle client, NvHandle subdevice,
                       reg_op_t *ops, int nops)
{
    exec_params_t p;
    nvos54_t c;

    memset(&p, 0, sizeof(p));
    p.bNonTransactional = 1;
    p.regOpCount = (uint32_t)nops;
    p.regOps = (NvP64)(uintptr_t)ops;
    p.grRouteInfo.flags = g_route_flags;
    p.grRouteInfo.route = g_route_data;

    memset(&c, 0, sizeof(c));
    c.hClient = client;
    c.hObject = subdevice;
    c.cmd = CMD_GPU_EXEC_REG_OPS;
    c.params = (NvP64)(uintptr_t)&p;
    c.paramsSize = sizeof(p);
    c.status = -1;
    if (rm_control(fd, &c) < 0) {
        fprintf(stderr, "exec_regops: %s\n", strerror(errno));
        return -1;
    }
    return c.status;
}

static int bar_rd32(const char *bdf, uint32_t off, uint32_t *out)
{
    char path[256];
    int fd;
    volatile uint8_t *bar;
    uint32_t v;

    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/resource0", bdf);
    fd = open(path, O_RDONLY);
    if (fd < 0)
        return -1;
    bar = mmap(NULL, 0x1000000, PROT_READ, MAP_SHARED, fd, 0);
    if (bar == MAP_FAILED) {
        close(fd);
        return -1;
    }
    v = *(volatile uint32_t *)(bar + off);
    munmap((void *)bar, 0x1000000);
    close(fd);
    *out = v;
    return 0;
}

static uint64_t wall_ns(void)
{
    struct timespec t;
    clock_gettime(CLOCK_REALTIME, &t);
    return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}

static int alloc_obj(int fd, NvHandle root, NvHandle parent, int32_t cls,
                     void *parms, uint32_t parm_size, NvHandle *out,
                     const char *what)
{
    nvos21_t a;
    memset(&a, 0, sizeof(a));
    a.hRoot = root;
    a.hObjectParent = parent;
    a.hObjectNew = 0;
    a.hClass = cls;
    a.pAllocParms = (NvP64)(uintptr_t)parms;
    a.paramsSize = parm_size;
    a.status = -1;
    if (rm_alloc(fd, &a) < 0) {
        fprintf(stderr, "alloc %s: ioctl: %s\n", what, strerror(errno));
        return -1;
    }
    if (a.status != 0) {
        fprintf(stderr, "alloc %s: RM status %#x\n", what, (unsigned)a.status);
        return -1;
    }
    *out = a.hObjectNew;
    printf("alloc %-12s -> handle %#x\n", what, *out);
    return 0;
}

static const char *status_name(uint8_t s)
{
    switch (s) {
    case 0x00: return "SUCCESS";
    case 0x01: return "INVALID_OP";
    case 0x02: return "INVALID_TYPE";
    case 0x04: return "INVALID_OFFSET";
    case 0x08: return "UNSUPPORTED_OP";
    case 0x10: return "INVALID_MASK";
    case 0x20: return "NOACCESS";
    default:   return "?";
    }
}

int main(int argc, char **argv)
{
    const char *bdf;
    int gpu, fd, i, write_mode = 0, rate_mode = 0, ratev2_mode = 0, throttle_mode = 0, name_mode = 0, one_mode = 0, wr_mode = 0, wrr_mode = 0, sc_mode = 0, dump_mode = 0, rep_mode = 0, emem_mode = 0, nops;
    unsigned long wr_off = 0, wr_val = 0, wrr_new = 0, wrr_orig = 0;
    unsigned long emem_ctrl = 0, emem_data = 0, emem_new = 0, emem_orig = 0;
    int emem_count = 0;
    NvHandle client = 0, device = 0, subdevice = 0;
    nv0080_t dev_parms;
    nv2080_t sub_parms;
    reg_op_t ops[12];
    exec_params_t params;
    nvos54_t ctl;

    struct { const char *name; uint32_t off; } regs[] = {
        { "NV_PMC_BOOT_0      ", 0x00000000 },
        { "FEAT_OVR_PLM       ", 0x00823804 },
        { "FEAT_READOUT_1     ", 0x00823818 },
        { "FEAT_OVR_SM_SS0    ", 0x0082381c },
        { "FEAT_OVR_SM_SS1    ", 0x00823820 },
        { "FUSE_SS_FMLA32     ", 0x008207d8 },
        { "SM_ISSUE_RATE_MOD  ", 0x00504204 },
        { "OPT_FEAT_FUSE_OVRD ", 0x008203f0 },
    };

    if (argc < 3) {
        fprintf(stderr,
                "usage: %s <gpu_index> <bdf> <mode>\n"
                "  modes: read | write | rate | ratev2 | throttle | name | one | sc\n"
                "         dump <base> <count> | rep <off> <count>\n"
                "         wr <off> <val> | wrr <off> <new> <orig>\n"
                "         bar <off> [count] | barw <off> <new> <orig>\n"
                "         ememstream <ctrl> <data> <new> <orig> <count>\n"
                "         gprobe | gprobe_route | gr <type> <off> <count>\n"
                "         gw <type> <off> <new> <orig> [grp] [subgrp]\n"
                "         race <new0> <orig0> <new1> <orig1>\n"
                "         plmpoll <interval_ms> <count>     (direct BAR0, read-only)\n"
                "  regType: 0=GLOBAL 1=GR_CTX 2=GR_CTX_TPC 4=GR_CTX_SM 8=CROP\n"
                "           0x10=ZROP 0x20=FB 0x40=GR_CTX_QUAD 0x80=DEVICE\n",
                argv[0]);
        return 2;
    }
    gpu = atoi(argv[1]);
    bdf = argv[2];
    if (argc > 3 && strcmp(argv[3], "write") == 0)
        write_mode = 1;
    if (argc > 3 && strcmp(argv[3], "rate") == 0)
        rate_mode = 1;
    if (argc > 3 && strcmp(argv[3], "ratev2") == 0)
        ratev2_mode = 1;
    if (argc > 3 && strcmp(argv[3], "throttle") == 0)
        throttle_mode = 1;
    if (argc > 3 && strcmp(argv[3], "name") == 0)
        name_mode = 1;
    if (argc > 3 && strcmp(argv[3], "one") == 0)
        one_mode = 1;
    if (argc > 3 && strcmp(argv[3], "sc") == 0)
        sc_mode = 1;
    if (argc > 5 && strcmp(argv[3], "dump") == 0)
        dump_mode = 1;
    if (argc > 5 && strcmp(argv[3], "rep") == 0)
        rep_mode = 1;
    if (argc > 5 && strcmp(argv[3], "wr") == 0) {
        wr_mode = 1;
        wr_off = strtoul(argv[4], NULL, 16);
        wr_val = strtoul(argv[5], NULL, 16);
    }
    if (argc > 6 && strcmp(argv[3], "wrr") == 0) {
        /* write, read back, restore, read back -- all in one RPC batch */
        wrr_mode = 1;
        wr_off = strtoul(argv[4], NULL, 16);
        wrr_new = strtoul(argv[5], NULL, 16);
        wrr_orig = strtoul(argv[6], NULL, 16);
    }
    if (argc > 8 && strcmp(argv[3], "ememstream") == 0) {
        /* write ctrl, read ctrl, read data x count, restore ctrl, read ctrl, read data
         * -- one RPC batch; the ctrl write sets the pointer (and AINCR if set). */
        emem_mode = 1;
        emem_ctrl = strtoul(argv[4], NULL, 16);
        emem_data = strtoul(argv[5], NULL, 16);
        emem_new = strtoul(argv[6], NULL, 16);
        emem_orig = strtoul(argv[7], NULL, 16);
        emem_count = (int)strtoul(argv[8], NULL, 16);
    }
    if (argc > 4 && strcmp(argv[3], "bar") == 0) {
        uint32_t boff = (uint32_t)strtoul(argv[4], NULL, 16);
        int bcount = (argc > 5) ? (int)strtoul(argv[5], NULL, 16) : 1;
        if (bcount < 1 || bcount > 64) { fprintf(stderr, "count 1..64\n"); return 2; }
        return bar_read(bdf, boff, bcount);
    }
    if (argc > 6 && strcmp(argv[3], "barw") == 0) {
        return bar_write_test(bdf,
                              (uint32_t)strtoul(argv[4], NULL, 16),
                              (uint32_t)strtoul(argv[5], NULL, 16),
                              (uint32_t)strtoul(argv[6], NULL, 16));
    }
    if (argc > 4 && strcmp(argv[3], "plmpoll") == 0) {
        int iv = atoi(argv[4]);
        int cnt = (argc > 5) ? atoi(argv[5]) : 1000;
        return bar_poll(bdf, iv, cnt);
    }

    fd = open("/dev/nvidiactl", O_RDWR);
    if (fd < 0) {
        fprintf(stderr, "open /dev/nvidiactl: %s\n", strerror(errno));
        return 1;
    }

    if (alloc_obj(fd, 0, 0, NV01_ROOT_CLIENT, NULL, 0, &client, "client") < 0)
        return 1;

    /* race mode: open the GPU node before the device allocation.  nv_open ->
     * nv_start_device -> RmInitAdapter is what boots the GSP; doing it here
     * starts the PL2 master as early as possible after the PCI bind. */
    if (argc > 3 && strcmp(argv[3], "race") == 0) {
        int devfd = open(gpu == 0 ? "/dev/nvidia0" : "/dev/nvidia1", O_RDWR);
        if (devfd >= 0) {
            int ctl_fd = fd;
            if (ioctl(devfd, _IOC(_IOC_READ | _IOC_WRITE, NV_IOCTL_MAGIC,
                                  NV_ESC_REGISTER_FD, sizeof(int)), &ctl_fd) < 0)
                fprintf(stderr, "race register_fd: %s\n", strerror(errno));
        } else {
            fprintf(stderr, "race open /dev/nvidia%d: %s\n", gpu, strerror(errno));
        }
    }

    memset(&dev_parms, 0, sizeof(dev_parms));
    dev_parms.deviceId = (uint32_t)gpu;
    if (alloc_obj(fd, client, client, NV01_DEVICE_0, &dev_parms,
                  sizeof(dev_parms), &device, "device") < 0) {
        int devfd = open(gpu == 0 ? "/dev/nvidia0" : "/dev/nvidia1", O_RDWR);
        if (devfd >= 0) {
            int ctl_fd = fd;
            printf("retrying after NV_ESC_REGISTER_FD on /dev/nvidia%d\n", gpu);
            if (ioctl(devfd, _IOC(_IOC_READ | _IOC_WRITE, NV_IOCTL_MAGIC,
                                  NV_ESC_REGISTER_FD, sizeof(int)), &ctl_fd) < 0)
                fprintf(stderr, "register_fd: %s\n", strerror(errno));
            if (alloc_obj(fd, client, client, NV01_DEVICE_0, &dev_parms,
                          sizeof(dev_parms), &device, "device") < 0)
                return 1;
        } else {
            return 1;
        }
    }

    memset(&sub_parms, 0, sizeof(sub_parms));
    sub_parms.subDeviceId = 0;
    if (alloc_obj(fd, client, device, NV20_SUBDEVICE_0, &sub_parms,
                  sizeof(sub_parms), &subdevice, "subdevice") < 0)
        return 1;

    /* race <new0> <orig0> <new1> <orig1>
     * Write SS0/SS1 immediately after RM init, read back, then write the orig
     * value.  Pass orig == new to keep the new value.  Prints wall-clock ns so
     * a concurrent plmpoll log can be correlated with the write. */
    if (argc > 7 && strcmp(argv[3], "race") == 0) {
        uint32_t n0 = (uint32_t)strtoul(argv[4], NULL, 16);
        uint32_t o0 = (uint32_t)strtoul(argv[5], NULL, 16);
        uint32_t n1 = (uint32_t)strtoul(argv[6], NULL, 16);
        uint32_t o1 = (uint32_t)strtoul(argv[7], NULL, 16);
        reg_op_t ops[8];
        uint32_t plm = 0, ss0 = 0, ss1 = 0;
        uint64_t t_pre, t_post;
        int st;

        bar_rd32(bdf, 0x00823804u, &plm);
        bar_rd32(bdf, 0x0082381cu, &ss0);
        bar_rd32(bdf, 0x00823820u, &ss1);
        t_pre = wall_ns();
        printf("RACE pre  wall_ns=%llu plm=%#010x ss0=%#010x ss1=%#010x\n",
               (unsigned long long)t_pre, plm, ss0, ss1);

        memset(ops, 0, sizeof(ops));
        ops[0].regOp = REG_OP_WRITE_32; ops[0].regType = REG_TYPE_GLOBAL;
        ops[0].regOffset = 0x0082381cu; ops[0].regValueLo = n0; ops[0].regAndNMaskLo = ~n0;
        ops[1].regOp = REG_OP_READ_32;  ops[1].regType = REG_TYPE_GLOBAL;
        ops[1].regOffset = 0x0082381cu;
        ops[2].regOp = REG_OP_WRITE_32; ops[2].regType = REG_TYPE_GLOBAL;
        ops[2].regOffset = 0x0082381cu; ops[2].regValueLo = o0; ops[2].regAndNMaskLo = ~o0;
        ops[3].regOp = REG_OP_READ_32;  ops[3].regType = REG_TYPE_GLOBAL;
        ops[3].regOffset = 0x0082381cu;
        ops[4].regOp = REG_OP_WRITE_32; ops[4].regType = REG_TYPE_GLOBAL;
        ops[4].regOffset = 0x00823820u; ops[4].regValueLo = n1; ops[4].regAndNMaskLo = ~n1;
        ops[5].regOp = REG_OP_READ_32;  ops[5].regType = REG_TYPE_GLOBAL;
        ops[5].regOffset = 0x00823820u;
        ops[6].regOp = REG_OP_WRITE_32; ops[6].regType = REG_TYPE_GLOBAL;
        ops[6].regOffset = 0x00823820u; ops[6].regValueLo = o1; ops[6].regAndNMaskLo = ~o1;
        ops[7].regOp = REG_OP_READ_32;  ops[7].regType = REG_TYPE_GLOBAL;
        ops[7].regOffset = 0x00823820u;

        st = exec_regops(fd, client, subdevice, ops, 8);
        t_post = wall_ns();

        bar_rd32(bdf, 0x00823804u, &plm);
        bar_rd32(bdf, 0x0082381cu, &ss0);
        bar_rd32(bdf, 0x00823820u, &ss1);

        printf("RACE post wall_ns=%llu status=%#x\n",
               (unsigned long long)t_post, (unsigned)st);
        printf("  SS0 write %#010x -> read %#010x status=%u %s\n",
               n0, ops[1].regValueLo, ops[1].regStatus, status_name(ops[1].regStatus));
        printf("  SS0 restore %#010x -> read %#010x status=%u %s\n",
               o0, ops[3].regValueLo, ops[3].regStatus, status_name(ops[3].regStatus));
        printf("  SS1 write %#010x -> read %#010x status=%u %s\n",
               n1, ops[5].regValueLo, ops[5].regStatus, status_name(ops[5].regStatus));
        printf("  SS1 restore %#010x -> read %#010x status=%u %s\n",
               o1, ops[7].regValueLo, ops[7].regStatus, status_name(ops[7].regStatus));
        printf("RACE bar0 plm=%#010x ss0=%#010x ss1=%#010x\n", plm, ss0, ss1);
        printf("RACE verdict ss0_landed=%d ss1_landed=%d\n",
               ops[0].regStatus == 0 && ops[1].regValueLo == n0,
               ops[4].regStatus == 0 && ops[5].regValueLo == n1);
        close(fd);
        return 0;
    }

    /* Read-only probe of the same offsets under every register type.
     * The GR_* types address per-context registers; a successful read with a
     * different value is the signature of a context-space register that the
     * GLOBAL campaign never touched. */
    if (argc > 3 && strcmp(argv[3], "gprobe") == 0) {
        static const uint32_t offs[] = {
            0x00504204u, 0x0082381cu, 0x00823820u, 0x00823804u
        };
        static const unsigned types[] = {
            REG_TYPE_GLOBAL, REG_TYPE_GR_CTX, REG_TYPE_GR_CTX_TPC,
            REG_TYPE_GR_CTX_SM, REG_TYPE_GR_CTX_QUAD, REG_TYPE_FB
        };
        reg_op_t ops[sizeof(offs) / sizeof(offs[0])];
        unsigned ti;
        int k, st;

        for (ti = 0; ti < sizeof(types) / sizeof(types[0]); ti++) {
            memset(ops, 0, sizeof(ops));
            for (k = 0; k < (int)(sizeof(offs) / sizeof(offs[0])); k++) {
                ops[k].regOp = REG_OP_READ_32;
                ops[k].regType = (uint8_t)types[ti];
                ops[k].regOffset = offs[k];
            }
            st = exec_regops(fd, client, subdevice, ops,
                             (int)(sizeof(offs) / sizeof(offs[0])));
            printf("gprobe %-12s status=%#x\n", type_name(types[ti]), (unsigned)st);
            for (k = 0; k < (int)(sizeof(offs) / sizeof(offs[0])); k++)
                printf("  %#010x = %#010x status=%u %s\n",
                       offs[k], ops[k].regValueLo, ops[k].regStatus,
                       status_name(ops[k].regStatus));
        }
        close(fd);
        return 0;
    }

    /* gprobe_route: GR_CTX reads with each NV0080_CTRL_GR_ROUTE_INFO flag.
     * flags 0=NONE, 1=ENGID, 2=CHANNEL, 3=both; route is 0 (engine/channel 0). */
    if (argc > 3 && strcmp(argv[3], "gprobe_route") == 0) {
        static const uint32_t offs[] = {
            0x00504204u, 0x0082381cu, 0x00823820u, 0x00823804u
        };
        reg_op_t ops[sizeof(offs) / sizeof(offs[0])];
        unsigned f;
        int k, st;

        for (f = 0; f < 4; f++) {
            g_route_flags = f;
            g_route_data = 0;
            memset(ops, 0, sizeof(ops));
            for (k = 0; k < (int)(sizeof(offs) / sizeof(offs[0])); k++) {
                ops[k].regOp = REG_OP_READ_32;
                ops[k].regType = REG_TYPE_GR_CTX;
                ops[k].regOffset = offs[k];
            }
            st = exec_regops(fd, client, subdevice, ops,
                             (int)(sizeof(offs) / sizeof(offs[0])));
            printf("gprobe_route flags=%u route=0 status=%#x\n", f, (unsigned)st);
            for (k = 0; k < (int)(sizeof(offs) / sizeof(offs[0])); k++)
                printf("  %#010x = %#010x status=%u %s\n",
                       offs[k], ops[k].regValueLo, ops[k].regStatus,
                       status_name(ops[k].regStatus));
        }
        g_route_flags = 0;
        close(fd);
        return 0;
    }

    /* gr <type> <off> <count>  -- typed read range */
    if (argc > 6 && strcmp(argv[3], "gr") == 0) {
        unsigned t = (unsigned)strtoul(argv[4], NULL, 0);
        uint32_t base = (uint32_t)strtoul(argv[5], NULL, 16);
        int count = (int)strtoul(argv[6], NULL, 16);
        reg_op_t *ops;
        int k, st;

        if (count < 1 || count > 64) { fprintf(stderr, "count 1..64\n"); return 2; }
        ops = calloc((size_t)count, sizeof(*ops));
        if (!ops) return 1;
        for (k = 0; k < count; k++) {
            ops[k].regOp = REG_OP_READ_32;
            ops[k].regType = (uint8_t)t;
            ops[k].regOffset = base + 4u * (uint32_t)k;
        }
        st = exec_regops(fd, client, subdevice, ops, count);
        printf("gr %s %#x..%#x status=%#x\n", type_name(t), base,
               base + 4u * (uint32_t)(count - 1), (unsigned)st);
        for (k = 0; k < count; k++)
            printf("  %#010x = %#010x status=%u %s\n",
                   ops[k].regOffset, ops[k].regValueLo, ops[k].regStatus,
                   status_name(ops[k].regStatus));
        free(ops);
        close(fd);
        return 0;
    }

    /* gw <type> <off> <new> <orig> [grp] [subgrp]
     * write new, read, restore orig, read -- one batch. */
    if (argc > 7 && strcmp(argv[3], "gw") == 0) {
        unsigned t = (unsigned)strtoul(argv[4], NULL, 0);
        uint32_t off = (uint32_t)strtoul(argv[5], NULL, 16);
        uint32_t nv  = (uint32_t)strtoul(argv[6], NULL, 16);
        uint32_t ov  = (uint32_t)strtoul(argv[7], NULL, 16);
        uint32_t grp = (argc > 8) ? (uint32_t)strtoul(argv[8], NULL, 16) : 0;
        uint32_t sub = (argc > 9) ? (uint32_t)strtoul(argv[9], NULL, 16) : 0;
        reg_op_t ops[4];
        int st;

        memset(ops, 0, sizeof(ops));
        ops[0].regOp = REG_OP_WRITE_32; ops[0].regType = (uint8_t)t;
        ops[0].regOffset = off; ops[0].regValueLo = nv; ops[0].regAndNMaskLo = ~nv;
        ops[0].regGroupMask = grp; ops[0].regSubGroupMask = sub;
        ops[1].regOp = REG_OP_READ_32; ops[1].regType = (uint8_t)t;
        ops[1].regOffset = off; ops[1].regGroupMask = grp; ops[1].regSubGroupMask = sub;
        ops[2].regOp = REG_OP_WRITE_32; ops[2].regType = (uint8_t)t;
        ops[2].regOffset = off; ops[2].regValueLo = ov; ops[2].regAndNMaskLo = ~ov;
        ops[2].regGroupMask = grp; ops[2].regSubGroupMask = sub;
        ops[3].regOp = REG_OP_READ_32; ops[3].regType = (uint8_t)t;
        ops[3].regOffset = off; ops[3].regGroupMask = grp; ops[3].regSubGroupMask = sub;

        st = exec_regops(fd, client, subdevice, ops, 4);
        printf("gw %s off=%#x new=%#x orig=%#x grp=%#x sub=%#x status=%#x\n",
               type_name(t), off, nv, ov, grp, sub, (unsigned)st);
        printf("  WRITE %#010x status=%u %s\n", nv, ops[0].regStatus,
               status_name(ops[0].regStatus));
        printf("  READ  after new    = %#010x status=%u %s -> %s\n",
               ops[1].regValueLo, ops[1].regStatus, status_name(ops[1].regStatus),
               ops[1].regValueLo == nv ? "LANDED" : "NOT NEW");
        printf("  WRITE %#010x status=%u %s\n", ov, ops[2].regStatus,
               status_name(ops[2].regStatus));
        printf("  READ  after restore= %#010x status=%u %s -> %s\n",
               ops[3].regValueLo, ops[3].regStatus, status_name(ops[3].regStatus),
               ops[3].regValueLo == ov ? "RESTORED" : "NOT RESTORED");
        close(fd);
        return 0;
    }

    if (dump_mode) {
        uint32_t base = (uint32_t)strtoul(argv[4], NULL, 16);
        int count = (int)strtoul(argv[5], NULL, 16);
        reg_op_t *dops;
        exec_params_t dp;
        nvos54_t dc;
        int k;

        if (count < 1 || count > 128) { fprintf(stderr, "count 1..128\n"); return 2; }
        dops = calloc((size_t)count, sizeof(*dops));
        if (!dops) return 1;
        for (k = 0; k < count; k++) {
            dops[k].regOp = REG_OP_READ_32;
            dops[k].regType = REG_TYPE_GLOBAL;
            dops[k].regOffset = base + 4u * (uint32_t)k;
        }
        memset(&dp, 0, sizeof(dp));
        dp.bNonTransactional = 1;          /* execute valid ops even if some are rejected */
        dp.regOpCount = (uint32_t)count;
        dp.regOps = (NvP64)(uintptr_t)dops;
        memset(&dc, 0, sizeof(dc));
        dc.hClient = client; dc.hObject = subdevice; dc.cmd = CMD_GPU_EXEC_REG_OPS;
        dc.params = (NvP64)(uintptr_t)&dp; dc.paramsSize = sizeof(dp); dc.status = -1;
        if (rm_control(fd, &dc) < 0) { fprintf(stderr, "dump: %s\n", strerror(errno)); return 1; }
        printf("dump %#x..%#x status = %#x (non-transactional)\n",
               base, base + 4u * (uint32_t)(count - 1), (unsigned)dc.status);
        for (k = 0; k < count; k++)
            printf("  %#010x = %#010x  status=%u %s\n",
                   dops[k].regOffset, dops[k].regValueLo, dops[k].regStatus,
                   status_name(dops[k].regStatus));
        free(dops);
        close(fd);
        return 0;
    }

    if (rep_mode) {
        /* N reads of the SAME offset -- for auto-incrementing port data registers */
        uint32_t roff = (uint32_t)strtoul(argv[4], NULL, 16);
        int rcount = (int)strtoul(argv[5], NULL, 16);
        reg_op_t *rops;
        exec_params_t rp;
        nvos54_t rctl;
        int k;

        if (rcount < 1 || rcount > 64) { fprintf(stderr, "count 1..64\n"); return 2; }
        rops = calloc((size_t)rcount, sizeof(*rops));
        if (!rops) return 1;
        for (k = 0; k < rcount; k++) {
            rops[k].regOp = REG_OP_READ_32;
            rops[k].regType = REG_TYPE_GLOBAL;
            rops[k].regOffset = roff;
        }
        memset(&rp, 0, sizeof(rp));
        rp.bNonTransactional = 1;
        rp.regOpCount = (uint32_t)rcount;
        rp.regOps = (NvP64)(uintptr_t)rops;
        memset(&rctl, 0, sizeof(rctl));
        rctl.hClient = client; rctl.hObject = subdevice; rctl.cmd = CMD_GPU_EXEC_REG_OPS;
        rctl.params = (NvP64)(uintptr_t)&rp; rctl.paramsSize = sizeof(rp); rctl.status = -1;
        if (rm_control(fd, &rctl) < 0) { fprintf(stderr, "rep: %s\n", strerror(errno)); return 1; }
        printf("rep %#x x %d status = %#x\n", roff, rcount, (unsigned)rctl.status);
        for (k = 0; k < rcount; k++)
            printf("  [%3d] %#010x  status=%u %s\n",
                   k, rops[k].regValueLo, rops[k].regStatus, status_name(rops[k].regStatus));
        free(rops);
        close(fd);
        return 0;
    }

    if (emem_mode) {
        /* Arm an EMEM control register, stream `count` data words, restore the
         * control and verify. Intended for the FSP/Falcon EMEM port pair where
         * the data register auto-increments while AINCR is set. */
        reg_op_t *eops;
        exec_params_t ep;
        nvos54_t ec;
        int k, total = emem_count + 5;
        int landed, restored;

        if (emem_count < 1 || emem_count > 120) {
            fprintf(stderr, "count 1..120 (total ops <= 125)\n");
            return 2;
        }
        eops = calloc((size_t)total, sizeof(*eops));
        if (!eops) return 1;

        eops[0].regOp = REG_OP_WRITE_32;
        eops[0].regType = REG_TYPE_GLOBAL;
        eops[0].regOffset = (uint32_t)emem_ctrl;
        eops[0].regValueLo = (uint32_t)emem_new;
        eops[0].regAndNMaskLo = ~(uint32_t)emem_new;

        eops[1].regOp = REG_OP_READ_32;
        eops[1].regType = REG_TYPE_GLOBAL;
        eops[1].regOffset = (uint32_t)emem_ctrl;

        for (k = 0; k < emem_count; k++) {
            eops[2 + k].regOp = REG_OP_READ_32;
            eops[2 + k].regType = REG_TYPE_GLOBAL;
            eops[2 + k].regOffset = (uint32_t)emem_data;
        }

        k = 2 + emem_count;
        eops[k].regOp = REG_OP_WRITE_32;
        eops[k].regType = REG_TYPE_GLOBAL;
        eops[k].regOffset = (uint32_t)emem_ctrl;
        eops[k].regValueLo = (uint32_t)emem_orig;
        eops[k].regAndNMaskLo = ~(uint32_t)emem_orig;

        eops[k + 1].regOp = REG_OP_READ_32;
        eops[k + 1].regType = REG_TYPE_GLOBAL;
        eops[k + 1].regOffset = (uint32_t)emem_ctrl;

        eops[k + 2].regOp = REG_OP_READ_32;
        eops[k + 2].regType = REG_TYPE_GLOBAL;
        eops[k + 2].regOffset = (uint32_t)emem_data;

        memset(&ep, 0, sizeof(ep));
        ep.bNonTransactional = 1;
        ep.regOpCount = (uint32_t)total;
        ep.regOps = (NvP64)(uintptr_t)eops;
        memset(&ec, 0, sizeof(ec));
        ec.hClient = client; ec.hObject = subdevice; ec.cmd = CMD_GPU_EXEC_REG_OPS;
        ec.params = (NvP64)(uintptr_t)&ep; ec.paramsSize = sizeof(ep); ec.status = -1;
        if (rm_control(fd, &ec) < 0) {
            fprintf(stderr, "ememstream: %s\n", strerror(errno));
            free(eops);
            return 1;
        }

        landed = (eops[1].regStatus == 0 && eops[1].regValueLo == (uint32_t)emem_new);
        restored = (eops[k + 1].regStatus == 0 &&
                    eops[k + 1].regValueLo == (uint32_t)emem_orig);

        printf("ememstream ctrl=%#x data=%#x new=%#x orig=%#x count=%d status=%#x\n",
               (unsigned)emem_ctrl, (unsigned)emem_data, (unsigned)emem_new,
               (unsigned)emem_orig, emem_count, (unsigned)ec.status);
        printf("  CTRL WRITE   new=%#010x status=%u %s\n",
               (unsigned)eops[0].regValueLo, eops[0].regStatus,
               status_name(eops[0].regStatus));
        printf("  CTRL READ    after new = %#010x status=%u %s  -> %s\n",
               eops[1].regValueLo, eops[1].regStatus, status_name(eops[1].regStatus),
               landed ? "LANDED" : "DROPPED");
        for (k = 0; k < emem_count; k++)
            printf("  DATA[%3d]    = %#010x status=%u %s\n",
                   k, eops[2 + k].regValueLo, eops[2 + k].regStatus,
                   status_name(eops[2 + k].regStatus));
        k = 2 + emem_count;
        printf("  CTRL WRITE   restore=%#010x status=%u %s\n",
               (unsigned)eops[k].regValueLo, eops[k].regStatus,
               status_name(eops[k].regStatus));
        printf("  CTRL READ    after restore = %#010x status=%u %s  -> %s\n",
               eops[k + 1].regValueLo, eops[k + 1].regStatus,
               status_name(eops[k + 1].regStatus),
               restored ? "RESTORED" : "NOT RESTORED");
        printf("  DATA final   = %#010x status=%u %s\n",
               eops[k + 2].regValueLo, eops[k + 2].regStatus,
               status_name(eops[k + 2].regStatus));
        if (!restored)
            printf("  WARNING: ctrl not back at orig -- rerun `wrr %lx %lx %lx`\n",
                   emem_ctrl, emem_orig, emem_orig);
        free(eops);
        close(fd);
        return 0;
    }

    if (sc_mode) {
        reg_op_t sops[16], wops[4];
        exec_params_t sp;
        nvos54_t sc;
        int k, pick = -1;
        uint32_t soff;

        memset(sops, 0, sizeof(sops));
        for (k = 0; k < 16; k++) {
            sops[k].regOp = REG_OP_READ_32;
            sops[k].regType = REG_TYPE_GLOBAL;
            sops[k].regOffset = 0x1400u + 4u * k;
        }
        memset(&sp, 0, sizeof(sp));
        sp.regOpCount = 16;
        sp.regOps = (NvP64)(uintptr_t)sops;
        memset(&sc, 0, sizeof(sc));
        sc.hClient = client; sc.hObject = subdevice; sc.cmd = CMD_GPU_EXEC_REG_OPS;
        sc.params = (NvP64)(uintptr_t)&sp; sc.paramsSize = sizeof(sp); sc.status = -1;
        if (rm_control(fd, &sc) < 0) { fprintf(stderr, "scratch dump: %s\n", strerror(errno)); return 1; }
        printf("scratch dump status = %#x\n", (unsigned)sc.status);
        for (k = 0; k < 16; k++) {
            printf("  SCRATCH[%2d] @%#06x = %#010x  status=%u\n", k,
                   0x1400u + 4u * k, sops[k].regValueLo, sops[k].regStatus);
            if (k >= 2 && sops[k].regStatus == 0 && sops[k].regValueLo == 0)
                pick = k;
        }
        if (pick < 0) { printf("no zero scratch available\n"); close(fd); return 0; }
        soff = 0x1400u + 4u * pick;
        printf("positive control on SCRATCH[%d] @%#x\n", pick, soff);
        memset(wops, 0, sizeof(wops));
        wops[0].regOp = REG_OP_WRITE_32; wops[0].regType = REG_TYPE_GLOBAL;
        wops[0].regOffset = soff; wops[0].regValueLo = 0x5a5aa5a5u;
        wops[0].regAndNMaskLo = ~0x5a5aa5a5u;
        wops[1].regOp = REG_OP_READ_32; wops[1].regType = REG_TYPE_GLOBAL; wops[1].regOffset = soff;
        wops[2].regOp = REG_OP_WRITE_32; wops[2].regType = REG_TYPE_GLOBAL;
        wops[2].regOffset = soff; wops[2].regValueLo = 0; wops[2].regAndNMaskLo = ~0u;
        wops[3].regOp = REG_OP_READ_32; wops[3].regType = REG_TYPE_GLOBAL; wops[3].regOffset = soff;
        memset(&sp, 0, sizeof(sp));
        sp.regOpCount = 4;
        sp.regOps = (NvP64)(uintptr_t)wops;
        memset(&sc, 0, sizeof(sc));
        sc.hClient = client; sc.hObject = subdevice; sc.cmd = CMD_GPU_EXEC_REG_OPS;
        sc.params = (NvP64)(uintptr_t)&sp; sc.paramsSize = sizeof(sp); sc.status = -1;
        if (rm_control(fd, &sc) < 0) { fprintf(stderr, "scratch rw: %s\n", strerror(errno)); return 1; }
        printf("scratch rw status = %#x\n", (unsigned)sc.status);
        for (k = 0; k < 4; k++)
            printf("  %s off=%#x status=%u value=%#010x\n",
                   wops[k].regOp == REG_OP_WRITE_32 ? "WRITE   " : "READBACK",
                   wops[k].regOffset, wops[k].regStatus, wops[k].regValueLo);
        close(fd);
        return 0;
    }

    if (name_mode) {
        struct {
            uint32_t flags;
            union { uint8_t ascii[64]; uint16_t unicode[64]; } name;
        } np;
        memset(&np, 0, sizeof(np));
        memset(&ctl, 0, sizeof(ctl));
        ctl.hClient = client;
        ctl.hObject = subdevice;
        ctl.cmd = 0x20800110u;
        ctl.params = (NvP64)(uintptr_t)&np;
        ctl.paramsSize = sizeof(np);
        ctl.status = -1;
        if (rm_control(fd, &ctl) < 0) {
            fprintf(stderr, "name control: ioctl: %s\n", strerror(errno));
            return 1;
        }
        printf("name getter status = %#x (%d): %.64s\n",
               (unsigned)ctl.status, ctl.status, (char *)np.name.ascii);
        close(fd);
        return 0;
    }

    if (rate_mode) {
        struct {
            route_info_t route;
            uint8_t imla0, fmla16, dp, fmla32, ffma, imla1, imla2, imla3, imla4;
        } rp;
        memset(&rp, 0, sizeof(rp));
        memset(&ctl, 0, sizeof(ctl));
        ctl.hClient = client;
        ctl.hObject = subdevice;
        ctl.cmd = 0x20801230u;
        ctl.params = (NvP64)(uintptr_t)&rp;
        ctl.paramsSize = sizeof(rp);
        ctl.status = -1;
        if (rm_control(fd, &ctl) < 0) {
            fprintf(stderr, "rate control: ioctl: %s\n", strerror(errno));
            return 1;
        }
        printf("rate getter status = %#x (%d)\n", (unsigned)ctl.status, ctl.status);
        printf("  imla0=%u fmla16=%u dp=%u fmla32=%u ffma=%u imla1=%u imla2=%u imla3=%u imla4=%u\n",
               rp.imla0, rp.fmla16, rp.dp, rp.fmla32, rp.ffma,
               rp.imla1, rp.imla2, rp.imla3, rp.imla4);
        close(fd);
        return 0;
    }

    if (ratev2_mode || throttle_mode) {
        static list_params_t lp;
        uint32_t k;
        memset(&lp, 0, sizeof(lp));
        lp.listSize = 0;   /* 0 = return every fuse value */
        memset(&ctl, 0, sizeof(ctl));
        ctl.hClient = client;
        ctl.hObject = subdevice;
        ctl.cmd = ratev2_mode ? CMD_GR_GET_SM_ISSUE_RATE_MODIFIER_V2
                              : CMD_GR_GET_SM_ISSUE_THROTTLE_CTRL;
        ctl.params = (NvP64)(uintptr_t)&lp;
        ctl.paramsSize = sizeof(lp);
        ctl.status = -1;
        if (rm_control(fd, &ctl) < 0) {
            fprintf(stderr, "%s: ioctl: %s\n",
                    ratev2_mode ? "ratev2" : "throttle", strerror(errno));
            return 1;
        }
        printf("%s status = %#x (%d) listSize=%u\n",
               ratev2_mode ? "ratev2" : "throttle",
               (unsigned)ctl.status, ctl.status, lp.listSize);
        for (k = 0; k < lp.listSize && k < 255; k++)
            printf("  [%2u] index=%#x data=%#x (%u)\n",
                   k, lp.list[k].index, lp.list[k].data, lp.list[k].data);
        close(fd);
        return 0;
    }

    memset(ops, 0, sizeof(ops));
    nops = (int)(sizeof(regs) / sizeof(regs[0]));
    if (one_mode)
        nops = 1;   /* single benign READ_32 of PMC_BOOT_0 */
    for (i = 0; i < nops; i++) {
        ops[i].regOp = REG_OP_READ_32;
        ops[i].regType = REG_TYPE_GLOBAL;
        ops[i].regOffset = regs[i].off;
    }
    if (wr_mode) {
        /* single write of wr_val to wr_off, then read it back */
        memset(ops, 0, sizeof(ops));
        ops[0].regOp = REG_OP_WRITE_32;
        ops[0].regType = REG_TYPE_GLOBAL;
        ops[0].regOffset = (uint32_t)wr_off;
        ops[0].regValueLo = (uint32_t)wr_val;
        ops[0].regAndNMaskLo = ~(uint32_t)wr_val;
        ops[1].regOp = REG_OP_READ_32;
        ops[1].regType = REG_TYPE_GLOBAL;
        ops[1].regOffset = (uint32_t)wr_off;
        nops = 2;
    }
    if (wrr_mode) {
        /* write new value, read back, restore original, read back */
        memset(ops, 0, sizeof(ops));
        ops[0].regOp = REG_OP_WRITE_32;
        ops[0].regType = REG_TYPE_GLOBAL;
        ops[0].regOffset = (uint32_t)wr_off;
        ops[0].regValueLo = (uint32_t)wrr_new;
        ops[0].regAndNMaskLo = ~(uint32_t)wrr_new;
        ops[1].regOp = REG_OP_READ_32;
        ops[1].regType = REG_TYPE_GLOBAL;
        ops[1].regOffset = (uint32_t)wr_off;
        ops[2].regOp = REG_OP_WRITE_32;
        ops[2].regType = REG_TYPE_GLOBAL;
        ops[2].regOffset = (uint32_t)wr_off;
        ops[2].regValueLo = (uint32_t)wrr_orig;
        ops[2].regAndNMaskLo = ~(uint32_t)wrr_orig;
        ops[3].regOp = REG_OP_READ_32;
        ops[3].regType = REG_TYPE_GLOBAL;
        ops[3].regOffset = (uint32_t)wr_off;
        nops = 4;
    }
    if (write_mode) {
        /* SS0 = 0x88888888, enable all eight fields at full rate */
        ops[nops].regOp = REG_OP_WRITE_32;
        ops[nops].regType = REG_TYPE_GLOBAL;
        ops[nops].regOffset = 0x0082381c;
        ops[nops].regValueLo = 0x88888888u;
        ops[nops].regAndNMaskLo = ~0x88888888u;
        nops++;
    }

    memset(&params, 0, sizeof(params));
    params.regOpCount = (uint32_t)nops;
    params.regOps = (NvP64)(uintptr_t)ops;

    memset(&ctl, 0, sizeof(ctl));
    ctl.hClient = client;
    ctl.hObject = subdevice;
    ctl.cmd = CMD_GPU_EXEC_REG_OPS;
    ctl.flags = 0;
    ctl.params = (NvP64)(uintptr_t)&params;
    ctl.paramsSize = sizeof(params);
    ctl.status = -1;

    if (rm_control(fd, &ctl) < 0) {
        fprintf(stderr, "control: ioctl: %s\n", strerror(errno));
        return 1;
    }
    printf("control status = %#x (%d)\n", (unsigned)ctl.status, ctl.status);

    for (i = 0; i < nops; i++) {
        const char *label = (wr_mode || wrr_mode)
            ? (ops[i].regOp == REG_OP_WRITE_32 ? "WRITE        " : "READBACK     ")
            : (i < (int)(sizeof(regs) / sizeof(regs[0])) ? regs[i].name : "WRITE_SS0    ");
        printf("  %s off=%#010x status=%-3u %-14s value=%#010x%s\n",
               label,
               ops[i].regOffset, ops[i].regStatus, status_name(ops[i].regStatus),
               ops[i].regValueLo,
               ops[i].regOp == REG_OP_WRITE_32 ? "  (write)" : "");
    }

    /* direct BAR0 comparison for the same offsets */
    {
        char path[256];
        int barfd;
        volatile uint8_t *bar;
        snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/resource0", bdf);
        barfd = open(path, O_RDONLY);
        if (barfd >= 0) {
            bar = mmap(NULL, 0x1000000, PROT_READ, MAP_SHARED, barfd, 0);
            if (bar != MAP_FAILED) {
                printf("direct BAR0 reads:\n");
                for (i = 0; i < (int)(sizeof(regs) / sizeof(regs[0])); i++) {
                    uint32_t v = *(volatile uint32_t *)(bar + regs[i].off);
                    printf("  %s = %#010x\n", regs[i].name, v);
                }
                munmap((void *)bar, 0x1000000);
            } else {
                fprintf(stderr, "mmap %s: %s\n", path, strerror(errno));
            }
            close(barfd);
        } else {
            fprintf(stderr, "open %s: %s\n", path, strerror(errno));
        }
    }

    close(fd);
    return 0;
}

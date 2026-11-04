/*
 * rm_debug_hook.c - LD_PRELOAD hook for a CUDA process.
 *
 * When the CUDA driver allocates its GT200_DEBUGGER object (class 0x83de),
 * this hook issues read-only controls on that object:
 *   - NV83DE_CTRL_CMD_DEBUG_GET_HANDLES      (0x83de0319)
 *   - NV83DE_CTRL_CMD_DEBUG_EXEC_REG_OPS     (0x83de031d), read PMC_BOOT_0
 *   - the same, read FEAT_READOUT_1 (0x823818)
 *
 * No register writes and no context state changes. The hook only uses the
 * fd and client the CUDA driver already owns.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>

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
    uint8_t  regOp, regType, regStatus, regQuad;
    uint32_t regGroupMask, regSubGroupMask, regOffset;
    uint32_t regValueHi, regValueLo, regAndNMaskHi, regAndNMaskLo;
} reg_op_t;

typedef struct {
    uint32_t bNonTransactional;
    uint32_t regOpCount;
    reg_op_t regOps[100];
} exec_regops_t;

typedef struct {
    NvHandle hChannel, hSubdevice;
} get_handles_t;

static int (*real_ioctl)(int, unsigned long, ...);
static int done;

static int rm_control(int fd, nvos54_t *c)
{
    return real_ioctl(fd,
        _IOC(_IOC_READ | _IOC_WRITE, 'F', 0x2A, sizeof(*c)), c);
}

static void read_reg(int fd, NvHandle client, NvHandle dbg, uint32_t off,
                     const char *label)
{
    exec_regops_t e;
    nvos54_t c;

    memset(&e, 0, sizeof(e));
    e.bNonTransactional = 1;
    e.regOpCount = 1;
    e.regOps[0].regOp = 0;       /* NV2080_CTRL_GPU_REG_OP_READ_32 */
    e.regOps[0].regType = 0;     /* NV2080_CTRL_GPU_REG_OP_TYPE_GLOBAL */
    e.regOps[0].regOffset = off;

    memset(&c, 0, sizeof(c));
    c.hClient = client;
    c.hObject = dbg;
    c.cmd = 0x83de031du;         /* NV83DE_CTRL_CMD_DEBUG_EXEC_REG_OPS */
    c.params = (NvP64)(uintptr_t)&e;
    c.paramsSize = sizeof(e);
    c.status = -1;

    if (rm_control(fd, &c) < 0) {
        fprintf(stderr, "DEBUG %-16s ioctl errno=%d\n", label, errno);
        return;
    }
    fprintf(stderr,
            "DEBUG %-16s status=%#x regStatus=%#x value=%#x\n",
            label, (unsigned)c.status,
            (unsigned)e.regOps[0].regStatus,
            (unsigned)e.regOps[0].regValueLo);
}

static void read_reg_type(int fd, NvHandle client, NvHandle dbg, uint32_t off,
                          uint8_t type, const char *label)
{
    exec_regops_t e;
    nvos54_t c;

    memset(&e, 0, sizeof(e));
    e.bNonTransactional = 1;
    e.regOpCount = 1;
    e.regOps[0].regOp = 0;
    e.regOps[0].regType = type;
    e.regOps[0].regOffset = off;

    memset(&c, 0, sizeof(c));
    c.hClient = client;
    c.hObject = dbg;
    c.cmd = 0x83de031du;
    c.params = (NvP64)(uintptr_t)&e;
    c.paramsSize = sizeof(e);
    c.status = -1;

    if (rm_control(fd, &c) < 0) {
        fprintf(stderr, "DEBUG %-22s ioctl errno=%d\n", label, errno);
        return;
    }
    fprintf(stderr,
            "DEBUG %-22s status=%#x regStatus=%#x value=%#x\n",
            label, (unsigned)c.status,
            (unsigned)e.regOps[0].regStatus,
            (unsigned)e.regOps[0].regValueLo);
}

static int is_sentinel(uint32_t v)
{
    switch (v) {
    case 0xbadf5040u: case 0xbadf1002u: case 0xbadf5610u:
    case 0xbadf5620u: case 0xbadf5720u: case 0xbadf5723u:
    case 0xbadf510cu: case 0xbadf5128u: case 0xbadf4100u:
    case 0xbadf5545u: case 0xbadf1100u: case 0xbadfffffu:
        return 1;
    default:
        return 0;
    }
}

static int is_badf(uint32_t v)
{
    return (v & 0xffff0000u) == 0xbadf0000u;
}

/* One non-transactional batch of read-only regops with a canary: op 0
 * re-reads PMC_BOOT_0 and must return the GB202 chip id, and the RM control
 * status must be 0. Any mismatch sets census_dead and every later batch
 * refuses to run, so a degraded read path aborts loudly instead of printing
 * silent zeros. Returns -1 on failure. Max n is 99. */
static int census_dead;

#define CENSUS_CANARY_OFF 0x00000000u    /* PMC_BOOT_0 */
#define CENSUS_CANARY_VAL 0x1b2000a1u    /* GB202 chip id */

static int census_batch(int fd, NvHandle client, NvHandle dbg,
                        const uint32_t *offs, uint32_t *vals, uint8_t *stats,
                        int n)
{
    exec_regops_t e;
    nvos54_t c;
    int k;

    if (census_dead)
        return -1;
    memset(&e, 0, sizeof(e));
    e.bNonTransactional = 1;
    e.regOpCount = (uint32_t)(n + 1);
    e.regOps[0].regOp = 0;
    e.regOps[0].regType = 0;
    e.regOps[0].regOffset = CENSUS_CANARY_OFF;
    for (k = 0; k < n; k++) {
        e.regOps[k + 1].regOp = 0;
        e.regOps[k + 1].regType = 0;
        e.regOps[k + 1].regOffset = offs[k];
    }

    memset(&c, 0, sizeof(c));
    c.hClient = client;
    c.hObject = dbg;
    c.cmd = 0x83de031du;
    c.params = (NvP64)(uintptr_t)&e;
    c.paramsSize = sizeof(e);
    c.status = -1;

    if (rm_control(fd, &c) < 0) {
        fprintf(stderr, "CENSUS ABORT: ioctl errno=%d\n", errno);
        census_dead = 1;
        return -1;
    }
    if (c.status != 0) {
        fprintf(stderr, "CENSUS ABORT: rm status=%#x near %#x\n",
                (unsigned)c.status, n > 0 ? offs[0] : 0u);
        census_dead = 1;
        return -1;
    }
    if (e.regOps[0].regStatus != 0 ||
        e.regOps[0].regValueLo != CENSUS_CANARY_VAL) {
        fprintf(stderr, "CENSUS ABORT: canary PMC_BOOT_0 = %#x (status %u) "
                "near %#x\n", e.regOps[0].regValueLo,
                (unsigned)e.regOps[0].regStatus, n > 0 ? offs[0] : 0u);
        census_dead = 1;
        return -1;
    }
    for (k = 0; k < n; k++) {
        vals[k] = e.regOps[k + 1].regValueLo;
        stats[k] = e.regOps[k + 1].regStatus;
    }
    return 0;
}

static void sweep(int fd, NvHandle client, NvHandle dbg, uint32_t base,
                  uint32_t count, uint8_t type, const char *label)
{
    uint32_t off;

    fprintf(stderr, "SWEEP %s base=%#x count=%u type=%u\n",
            label, base, count, type);

    for (off = 0; off < count; off += 100) {
        exec_regops_t e;
        nvos54_t c;
        int k, m = (int)((count - off) > 100 ? 100 : (count - off));

        memset(&e, 0, sizeof(e));
        e.bNonTransactional = 1;
        e.regOpCount = (uint32_t)m;
        for (k = 0; k < m; k++) {
            e.regOps[k].regOp = 0;
            e.regOps[k].regType = type;
            e.regOps[k].regOffset = base + 4u * (off + (uint32_t)k);
        }

        memset(&c, 0, sizeof(c));
        c.hClient = client;
        c.hObject = dbg;
        c.cmd = 0x83de031du;
        c.params = (NvP64)(uintptr_t)&e;
        c.paramsSize = sizeof(e);
        c.status = -1;

        if (rm_control(fd, &c) < 0) {
            fprintf(stderr, "SWEEP %s ioctl errno=%d\n", label, errno);
            return;
        }
        {
            int sent = 0;

            for (k = 0; k < m; k++) {
                uint32_t v = e.regOps[k].regValueLo;

                if (e.regOps[k].regStatus != 0) {
                    fprintf(stderr, "  %s %#010x status=%u\n", label,
                            e.regOps[k].regOffset,
                            (unsigned)e.regOps[k].regStatus);
                } else if (v != 0 && !is_sentinel(v)) {
                    fprintf(stderr, "  %s %#010x = %#010x\n", label,
                            e.regOps[k].regOffset, (unsigned)v);
                } else if (v != 0) {
                    sent++;
                }
            }
            fprintf(stderr, "  %s batch %#x..%#x: sentinels=%d\n", label,
                    base + 4u * off, base + 4u * (off + (uint32_t)m - 1),
                    sent);
        }
    }
}

/*
 * map_steps - like sweep_steps, but every non-zero value is printed,
 * sentinels included. A map of a register range where the sentinel
 * boundaries are themselves the data.
 */
static void map_steps(int fd, NvHandle client, NvHandle dbg, uint32_t base,
                      uint32_t count, uint32_t step, uint8_t type,
                      const char *label)
{
    uint32_t off;

    fprintf(stderr, "MAP %s base=%#x count=%u step=%#x type=%u\n",
            label, base, count, step, type);

    for (off = 0; off < count; off += 100) {
        exec_regops_t e;
        nvos54_t c;
        int k, m = (int)((count - off) > 100 ? 100 : (count - off));
        int nz = 0, bad = 0;

        memset(&e, 0, sizeof(e));
        e.bNonTransactional = 1;
        e.regOpCount = (uint32_t)m;
        for (k = 0; k < m; k++) {
            e.regOps[k].regOp = 0;
            e.regOps[k].regType = type;
            e.regOps[k].regOffset = base + step * (off + (uint32_t)k);
        }

        memset(&c, 0, sizeof(c));
        c.hClient = client;
        c.hObject = dbg;
        c.cmd = 0x83de031du;
        c.params = (NvP64)(uintptr_t)&e;
        c.paramsSize = sizeof(e);
        c.status = -1;

        if (rm_control(fd, &c) < 0) {
            fprintf(stderr, "MAP %s ioctl errno=%d\n", label, errno);
            return;
        }

        for (k = 0; k < m; k++) {
            uint32_t v = e.regOps[k].regValueLo;

            if (e.regOps[k].regStatus != 0) {
                bad++;
                fprintf(stderr, "  MAP %s %#010x status=%u\n", label,
                        e.regOps[k].regOffset,
                        (unsigned)e.regOps[k].regStatus);
            } else if (v != 0) {
                nz++;
                fprintf(stderr, "  MAP %s %#010x = %#010x%s\n", label,
                        e.regOps[k].regOffset, (unsigned)v,
                        is_sentinel(v) ? " sentinel" : "");
            }
        }
        fprintf(stderr, "  MAP %s batch %#x..%#x: nonzero=%d bad=%d zeros=%d\n",
                label, base + step * off,
                base + step * (off + (uint32_t)m - 1), nz, bad, m - nz - bad);
    }
}

static void sweep_steps(int fd, NvHandle client, NvHandle dbg, uint32_t base,
                        uint32_t count, uint32_t step, uint8_t type,
                        const char *label)
{
    uint32_t off;

    fprintf(stderr, "SWEEP %s base=%#x count=%u step=%#x type=%u\n",
            label, base, count, step, type);

    for (off = 0; off < count; off += 100) {
        exec_regops_t e;
        nvos54_t c;
        int k, m = (int)((count - off) > 100 ? 100 : (count - off));

        memset(&e, 0, sizeof(e));
        e.bNonTransactional = 1;
        e.regOpCount = (uint32_t)m;
        for (k = 0; k < m; k++) {
            e.regOps[k].regOp = 0;
            e.regOps[k].regType = type;
            e.regOps[k].regOffset = base + step * (off + (uint32_t)k);
        }

        memset(&c, 0, sizeof(c));
        c.hClient = client;
        c.hObject = dbg;
        c.cmd = 0x83de031du;
        c.params = (NvP64)(uintptr_t)&e;
        c.paramsSize = sizeof(e);
        c.status = -1;

        if (rm_control(fd, &c) < 0) {
            fprintf(stderr, "SWEEP %s ioctl errno=%d\n", label, errno);
            return;
        }

        for (k = 0; k < m; k++) {
            uint32_t v = e.regOps[k].regValueLo;

            if (e.regOps[k].regStatus != 0)
                fprintf(stderr, "  %s %#010x status=%u\n", label,
                        e.regOps[k].regOffset,
                        (unsigned)e.regOps[k].regStatus);
            else if (v != 0 && !is_sentinel(v))
                fprintf(stderr, "  %s %#010x = %#010x\n", label,
                        e.regOps[k].regOffset, (unsigned)v);
        }
    }
}

static void write_reg(int fd, NvHandle client, NvHandle dbg, uint32_t off,
                      uint32_t val, const char *label)
{
    exec_regops_t e;
    nvos54_t c;

    memset(&e, 0, sizeof(e));
    e.bNonTransactional = 1;
    e.regOpCount = 1;
    e.regOps[0].regOp = 1;       /* NV2080_CTRL_GPU_REG_OP_WRITE_32 */
    e.regOps[0].regType = 0;     /* GLOBAL */
    e.regOps[0].regOffset = off;
    e.regOps[0].regValueLo = val;
    e.regOps[0].regAndNMaskLo = ~val;

    memset(&c, 0, sizeof(c));
    c.hClient = client;
    c.hObject = dbg;
    c.cmd = 0x83de031du;
    c.params = (NvP64)(uintptr_t)&e;
    c.paramsSize = sizeof(e);
    c.status = -1;

    if (rm_control(fd, &c) < 0) {
        fprintf(stderr, "DEBUG write %-16s ioctl errno=%d\n", label, errno);
        return;
    }
    fprintf(stderr, "DEBUG write %-16s status=%#x regStatus=%#x val=%#x\n",
            label, (unsigned)c.status, (unsigned)e.regOps[0].regStatus,
            (unsigned)val);
}

static void on_debugger_alloc(int fd, nvos21_t *a)
{
    static const struct { uint32_t off; const char *name; } regs[] = {
        { 0x00000000u, "PMC_BOOT_0" },
        { 0x00823804u, "FEAT_OVR_PLM" },
        { 0x00823814u, "FEAT_READOUT_0" },
        { 0x00823818u, "FEAT_READOUT_1" },
        { 0x0082381cu, "SS0" },
        { 0x00823820u, "SS1" },
        { 0x008207d8u, "FUSE_SS_FMLA32" },
        { 0x008200fcu, "FUSE_SS_PLM" },
        { 0x008203f0u, "OPT_FEATURE_FUSES_OVERRIDE_DISABLE" },
        { 0x0082038cu, "SEC_WORD_82038c" },
        { 0x008200d0u, "SEC_WORD_8200d0" },
    };
    unsigned i;

    fprintf(stderr, "DEBUG object root=%#x parent=%#x handle=%#x\n",
            a->hRoot, a->hObjectParent, a->hObjectNew);

    for (i = 0; i < sizeof(regs) / sizeof(regs[0]); i++)
        read_reg(fd, a->hRoot, a->hObjectNew, regs[i].off, regs[i].name);

    /* Offsets the generic subdevice regop path rejected as caller-identity
     * failures; the debugger object has a real channel/subdevice context. */
    read_reg_type(fd, a->hRoot, a->hObjectNew, 0x00504204u, 0x01,
                  "GR_CTX 0x504204");
    read_reg_type(fd, a->hRoot, a->hObjectNew, 0x00504204u, 0x02,
                  "TPC 0x504204");
    read_reg_type(fd, a->hRoot, a->hObjectNew, 0x00504204u, 0x04,
                  "SM 0x504204");
    read_reg_type(fd, a->hRoot, a->hObjectNew, 0x00504204u, 0x40,
                  "QUAD 0x504204");
    read_reg_type(fd, a->hRoot, a->hObjectNew, 0x00137200u, 0x00,
                  "0x137200 GLOBAL");

    /* Secure-core apertures that returned sentinels to the host/GSP. */
    {
        static const struct { uint32_t off; const char *name; } blocks[] = {
            { 0x00137100u, "BLOCK 0x137100" },
            { 0x00137204u, "BLOCK 0x137204" },
            { 0x00137208u, "BLOCK 0x137208" },
            { 0x0013720cu, "BLOCK 0x13720c" },
            { 0x00137300u, "BLOCK 0x137300" },
            { 0x00840000u, "SEC2 0x840000" },
            { 0x008401c0u, "SEC2 0x8401c0" },
            { 0x008403c4u, "SEC2 0x8403c4" },
            { 0x008f0000u, "FSP 0x8f0000" },
            { 0x008f03d0u, "FSP 0x8f03d0" },
            { 0x008f2ac0u, "FSP 0x8f2ac0" },
            { 0x008f3000u, "FSP 0x8f3000" },
            { 0x00110000u, "GSP 0x110000" },
            { 0x001103d0u, "GSP 0x1103d0" },
            { 0x001113d0u, "GSP 0x1113d0" },
            { 0x00820040u, "FUSE 0x820040" },
            { 0x008200d0u, "FUSE 0x8200d0" },
        };
        unsigned j;

        for (j = 0; j < sizeof(blocks) / sizeof(blocks[0]); j++)
            read_reg_type(fd, a->hRoot, a->hObjectNew, blocks[j].off, 0x00,
                          blocks[j].name);
    }

    sweep(fd, a->hRoot, a->hObjectNew, 0x00137000u, 0x400u, 0x00,
          "0x137000");
    sweep(fd, a->hRoot, a->hObjectNew, 0x00504240u, 0x30u, 0x01,
          "0x504240 GR_CTX");
    sweep(fd, a->hRoot, a->hObjectNew, 0x00823800u, 0x40u, 0x01,
          "0x823800 GR_CTX");

    /*
     * Read-only falcon probe: the standard FALCON register block at the
     * known engine bases, the FPF ucode-version fuse arrays, and the FECS
     * 0x409bxx block. No writes, no falcon port cycles.
     * Disabled unless RM_DEBUG_FALCON=1.
     */
    if (getenv("RM_DEBUG_FALCON") && strcmp(getenv("RM_DEBUG_FALCON"), "1") == 0) {
        static const struct { uint32_t base; const char *name; } falcons[] = {
            { 0x0010a000u, "PMU" },
            { 0x00110000u, "GSP" },
            { 0x008f0000u, "FSP" },
            { 0x00409000u, "FECS" },
            { 0x0041a000u, "GPCCS" },
            { 0x00840000u, "SEC2" },
        };
        static const struct { uint32_t off; const char *name; } fregs[] = {
            { 0x000u, "BASE" },       { 0x004u, "IRQSCLR" },
            { 0x040u, "MAILBOX0" },   { 0x0f0u, "HWCFG" },
            { 0x0f4u, "HWCFG2" },     { 0x100u, "CPUCTL" },
            { 0x104u, "BOOTVEC" },    { 0x10cu, "DMACTL" },
            { 0x198u, "BROM_UCODE_ID" }, { 0x19cu, "BROM_ENGIDMASK" },
            { 0x3c0u, "ENGINE_RESET" },  { 0x40cu, "MAILBOX_TEST" },
        };
        char label[64];
        unsigned k, r;

        for (k = 0; k < sizeof(falcons) / sizeof(falcons[0]); k++) {
            for (r = 0; r < sizeof(fregs) / sizeof(fregs[0]); r++) {
                snprintf(label, sizeof(label), "%s+%#04x %s",
                         falcons[k].name, fregs[r].off, fregs[r].name);
                read_reg_type(fd, a->hRoot, a->hObjectNew,
                              falcons[k].base + fregs[r].off, 0x00, label);
            }
        }

        /* FPF ucode-version fuse arrays: 16 words per engine (open driver
         * NV_FUSE_OPT_FPF_{SEC2,NVDEC,GSP}_UCODE1_VERSION). */
        {
            static const struct { uint32_t base; const char *name; } arrays[] = {
                { 0x00824100u, "FPF_NVDEC" },
                { 0x00824140u, "FPF_SEC2" },
                { 0x008241c0u, "FPF_GSP" },
            };
            for (k = 0; k < sizeof(arrays) / sizeof(arrays[0]); k++) {
                for (r = 0; r < 16; r++) {
                    snprintf(label, sizeof(label), "%s_UCODE%u_VERSION",
                             arrays[k].name, r + 1);
                    read_reg_type(fd, a->hRoot, a->hObjectNew,
                                  arrays[k].base + r * 4, 0x00, label);
                }
            }
        }

        /* FECS 0x409bxx block: the GSP-RM gr_fecs allowlist names these. */
        for (r = 0; r < 8; r++) {
            snprintf(label, sizeof(label), "FECS 0x409b%02x", r * 4);
            read_reg_type(fd, a->hRoot, a->hObjectNew,
                          0x00409b00u + r * 4, 0x00, label);
        }
    }

    /*
     * GR window probe: the GSP-RM gr_fecs allowlist admits 0x409b00,
     * 0x409b78 and the 0x140000-0x17ffff range. Read the window at page
     * starts and one dense page, plus the 0x409bxx cluster. Read-only.
     * Disabled unless RM_DEBUG_GRWIN=1.
     */
    if (getenv("RM_DEBUG_GRWIN") && strcmp(getenv("RM_DEBUG_GRWIN"), "1") == 0) {
        sweep_steps(fd, a->hRoot, a->hObjectNew, 0x00140000u, 0x40u, 4u, 0x00,
                    "0x140000 dense");
        sweep_steps(fd, a->hRoot, a->hObjectNew, 0x00140000u, 0x400u, 0x400u,
                    0x00, "0x140000 pages");
        sweep_steps(fd, a->hRoot, a->hObjectNew, 0x0017f000u, 0x400u, 0x4u, 0x00,
                    "0x17f000 dense");
        sweep_steps(fd, a->hRoot, a->hObjectNew, 0x00409b00u, 0x20u, 0x4u, 0x00,
                    "0x409b00");
    }

    /*
     * Per-card GR block probe: dump 0x1f2000-0x1f3fff densely, the same
     * range as GR_CTX, and the FEAT/FPF fuse windows for comparison.
     * Read-only. Disabled unless RM_DEBUG_GRBLK=1.
     */
    if (getenv("RM_DEBUG_GRBLK") && strcmp(getenv("RM_DEBUG_GRBLK"), "1") == 0) {
        map_steps(fd, a->hRoot, a->hObjectNew, 0x001f2000u, 0x800u, 4u, 0x00,
                  "0x1f2000 full");
        map_steps(fd, a->hRoot, a->hObjectNew, 0x001f2000u, 0x800u, 4u, 0x01,
                  "0x1f2000 ctx");
        map_steps(fd, a->hRoot, a->hObjectNew, 0x00823800u, 0x80u, 4u, 0x00,
                  "0x823800 feat");
        map_steps(fd, a->hRoot, a->hObjectNew, 0x00824100u, 0x40u, 4u, 0x00,
                  "0x824100 fpf");
        map_steps(fd, a->hRoot, a->hObjectNew, 0x00824140u, 0x40u, 4u, 0x00,
                  "0x824140 fpf");
        map_steps(fd, a->hRoot, a->hObjectNew, 0x008241c0u, 0x40u, 4u, 0x00,
                  "0x8241c0 fpf");
        {
            static const uint32_t probes[] = { 0x1f2000u, 0x1f2080u, 0x1f2100u };
            char lbl[48];
            int t;
            size_t i;

            for (t = 0; t <= 4; t++) {
                for (i = 0; i < sizeof(probes) / sizeof(probes[0]); i++) {
                    snprintf(lbl, sizeof(lbl), "%#x type%d", probes[i], t);
                    read_reg_type(fd, a->hRoot, a->hObjectNew, probes[i],
                                  (uint8_t)t, lbl);
                }
            }
        }
    }

    /*
     * GR map probe: sweep the space above the admitted window
     * (0x180000-0x23ffff) at page starts, read the blocks that answered in
     * the earlier coarse sweep densely, refine each boundary at 0x100 steps,
     * and continue a coarse 0x10000 sweep to 0x400000 to find where the
     * space ends. Every non-zero value is printed, sentinels included.
     * Read-only. Disabled unless RM_DEBUG_GRMAP=1.
     */
    if (getenv("RM_DEBUG_GRMAP") && strcmp(getenv("RM_DEBUG_GRMAP"), "1") == 0) {
        map_steps(fd, a->hRoot, a->hObjectNew, 0x00180000u, 0xc0u, 0x1000u, 0x00,
                  "0x180000 pages");
        map_steps(fd, a->hRoot, a->hObjectNew, 0x001c0000u, 0x40u, 4u, 0x00,
                  "0x1c0000 dense");
        map_steps(fd, a->hRoot, a->hObjectNew, 0x001c7000u, 0x40u, 0x100u, 0x00,
                  "0x1c7000 boundary");
        map_steps(fd, a->hRoot, a->hObjectNew, 0x001c7f00u, 0x40u, 4u, 0x00,
                  "0x1c7f00 dense");
        map_steps(fd, a->hRoot, a->hObjectNew, 0x001c8000u, 0x40u, 4u, 0x00,
                  "0x1c8000 dense");
        map_steps(fd, a->hRoot, a->hObjectNew, 0x001cbc00u, 0x40u, 4u, 0x00,
                  "0x1cbc00 dense");
        map_steps(fd, a->hRoot, a->hObjectNew, 0x001f1000u, 0x40u, 0x100u, 0x00,
                  "0x1f1000 boundary");
        map_steps(fd, a->hRoot, a->hObjectNew, 0x001f2000u, 0x40u, 4u, 0x00,
                  "0x1f2000 dense");
        map_steps(fd, a->hRoot, a->hObjectNew, 0x001f4000u, 0x40u, 4u, 0x00,
                  "0x1f4000 dense");
        map_steps(fd, a->hRoot, a->hObjectNew, 0x0022b000u, 0x60u, 0x100u, 0x00,
                  "0x22b000 boundary");
        map_steps(fd, a->hRoot, a->hObjectNew, 0x0022c000u, 0x40u, 4u, 0x00,
                  "0x22c000 dense");
        map_steps(fd, a->hRoot, a->hObjectNew, 0x00240000u, 0x1cu, 0x10000u, 0x00,
                  "0x240000 coarse");
        map_steps(fd, a->hRoot, a->hObjectNew, 0x00290000u, 0x40u, 4u, 0x00,
                  "0x290000 dense");
        map_steps(fd, a->hRoot, a->hObjectNew, 0x00300000u, 0x40u, 4u, 0x00,
                  "0x300000 dense");
        map_steps(fd, a->hRoot, a->hObjectNew, 0x00310000u, 0x400u, 4u, 0x00,
                  "0x310000 page4k");
        map_steps(fd, a->hRoot, a->hObjectNew, 0x00300400u, 0x300u, 4u, 0x00,
                  "0x300400 page4k");
        map_steps(fd, a->hRoot, a->hObjectNew, 0x00300000u, 0x20u, 0x1000u, 0x00,
                  "0x300000 pages");
        map_steps(fd, a->hRoot, a->hObjectNew, 0x0030f000u, 0x400u, 4u, 0x00,
                  "0x30f000 page4k");
        map_steps(fd, a->hRoot, a->hObjectNew, 0x00311000u, 0x400u, 4u, 0x00,
                  "0x311000 page4k");
        map_steps(fd, a->hRoot, a->hObjectNew, 0x00240000u, 0xc0u, 0x1000u, 0x00,
                  "0x240000 pages");
        map_steps(fd, a->hRoot, a->hObjectNew, 0x002ff000u, 0x400u, 4u, 0x00,
                  "0x2ff000 page4k");
        map_steps(fd, a->hRoot, a->hObjectNew, 0x004ff000u, 0x400u, 4u, 0x00,
                  "0x4ff000 page4k");
        map_steps(fd, a->hRoot, a->hObjectNew, 0x00500000u, 0x40u, 4u, 0x00,
                  "0x500000 dense");
    }

    /*
     * C29 engine-map census, read-only, v2. Every batch carries a PMC_BOOT_0
     * canary and an RM-status check; any mismatch aborts the census instead
     * of printing silent zeros. Runs small passes first so a late abort
     * still leaves the valuable data in the log. Pass order C, A, D, B:
     *
     *  C. dense follow-ups: labeled signature reads at the six documented
     *     falcon bases plus 0x500000/0x1c0000/0x1c8000/0x22c000, the
     *     0x1c0000 header, the 0x1ce000 page, and the 0x500000 block at
     *     decreasing stride.
     *  A. falcon signature: at every 0x1000-aligned base in [0, 0x1000000),
     *     skipping the 0x300000-0x400000 hazard, read +0xf4 (HWCFG2),
     *     +0x100 (CPUCTL), +0x3c0 (ENGINE_RESET). A row is flagged when
     *     HWCFG2 answers non-sentinel and non-zero, when ENGINE_RESET reads
     *     0x200, or when all three answer non-sentinel. The GSP, FSP, and
     *     SEC2 bases must flag; PMU, FECS, and GPCCS must not.
     *  D. a 0x10000-stride probe from 0x1000000 to the 64 MiB BAR0 end,
     *     plus a re-dump of the per-card 0x1f2000 table.
     *  B. coarse map: one read at every 0x100-aligned X in
     *     [0x500000, 0x1000000). The doorbell/echo geometry is derived
     *     offline from this map; no live X+0x300 reads (the v1 census
     *     crashed GSP-RM with a read near 0x42f900-0x431004, and the band
     *     0x42f804-0x500000 stays unscanned).
     *
     * No writes, no falcon port cycles. Master switch RM_DEBUG_CENSUS=1 runs
     * everything; RM_DEBUG_CENSUS_NAME / RM_DEBUG_CENSUS_1F2 /
     * RM_DEBUG_CENSUS_B (with CENSUS_B_START / CENSUS_B_END hex bounds) run
     * one follow-up each in a fresh client, for when the master run aborted
     * partway or a sub-pass needs its own budget.
     */
    {
    int cen_all = getenv("RM_DEBUG_CENSUS") &&
                  strcmp(getenv("RM_DEBUG_CENSUS"), "1") == 0;
    int cen_name = getenv("RM_DEBUG_CENSUS_NAME") &&
                   strcmp(getenv("RM_DEBUG_CENSUS_NAME"), "1") == 0;
    int cen_1f2 = getenv("RM_DEBUG_CENSUS_1F2") &&
                  strcmp(getenv("RM_DEBUG_CENSUS_1F2"), "1") == 0;
    int cen_b = getenv("RM_DEBUG_CENSUS_B") &&
                strcmp(getenv("RM_DEBUG_CENSUS_B"), "1") == 0;
    if (cen_all || cen_name || cen_1f2 || cen_b) {
        uint32_t offs[100], vals[100];
        uint8_t stats[100];
        uint32_t base, x;
        int k;

        /*
         * Naming pass: the full falcon register set at every candidate the
         * signature census flagged, plus the three live secure cores as
         * calibration. The BROM ucode-id at +0x198 is the discriminator
         * against the vBIOS ucode table targets (0x01 = PMU family).
         */
        if (cen_all || cen_name) {
            static const struct { uint32_t base; const char *name; } cand[] = {
                { 0x00110000u, "GSP" },      { 0x008f0000u, "FSP" },
                { 0x00840000u, "SEC2" },
                { 0x001cc000u, "CAND1CC" },  { 0x001ce000u, "CAND1CE" },
                { 0x001d0000u, "CAND1D0" },  { 0x001d2000u, "CAND1D2" },
                { 0x001d4000u, "CAND1D4" },  { 0x001d6000u, "CAND1D6" },
                { 0x0040c000u, "CAND40C" },  { 0x0042f000u, "CAND42F" },
                { 0x0050f000u, "CAND50F" },  { 0x0055f000u, "CAND55F" },
                { 0x005af000u, "CAND5AF" },
                { 0x00651000u, "CAND651" },
                { 0x00844000u, "CAND844" },  { 0x00848000u, "CAND848" },
                { 0x00854000u, "CAND854" },  { 0x008f4000u, "CAND8F4" },
                { 0x009a4000u, "CAND9A4" },  { 0x009c0000u, "CAND9C0" },
                { 0x009d8000u, "CAND9D8" },  { 0x00d40000u, "CANDD40" },
                { 0x001c8000u, "CAND1C8" },
            };
            static const struct { uint32_t off; const char *name; } nregs[] = {
                { 0x040u, "MAILBOX0" },  { 0x044u, "MAILBOX1" },
                { 0x0f0u, "HWCFG" },     { 0x0f4u, "HWCFG2" },
                { 0x100u, "CPUCTL" },    { 0x104u, "BOOTVEC" },
                { 0x10cu, "DMACTL" },    { 0x198u, "UCODE_ID" },
                { 0x19cu, "ENGIDMASK" }, { 0x3c0u, "ENGRESET" },
            };
            unsigned ci, ri;

            fprintf(stderr, "CENSUS N: naming pass, %u bases x %u regs\n",
                    (unsigned)(sizeof(cand) / sizeof(cand[0])),
                    (unsigned)(sizeof(nregs) / sizeof(nregs[0])));
            for (ci = 0; ci < sizeof(cand) / sizeof(cand[0]) && !census_dead;
                 ci++) {
                fprintf(stderr, "CENSUS NAME %s base=%#010x\n",
                        cand[ci].name, cand[ci].base);
                for (ri = 0; ri < sizeof(nregs) / sizeof(nregs[0]); ri++)
                    offs[ri] = cand[ci].base + nregs[ri].off;
                if (census_batch(fd, a->hRoot, a->hObjectNew,
                                 offs, vals, stats,
                                 (int)(sizeof(nregs) / sizeof(nregs[0]))) == 0)
                    for (ri = 0; ri < sizeof(nregs) / sizeof(nregs[0]); ri++)
                        fprintf(stderr, "CENSUS NAME   %-9s +%#04x = "
                                "%#010x%s\n", nregs[ri].name,
                                nregs[ri].off, vals[ri],
                                is_badf(vals[ri]) ? " sentinel" : "");
            }
            fprintf(stderr, "CENSUS N: done%s\n",
                    census_dead ? " (ABORTED)" : "");
        }

        if (!cen_all) {
            /* follow-up-only runs skip the master passes except the
             * requested ones below */
        }

        /* --- pass C: dense follow-ups first --- */
        if (cen_all) {
        fprintf(stderr, "CENSUS C: dense follow-ups\n");
        {
            static const struct { uint32_t base; const char *name; } bases[] = {
                { 0x0010a000u, "PMU" },   { 0x00110000u, "GSP" },
                { 0x008f0000u, "FSP" },   { 0x00409000u, "FECS" },
                { 0x0041a000u, "GPCCS" }, { 0x00840000u, "SEC2" },
                { 0x00500000u, "BLK500000" },
                { 0x001c0000u, "BLK1C0000" },
                { 0x001c8000u, "BLK1C8000" },
                { 0x0022c000u, "BLK22C000" },
            };
            unsigned bi;

            for (bi = 0; bi < sizeof(bases) / sizeof(bases[0]); bi++) {
                offs[0] = bases[bi].base + 0xf4u;
                offs[1] = bases[bi].base + 0x100u;
                offs[2] = bases[bi].base + 0x3c0u;
                if (census_batch(fd, a->hRoot, a->hObjectNew,
                                 offs, vals, stats, 3) == 0)
                    fprintf(stderr, "CENSUS SIG %-10s base=%#010x "
                            "HWCFG2=%#010x(s%u) CPUCTL=%#010x(s%u) "
                            "ENGRESET=%#010x(s%u)\n",
                            bases[bi].name, bases[bi].base,
                            vals[0], stats[0], vals[1], stats[1],
                            vals[2], stats[2]);
            }

            /* 0x1c0000 header and the 0x1ce000 page at 4-byte stride */
            for (k = 0; k < 0x50 / 4; k++)
                offs[k] = 0x001c0000u + 4u * (uint32_t)k;
            if (census_batch(fd, a->hRoot, a->hObjectNew,
                             offs, vals, stats, 0x50 / 4) == 0)
                for (k = 0; k < 0x50 / 4; k++)
                    if (vals[k] != 0)
                        fprintf(stderr, "CENSUS 1C0000 +%03x = %#010x%s\n",
                                4 * k, vals[k], is_badf(vals[k]) ?
                                " sentinel" : "");
            for (k = 0; k < 0x40 / 4; k++)
                offs[k] = 0x001ce000u + 4u * (uint32_t)k;
            if (census_batch(fd, a->hRoot, a->hObjectNew,
                             offs, vals, stats, 0x40 / 4) == 0)
                for (k = 0; k < 0x40 / 4; k++)
                    if (vals[k] != 0)
                        fprintf(stderr, "CENSUS 1CE000 +%03x = %#010x%s\n",
                                4 * k, vals[k], is_badf(vals[k]) ?
                                " sentinel" : "");

            /* 0x500000 block: dense core, then decreasing stride outward */
            for (k = 0; k < 0x80 / 4; k++)
                offs[k] = 0x00500000u + 4u * (uint32_t)k;
            if (census_batch(fd, a->hRoot, a->hObjectNew,
                             offs, vals, stats, 0x80 / 4) == 0)
                for (k = 0; k < 0x80 / 4; k++)
                    if (vals[k] != 0)
                        fprintf(stderr, "CENSUS 500000 +%03x = %#010x%s\n",
                                4 * k, vals[k], is_badf(vals[k]) ?
                                " sentinel" : "");
            for (x = 0x80; x < 0x400; x += 0x10) {
                offs[0] = 0x00500000u + x;
                if (census_batch(fd, a->hRoot, a->hObjectNew,
                                 &offs[0], vals, stats, 1) == 0 &&
                    vals[0] != 0)
                    fprintf(stderr, "CENSUS 500000 +%03x = %#010x%s\n",
                            x, vals[0], is_badf(vals[0]) ? " sentinel" : "");
            }
            for (x = 0x400; x < 0x10000; x += 0x1000) {
                offs[0] = 0x00500000u + x;
                if (census_batch(fd, a->hRoot, a->hObjectNew,
                                 offs, vals, stats, 1) == 0 &&
                    vals[0] != 0)
                    fprintf(stderr, "CENSUS 500000 +%05x = %#010x%s\n",
                            x, vals[0], is_badf(vals[0]) ? " sentinel" : "");
            }
            fprintf(stderr, "CENSUS C: done%s\n",
                    census_dead ? " (ABORTED)" : "");
        }
        }

        /* --- pass A: falcon signature at 0x1000-aligned bases --- */
        if (cen_all) {
        fprintf(stderr, "CENSUS A: falcon signature, step 0x1000, "
                "range 0..0x1000000, skip 0x300000..0x400000\n");
        {
            int nb = 0;            /* bases in the pending batch */
            uint32_t bbatch[33];   /* the batch's real base addresses */

            for (base = 0; base < 0x1000000u && !census_dead;
                 base += 0x1000u) {
                if (base >= 0x300000u && base < 0x400000u)
                    continue;
                bbatch[nb] = base;
                offs[3 * nb + 0] = base + 0xf4u;
                offs[3 * nb + 1] = base + 0x100u;
                offs[3 * nb + 2] = base + 0x3c0u;
                nb++;
                if (nb == 33) {
                    if (census_batch(fd, a->hRoot, a->hObjectNew,
                                     offs, vals, stats, 99) == 0) {
                        for (k = 0; k < nb; k++) {
                            uint32_t B = bbatch[k];
                            uint32_t hw = vals[3 * k + 0];
                            uint32_t cc = vals[3 * k + 1];
                            uint32_t er = vals[3 * k + 2];
                            int live = 0;

                            if (!is_badf(hw) && hw != 0)
                                live = 1;
                            if (er == 0x200u)
                                live = 1;
                            if (!is_badf(hw) && !is_badf(cc) && !is_badf(er))
                                live = 1;
                            if (live)
                                fprintf(stderr, "CENSUS FALCON? base=%#010x "
                                        "HWCFG2=%#010x(s%u) CPUCTL=%#010x(s%u)"
                                        " ENGRESET=%#010x(s%u)\n",
                                        B, hw, stats[3 * k + 0],
                                        cc, stats[3 * k + 1],
                                        er, stats[3 * k + 2]);
                        }
                    }
                    nb = 0;
                }
            }
            if (nb > 0 && !census_dead) {
                if (census_batch(fd, a->hRoot, a->hObjectNew,
                                 offs, vals, stats, 3 * nb) == 0) {
                    for (k = 0; k < nb; k++) {
                        uint32_t B = bbatch[k];
                        uint32_t hw = vals[3 * k + 0];
                        uint32_t cc = vals[3 * k + 1];
                        uint32_t er = vals[3 * k + 2];
                        int live = 0;

                        if (!is_badf(hw) && hw != 0)
                            live = 1;
                        if (er == 0x200u)
                            live = 1;
                        if (!is_badf(hw) && !is_badf(cc) && !is_badf(er))
                            live = 1;
                        if (live)
                            fprintf(stderr, "CENSUS FALCON? base=%#010x "
                                    "HWCFG2=%#010x(s%u) CPUCTL=%#010x(s%u)"
                                    " ENGRESET=%#010x(s%u)\n",
                                    B, hw, stats[3 * k + 0],
                                    cc, stats[3 * k + 1],
                                    er, stats[3 * k + 2]);
                    }
                }
            }
            fprintf(stderr, "CENSUS A: done%s\n",
                    census_dead ? " (ABORTED)" : "");
        }
        }

        /* --- pass D: top-of-BAR0 probe and the 0x1f2000 re-dump --- */
        if (cen_all) {
        fprintf(stderr, "CENSUS D: 0x10000-stride probe 0x1000000..0x4000000, "
                "then the 0x1f2000 table\n");
        {
            for (x = 0x1000000u; x < 0x4000000u && !census_dead;
                 x += 0x10000u) {
                offs[0] = x;
                if (census_batch(fd, a->hRoot, a->hObjectNew,
                                 offs, vals, stats, 1) == 0 &&
                    vals[0] != 0)
                    fprintf(stderr, "CENSUS TOP %#010x = %#010x%s\n",
                            x, vals[0], is_badf(vals[0]) ? " sentinel" : "");
            }
            fprintf(stderr, "CENSUS D: top probe done%s\n",
                    census_dead ? " (ABORTED)" : "");
        }
        }

        if (cen_all || cen_1f2) {
            fprintf(stderr, "CENSUS 1F2: re-dump of the 0x1f2000 table\n");
            {
                uint32_t done_words = 0;

                while (done_words < 0x800u && !census_dead) {
                    /* 99 data ops max: the canary takes the 100th slot */
                    int nw = (int)((0x800u - done_words) > 99u ?
                                   99u : (0x800u - done_words));

                    for (k = 0; k < nw; k++)
                        offs[k] = 0x001f2000u +
                                  4u * (done_words + (uint32_t)k);
                    if (census_batch(fd, a->hRoot, a->hObjectNew,
                                     offs, vals, stats, nw) == 0)
                        for (k = 0; k < nw; k++)
                            if (vals[k] != 0)
                                fprintf(stderr, "CENSUS 1F2000 %#010x = "
                                        "%#010x%s\n", offs[k], vals[k],
                                        is_badf(vals[k]) ? " sentinel" : "");
                    done_words += (uint32_t)nw;
                }
            }
            fprintf(stderr, "CENSUS 1F2: done%s\n",
                    census_dead ? " (ABORTED)" : "");
        }

        /* --- pass B: single-read coarse map at 0x100 stride --- */
        if (cen_all || cen_b) {
        {
            uint32_t b_start = 0x500000u, b_end = 0x1000000u;
            const char *bs = getenv("CENSUS_B_START");
            const char *be = getenv("CENSUS_B_END");
            int nx = 0;            /* X candidates in the pending batch */
            uint32_t xbatch[99];   /* the batch's real X addresses */
            uint32_t reg_zeros = 0, reg_badf = 0, reg_live = 0, reg_stat = 0;
            uint32_t sum_region;

            if (bs) b_start = (uint32_t)strtoul(bs, NULL, 16);
            if (be) b_end = (uint32_t)strtoul(be, NULL, 16);
            sum_region = b_start;
            fprintf(stderr, "CENSUS B: coarse map, step 0x100, single read, "
                    "range %#x..%#x (0x42f804..0x500000 unscanned)\n",
                    b_start, b_end);

            for (x = b_start; x < b_end && !census_dead;
                 x += 0x100u) {
                xbatch[nx] = x;
                offs[nx] = x;
                nx++;
                if (nx == 99) {
                    if (census_batch(fd, a->hRoot, a->hObjectNew,
                                     offs, vals, stats, 99) == 0) {
                        for (k = 0; k < nx; k++) {
                            uint32_t X = xbatch[k];
                            uint32_t v = vals[k];

                            if (stats[k] != 0) {
                                reg_stat++;
                                fprintf(stderr, "CENSUS MAP %#010x "
                                        "status=%u\n", X, stats[k]);
                            } else if (v == 0) {
                                reg_zeros++;
                            } else if (is_badf(v)) {
                                reg_badf++;
                                fprintf(stderr, "CENSUS MAP %#010x = "
                                        "%#010x sentinel\n", X, v);
                            } else {
                                reg_live++;
                                fprintf(stderr, "CENSUS MAP %#010x = "
                                        "%#010x\n", X, v);
                            }
                        }
                    }
                    nx = 0;
                }
                if (((x + 0x100u) & 0xffffu) == 0) {
                    fprintf(stderr, "CENSUS B: region %#010x..%#010x "
                            "zeros=%u badf=%u live=%u stat=%u\n",
                            sum_region, x, reg_zeros, reg_badf,
                            reg_live, reg_stat);
                    sum_region = x + 0x100u;
                    reg_zeros = reg_badf = reg_live = reg_stat = 0;
                }
            }
            fprintf(stderr, "CENSUS B: done%s\n",
                    census_dead ? " (ABORTED)" : "");
        }
        }

        fprintf(stderr, "CENSUS: complete%s\n",
                census_dead ? " (ABORTED)" : "");
    }
    }

    /*
     * Benign write probe: FEAT_OVR_QUADRO (0x823808) is a per-card
     * classification word, not rate or ECC. Flip one bit, read back,
     * restore, read back. A silent PLM drop leaves the value unchanged.
     * Disabled unless RM_DEBUG_WRITE=1; the default hook is read-only.
     */
    if (getenv("RM_DEBUG_WRITE") && strcmp(getenv("RM_DEBUG_WRITE"), "1") == 0) {
        exec_regops_t e;
        nvos54_t c;
        uint32_t orig = 0, after_w = 0, after_r = 0;

        memset(&e, 0, sizeof(e));
        e.bNonTransactional = 1;
        e.regOpCount = 1;
        e.regOps[0].regOp = 0;
        e.regOps[0].regType = 0;
        e.regOps[0].regOffset = 0x00823808u;
        memset(&c, 0, sizeof(c));
        c.hClient = a->hRoot;
        c.hObject = a->hObjectNew;
        c.cmd = 0x83de031du;
        c.params = (NvP64)(uintptr_t)&e;
        c.paramsSize = sizeof(e);
        c.status = -1;
        if (rm_control(fd, &c) == 0)
            orig = e.regOps[0].regValueLo;
        fprintf(stderr, "DEBUG QUADRO orig=%#x\n", (unsigned)orig);

        write_reg(fd, a->hRoot, a->hObjectNew, 0x00823808u,
                  orig ^ 0x1u, "QUADRO flip");

        memset(&e, 0, sizeof(e));
        e.bNonTransactional = 1;
        e.regOpCount = 1;
        e.regOps[0].regOp = 0;
        e.regOps[0].regType = 0;
        e.regOps[0].regOffset = 0x00823808u;
        memset(&c, 0, sizeof(c));
        c.hClient = a->hRoot;
        c.hObject = a->hObjectNew;
        c.cmd = 0x83de031du;
        c.params = (NvP64)(uintptr_t)&e;
        c.paramsSize = sizeof(e);
        c.status = -1;
        if (rm_control(fd, &c) == 0)
            after_w = e.regOps[0].regValueLo;
        fprintf(stderr, "DEBUG QUADRO after flip=%#x\n", (unsigned)after_w);

        write_reg(fd, a->hRoot, a->hObjectNew, 0x00823808u,
                  orig, "QUADRO restore");
        memset(&e, 0, sizeof(e));
        e.bNonTransactional = 1;
        e.regOpCount = 1;
        e.regOps[0].regOp = 0;
        e.regOps[0].regType = 0;
        e.regOps[0].regOffset = 0x00823808u;
        memset(&c, 0, sizeof(c));
        c.hClient = a->hRoot;
        c.hObject = a->hObjectNew;
        c.cmd = 0x83de031du;
        c.params = (NvP64)(uintptr_t)&e;
        c.paramsSize = sizeof(e);
        c.status = -1;
        if (rm_control(fd, &c) == 0)
            after_r = e.regOps[0].regValueLo;
        fprintf(stderr, "DEBUG QUADRO restored=%#x\n", (unsigned)after_r);
    }
}

int ioctl(int fd, unsigned long req, ...)
{
    va_list ap;
    void *arg = NULL;
    int ret;

    va_start(ap, req);
    arg = va_arg(ap, void *);
    va_end(ap);

    if (!real_ioctl) {
        real_ioctl = dlsym(RTLD_NEXT, "ioctl");
    }

    ret = real_ioctl(fd, req, arg);

    if (!done && ret == 0 && arg &&
        _IOC_TYPE(req) == 'F' && _IOC_NR(req) == 0x2B) {
        nvos21_t *a = arg;

        if (a->hClass == 0x83de && a->status == 0 && a->hObjectNew != 0) {
            done = 1;
            fprintf(stderr,
                    "DEBUG alloc class=0x83de root=%#x parent=%#x new=%#x\n",
                    a->hRoot, a->hObjectParent, a->hObjectNew);
            on_debugger_alloc(fd, a);
        }
    }

    return ret;
}

/*
 * c27_hook.c - LD_PRELOAD hook that runs the C27 debugger-class command census.
 *
 * C27 asks which commands of the exposed GT200_DEBUGGER class (0x83de) beyond
 * the register-op command actually work on GB202, and whether any of them is a
 * new read surface.  This hook:
 *
 *   - tracks NV_ESC_RM_ALLOC so it knows the CUDA client, the debuggee channel
 *     (the parent of the compute class object), and candidate memory handles;
 *   - captures the CUDA driver's own debugger object when it is allocated;
 *   - exports c27_run(), which the CUDA probe calls after cuCtxCreate and after
 *     a kernel launch, so the GR context is real and resident.
 *
 * Only reads are issued by default.  SUSPEND/RESUME run only when
 * C27_SUSPEND=1.  A refused command can drop the CUDA context; nothing here
 * touches registers or firmware memory.
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
typedef uint8_t  NvBool;

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

/* ---- public ctrl83de structures (ctrl83dedebug.h) ---------------------- */

typedef struct {
    uint32_t hwwGlobalEsr;
    uint32_t hwwWarpEsr;
    uint32_t hwwWarpEsrPc;
    uint32_t hwwGlobalEsrReportMask;
    uint32_t hwwWarpEsrReportMask;
    uint64_t hwwEsrAddr;
    uint64_t hwwWarpEsrPc64;
    uint32_t hwwCgaEsr;
    uint32_t hwwCgaEsrReportMask;
} __attribute__((aligned(8))) sm_error_state_t;

typedef struct {
    NvHandle hTargetChannel;
    uint32_t numSMsToRead;
    sm_error_state_t smErrorStateArray[100];
    uint32_t mmuFaultInfo;
    struct { NvBool valid; uint32_t faultInfo; } mmuFault;
    uint32_t startingSM;
} read_all_sm_t;

typedef struct {
    NvHandle hTargetChannel;
    uint32_t smID;
    sm_error_state_t smErrorState;
} read_single_sm_t;

typedef struct {
    uint64_t gpuVA;
    uint32_t size;
} __attribute__((aligned(8))) mapping_op_t;

typedef struct {
    uint64_t vaLo;
    uint64_t vaHi;
    uint32_t count;
    uint32_t hasMore;
    mapping_op_t opsBuffer[64];
} __attribute__((aligned(8))) get_mappings_t;

typedef struct {
    uint64_t gpuVA;
    NvP64    pCpuVA;
    uint32_t size;
    uint32_t valid;
} __attribute__((aligned(8))) access_op_t;

typedef struct {
    uint32_t count;
    access_op_t opsBuffer[64];
} __attribute__((aligned(8))) access_surface_t;

typedef struct {
    uint32_t hMemory;
    uint32_t length;
    uint64_t offset;
    NvP64    buffer;
} __attribute__((aligned(8))) read_memory_t;

typedef struct {
    uint32_t waitForEvent;
    NvHandle hResidentChannel;
} suspend_t;

typedef struct {
    uint32_t smID;
    struct { NvBool bInTrapMode, bCrsFlushDone, bRunTriggerInProgress,
             bComputeContext, bLockedDown; } st;
} single_sm_status_t;

typedef struct {
    struct { uint64_t faultAddress; uint32_t faultType, accessType; } list[4];
    uint32_t count;
} __attribute__((aligned(8))) mmu_fault_info_t;

typedef struct {
    uint32_t value;
} dbg_mode_t;

/* ---- ioctl plumbing ---------------------------------------------------- */

#define NV_ESC_RM_ALLOC   0x2B
#define NV_ESC_RM_CONTROL 0x2A
#define NV_CTRL_IOC_SIZE  sizeof(nvos54_t)

static int (*real_ioctl)(int, unsigned long, ...);
static __thread int in_hook;
static int g_fd = -1;
static int g_done;

typedef struct {
    NvHandle h, parent, root;
    int32_t  cls;
    uint32_t param_size;
    uint64_t param_ptr;
} alloc_rec_t;
#define MAX_ALLOCS 4096
static alloc_rec_t g_allocs[MAX_ALLOCS];
static int g_nallocs;

static NvHandle g_client, g_debugger, g_device, g_channel, g_compute;
static int g_have_debugger;
static int g_quiet;

static void rec_alloc(const nvos21_t *a)
{
    if (g_nallocs >= MAX_ALLOCS)
        return;
    g_allocs[g_nallocs].h = a->hObjectNew;
    g_allocs[g_nallocs].parent = a->hObjectParent;
    g_allocs[g_nallocs].root = a->hRoot;
    g_allocs[g_nallocs].cls = a->hClass;
    g_allocs[g_nallocs].param_size = a->paramsSize;
    g_allocs[g_nallocs].param_ptr = (uint64_t)(uintptr_t)a->pAllocParms;
    g_nallocs++;
}

static NvHandle parent_of(NvHandle h)
{
    int i;
    for (i = g_nallocs - 1; i >= 0; i--)
        if (g_allocs[i].h == h)
            return g_allocs[i].parent;
    return 0;
}

static void on_debugger_alloc(const nvos21_t *a)
{
    /* NV83DE_ALLOC_PARAMETERS: obsolete, hAppClient, hClass3dObject. */
    uint32_t parms[3] = {0, 0, 0};

    if (a->pAllocParms)
        memcpy(parms, (const void *)(uintptr_t)a->pAllocParms, sizeof(parms));

    g_client = a->hRoot;
    g_debugger = a->hObjectNew;
    g_device = a->hObjectParent;
    g_compute = parms[2];
    g_channel = parent_of(g_compute);
    g_have_debugger = 1;

    fprintf(stderr,
            "C27 debugger handle=%#x client=%#x device=%#x compute=%#x "
            "channel=%#x\n",
            g_debugger, g_client, g_device, g_compute, g_channel);
}

static uint32_t rm_control(NvHandle client, NvHandle object, uint32_t cmd,
                           void *params, uint32_t size, const char *label)
{
    nvos54_t c;
    int ret;

    memset(&c, 0, sizeof(c));
    c.hClient = client;
    c.hObject = object;
    c.cmd = (int32_t)cmd;
    c.params = (NvP64)(uintptr_t)params;
    c.paramsSize = size;
    c.status = -1;

    ret = real_ioctl(g_fd, _IOC(_IOC_READ | _IOC_WRITE, 'F',
                                NV_ESC_RM_CONTROL, NV_CTRL_IOC_SIZE), &c);
    if (!g_quiet)
        fprintf(stderr, "C27 %-42s status=%#x%s\n", label,
                (unsigned)c.status, ret < 0 ? " ioctl-fail" : "");
    return (uint32_t)c.status;
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

static int interesting(uint32_t v)
{
    return v != 0 && !is_sentinel(v);
}

/* ---- the census -------------------------------------------------------- */

static void scan_sm_array(const read_all_sm_t *p, const char *tag)
{
    static const uint32_t pats[] = {
        0x00c36180u, 0x21265043u, 0x00000006u, 0xfffffb8fu,
        0x00823818u, 0x50420400u, 0x00000233u,
    };
    unsigned i, k;
    int nonzero = 0, hits = 0;

    for (i = 0; i < p->numSMsToRead && i < 100; i++) {
        const sm_error_state_t *s = &p->smErrorStateArray[i];
        const uint32_t *w = (const uint32_t *)s;
        unsigned n = sizeof(*s) / 4;

        for (k = 0; k < n; k++) {
            if (!interesting(w[k]))
                continue;
            nonzero++;
            if (i < 4) {
                fprintf(stderr, "C27   SM%-3u word%-2u = %#010x\n",
                        p->startingSM + i, k, w[k]);
            }
            {
                unsigned q;
                for (q = 0; q < sizeof(pats) / sizeof(pats[0]); q++) {
                    if (w[k] == pats[q] || (w[k] & 0xffffff00u) == (pats[q] & 0xffffff00u)) {
                        fprintf(stderr, "C27   HIT %s SM%u word%u = %#010x\n",
                                tag, i, k, w[k]);
                        hits++;
                    }
                }
            }
        }
    }
    fprintf(stderr, "C27   %s: SMs=%u nonzero_words=%d pattern_hits=%d "
            "mmuFault.valid=%u faultInfo=%#x deprecated=%#x\n",
            tag, p->numSMsToRead, nonzero, hits,
            (unsigned)p->mmuFault.valid, p->mmuFault.faultInfo,
            p->mmuFaultInfo);
}

static void do_get_mappings(uint64_t lo, uint64_t hi, int max_pages)
{
    int page;
    uint64_t cur = lo;

    for (page = 0; page < max_pages; page++) {
        get_mappings_t g;
        uint32_t st;
        char label[96];
        uint32_t i;

        memset(&g, 0, sizeof(g));
        g.vaLo = cur;
        g.vaHi = hi;
        snprintf(label, sizeof(label), "GET_MAPPINGS %#llx-%#llx",
                 (unsigned long long)cur, (unsigned long long)hi);
        st = rm_control(g_client, g_debugger, 0x83de031cu, &g,
                        sizeof(g), label);
        if (st != 0)
            return;
        fprintf(stderr, "C27   mappings count=%u hasMore=%u\n",
                g.count, g.hasMore);
        for (i = 0; i < g.count && i < 64; i++) {
            fprintf(stderr, "C27   map %#018llx size=%#x\n",
                    (unsigned long long)g.opsBuffer[i].gpuVA,
                    g.opsBuffer[i].size);
        }
        if (!g.hasMore || g.count == 0)
            return;
        cur = g.opsBuffer[g.count - 1].gpuVA + g.opsBuffer[g.count - 1].size;
        if (cur <= g.vaLo)
            return;
    }
}

static void do_read_surface(const uint64_t *vas, unsigned nvas)
{
    access_surface_t s;
    uint8_t buf[64];
    unsigned i;

    for (i = 0; i < nvas && i < 64; i++) {
        uint32_t st;

        memset(&s, 0, sizeof(s));
        memset(buf, 0, sizeof(buf));
        s.count = 1;
        s.opsBuffer[0].gpuVA = vas[i];
        s.opsBuffer[0].pCpuVA = (NvP64)(uintptr_t)buf;
        s.opsBuffer[0].size = sizeof(buf);

        st = rm_control(g_client, g_debugger, 0x83de031au, &s, sizeof(s),
                        "READ_SURFACE");
        fprintf(stderr, "C27   surface VA=%#018llx valid=%u status=%#x "
                "head=%02x%02x%02x%02x%02x%02x%02x%02x\n",
                (unsigned long long)vas[i], s.opsBuffer[0].valid, st,
                buf[0], buf[1], buf[2], buf[3], buf[4], buf[5], buf[6], buf[7]);
    }
}

static void do_batch_read(int found)
{
    struct __attribute__((aligned(8))) {
        NvP64    pData;
        uint32_t dataLength;
        uint32_t count;
        struct __attribute__((aligned(8))) {
            NvHandle hMemory;
            uint32_t length;
            uint64_t memOffset;
            uint32_t dataOffset;
            int32_t  status;
        } entries[150];
    } b;
    uint8_t data[128];
    uint32_t st;
    unsigned i;

    if (found < 0)
        return;
    /* First a valid one-entry batch, so a refusal is the command, not the
     * invalid entry. */
    memset(&b, 0, sizeof(b));
    memset(data, 0, sizeof(data));
    b.pData = (NvP64)(uintptr_t)data;
    b.dataLength = sizeof(data);
    b.count = 1;
    b.entries[0].hMemory = g_allocs[found].h;
    b.entries[0].length = 64;
    b.entries[0].memOffset = 0;
    b.entries[0].dataOffset = 0;
    st = rm_control(g_client, g_debugger, 0x83de0326u, &b, sizeof(b),
                    "READ_BATCH_MEMORY one valid");
    fprintf(stderr, "C27   batch1 status=%#x data[0..7]=",
            (unsigned)b.entries[0].status);
    for (i = 0; i < 8; i++)
        fprintf(stderr, "%02x", data[i]);
    fprintf(stderr, " cmd_status=%#x\n", st);

    memset(&b, 0, sizeof(b));
    memset(data, 0, sizeof(data));
    b.pData = (NvP64)(uintptr_t)data;
    b.dataLength = sizeof(data);
    b.count = 3;
    b.entries[0].hMemory = g_allocs[found].h;
    b.entries[0].length = 64;
    b.entries[0].memOffset = 0;
    b.entries[0].dataOffset = 0;
    b.entries[1].hMemory = g_allocs[found].h;
    b.entries[1].length = 16;
    b.entries[1].memOffset = 0x1000;
    b.entries[1].dataOffset = 64;
    b.entries[2].hMemory = g_device;
    b.entries[2].length = 16;
    b.entries[2].memOffset = 0;
    b.entries[2].dataOffset = 80;

    st = rm_control(g_client, g_debugger, 0x83de0326u, &b, sizeof(b),
                    "READ_BATCH_MEMORY mixed");
    for (i = 0; i < b.count; i++)
        fprintf(stderr, "C27   batch %u h=%#x len=%u off=%#llx "
                "dataOff=%u status=%#x\n", i, b.entries[i].hMemory,
                b.entries[i].length,
                (unsigned long long)b.entries[i].memOffset,
                b.entries[i].dataOffset, (unsigned)b.entries[i].status);
    fprintf(stderr, "C27   batch data[0..15]=");
    for (i = 0; i < 16; i++)
        fprintf(stderr, "%02x", data[i]);
    fprintf(stderr, " cmd_status=%#x\n", st);
}

static void do_read_memory(uint64_t devptr)
{
    uint8_t buf[64];
    unsigned i;
    int found = -1;

    /* Candidate handles: memory-class allocations (0x40 local user, 0x70
     * virtual, 0x3e/0x40 context objects seen in the CUDA captures), plus
     * the non-memory handles as negative controls. */
    for (i = 0; i < (unsigned)g_nallocs && i < 512; i++) {
        read_memory_t r;
        uint32_t st;
        char label[96];
        unsigned k;

        if (g_allocs[i].root != g_client)
            continue;
        memset(&r, 0, sizeof(r));
        memset(buf, 0, sizeof(buf));
        r.hMemory = g_allocs[i].h;
        r.length = sizeof(buf);
        r.offset = 0;
        r.buffer = (NvP64)(uintptr_t)buf;
        snprintf(label, sizeof(label), "READ_MEMORY h=%#x cls=%#x",
                 g_allocs[i].h, g_allocs[i].cls);
        st = rm_control(g_client, g_debugger, 0x83de0315u, &r, sizeof(r),
                        label);
        if (st != 0)
            continue;
        for (k = 0; k + 32 <= sizeof(buf); k += 4) {
            if (buf[k] == 0xc2 && buf[k + 1] == 0x7c &&
                buf[k + 2] == 0xc2 && buf[k + 3] == 0x7c) {
                fprintf(stderr, "C27   PATTERN at h=%#x off=%u\n",
                        g_allocs[i].h, k);
                found = (int)i;
                break;
            }
        }
        if (found >= 0)
            break;
    }

    if (found >= 0) {
        /* Characterize validation on the handle that worked. */
        static const struct { uint32_t off, len; const char *name; } v[] = {
            {0x0, 0x10, "h+0/16"},
            {0x0, 0x0, "h+0/0"},
            {0x1000, 0x10, "h+1000/16"},
            {0x100000, 0x10, "h+100000/16"},
        };
        unsigned j;
        for (j = 0; j < sizeof(v) / sizeof(v[0]); j++) {
            read_memory_t r;
            char label[96];
            memset(&r, 0, sizeof(r));
            r.hMemory = g_allocs[found].h;
            r.offset = v[j].off;
            r.length = v[j].len;
            r.buffer = (NvP64)(uintptr_t)buf;
            snprintf(label, sizeof(label), "READ_MEMORY %s", v[j].name);
            rm_control(g_client, g_debugger, 0x83de0315u, &r, sizeof(r),
                       label);
        }
    }

    do_batch_read(found);

    /* Negative controls: non-memory and null handles. */
    {
        struct { NvHandle h; const char *name; } bad[6];
        unsigned j;

        bad[0].h = 0;           bad[0].name = "null";
        bad[1].h = 1;           bad[1].name = "handle1";
        bad[2].h = g_device;    bad[2].name = "device";
        bad[3].h = g_channel;   bad[3].name = "channel";
        bad[4].h = g_compute;   bad[4].name = "compute";
        bad[5].h = g_debugger;  bad[5].name = "debugger";
        for (j = 0; j < sizeof(bad) / sizeof(bad[0]); j++) {
            read_memory_t r;
            char label[96];
            memset(&r, 0, sizeof(r));
            r.hMemory = bad[j].h;
            r.length = 16;
            r.offset = 0;
            r.buffer = (NvP64)(uintptr_t)buf;
            snprintf(label, sizeof(label), "READ_MEMORY neg %s", bad[j].name);
            rm_control(g_client, g_debugger, 0x83de0315u, &r, sizeof(r),
                       label);
        }
    }
    fprintf(stderr, "C27   read_memory devptr=%#llx found_handle=%s\n",
            (unsigned long long)devptr, found >= 0 ? "yes" : "no");
}

/*
 * Scan readable objects for a copy of the rate state.  The SM error-state
 * path returned zeros; this checks the client's own context/ring buffers for
 * any FEAT bank or selector shadow.
 */
static void scan_objects(void)
{
    static const struct { uint32_t v; const char *name; } pats[] = {
        {0x00c36180u, "READOUT_1"},
        {0x21265043u, "SS0 card1"},
        {0x54226037u, "SS0 card2"},
        {0x00000006u, "SS1 card1"},
        {0x00026005u, "SS1 card2"},
        {0xfffffb8fu, "PLM stock"},
        {0x00823804u, "FEAT_OVR_PLM addr"},
        {0x00504204u, "SM_ISSUE_RATE_MODIFIER"},
        {0x008207d8u, "FUSE_SS_FMLA32 addr"},
    };
    uint8_t *buf = NULL;
    int i;

    buf = malloc(0x4000);
    if (!buf)
        return;
    g_quiet = 1;

    for (i = 0; i < g_nallocs && i < 512; i++) {
        uint64_t off;
        int readable = 0;

        if (g_allocs[i].root != g_client)
            continue;
        for (off = 0; off < 0x40000; off += 0x4000) {
            read_memory_t r;
            uint32_t st;
            unsigned k;

            memset(&r, 0, sizeof(r));
            memset(buf, 0, 0x4000);
            r.hMemory = g_allocs[i].h;
            r.offset = off;
            r.length = 0x4000;
            r.buffer = (NvP64)(uintptr_t)buf;
            st = rm_control(g_client, g_debugger, 0x83de0315u, &r,
                            sizeof(r), "SCAN chunk");
            if (st != 0) {
                if (off == 0)
                    break;
                break;
            }
            readable = 1;
            for (k = 0; k + 4 <= 0x4000; k += 4) {
                uint32_t w;
                unsigned q;
                memcpy(&w, buf + k, 4);
                for (q = 0; q < sizeof(pats) / sizeof(pats[0]); q++) {
                    if (w == pats[q].v) {
                        fprintf(stderr,
                                "C27   SCAN HIT %s = %#010x at h=%#x "
                                "cls=%#x off=%#llx\n",
                                pats[q].name, w, g_allocs[i].h,
                                g_allocs[i].cls,
                                (unsigned long long)(off + k));
                    }
                }
            }
        }
        if (readable)
            fprintf(stderr, "C27   scanned h=%#x cls=%#x\n",
                    g_allocs[i].h, g_allocs[i].cls);
    }
    g_quiet = 0;
    free(buf);
}

/*
 * Dump the first readable handle of each distinct class and probe its size.
 * This answers the other half of the C27 question: once READ_MEMORY is known
 * to work, what does the class reach that the caller could not map?
 */
static void dump_objects(void)
{
    int32_t seen[32];
    int nseen = 0;
    int i;

    for (i = 0; i < g_nallocs && i < 512; i++) {
        read_memory_t r;
        uint8_t buf[64];
        uint32_t st;
        int j, dup = 0;
        static const uint32_t offs[] = {
            0x0u, 0x1000u, 0x10000u, 0x100000u, 0x1000000u, 0x10000000u,
        };
        unsigned k;

        if (g_allocs[i].root != g_client)
            continue;
        for (j = 0; j < nseen; j++)
            if (seen[j] == g_allocs[i].cls)
                dup = 1;
        if (dup)
            continue;
        if (nseen < 32)
            seen[nseen++] = g_allocs[i].cls;

        memset(&r, 0, sizeof(r));
        memset(buf, 0, sizeof(buf));
        r.hMemory = g_allocs[i].h;
        r.length = sizeof(buf);
        r.buffer = (NvP64)(uintptr_t)buf;
        st = rm_control(g_client, g_debugger, 0x83de0315u, &r, sizeof(r),
                        "DUMP first-of-class");
        if (st != 0) {
            fprintf(stderr, "C27   class %#x h=%#x not readable\n",
                    g_allocs[i].cls, g_allocs[i].h);
            continue;
        }
        fprintf(stderr, "C27   class %#x h=%#x head=", g_allocs[i].cls,
                g_allocs[i].h);
        for (k = 0; k < 16; k++)
            fprintf(stderr, "%02x", buf[k]);
        fprintf(stderr, "\n");
        for (k = 0; k < sizeof(offs) / sizeof(offs[0]); k++) {
            char label[64];
            if (offs[k] == 0)
                continue;
            memset(&r, 0, sizeof(r));
            memset(buf, 0, sizeof(buf));
            r.hMemory = g_allocs[i].h;
            r.offset = offs[k];
            r.length = 16;
            r.buffer = (NvP64)(uintptr_t)buf;
            snprintf(label, sizeof(label), "DUMP class %#x +%#x",
                     g_allocs[i].cls, offs[k]);
            st = rm_control(g_client, g_debugger, 0x83de0315u, &r,
                            sizeof(r), label);
            if (st == 0) {
                fprintf(stderr, "C27     +%#x = ", offs[k]);
                for (j = 0; j < 16; j++)
                    fprintf(stderr, "%02x", buf[j]);
                fprintf(stderr, "\n");
            }
        }
    }
}

void c27_run(uint64_t devptr, uint64_t devsize)
{
    read_all_sm_t all;
    read_single_sm_t one;
    single_sm_status_t sst;
    mmu_fault_info_t fault;
    dbg_mode_t mode;
    unsigned i;

    (void)devsize;
    if (!g_have_debugger || g_fd < 0) {
        fprintf(stderr, "C27 no debugger/fd captured\n");
        return;
    }

    fprintf(stderr, "C27 === census start client=%#x debugger=%#x "
            "channel=%#x compute=%#x allocs=%d ===\n",
            g_client, g_debugger, g_channel, g_compute, g_nallocs);

    /* 1. Handles.  Public header says debug/develop builds only. */
    {
        struct { NvHandle hChannel, hSubdevice; } h = {0, 0};
        rm_control(g_client, g_debugger, 0x83de0319u, &h, sizeof(h),
                   "GET_HANDLES");
        fprintf(stderr, "C27   hChannel=%#x hSubdevice=%#x\n",
                h.hChannel, h.hSubdevice);
    }

    /* 2. Mode getters (safe). */
    mode.value = 0;
    rm_control(g_client, g_debugger, 0x83de0308u, &mode, sizeof(mode),
               "GET_MODE_MMU_DEBUG");
    fprintf(stderr, "C27   mmuDebug=%u\n", mode.value);
    mode.value = 0;
    rm_control(g_client, g_debugger, 0x83de0320u, &mode, sizeof(mode),
               "GET_MODE_ERRBAR_DEBUG");
    fprintf(stderr, "C27   errbarDebug=%u\n", mode.value);

    /* 3. SM error states.  Needs a resident GR context. */
    memset(&all, 0, sizeof(all));
    all.hTargetChannel = g_channel;
    all.numSMsToRead = 100;
    all.startingSM = 0;
    rm_control(g_client, g_debugger, 0x83de030cu, &all, sizeof(all),
               "READ_ALL_SM_ERROR_STATES sm0..99");
    scan_sm_array(&all, "all-sm0");

    /* GB202 has more than 100 SMs; read the remaining 70.  The RM rejects a
     * request that runs past the device's SM count, which is why 100 at
     * startingSM 100 failed on the first pass. */
    memset(&all, 0, sizeof(all));
    all.hTargetChannel = g_channel;
    all.numSMsToRead = 70;
    all.startingSM = 100;
    rm_control(g_client, g_debugger, 0x83de030cu, &all, sizeof(all),
               "READ_ALL_SM_ERROR_STATES sm100..169");
    scan_sm_array(&all, "all-sm100");

    memset(&one, 0, sizeof(one));
    one.hTargetChannel = g_channel;
    one.smID = 0;
    rm_control(g_client, g_debugger, 0x83de030bu, &one, sizeof(one),
               "READ_SINGLE_SM_ERROR_STATE sm0");
    {
        const uint32_t *w = (const uint32_t *)&one.smErrorState;
        for (i = 0; i < sizeof(one.smErrorState) / 4; i++)
            if (interesting(w[i]))
                fprintf(stderr, "C27   single SM0 word%-2u = %#010x\n",
                        i, w[i]);
    }

    memset(&sst, 0, sizeof(sst));
    sst.smID = 0;
    rm_control(g_client, g_debugger, 0x83de0325u, &sst, sizeof(sst),
               "GET_SINGLE_SM_DEBUGGER_STATUS sm0");
    fprintf(stderr, "C27   sm0 trap=%u crs=%u run=%u compute=%u locked=%u\n",
            sst.st.bInTrapMode, sst.st.bCrsFlushDone,
            sst.st.bRunTriggerInProgress, sst.st.bComputeContext,
            sst.st.bLockedDown);

    memset(&fault, 0, sizeof(fault));
    rm_control(g_client, g_debugger, 0x83de0328u, &fault, sizeof(fault),
               "READ_MMU_FAULT_INFO");
    for (i = 0; i < fault.count && i < 4; i++)
        fprintf(stderr, "C27   mmu fault %u addr=%#llx type=%u access=%u\n",
                i, (unsigned long long)fault.list[i].faultAddress,
                fault.list[i].faultType, fault.list[i].accessType);

    /* 4. Mappings.  The debuggee VAS is the CUDA VAS on this channel.
     * CUDA device pointers sit high (the probe buffer is around 0x7c...),
     * so query the buffer's own neighborhood, not just low VA. */
    do_get_mappings(0, 0x10000000000ull, 2);      /* 1 TiB, low */
    do_get_mappings(devptr & ~0xfffffull,
                    (devptr & ~0xfffffull) + 0x400000ull, 4);
    do_get_mappings(devptr, devptr + 0x10000ull, 2);
    do_get_mappings(0x7f0000000000ull, 0x7f1000000000ull, 2);

    /* 5. Surface reads: our buffer, then RM/engine VA candidates. */
    {
        uint64_t vas[8] = {
            devptr, 0x93000000ull, 0x01000000ull, 0x04000000ull,
            0x20393000ull, 0x100000000ull, 0x1000000000ull, 0x7f0000000ull,
        };
        do_read_surface(vas, 8);
    }

    /* 6. Memory reads with positive and negative controls. */
    do_read_memory(devptr);

    /* 6b. What the readable handles actually contain, one per class. */
    if (getenv("C27_DUMP") && strcmp(getenv("C27_DUMP"), "1") == 0)
        dump_objects();

    /* 6c. Search readable objects for a copy of the rate state. */
    if (getenv("C27_SCAN") && strcmp(getenv("C27_SCAN"), "1") == 0)
        scan_objects();

    /* 7. Optional suspend/resume: state-changing, so last and opt-in. */
    if (getenv("C27_SUSPEND") && strcmp(getenv("C27_SUSPEND"), "1") == 0) {
        suspend_t s;
        memset(&s, 0, sizeof(s));
        s.waitForEvent = 0;
        s.hResidentChannel = g_channel;
        rm_control(g_client, g_debugger, 0x83de0317u, &s, sizeof(s),
                   "SUSPEND_CONTEXT");
        fprintf(stderr, "C27   waitForEvent=%u\n", s.waitForEvent);
        rm_control(g_client, g_debugger, 0x83de0318u, NULL, 0,
                   "RESUME_CONTEXT");
    }

    fprintf(stderr, "C27 === census done ===\n");
}

/* ---- ioctl interposer -------------------------------------------------- */

int ioctl(int fd, unsigned long req, ...)
{
    va_list ap;
    void *arg = NULL;
    int ret;

    va_start(ap, req);
    arg = va_arg(ap, void *);
    va_end(ap);

    if (!real_ioctl)
        real_ioctl = dlsym(RTLD_NEXT, "ioctl");

    ret = real_ioctl(fd, req, arg);

    if (!in_hook && arg && _IOC_TYPE(req) == 'F') {
        unsigned long nr = _IOC_NR(req);

        in_hook = 1;
        if (nr == NV_ESC_RM_ALLOC) {
            nvos21_t *a = arg;
            if (ret == 0 && a->status == 0) {
                g_fd = fd;
                rec_alloc(a);
                if (a->hClass == 0x83de && !g_done) {
                    g_done = 1;
                    on_debugger_alloc(a);
                }
            }
        }
        in_hook = 0;
    }

    return ret;
}

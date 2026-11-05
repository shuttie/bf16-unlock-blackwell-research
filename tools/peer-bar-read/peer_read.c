// peer_read.c -- aim a second GPU's DMA engine at the first GPU's BAR1.
//
// The host reads the protected WPR through its own BAR1/PRAMIN route and gets
// the 0xbad0ac00 fill. This asks the other question: does a *peer* engine's
// PCIe read of the same VRAM offset take the same enforcement path?
//
// Method:
//   1. positive control: cuMemcpyPeer on an ordinary allocation (CE over PCIe).
//   2. map GPU0's BAR1 window through sysfs and read it from the CPU, the
//      host route, so every target has a same-offset reference.
//   3. register the window with CUDA as I/O memory (CU_MEMHOSTREGISTER_IOMEMORY)
//      and copy it into GPU1 with GPU1's copy engine. That DMA's source address
//      is GPU0's BAR1 bus address, i.e. a peer PCIe read.
//   4. compare the peer read with the host read.
//
// Build: gcc -O2 -o peer_read peer_read.c -lcuda
// Run as root (the BAR1 resource files are 0600) with the peer GPU idle.
//
// Exit codes: 0 ran, 1 setup error, 2 no usable peer path.

#define _GNU_SOURCE
#include <cuda.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define PAGE_SZ 4096ULL
#define GIB (1024ULL * 1024ULL * 1024ULL)

static int failures = 0;

static void out(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    fflush(stdout);
}

static const char *curc(CUresult r)
{
    static __thread char buf[160];
    const char *s = "?";
    cuGetErrorString(r, &s);
    snprintf(buf, sizeof(buf), "%s (0x%x)", s ? s : "?", (unsigned)r);
    return buf;
}

static CUresult cu_check(CUresult r, const char *what)
{
    out("RESULT %-28s -> %s\n", what, r == CUDA_SUCCESS ? "ok" : curc(r));
    if (r != CUDA_SUCCESS)
        failures++;
    return r;
}

static int find_device(const char *bdf, CUdevice *dev)
{
    int n = 0;
    if (cuDeviceGetCount(&n) != CUDA_SUCCESS || n == 0) {
        out("ERROR no CUDA devices\n");
        return -1;
    }
    for (int i = 0; i < n; i++) {
        char id[64] = {0};
        if (cuDeviceGetPCIBusId(id, sizeof(id), i) != CUDA_SUCCESS)
            continue;
        const char *a = id, *b = bdf;
        // accept "0000:41:00.0" or "41:00.0"
        if (strlen(b) == 7 && strlen(a) == 12)
            a += 5;
        if (!strcasecmp(a, b)) {
            *dev = i;
            return 0;
        }
    }
    out("ERROR device %s not found\n", bdf);
    return -1;
}

struct window {
    const char *name;
    const char *bdf;
    int bar;
    uint64_t off;
    size_t len;
    int fd;
    void *va;
    unsigned char *host;
};

// Map a PCI resource window through sysfs. Root only.
static int map_window(struct window *w)
{
    char path[256];
    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/resource%d", w->bdf, w->bar);
    w->fd = open(path, O_RDONLY | O_CLOEXEC);
    if (w->fd < 0) {
        out("RESULT map:%-20s -> open %s failed: %s\n", w->name, path, strerror(errno));
        return -1;
    }
    w->va = mmap(NULL, w->len, PROT_READ, MAP_SHARED, w->fd, (off_t)w->off);
    if (w->va == MAP_FAILED) {
        out("RESULT map:%-20s -> mmap off=0x%llx len=0x%zx failed: %s\n",
            w->name, (unsigned long long)w->off, w->len, strerror(errno));
        close(w->fd);
        w->fd = -1;
        return -1;
    }
    out("RESULT map:%-20s -> va=%p off=0x%llx len=0x%zx\n",
        w->name, w->va, (unsigned long long)w->off, w->len);
    return 0;
}

static void *xmalloc(size_t n)
{
    void *p = NULL;
    if (posix_memalign(&p, PAGE_SZ, n) != 0)
        return NULL;
    return p;
}

// Host-side read of a mapped window. UNCACHED MMIO: volatile, one dword at a
// time. Used as the host-route reference for the same VRAM offset.
static void host_read_n(const void *va, unsigned char *dst, size_t len)
{
    const volatile uint32_t *p = (const volatile uint32_t *)va;
    size_t n = len / 4;
    uint32_t *d = (uint32_t *)dst;
    for (size_t i = 0; i < n; i++)
        d[i] = p[i];
    if (len & 3)
        memcpy(dst + (len & ~(size_t)3), (const void *)(p + n), len & 3);
}

// Compare a host reference with a peer read. On a difference, report where
// the two diverge: the offset is the interesting number (transfer granularity,
// partial mapping, or a real value difference).
static void compare_named(const char *name, const unsigned char *host,
                          const unsigned char *peer, size_t n)
{
    size_t fd = 0;
    while (fd < n && host[fd] == peer[fd])
        fd++;
    if (fd == n) {
        out("RESULT compare:%-20s -> same\n", name);
        return;
    }
    out("RESULT compare:%-20s -> DIFFER first=0x%zx host=%02x peer=%02x\n",
        name, fd, host[fd], peer[fd]);
    // How many 256-byte blocks carry a matching first dword? A peer read of a
    // register aperture can have per-block granularity; this makes it visible.
    size_t blocks = n / 256, okb = 0;
    for (size_t b = 0; b < blocks; b++) {
        size_t o = b * 256;
        if (!memcmp(host + o, peer + o, 4))
            okb++;
    }
    out("RESULT blocks4:%-18s -> %zu/%zu first-dword matches\n", name, okb, blocks);
}

static void stats(const char *tag, const unsigned char *b, size_t n)
{
    uint64_t h[256] = {0};
    size_t nz = 0;
    for (size_t i = 0; i < n; i++) {
        h[b[i]]++;
        if (b[i])
            nz++;
    }
    double ent = 0.0;
    for (int i = 0; i < 256; i++) {
        if (!h[i])
            continue;
        double p = (double)h[i] / (double)n;
        ent -= p * (double)(p > 0 ? (__builtin_log2(p)) : 0);
    }
    out("DATA %-24s size=0x%zx nz=%zu entropy=%.4f head=", tag, n, nz, ent);
    for (int i = 0; i < 16 && (size_t)i < n; i++)
        out("%02x", b[i]);
    out("\n");
}

// Scan a mapped BAR1 for the WPR fill. The fill is the repeated dword
// 0xbad0ac00; probe at a coarse stride, then bracket the first hit.
// Returns the start offset, or UINT64_MAX if nothing matched.
static uint64_t scan_wpr(const volatile uint32_t *p, uint64_t size, uint64_t *end_out)
{
    uint64_t stride = 1ULL << 20;   // 1 MiB
    uint64_t first = UINT64_MAX;

    for (uint64_t off = 0; off + 64 < size; off += stride) {
        size_t i = off / 4;
        if (p[i] == 0xbad0ac00u && p[i + 1] == 0xbad0ac00u &&
            p[i + 2] == 0xbad0ac00u && p[i + 3] == 0xbad0ac00u) {
            first = off;
            break;
        }
    }
    if (first == UINT64_MAX)
        return UINT64_MAX;

    // Step back to the first non-fill page, bracket the end at 1 MiB, then
    // refine the end at page granularity.
    uint64_t start = first;
    while (start >= PAGE_SZ) {
        size_t i = (start - PAGE_SZ) / 4;
        if (p[i] != 0xbad0ac00u)
            break;
        start -= PAGE_SZ;
    }
    uint64_t end = first;
    while (end + stride < size) {
        size_t i = (end + stride) / 4;
        if (p[i] != 0xbad0ac00u)
            break;
        end += stride;
    }
    while (end + PAGE_SZ < size) {
        size_t i = (end + PAGE_SZ) / 4;
        if (p[i] != 0xbad0ac00u)
            break;
        end += PAGE_SZ;
    }
    *end_out = end + PAGE_SZ;   // one past the last fill page
    return start;
}

static int register_io_memory(struct window *w, CUdeviceptr *dptr)
{
    static const struct {
        const char *name;
        unsigned flags;
    } tries[] = {
        {"IOMEM|DEVMAP|RDONLY", CU_MEMHOSTREGISTER_IOMEMORY |
                                    CU_MEMHOSTREGISTER_DEVICEMAP |
                                    CU_MEMHOSTREGISTER_READ_ONLY},
        {"IOMEM|DEVMAP", CU_MEMHOSTREGISTER_IOMEMORY |
                             CU_MEMHOSTREGISTER_DEVICEMAP},
        {"IOMEM", CU_MEMHOSTREGISTER_IOMEMORY},
    };

    for (size_t i = 0; i < sizeof(tries) / sizeof(tries[0]); i++) {
        CUresult r = cuMemHostRegister(w->va, w->len, tries[i].flags);
        out("RESULT reg:%-20s %-22s -> %s\n", w->name, tries[i].name,
            r == CUDA_SUCCESS ? "ok" : curc(r));
        if (r == CUDA_SUCCESS) {
            CUresult g = cuMemHostGetDevicePointer(dptr, w->va, 0);
            out("RESULT devptr:%-17s -> %s\n", w->name,
                g == CUDA_SUCCESS ? "ok" : curc(g));
            if (g == CUDA_SUCCESS)
                return 0;
            cuMemHostUnregister(w->va);
            return -1;
        }
    }
    return -1;
}

static int peer_copy(const char *name, CUdeviceptr dptr, void *host_va,
                     size_t len, CUcontext ctx1, unsigned char *host_out)
{
    CUdeviceptr dst = 0;
    CUstream stream = NULL;
    CUresult r;

    r = cuMemAlloc(&dst, len);
    if (r != CUDA_SUCCESS) {
        out("RESULT peer:%-19s cuMemAlloc -> %s\n", name, curc(r));
        return -1;
    }
    r = cuStreamCreate(&stream, 0);
    if (r != CUDA_SUCCESS) {
        out("RESULT peer:%-19s cuStreamCreate -> %s\n", name, curc(r));
        cuMemFree(dst);
        return -1;
    }

    // The source is an I/O mapping registered as a device mapping. The copy
    // engine on this GPU issues the read; with the source physically in GPU0's
    // BAR1 that read crosses PCIe to the peer.
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    r = cuMemcpyDtoDAsync(dst, dptr, len, stream);
    if (r != CUDA_SUCCESS && host_va != NULL) {
        out("RESULT peer:%-19s cuMemcpyDtoDAsync -> %s; trying H2D\n", name,
            curc(r));
        r = cuMemcpyHtoDAsync(dst, host_va, len, stream);
    }
    out("RESULT peer:%-19s copy -> %s\n", name,
        r == CUDA_SUCCESS ? "ok" : curc(r));
    if (r == CUDA_SUCCESS) {
        r = cuStreamSynchronize(stream);
        clock_gettime(CLOCK_MONOTONIC, &t1);
        double sec = (double)(t1.tv_sec - t0.tv_sec) +
                     (double)(t1.tv_nsec - t0.tv_nsec) / 1e9;
        out("RESULT peer:%-19s sync -> %s time=%.3f ms rate=%.2f GB/s\n",
            name, r == CUDA_SUCCESS ? "ok" : curc(r), sec * 1e3,
            sec > 0 ? (double)len / sec / 1e9 : 0.0);
    }
    if (r == CUDA_SUCCESS) {
        r = cuMemcpyDtoH(host_out, dst, len);
        out("RESULT peer:%-19s D2H -> %s\n", name,
            r == CUDA_SUCCESS ? "ok" : curc(r));
    }

    cuStreamDestroy(stream);
    cuMemFree(dst);
    (void)ctx1;
    return r == CUDA_SUCCESS ? 0 : -1;
}

static int p2p_control(CUdevice dev0, CUdevice dev1, CUcontext ctx0, CUcontext ctx1,
                       size_t bytes)
{
    CUdeviceptr src = 0, dst = 0;
    unsigned char *h = NULL, *h2 = NULL;
    CUresult r;

    cuCtxSetCurrent(ctx0);
    r = cuMemAlloc(&src, bytes);
    if (r != CUDA_SUCCESS) {
        out("RESULT p2p:alloc_src -> %s\n", curc(r));
        return -1;
    }
    h = xmalloc(bytes);
    for (size_t i = 0; i < bytes; i++)
        h[i] = (unsigned char)((i * 131u + 17u) & 0xff);
    r = cuMemcpyHtoD(src, h, bytes);
    if (r != CUDA_SUCCESS) {
        out("RESULT p2p:H2D -> %s\n", curc(r));
        return -1;
    }

    cuCtxSetCurrent(ctx1);
    r = cuCtxEnablePeerAccess(ctx0, 0);
    out("RESULT p2p:enable -> %s\n", r == CUDA_SUCCESS ? "ok" : curc(r));
    if (r != CUDA_SUCCESS && r != CUDA_ERROR_PEER_ACCESS_ALREADY_ENABLED) {
        failures++;
        return -1;
    }
    r = cuMemAlloc(&dst, bytes);
    if (r != CUDA_SUCCESS) {
        out("RESULT p2p:alloc_dst -> %s\n", curc(r));
        return -1;
    }
    CUstream st = NULL;
    cuStreamCreate(&st, 0);
    r = cuMemcpyPeerAsync(dst, ctx1, src, ctx0, bytes, st);
    out("RESULT p2p:memcpy -> %s\n", r == CUDA_SUCCESS ? "ok" : curc(r));
    if (r == CUDA_SUCCESS)
        r = cuStreamSynchronize(st);

    h2 = xmalloc(bytes);
    if (r == CUDA_SUCCESS)
        r = cuMemcpyDtoH(h2, dst, bytes);
    if (r == CUDA_SUCCESS) {
        int bad = memcmp(h, h2, bytes) != 0;
        out("RESULT p2p:verify size=0x%zx -> %s\n", bytes, bad ? "MISMATCH" : "ok");
        if (bad)
            failures++;
    }
    free(h);
    free(h2);
    cuStreamDestroy(st);
    cuMemFree(src);
    cuMemFree(dst);
    return r == CUDA_SUCCESS ? 0 : -1;
}

// ---------------------------------------------------------------------------
// BAR0 PRAMIN window. NV_XAL_BASE_ADDRESS (0x10F000) + NV_XAL_EP_ZB_BAR0_WINDOW
// (0xD40) holds the FB offset of the 64 KiB PRAMIN window at BAR0+0x700000,
// in 64 KiB units. Writable from the host aperture.
// ---------------------------------------------------------------------------
#define BAR0_WIN_REG   0x10FD40ULL
#define BAR0_WIN_PAGE  0x10F000ULL
#define BAR0_PRAMIN    0x700000ULL
#define BAR0_WIN_SHIFT 16

static int bar0_window_rw(const char *bdf, uint32_t *val, int write)
{
    char path[256];
    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/resource0", bdf);
    int fd = open(path, O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        out("RESULT pramin:open -> %s\n", strerror(errno));
        return -1;
    }
    void *p = mmap(NULL, PAGE_SZ, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
                   (off_t)BAR0_WIN_PAGE);
    if (p == MAP_FAILED) {
        out("RESULT pramin:mmap reg -> %s\n", strerror(errno));
        close(fd);
        return -1;
    }
    volatile uint32_t *reg = (volatile uint32_t *)((char *)p + (BAR0_WIN_REG - BAR0_WIN_PAGE));
    if (write)
        *reg = *val;
    else
        *val = *reg;
    munmap(p, PAGE_SZ);
    close(fd);
    return 0;
}

// Parse "name:off:len" into a BAR1 window of gpu0.
static int parse_win(char *spec, const char *bdf0, struct window *w)
{
    char *c1 = strchr(spec, ':');
    if (!c1)
        return -1;
    *c1++ = 0;
    char *c2 = strchr(c1, ':');
    if (!c2)
        return -1;
    *c2++ = 0;
    memset(w, 0, sizeof(*w));
    w->name = spec;
    w->bdf = bdf0;
    w->bar = 1;
    w->off = strtoull(c1, NULL, 0);
    w->len = strtoull(c2, NULL, 0);
    w->fd = -1;
    return 0;
}

// Chunked scan of BAR1 for the WPR fill. A single mmap of the whole 32 GiB
// resource is refused (EINVAL), so map and scan bounded chunks.
static void scan_bar1(const char *path, uint64_t chunk)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        out("RESULT scan:open -> %s\n", strerror(errno));
        return;
    }
    struct stat st;
    fstat(fd, &st);
    uint64_t size = (uint64_t)st.st_size;
    out("RESULT scan:start size=0x%llx chunk=0x%llx\n",
        (unsigned long long)size, (unsigned long long)chunk);

    uint64_t first = UINT64_MAX, end = 0;
    int map_fail = 0, chunks = 0;
    for (uint64_t off = 0; off < size; off += chunk) {
        size_t len = (size - off < chunk) ? (size_t)(size - off) : (size_t)chunk;
        void *va = mmap(NULL, len, PROT_READ, MAP_SHARED, fd, (off_t)off);
        if (va == MAP_FAILED) {
            if (map_fail++ < 3)
                out("RESULT scan:mmap off=0x%llx len=0x%zx -> %s\n",
                    (unsigned long long)off, len, strerror(errno));
            continue;
        }
        chunks++;
        uint64_t cend = 0;
        uint64_t s = scan_wpr((const volatile uint32_t *)va, len, &cend);
        if (s != UINT64_MAX) {
            first = off + s;
            end = off + cend;
            munmap(va, len);
            break;
        }
        munmap(va, len);
    }
    close(fd);

    out("RESULT scan:chunks_ok=%d chunks_failed=%d\n", chunks, map_fail);
    if (first == UINT64_MAX)
        out("RESULT scan:sentinel -> none found\n");
    else
        out("RESULT scan:sentinel start=0x%llx end=0x%llx\n",
            (unsigned long long)first, (unsigned long long)end);
}

// Locate a byte pattern inside BAR1 at a fixed stride. Used to find a CUDA
// allocation's pattern in the aperture (positive control for address math).
static uint64_t scan_needle(const char *path, uint64_t chunk,
                            const unsigned char *needle, size_t nlen,
                            uint64_t stride)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return UINT64_MAX;
    struct stat st;
    fstat(fd, &st);
    uint64_t size = (uint64_t)st.st_size;
    uint64_t found = UINT64_MAX;

    for (uint64_t off = 0; off < size && found == UINT64_MAX; off += chunk) {
        size_t len = (size - off < chunk) ? (size_t)(size - off) : (size_t)chunk;
        unsigned char *va = mmap(NULL, len, PROT_READ, MAP_SHARED, fd, (off_t)off);
        if (va == MAP_FAILED)
            continue;
        // One 64-bit MMIO read per probe; memcmp only on a prefix hit.
        uint64_t want;
        memcpy(&want, needle, sizeof(want));
        const volatile uint64_t *q = (const volatile uint64_t *)va;
        for (size_t i = 0; i + nlen <= len; i += stride) {
            if (q[i / 8] == want && !memcmp(va + i, needle, nlen)) {
                found = off + i;
                break;
            }
        }
        munmap(va, len);
    }
    close(fd);
    return found;
}

static void usage(const char *p)
{
    fprintf(stderr,
            "usage: %s --gpu0 BDF --gpu1 BDF [--scan BAR1PATH [chunk]]\n"
            "          [--win name:off:len ...] [--probe name:off:len ...]\n"
            "          [--control PATH OFF LEN] [--mb N]\n",
            p);
}

int main(int argc, char **argv)
{
    const char *bdf0 = "0000:41:00.0", *bdf1 = "0000:c1:00.0";
    const char *scan_path = NULL, *control_path = NULL;
    uint64_t scan_chunk = 256 * 1024 * 1024;
    uint64_t control_off = 0, control_len = 64 * 1024;
    size_t p2p_bytes = 32 * 1024 * 1024;
    int find_magic = 0, have_bar1_start = 0;
    uint64_t bar1_start = 0;
    struct window wins[24], probes[8];
    int nwin = 0, nprobe = 0;
    struct { const char *name; uint64_t fb; size_t len; } pram[32];
    int npram = 0;
    memset(wins, 0, sizeof(wins));
    memset(probes, 0, sizeof(probes));

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--gpu0") && i + 1 < argc) {
            bdf0 = argv[++i];
        } else if (!strcmp(argv[i], "--gpu1") && i + 1 < argc) {
            bdf1 = argv[++i];
        } else if (!strcmp(argv[i], "--scan") && i + 1 < argc) {
            scan_path = argv[++i];
            if (i + 1 < argc && argv[i + 1][0] != '-')
                scan_chunk = strtoull(argv[++i], NULL, 0);
        } else if (!strcmp(argv[i], "--control") && i + 3 < argc) {
            control_path = argv[++i];
            control_off = strtoull(argv[++i], NULL, 0);
            control_len = strtoull(argv[++i], NULL, 0);
        } else if (!strcmp(argv[i], "--win") && i + 1 < argc) {
            if (nwin >= (int)(sizeof(wins) / sizeof(wins[0])) ||
                parse_win(argv[++i], bdf0, &wins[nwin]) != 0) {
                usage(argv[0]);
                return 1;
            }
            nwin++;
        } else if (!strcmp(argv[i], "--probe") && i + 1 < argc) {
            if (nprobe >= (int)(sizeof(probes) / sizeof(probes[0])) ||
                parse_win(argv[++i], bdf0, &probes[nprobe]) != 0) {
                usage(argv[0]);
                return 1;
            }
            nprobe++;
        } else if (!strcmp(argv[i], "--magic")) {
            find_magic = 1;
        } else if (!strcmp(argv[i], "--bar1-start") && i + 1 < argc) {
            bar1_start = strtoull(argv[++i], NULL, 0);
            have_bar1_start = 1;
        } else if (!strcmp(argv[i], "--pramin") && i + 1 < argc) {
            char *spec = argv[++i];
            char *c1 = strchr(spec, ':');
            if (!c1 || npram >= (int)(sizeof(pram) / sizeof(pram[0]))) {
                usage(argv[0]);
                return 1;
            }
            *c1++ = 0;
            char *c2 = strchr(c1, ':');
            if (!c2) {
                usage(argv[0]);
                return 1;
            }
            *c2++ = 0;
            pram[npram].name = spec;
            pram[npram].fb = strtoull(c1, NULL, 0);
            pram[npram].len = strtoull(c2, NULL, 0);
            npram++;
        } else if (!strcmp(argv[i], "--mb") && i + 1 < argc) {
            p2p_bytes = strtoull(argv[++i], NULL, 0) * 1024 * 1024;
        } else if (!strcmp(argv[i], "--help")) {
            usage(argv[0]);
            return 0;
        } else {
            usage(argv[0]);
            return 1;
        }
    }

    out("== peer_read pid=%d uid=%d\n", (int)getpid(), (int)getuid());

    CUresult r = cuInit(0);
    if (cu_check(r, "cuInit") != CUDA_SUCCESS)
        return 1;

    CUdevice dev0, dev1;
    if (find_device(bdf0, &dev0) || find_device(bdf1, &dev1))
        return 1;

    char name0[128] = {0}, name1[128] = {0};
    cuDeviceGetName(name0, sizeof(name0), dev0);
    cuDeviceGetName(name1, sizeof(name1), dev1);
    out("INFO gpu0=%s bdf=%s cu=%d\n", name0, bdf0, (int)dev0);
    out("INFO gpu1=%s bdf=%s cu=%d\n", name1, bdf1, (int)dev1);

    CUcontext ctx0 = NULL, ctx1 = NULL;
    if (cuDevicePrimaryCtxRetain(&ctx0, dev0) != CUDA_SUCCESS ||
        cuDevicePrimaryCtxRetain(&ctx1, dev1) != CUDA_SUCCESS) {
        out("ERROR primary context retain failed\n");
        return 1;
    }

    // --- 1. positive control: an ordinary peer copy over PCIe -------------
    out("-- positive control: cuMemcpyPeer\n");
    p2p_control(dev0, dev1, ctx0, ctx1, p2p_bytes);

    // --- 2. optional WPR scan of BAR1 ------------------------------------
    if (scan_path) {
        out("-- scan BAR1 for the WPR fill\n");
        scan_bar1(scan_path, scan_chunk);
    }

    // --- 2b. positive control: find a known allocation through BAR1 ------
    CUdeviceptr keep_alive = 0;
    if (scan_path && find_magic) {
        static const unsigned char magic[32] = {
            'B', 'F', '1', '6', 'P', 'E', 'E', 'R', 'M', 'A', 'G', 'I', 'C', 0,
            '0', '0', '0', '1', 0xde, 0xad, 0xbe, 0xef, 0xca, 0xfe, 0xba, 0xbe,
            0x11, 0x22, 0x33, 0x44, 0x55, 0x66};
        const size_t alloc_len = 4 * 1024 * 1024;
        CUdeviceptr mptr = 0;
        unsigned char *h = xmalloc(alloc_len);
        // Nonzero everywhere: a truncated transfer shows up as a first
        // difference at the truncation boundary, not as matching zeros.
        for (size_t i = 0; i < alloc_len; i++)
            h[i] = (unsigned char)((i * 37u + 11u) & 0xffu);
        memcpy(h, magic, sizeof(magic));
        memcpy(h + alloc_len / 2, magic, sizeof(magic));
        cuCtxSetCurrent(ctx0);
        CUresult mr = cuMemAlloc(&mptr, alloc_len);
        out("RESULT magic:alloc -> %s ptr=0x%llx\n",
            mr == CUDA_SUCCESS ? "ok" : curc(mr), (unsigned long long)mptr);
        if (mr == CUDA_SUCCESS) {
            mr = cuMemcpyHtoD(mptr, h, alloc_len);
            out("RESULT magic:fill -> %s\n", mr == CUDA_SUCCESS ? "ok" : curc(mr));
            cuCtxSynchronize();
            static const uint64_t strides[] = {1ULL << 20, 64 * 1024, 4096};
            uint64_t mo = UINT64_MAX;
            for (size_t si = 0; si < sizeof(strides) / sizeof(strides[0]); si++) {
                mo = scan_needle(scan_path, scan_chunk, magic, sizeof(magic),
                                 strides[si]);
                out("RESULT magic:scan stride=0x%llx -> %s\n",
                    (unsigned long long)strides[si],
                    mo == UINT64_MAX ? "not found" : "found");
                if (mo != UINT64_MAX)
                    break;
            }
            if (mo != UINT64_MAX) {
                out("RESULT magic:offset 0x%llx (BAR1 offset of the allocation)\n",
                    (unsigned long long)mo);
                // Add the allocation page as a target and keep it allocated
                // until every window has been read.
                if (nwin < (int)(sizeof(wins) / sizeof(wins[0]))) {
                    memset(&wins[nwin], 0, sizeof(wins[nwin]));
                    wins[nwin].name = "magic4k";
                    wins[nwin].bdf = bdf0;
                    wins[nwin].bar = 1;
                    wins[nwin].off = mo & ~(PAGE_SZ - 1);
                    wins[nwin].len = PAGE_SZ;
                    wins[nwin].fd = -1;
                    nwin++;
                    if (nwin < (int)(sizeof(wins) / sizeof(wins[0]))) {
                        memset(&wins[nwin], 0, sizeof(wins[nwin]));
                        wins[nwin].name = "magic64k";
                        wins[nwin].bdf = bdf0;
                        wins[nwin].bar = 1;
                        wins[nwin].off = mo & ~(PAGE_SZ - 1);
                        wins[nwin].len = 64 * 1024;
                        wins[nwin].fd = -1;
                        nwin++;
                    }
                    keep_alive = mptr;
                }
                // Same allocation through the movable BAR0 window at several
                // sizes and offsets, if the caller told us where FB offset 0
                // sits in BAR1. These measure the transfer granularity.
                if (have_bar1_start && mo >= bar1_start) {
                    static const struct { const char *n; uint64_t o; size_t l; }
                    mp[] = {
                        {"prammagic1k",  0x0,     0x400},
                        {"prammagic4k",  0x0,     0x1000},
                        {"prammagic64k", 0x0,     0x10000},
                        {"prammagicp1",  0x400,   0x400},
                        {"prammagicp4",  0x1000,  0x1000},
                        {"prammagicp64", 0x10000, 0x1000},
                    };
                    uint64_t fbbase = mo - bar1_start;
                    for (size_t k = 0;
                         k < sizeof(mp) / sizeof(mp[0]) &&
                         npram < (int)(sizeof(pram) / sizeof(pram[0])); k++) {
                        pram[npram].name = mp[k].n;
                        pram[npram].fb = fbbase + mp[k].o;
                        pram[npram].len = mp[k].l;
                        npram++;
                    }
                }
            }
            if (!keep_alive)
                cuMemFree(mptr);
        }
        free(h);
    }

    // --- 3. I/O-memory control on a non-GPU BAR --------------------------
    if (control_path) {
        out("-- I/O memory control (non-GPU BAR)\n");
        struct window cw = {.name = "iomem_ctl"};
        char path[256], bdf[64];
        int bar = 0;
        // Accept a full sysfs resource path; derive bdf/bar for map_window.
        if (sscanf(control_path, "/sys/bus/pci/devices/%63[^/]/resource%d",
                   bdf, &bar) == 2) {
            cw.bdf = bdf;
            cw.bar = bar;
            cw.off = control_off;
            cw.len = control_len;
            cw.fd = -1;
            (void)path;
            if (map_window(&cw) == 0) {
                CUdeviceptr d = 0;
                cuCtxSetCurrent(ctx1);
                if (register_io_memory(&cw, &d) == 0) {
                    unsigned char *ref = xmalloc(cw.len);
                    unsigned char *peer = xmalloc(cw.len);
                    host_read_n(cw.va, ref, cw.len);
                    if (peer_copy(cw.name, d, cw.va, cw.len, ctx1, peer) == 0) {
                        stats("control.host", ref, cw.len);
                        stats("control.peer", peer, cw.len);
                        out("RESULT control:compare -> %s\n",
                            memcmp(ref, peer, cw.len) ? "DIFFER" : "same");
                    }
                    free(ref);
                    free(peer);
                    cuMemHostUnregister(cw.va);
                }
                munmap(cw.va, cw.len);
                close(cw.fd);
            }
        } else {
            out("RESULT control:path -> unparsable %s\n", control_path);
        }
    }

    // --- 3b. map-only probes --------------------------------------------
    for (int i = 0; i < nprobe; i++) {
        struct window *w = &probes[i];
        out("-- probe %s off=0x%llx len=0x%zx\n", w->name,
            (unsigned long long)w->off, w->len);
        if (map_window(w) != 0)
            continue;
        unsigned char *b = xmalloc(w->len);
        host_read_n(w->va, b, w->len);
        stats(w->name, b, w->len);
        free(b);
        munmap(w->va, w->len);
        close(w->fd);
    }

    // --- 4. the target windows ------------------------------------------
    cuCtxSetCurrent(ctx1);
    for (int i = 0; i < nwin; i++) {
        struct window *w = &wins[i];
        w->host = xmalloc(w->len);
        out("-- target %s off=0x%llx len=0x%zx\n", w->name,
            (unsigned long long)w->off, w->len);
        if (map_window(w) != 0)
            continue;

        host_read_n(w->va, w->host, w->len);
        stats(w->name, w->host, w->len);

        CUdeviceptr dptr = 0;
        if (register_io_memory(w, &dptr) != 0) {
            out("RESULT peer:%-20s -> no I/O memory mapping\n", w->name);
            munmap(w->va, w->len);
            close(w->fd);
            continue;
        }

        unsigned char *peer = xmalloc(w->len);
        cuCtxSetCurrent(ctx1);
        if (peer_copy(w->name, dptr, w->va, w->len, ctx1, peer) == 0) {
            char tag[64];
            snprintf(tag, sizeof(tag), "%s.peer", w->name);
            stats(tag, peer, w->len);
            compare_named(w->name, w->host, peer, w->len);
        }
        free(peer);
        cuMemHostUnregister(w->va);
        munmap(w->va, w->len);
        close(w->fd);
    }

    // --- 5. BAR0 PRAMIN windows, aimed by the host aperture register -----
    // One I/O registration for the whole 64 KiB PRAMIN window. Its physical
    // range is fixed; only the FB base in the window register changes, so
    // every target reads through the same GPU1 mapping. (The RM stops
    // accepting registrations after a few overlapping OS-descriptor imports.)
    if (npram > 0) {
        struct window reg;
        memset(&reg, 0, sizeof(reg));
        reg.name = "pramreg";
        reg.bdf = bdf0;
        reg.bar = 0;
        reg.off = BAR0_PRAMIN;
        reg.len = 64 * 1024;
        reg.fd = -1;
        CUdeviceptr dptr = 0;
        int have_reg = 0;
        if (map_window(&reg) == 0) {
            cuCtxSetCurrent(ctx1);
            have_reg = (register_io_memory(&reg, &dptr) == 0);
            if (!have_reg) {
                munmap(reg.va, reg.len);
                close(reg.fd);
            }
        } else {
            reg.va = NULL;
            reg.fd = -1;
        }

        for (int i = 0; i < npram; i++) {
            uint32_t old = 0, newv = 0, rb = 0;
            out("-- pramin %s fb=0x%llx len=0x%zx reg=%d\n", pram[i].name,
                (unsigned long long)pram[i].fb, pram[i].len, have_reg);
            if (bar0_window_rw(bdf0, &old, 0) != 0)
                continue;
            out("RESULT pramin:reg_old 0x%08x (fb 0x%llx)\n", old,
                (unsigned long long)old << BAR0_WIN_SHIFT);
            // Refuse to write a register that does not look like the window
            // base (23-bit field, high bits reserved zero).
            if ((old & ~0x7FFFFFu) != 0) {
                out("RESULT pramin:%s -> reg_old out of range, not writing\n",
                    pram[i].name);
                continue;
            }
            newv = (uint32_t)(pram[i].fb >> BAR0_WIN_SHIFT);
            if (bar0_window_rw(bdf0, &newv, 1) != 0)
                continue;
            bar0_window_rw(bdf0, &rb, 0);
            out("RESULT pramin:reg_new 0x%08x readback 0x%08x (fb 0x%llx)\n",
                newv, rb, (unsigned long long)rb << BAR0_WIN_SHIFT);

            if (have_reg && pram[i].len <= reg.len) {
                unsigned char *host = xmalloc(pram[i].len);
                unsigned char *peer = xmalloc(pram[i].len);
                host_read_n(reg.va, host, pram[i].len);   // current window content
                stats(pram[i].name, host, pram[i].len);
                if (peer_copy(pram[i].name, dptr, reg.va, pram[i].len,
                              ctx1, peer) == 0) {
                    char tag[64];
                    snprintf(tag, sizeof(tag), "%s.peer", pram[i].name);
                    stats(tag, peer, pram[i].len);
                    compare_named(pram[i].name, host, peer, pram[i].len);
                }
                free(host);
                free(peer);
            }
            bar0_window_rw(bdf0, &old, 1);
            out("RESULT pramin:restored 0x%08x\n", old);
        }
        if (have_reg) {
            cuMemHostUnregister(reg.va);
            munmap(reg.va, reg.len);
            close(reg.fd);
        }
    }

    if (keep_alive) {
        cuCtxSetCurrent(ctx0);
        cuMemFree(keep_alive);
    }
    out("== done failures=%d\n", failures);
    return 0;
}

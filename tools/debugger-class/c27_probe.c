/*
 * c27_probe.c - CUDA driver-API probe that drives the C27 census hook.
 *
 * Creates a real CUDA context and a resident kernel, allocates a device
 * buffer with a recognizable pattern, then calls c27_run() exported by
 * c27_hook.c.  The hook owns the RM client, the CUDA driver's debugger
 * object, and the debuggee channel; this program only creates the context
 * and the memory those commands act on.
 */
#include <cuda.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int (*c27_run_fn)(uint64_t devptr, uint64_t size);

static int chk(CUresult r, const char *what)
{
    if (r != CUDA_SUCCESS) {
        const char *s = NULL;
        cuGetErrorString(r, &s);
        fprintf(stderr, "PROBE %s failed: %d (%s)\n", what, (int)r,
                s ? s : "?");
        return -1;
    }
    return 0;
}

int main(void)
{
    CUdevice dev;
    CUcontext ctx;
    CUdeviceptr dptr = 0, sink = 0;
    CUmodule mod = NULL;
    CUfunction fn = NULL;
    unsigned long long iters = 1;
    unsigned char *host;
    size_t n = 64 * 1024;
    const char *cubin = getenv("C27_CUBIN");
    const char *devstr = getenv("C27_DEVICE");
    int devnum = devstr ? atoi(devstr) : 0;
    c27_run_fn run;
    size_t i;

    if (chk(cuInit(0), "cuInit")) return 1;
    if (chk(cuDeviceGet(&dev, devnum), "cuDeviceGet")) return 1;
    fprintf(stderr, "PROBE device=%d %s\n", (int)dev, "");
    if (chk(cuCtxCreate(&ctx, NULL, CU_CTX_SCHED_AUTO, dev), "cuCtxCreate"))
        return 1;
    fprintf(stderr, "PROBE ctx created\n");

    /* A device buffer with a pattern the hook can find through READ_MEMORY. */
    if (chk(cuMemAlloc(&dptr, n), "cuMemAlloc")) return 1;
    fprintf(stderr, "PROBE devalloc %#llx\n", (unsigned long long)dptr);
    host = malloc(n);
    if (!host) return 1;
    for (i = 0; i < n; i++)
        host[i] = (i & 1) ? 0x7c : 0xc2;
    fprintf(stderr, "PROBE host filled\n");
    if (chk(cuMemcpyHtoD(dptr, host, n), "cuMemcpyHtoD")) return 1;
    fprintf(stderr, "PROBE copied\n");
    free(host);
    printf("PROBE buffer=%#llx size=%zu\n",
           (unsigned long long)dptr, n);

    /* Make the GR context resident so the SM-state commands have a target. */
    if (!cubin) {
        fprintf(stderr, "PROBE C27_CUBIN unset; no kernel launch\n");
    } else if (chk(cuModuleLoad(&mod, cubin), "cuModuleLoad")) {
        fprintf(stderr, "PROBE continuing without a kernel launch\n");
    } else if (chk(cuModuleGetFunction(&fn, mod, "bench_bf16_f32"),
                   "cuModuleGetFunction")) {
        fprintf(stderr, "PROBE continuing without a kernel launch\n");
    } else if (chk(cuMemAlloc(&sink, 4096), "cuMemAlloc sink")) {
        fprintf(stderr, "PROBE continuing without a kernel launch\n");
    } else {
        void *args[2] = { &iters, &sink };
        if (chk(cuLaunchKernel(fn, 1, 1, 1, 32, 1, 1, 0, 0, args, NULL),
                "cuLaunchKernel"))
            fprintf(stderr, "PROBE launch failed; context may not be resident\n");
        cuCtxSynchronize();
        printf("PROBE kernel launched\n");
    }

    run = (c27_run_fn)(uintptr_t)dlsym(RTLD_DEFAULT, "c27_run");
    if (!run) {
        fprintf(stderr, "PROBE c27_run not found; is c27_hook.so preloaded?\n");
        return 1;
    }
    run((uint64_t)dptr, (uint64_t)n);

    if (sink) cuMemFree(sink);
    if (mod) cuModuleUnload(mod);
    cuMemFree(dptr);
    cuCtxDestroy(ctx);
    printf("PROBE done\n");
    return 0;
}

#include <cuda.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
int main(int argc, char **argv)
{
    int secs = (argc > 1) ? atoi(argv[1]) : 60;
    CUresult r;
    CUdevice dev;
    CUcontext ctx;
    CUdeviceptr p = 0;

    r = cuInit(0);
    if (r != CUDA_SUCCESS) { printf("cuInit %d\n", (int)r); return 1; }
    r = cuDeviceGet(&dev, 0);
    if (r != CUDA_SUCCESS) { printf("cuDeviceGet %d\n", (int)r); return 1; }
    r = cuCtxCreate(&ctx, NULL, 0, dev);
    if (r != CUDA_SUCCESS) { printf("cuCtxCreate %d\n", (int)r); return 1; }
    r = cuMemAlloc_v2(&p, 4096);
    if (r != CUDA_SUCCESS) { printf("cuMemAlloc %d\n", (int)r); return 1; }
    cuMemFree_v2(p);
    printf("ctx ok dev=%d secs=%d\n", (int)dev, secs);
    fflush(stdout);
    sleep(secs);
    cuCtxDestroy_v2(ctx);
    return 0;
}

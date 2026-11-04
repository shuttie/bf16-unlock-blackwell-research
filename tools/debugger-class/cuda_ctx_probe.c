#include <cuda.h>
#include <stdio.h>

int main(void)
{
    CUdevice dev;
    CUcontext ctx;
    CUresult r;

    r = cuInit(0);
    printf("cuInit=%d\n", r);
    if (r != CUDA_SUCCESS)
        return 1;

    r = cuDeviceGet(&dev, 0);
    printf("cuDeviceGet=%d dev=%d\n", r, (int)dev);
    if (r != CUDA_SUCCESS)
        return 1;

    r = cuCtxCreate(&ctx, NULL, CU_CTX_SCHED_AUTO, dev);
    printf("cuCtxCreate=%d ctx=%p\n", r, (void *)ctx);

    if (r == CUDA_SUCCESS) {
        r = cuCtxDestroy(ctx);
        printf("cuCtxDestroy=%d\n", r);
    }
    return 0;
}

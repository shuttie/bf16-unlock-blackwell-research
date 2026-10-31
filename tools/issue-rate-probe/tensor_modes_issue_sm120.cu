// SPDX-License-Identifier: GPL-2.0-only
// Register-resident SM120 (RTX 5090, sm_120) MMA issue-rate probe.
// Adapted from the 4090 issue-rate probe.
// Every input is exactly one except the FP16-accumulate mode, which uses 1/16
// so the half accumulator stays exact. Each warp keeps eight accumulator chains
// in flight.
// BF16 was added locally: the capped FP32-accumulate path is BF16-relevant.
// No host includes: NVRTC compiles this device-only source.

#define CHAINS 8

extern "C" __global__ void bench_f16_f32(unsigned long long iters, float *sink) {
    const unsigned a0=0x3c003c00u,a1=a0,a2=a0,a3=a0,b0=a0,b1=a0;
    float c0[CHAINS],c1[CHAINS],c2[CHAINS],c3[CHAINS];
#pragma unroll
    for(int j=0;j<CHAINS;++j) c0[j]=c1[j]=c2[j]=c3[j]=0.0f;
    for(unsigned long long i=0;i<iters;++i) {
#pragma unroll
        for(int j=0;j<CHAINS;++j)
            asm volatile("mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32 "
                         "{%0,%1,%2,%3}, {%4,%5,%6,%7}, {%8,%9}, {%0,%1,%2,%3};"
                         : "+f"(c0[j]),"+f"(c1[j]),"+f"(c2[j]),"+f"(c3[j])
                         : "r"(a0),"r"(a1),"r"(a2),"r"(a3),"r"(b0),"r"(b1));
    }
    float sum=0.0f;
#pragma unroll
    for(int j=0;j<CHAINS;++j) sum+=c0[j]+c1[j]+c2[j]+c3[j];
    sink[blockIdx.x*blockDim.x+threadIdx.x]=sum;
}

extern "C" __global__ void bench_bf16_f32(unsigned long long iters, float *sink) {
    const unsigned a0=0x3f803f80u,a1=a0,a2=a0,a3=a0,b0=a0,b1=a0;
    float c0[CHAINS],c1[CHAINS],c2[CHAINS],c3[CHAINS];
#pragma unroll
    for(int j=0;j<CHAINS;++j) c0[j]=c1[j]=c2[j]=c3[j]=0.0f;
    for(unsigned long long i=0;i<iters;++i) {
#pragma unroll
        for(int j=0;j<CHAINS;++j)
            asm volatile("mma.sync.aligned.m16n8k16.row.col.f32.bf16.bf16.f32 "
                         "{%0,%1,%2,%3}, {%4,%5,%6,%7}, {%8,%9}, {%0,%1,%2,%3};"
                         : "+f"(c0[j]),"+f"(c1[j]),"+f"(c2[j]),"+f"(c3[j])
                         : "r"(a0),"r"(a1),"r"(a2),"r"(a3),"r"(b0),"r"(b1));
    }
    float sum=0.0f;
#pragma unroll
    for(int j=0;j<CHAINS;++j) sum+=c0[j]+c1[j]+c2[j]+c3[j];
    sink[blockIdx.x*blockDim.x+threadIdx.x]=sum;
}

// FP16 -> FP16 accumulate: the mode the 5090 caps at ~2x the FP32-accumulate
// rate. Inputs are 1/16 (0x2c00) so the half accumulator stays exact and in
// range: 16 * (1/16)^2 = 1/16 per MMA, 1250 after 20000 iterations. The
// accumulator stalls at 128 once the increment falls below half an ulp, so the
// runner validates this mode at 2000 iterations.
extern "C" __global__ void bench_f16_f16(unsigned long long iters, float *sink) {
    const unsigned a0=0x2c002c00u,a1=a0,a2=a0,a3=a0,b0=a0,b1=a0;
    unsigned c0[CHAINS],c1[CHAINS];
#pragma unroll
    for(int j=0;j<CHAINS;++j) c0[j]=c1[j]=0u;
    for(unsigned long long i=0;i<iters;++i) {
#pragma unroll
        for(int j=0;j<CHAINS;++j)
            asm volatile("mma.sync.aligned.m16n8k16.row.col.f16.f16.f16.f16 "
                         "{%0,%1}, {%2,%3,%4,%5}, {%6,%7}, {%0,%1};"
                         : "+r"(c0[j]),"+r"(c1[j])
                         : "r"(a0),"r"(a1),"r"(a2),"r"(a3),"r"(b0),"r"(b1));
    }
    float sum=0.0f;
#pragma unroll
    for(int j=0;j<CHAINS;++j) {
#pragma unroll
        for(int r=0;r<2;++r) {
            unsigned v = (r==0) ? c0[j] : c1[j];
            unsigned short s0=(unsigned short)(v & 0xffffu);
            unsigned short s1=(unsigned short)(v >> 16);
            float lo,hi;
            asm("cvt.f32.f16 %0, %1;" : "=f"(lo) : "h"(s0));
            asm("cvt.f32.f16 %0, %1;" : "=f"(hi) : "h"(s1));
            sum += lo + hi;
        }
    }
    sink[blockIdx.x*blockDim.x+threadIdx.x]=sum;
}

extern "C" __global__ void bench_tf32(unsigned long long iters, float *sink) {
    const unsigned a0=0x3f800000u,a1=a0,a2=a0,a3=a0,b0=a0,b1=a0;
    float c0[CHAINS],c1[CHAINS],c2[CHAINS],c3[CHAINS];
#pragma unroll
    for(int j=0;j<CHAINS;++j) c0[j]=c1[j]=c2[j]=c3[j]=0.0f;
    for(unsigned long long i=0;i<iters;++i) {
#pragma unroll
        for(int j=0;j<CHAINS;++j)
            asm volatile("mma.sync.aligned.m16n8k8.row.col.f32.tf32.tf32.f32 "
                         "{%0,%1,%2,%3}, {%4,%5,%6,%7}, {%8,%9}, {%0,%1,%2,%3};"
                         : "+f"(c0[j]),"+f"(c1[j]),"+f"(c2[j]),"+f"(c3[j])
                         : "r"(a0),"r"(a1),"r"(a2),"r"(a3),"r"(b0),"r"(b1));
    }
    float sum=0.0f;
#pragma unroll
    for(int j=0;j<CHAINS;++j) sum+=c0[j]+c1[j]+c2[j]+c3[j];
    sink[blockIdx.x*blockDim.x+threadIdx.x]=sum;
}

extern "C" __global__ void bench_u4(unsigned long long iters, int *sink) {
    const unsigned a0=0x11111111u,a1=a0,a2=a0,a3=a0,b0=a0,b1=a0;
    int c0[CHAINS],c1[CHAINS],c2[CHAINS],c3[CHAINS];
#pragma unroll
    for(int j=0;j<CHAINS;++j) c0[j]=c1[j]=c2[j]=c3[j]=0;
    for(unsigned long long i=0;i<iters;++i) {
#pragma unroll
        for(int j=0;j<CHAINS;++j)
            asm volatile("mma.sync.aligned.m16n8k64.row.col.s32.u4.u4.s32 "
                         "{%0,%1,%2,%3}, {%4,%5,%6,%7}, {%8,%9}, {%0,%1,%2,%3};"
                         : "+r"(c0[j]),"+r"(c1[j]),"+r"(c2[j]),"+r"(c3[j])
                         : "r"(a0),"r"(a1),"r"(a2),"r"(a3),"r"(b0),"r"(b1));
    }
    int sum=0;
#pragma unroll
    for(int j=0;j<CHAINS;++j) sum+=c0[j]+c1[j]+c2[j]+c3[j];
    sink[blockIdx.x*blockDim.x+threadIdx.x]=sum;
}

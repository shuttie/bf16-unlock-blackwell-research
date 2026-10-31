// SPDX-License-Identifier: GPL-2.0-only
//
// key37_cuda.cu - GPU search for NVIDIA's debug test key.
//
// Same hypothesis and oracle as key37_factoradic.c:
//   the key is one of the 16! permutations of the MD5 IV bytes, used as an
//   AES-128 key, and AES-128-ECB(K, 00*16) ==
//   71 7d 14 94 ea ca 31 7f f1 06 19 52 58 b3 83 77.
//
// Build (CUDA 13, RTX 5090 = sm_120):
//   $CUDA_HOME/bin/nvcc -O3 -arch=sm_120 \
//       -o key37_cuda key37_cuda.cu
//
// Usage:
//   ./key37_cuda --selftest --device 0
//   ./key37_cuda --device 0 --chunks 256
//   ./key37_cuda --device 0 --start S --count C    # one shard
//
// Run one process per GPU with complementary --start/--count.  On a match it
// writes key37_found.bin in the current directory.  Offline; no firmware.

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <ctime>
#include <chrono>
#include <cuda_runtime.h>

/* gcc 15's <cmath> conflicts with CUDA 13's noexcept math declarations, so the
 * host threshold arithmetic uses the compiler builtin instead of the header. */
static inline double host_sqrt(double x) { return __builtin_sqrt(x); }
static inline int host_round(double x)
{
    return (int)(x >= 0.0 ? x + 0.5 : x - 0.5);
}

#define TOTAL 20922789888000ULL

__device__ __constant__ uint8_t POOL_D[16] = {
    0x01, 0x10, 0x23, 0x32, 0x45, 0x54, 0x67, 0x76,
    0x89, 0x98, 0xab, 0xba, 0xcd, 0xdc, 0xef, 0xfe
};
__device__ __constant__ uint8_t KAT_D[16] = {
    0x71, 0x7d, 0x14, 0x94, 0xea, 0xca, 0x31, 0x7f,
    0xf1, 0x06, 0x19, 0x52, 0x58, 0xb3, 0x83, 0x77
};
__device__ __constant__ uint8_t SBOX_D[256] = {
0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16
};

__device__ __constant__ uint8_t INVSBOX_D[256] = {
0x52,0x09,0x6a,0xd5,0x30,0x36,0xa5,0x38,0xbf,0x40,0xa3,0x9e,0x81,0xf3,0xd7,0xfb,
0x7c,0xe3,0x39,0x82,0x9b,0x2f,0xff,0x87,0x34,0x8e,0x43,0x44,0xc4,0xde,0xe9,0xcb,
0x54,0x7b,0x94,0x32,0xa6,0xc2,0x23,0x3d,0xee,0x4c,0x95,0x0b,0x42,0xfa,0xc3,0x4e,
0x08,0x2e,0xa1,0x66,0x28,0xd9,0x24,0xb2,0x76,0x5b,0xa2,0x49,0x6d,0x8b,0xd1,0x25,
0x72,0xf8,0xf6,0x64,0x86,0x68,0x98,0x16,0xd4,0xa4,0x5c,0xcc,0x5d,0x65,0xb6,0x92,
0x6c,0x70,0x48,0x50,0xfd,0xed,0xb9,0xda,0x5e,0x15,0x46,0x57,0xa7,0x8d,0x9d,0x84,
0x90,0xd8,0xab,0x00,0x8c,0xbc,0xd3,0x0a,0xf7,0xe4,0x58,0x05,0xb8,0xb3,0x45,0x06,
0xd0,0x2c,0x1e,0x8f,0xca,0x3f,0x0f,0x02,0xc1,0xaf,0xbd,0x03,0x01,0x13,0x8a,0x6b,
0x3a,0x91,0x11,0x41,0x4f,0x67,0xdc,0xea,0x97,0xf2,0xcf,0xce,0xf0,0xb4,0xe6,0x73,
0x96,0xac,0x74,0x22,0xe7,0xad,0x35,0x85,0xe2,0xf9,0x37,0xe8,0x1c,0x75,0xdf,0x6e,
0x47,0xf1,0x1a,0x71,0x1d,0x29,0xc5,0x89,0x6f,0xb7,0x62,0x0e,0xaa,0x18,0xbe,0x1b,
0xfc,0x56,0x3e,0x4b,0xc6,0xd2,0x79,0x20,0x9a,0xdb,0xc0,0xfe,0x78,0xcd,0x5a,0xf4,
0x1f,0xdd,0xa8,0x33,0x88,0x07,0xc7,0x31,0xb1,0x12,0x10,0x59,0x27,0x80,0xec,0x5f,
0x60,0x51,0x7f,0xa9,0x19,0xb5,0x4a,0x0d,0x2d,0xe5,0x7a,0x9f,0x93,0xc9,0x9c,0xef,
0xa0,0xe0,0x3b,0x4d,0xae,0x2a,0xf5,0xb0,0xc8,0xeb,0xbb,0x3c,0x83,0x53,0x99,0x61,
0x17,0x2b,0x04,0x7e,0xba,0x77,0xd6,0x26,0xe1,0x69,0x14,0x63,0x55,0x21,0x0c,0x7d
};

__device__ __constant__ uint8_t RCON[11] = {
    0x00,0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36
};

__device__ __constant__ uint64_t FACT_D[16] = {
    1ULL, 1ULL, 2ULL, 6ULL, 24ULL, 120ULL, 720ULL, 5040ULL,
    40320ULL, 362880ULL, 3628800ULL, 39916800ULL, 479001600ULL,
    6227020800ULL, 87178291200ULL, 1307674368000ULL
};

__device__ __constant__ uint8_t C0_D[16];
/* First 64 ciphertext blocks of the container body (offset 0x48), for the
 * RISC-V-validity oracle's multi-block stage. */
__device__ __constant__ uint8_t CBLK_D[64][16];
/* Container bytes 0..15 (magic + size fields), tested as a per-component CBC
 * IV candidate. */
__device__ __constant__ uint8_t HIV_D[16];

/* 16-bit parcel log2-probability table (half-bit units), trained on the GSP-RM
 * code segment by build_riscv_logp.py.  Global memory: 64 KB, kept in L1 by the
 * read-only path; it does not fit in the 64 KB constant bank beside the other
 * tables. */
__device__ int8_t g_logp[65536];

#define HITMAX (1u << 20)
__device__ uint8_t g_hitkey[HITMAX][16];
__device__ uint64_t g_hitrank[HITMAX];
__device__ uint8_t g_hitp0[HITMAX][16];
__device__ uint8_t g_hitmode[HITMAX];
__device__ int32_t g_hitscore[HITMAX];
__device__ uint32_t g_hitcount = 0;

static __device__ __forceinline__ uint8_t xtime(uint8_t x)
{
    return (uint8_t)((x << 1) ^ ((x >> 7) * 0x1b));
}

static __device__ void key_expand(const uint8_t key[16], uint8_t rk[176])
{
    memcpy(rk, key, 16);
    for (int i = 16; i < 176; i += 4) {
        uint8_t t0 = rk[i - 4], t1 = rk[i - 3], t2 = rk[i - 2], t3 = rk[i - 1];
        if ((i & 15) == 0) {
            uint8_t tmp = t0;
            t0 = (uint8_t)(SBOX_D[t1] ^ RCON[i >> 4]);
            t1 = SBOX_D[t2];
            t2 = SBOX_D[t3];
            t3 = SBOX_D[tmp];
        }
        rk[i + 0] = (uint8_t)(rk[i - 16] ^ t0);
        rk[i + 1] = (uint8_t)(rk[i - 15] ^ t1);
        rk[i + 2] = (uint8_t)(rk[i - 14] ^ t2);
        rk[i + 3] = (uint8_t)(rk[i - 13] ^ t3);
    }
}

static __device__ void encrypt_block(const uint8_t rk[176], uint8_t st[16])
{
    for (int i = 0; i < 16; i++)
        st[i] ^= rk[i];
    for (int round = 1; round <= 10; round++) {
        /* SubBytes */
        for (int i = 0; i < 16; i++)
            st[i] = SBOX_D[st[i]];
        /* ShiftRows: row r shifted left by r; state is column-major st[r + 4c] */
        uint8_t t[16];
        for (int r = 0; r < 4; r++)
            for (int c = 0; c < 4; c++)
                t[r + 4 * c] = st[r + 4 * ((c + r) & 3)];
        memcpy(st, t, 16);
        if (round != 10) {
            /* MixColumns */
            for (int c = 0; c < 4; c++) {
                uint8_t a0 = st[4*c], a1 = st[4*c+1], a2 = st[4*c+2], a3 = st[4*c+3];
                uint8_t all = (uint8_t)(a0 ^ a1 ^ a2 ^ a3);
                st[4*c+0] = (uint8_t)(a0 ^ all ^ xtime((uint8_t)(a0 ^ a1)));
                st[4*c+1] = (uint8_t)(a1 ^ all ^ xtime((uint8_t)(a1 ^ a2)));
                st[4*c+2] = (uint8_t)(a2 ^ all ^ xtime((uint8_t)(a2 ^ a3)));
                st[4*c+3] = (uint8_t)(a3 ^ all ^ xtime((uint8_t)(a3 ^ a0)));
            }
        }
        for (int i = 0; i < 16; i++)
            st[i] ^= rk[16 * round + i];
    }
}

static __device__ __forceinline__ uint32_t load_be32(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static __device__ __forceinline__ uint32_t rotr32(uint32_t x, int n)
{
    return (x >> n) | (x << (32 - n));
}

static __device__ __forceinline__ uint32_t bswap32(uint32_t x)
{
    return ((x & 0xffu) << 24) | ((x & 0xff00u) << 8) |
           ((x >> 8) & 0xff00u) | (x >> 24);
}

static __device__ __forceinline__ uint32_t subword(uint32_t x, const uint8_t *S)
{
    return ((uint32_t)S[(x >> 24) & 0xff] << 24) |
           ((uint32_t)S[(x >> 16) & 0xff] << 16) |
           ((uint32_t)S[(x >> 8) & 0xff] << 8) |
           (uint32_t)S[x & 0xff];
}

static __device__ void key_expand_tt(const uint8_t key[16], uint32_t w[44],
                                     const uint8_t *S)
{
    for (int i = 0; i < 4; i++)
        w[i] = ((uint32_t)key[4*i] << 24) | ((uint32_t)key[4*i+1] << 16) |
               ((uint32_t)key[4*i+2] << 8) | (uint32_t)key[4*i+3];
    for (int i = 4; i < 44; i++) {
        uint32_t t = w[i - 1];
        if ((i & 3) == 0)
            t = subword(rotr32(t, 24), S) ^ ((uint32_t)RCON[i >> 2] << 24);
        w[i] = w[i - 4] ^ t;
    }
}

static __device__ void encrypt_tt(const uint32_t w[44],
                                  uint32_t p0, uint32_t p1, uint32_t p2, uint32_t p3,
                                  const uint8_t *S,
                                  const uint32_t *T0, const uint32_t *T1,
                                  const uint32_t *T2, const uint32_t *T3,
                                  uint32_t *c0, uint32_t *c1,
                                  uint32_t *c2, uint32_t *c3)
{
    uint32_t s0 = p0 ^ w[0], s1 = p1 ^ w[1];
    uint32_t s2 = p2 ^ w[2], s3 = p3 ^ w[3];
    for (int r = 1; r <= 9; r++) {
        uint32_t a0 = T0[(s0 >> 24) & 0xff] ^ T1[(s1 >> 16) & 0xff] ^
                      T2[(s2 >> 8) & 0xff] ^ T3[s3 & 0xff] ^ w[4*r + 0];
        uint32_t a1 = T0[(s1 >> 24) & 0xff] ^ T1[(s2 >> 16) & 0xff] ^
                      T2[(s3 >> 8) & 0xff] ^ T3[s0 & 0xff] ^ w[4*r + 1];
        uint32_t a2 = T0[(s2 >> 24) & 0xff] ^ T1[(s3 >> 16) & 0xff] ^
                      T2[(s0 >> 8) & 0xff] ^ T3[s1 & 0xff] ^ w[4*r + 2];
        uint32_t a3 = T0[(s3 >> 24) & 0xff] ^ T1[(s0 >> 16) & 0xff] ^
                      T2[(s1 >> 8) & 0xff] ^ T3[s2 & 0xff] ^ w[4*r + 3];
        s0 = a0; s1 = a1; s2 = a2; s3 = a3;
    }
    uint32_t a0 = ((uint32_t)S[(s0 >> 24) & 0xff] << 24) |
                  ((uint32_t)S[(s1 >> 16) & 0xff] << 16) |
                  ((uint32_t)S[(s2 >> 8) & 0xff] << 8) | S[s3 & 0xff];
    uint32_t a1 = ((uint32_t)S[(s1 >> 24) & 0xff] << 24) |
                  ((uint32_t)S[(s2 >> 16) & 0xff] << 16) |
                  ((uint32_t)S[(s3 >> 8) & 0xff] << 8) | S[s0 & 0xff];
    uint32_t a2 = ((uint32_t)S[(s2 >> 24) & 0xff] << 24) |
                  ((uint32_t)S[(s3 >> 16) & 0xff] << 16) |
                  ((uint32_t)S[(s0 >> 8) & 0xff] << 8) | S[s1 & 0xff];
    uint32_t a3 = ((uint32_t)S[(s3 >> 24) & 0xff] << 24) |
                  ((uint32_t)S[(s0 >> 16) & 0xff] << 16) |
                  ((uint32_t)S[(s1 >> 8) & 0xff] << 8) | S[s2 & 0xff];
    *c0 = a0 ^ w[40]; *c1 = a1 ^ w[41];
    *c2 = a2 ^ w[42]; *c3 = a3 ^ w[43];
}

/* Rolling on-the-fly round-key schedule: keep only the current 4-word round
 * key in registers instead of a 44-word expansion (Yang & Goodman 2007;
 * Hansung bitslicing dissertation).  p is the uniform plaintext word (0 or
 * 0xffffffff). */
static __device__ __forceinline__ void encrypt_tt_roll(const uint8_t key[16], uint32_t p,
                                       const uint8_t *S,
                                       const uint32_t *T0, const uint32_t *T1,
                                       const uint32_t *T2, const uint32_t *T3,
                                       uint32_t *c0, uint32_t *c1,
                                       uint32_t *c2, uint32_t *c3)
{
    uint32_t k0 = load_be32(key + 0), k1 = load_be32(key + 4);
    uint32_t k2 = load_be32(key + 8), k3 = load_be32(key + 12);
    uint32_t s0 = p ^ k0, s1 = p ^ k1, s2 = p ^ k2, s3 = p ^ k3;
    for (int r = 1; r <= 10; r++) {
        uint32_t t = subword(rotr32(k3, 24), S) ^ ((uint32_t)RCON[r] << 24);
        uint32_t n0 = k0 ^ t;
        uint32_t n1 = k1 ^ n0;
        uint32_t n2 = k2 ^ n1;
        uint32_t n3 = k3 ^ n2;
        k0 = n0; k1 = n1; k2 = n2; k3 = n3;
        if (r != 10) {
            uint32_t a0 = T0[(s0 >> 24) & 0xff] ^ T1[(s1 >> 16) & 0xff] ^
                          T2[(s2 >> 8) & 0xff] ^ T3[s3 & 0xff] ^ k0;
            uint32_t a1 = T0[(s1 >> 24) & 0xff] ^ T1[(s2 >> 16) & 0xff] ^
                          T2[(s3 >> 8) & 0xff] ^ T3[s0 & 0xff] ^ k1;
            uint32_t a2 = T0[(s2 >> 24) & 0xff] ^ T1[(s3 >> 16) & 0xff] ^
                          T2[(s0 >> 8) & 0xff] ^ T3[s1 & 0xff] ^ k2;
            uint32_t a3 = T0[(s3 >> 24) & 0xff] ^ T1[(s0 >> 16) & 0xff] ^
                          T2[(s1 >> 8) & 0xff] ^ T3[s2 & 0xff] ^ k3;
            s0 = a0; s1 = a1; s2 = a2; s3 = a3;
        } else {
            uint32_t a0 = ((uint32_t)S[(s0 >> 24) & 0xff] << 24) |
                          ((uint32_t)S[(s1 >> 16) & 0xff] << 16) |
                          ((uint32_t)S[(s2 >> 8) & 0xff] << 8) | S[s3 & 0xff];
            uint32_t a1 = ((uint32_t)S[(s1 >> 24) & 0xff] << 24) |
                          ((uint32_t)S[(s2 >> 16) & 0xff] << 16) |
                          ((uint32_t)S[(s3 >> 8) & 0xff] << 8) | S[s0 & 0xff];
            uint32_t a2 = ((uint32_t)S[(s2 >> 24) & 0xff] << 24) |
                          ((uint32_t)S[(s3 >> 16) & 0xff] << 16) |
                          ((uint32_t)S[(s0 >> 8) & 0xff] << 8) | S[s1 & 0xff];
            uint32_t a3 = ((uint32_t)S[(s3 >> 24) & 0xff] << 24) |
                          ((uint32_t)S[(s0 >> 16) & 0xff] << 16) |
                          ((uint32_t)S[(s1 >> 8) & 0xff] << 8) | S[s2 & 0xff];
            *c0 = a0 ^ k0; *c1 = a1 ^ k1;
            *c2 = a2 ^ k2; *c3 = a3 ^ k3;
            return;
        }
    }
}

static __device__ __forceinline__ uint8_t kb(uint32_t x, int j)
{
    return (uint8_t)(x >> (24 - 8 * j));
}

static __device__ __forceinline__ void add_rk(uint8_t st[16], const uint32_t *w)
{
    for (int i = 0; i < 16; i++)
        st[i] ^= kb(w[i >> 2], i & 3);
}

static __device__ __forceinline__ uint8_t xs1(uint8_t a) { return xtime(a); }
static __device__ __forceinline__ uint8_t xs2(uint8_t a) { return xtime(xtime(a)); }
static __device__ __forceinline__ uint8_t xs3(uint8_t a) { return xtime(xtime(xtime(a))); }

/* InvMixColumns multipliers: 9 = 8^1, 11 = 8^2^1, 13 = 8^4^1, 14 = 8^4^2. */
static __device__ __forceinline__ uint8_t mul9(uint8_t a)  { return (uint8_t)(xs3(a) ^ a); }
static __device__ __forceinline__ uint8_t mul11(uint8_t a) { return (uint8_t)(xs3(a) ^ xs1(a) ^ a); }
static __device__ __forceinline__ uint8_t mul13(uint8_t a) { return (uint8_t)(xs3(a) ^ xs2(a) ^ a); }
static __device__ __forceinline__ uint8_t mul14(uint8_t a) { return (uint8_t)(xs3(a) ^ xs2(a) ^ xs1(a)); }

static __device__ void inv_mix(uint8_t st[16])
{
    for (int c = 0; c < 4; c++) {
        uint8_t a0 = st[4*c+0], a1 = st[4*c+1], a2 = st[4*c+2], a3 = st[4*c+3];
        uint8_t b0 = (xs3(a0) ^ xs2(a0) ^ xs1(a0)) ^ (xs3(a1) ^ xs1(a1) ^ a1) ^
                     (xs3(a2) ^ xs2(a2) ^ a2) ^ (xs3(a3) ^ a3);
        uint8_t b1 = (xs3(a0) ^ a0) ^ (xs3(a1) ^ xs2(a1) ^ xs1(a1)) ^
                     (xs3(a2) ^ xs1(a2) ^ a2) ^ (xs3(a3) ^ xs2(a3) ^ a3);
        uint8_t b2 = (xs3(a0) ^ xs2(a0) ^ a0) ^ (xs3(a1) ^ a1) ^
                     (xs3(a2) ^ xs2(a2) ^ xs1(a2)) ^ (xs3(a3) ^ xs1(a3) ^ a3);
        uint8_t b3 = (xs3(a0) ^ xs1(a0) ^ a0) ^ (xs3(a1) ^ xs2(a1) ^ a1) ^
                     (xs3(a2) ^ a2) ^ (xs3(a3) ^ xs2(a3) ^ xs1(a3));
        st[4*c+0] = b0; st[4*c+1] = b1; st[4*c+2] = b2; st[4*c+3] = b3;
    }
}

static __device__ void aes_decrypt(const uint32_t w[44], uint8_t st[16],
                                   const uint8_t *IS)
{
    add_rk(st, w + 40);
    for (int r = 9; r >= 1; r--) {
        uint8_t t[16];
        for (int row = 0; row < 4; row++)
            for (int c = 0; c < 4; c++)
                t[row + 4*c] = st[row + 4*((c - row + 4) & 3)];
        memcpy(st, t, 16);
        for (int i = 0; i < 16; i++)
            st[i] = IS[st[i]];
        add_rk(st, w + 4*r);
        inv_mix(st);
    }
    uint8_t t[16];
    for (int row = 0; row < 4; row++)
        for (int c = 0; c < 4; c++)
            t[row + 4*c] = st[row + 4*((c - row + 4) & 3)];
    memcpy(st, t, 16);
    for (int i = 0; i < 16; i++)
        st[i] = IS[st[i]];
    add_rk(st, w);
}

/* Equivalent-inverse-cipher fast path.  Td0..Td3 fuse InvSubBytes, InvShiftRows
 * and InvMixColumns into one lookup per byte; U0..U3 are the raw-byte
 * InvMixColumns columns, so the transformed round keys
 * dw[r] = InvMixColumns(w[r]) cost four lookups per word with no S-box step.
 * Td1/U1 etc. are stored one/two/three slots high and passed offset, matching
 * the T0..T3 convention, to keep the banks conflict-free. */
static __device__ void aes_decrypt_tt(const uint32_t w[44],
                                      uint32_t s0, uint32_t s1,
                                      uint32_t s2, uint32_t s3,
                                      const uint8_t *IS,
                                      const uint32_t *Td0, const uint32_t *Td1,
                                      const uint32_t *Td2, const uint32_t *Td3,
                                      const uint32_t *U0, const uint32_t *U1,
                                      const uint32_t *U2, const uint32_t *U3,
                                      uint32_t *p0, uint32_t *p1,
                                      uint32_t *p2, uint32_t *p3)
{
    s0 ^= w[40]; s1 ^= w[41]; s2 ^= w[42]; s3 ^= w[43];
    for (int r = 9; r >= 1; r--) {
        uint32_t x0 = w[4*r+0], x1 = w[4*r+1];
        uint32_t x2 = w[4*r+2], x3 = w[4*r+3];
        uint32_t k0 = U0[(x0 >> 24) & 0xff] ^ U1[(x0 >> 16) & 0xff] ^
                      U2[(x0 >> 8) & 0xff] ^ U3[x0 & 0xff];
        uint32_t k1 = U0[(x1 >> 24) & 0xff] ^ U1[(x1 >> 16) & 0xff] ^
                      U2[(x1 >> 8) & 0xff] ^ U3[x1 & 0xff];
        uint32_t k2 = U0[(x2 >> 24) & 0xff] ^ U1[(x2 >> 16) & 0xff] ^
                      U2[(x2 >> 8) & 0xff] ^ U3[x2 & 0xff];
        uint32_t k3 = U0[(x3 >> 24) & 0xff] ^ U1[(x3 >> 16) & 0xff] ^
                      U2[(x3 >> 8) & 0xff] ^ U3[x3 & 0xff];
        uint32_t a0 = Td0[(s0 >> 24) & 0xff] ^ Td1[(s3 >> 16) & 0xff] ^
                      Td2[(s2 >> 8) & 0xff] ^ Td3[s1 & 0xff] ^ k0;
        uint32_t a1 = Td0[(s1 >> 24) & 0xff] ^ Td1[(s0 >> 16) & 0xff] ^
                      Td2[(s3 >> 8) & 0xff] ^ Td3[s2 & 0xff] ^ k1;
        uint32_t a2 = Td0[(s2 >> 24) & 0xff] ^ Td1[(s1 >> 16) & 0xff] ^
                      Td2[(s0 >> 8) & 0xff] ^ Td3[s3 & 0xff] ^ k2;
        uint32_t a3 = Td0[(s3 >> 24) & 0xff] ^ Td1[(s2 >> 16) & 0xff] ^
                      Td2[(s1 >> 8) & 0xff] ^ Td3[s0 & 0xff] ^ k3;
        s0 = a0; s1 = a1; s2 = a2; s3 = a3;
    }
    *p0 = ((uint32_t)IS[(s0 >> 24) & 0xff] << 24) |
          ((uint32_t)IS[(s3 >> 16) & 0xff] << 16) |
          ((uint32_t)IS[(s2 >> 8) & 0xff] << 8) | IS[s1 & 0xff];
    *p1 = ((uint32_t)IS[(s1 >> 24) & 0xff] << 24) |
          ((uint32_t)IS[(s0 >> 16) & 0xff] << 16) |
          ((uint32_t)IS[(s3 >> 8) & 0xff] << 8) | IS[s2 & 0xff];
    *p2 = ((uint32_t)IS[(s2 >> 24) & 0xff] << 24) |
          ((uint32_t)IS[(s1 >> 16) & 0xff] << 16) |
          ((uint32_t)IS[(s0 >> 8) & 0xff] << 8) | IS[s3 & 0xff];
    *p3 = ((uint32_t)IS[(s3 >> 24) & 0xff] << 24) |
          ((uint32_t)IS[(s2 >> 16) & 0xff] << 16) |
          ((uint32_t)IS[(s1 >> 8) & 0xff] << 8) | IS[s0 & 0xff];
    *p0 ^= w[0]; *p1 ^= w[1]; *p2 ^= w[2]; *p3 ^= w[3];
}

/* Step the AES-128 schedule backwards: from round-q key words k0..k3 produce
 * round-(q-1) key words.  Uses Rcon[q] because w[4q] is the word that names it. */
static __device__ __forceinline__ void inv_key_step(uint32_t k0, uint32_t k1,
                                                    uint32_t k2, uint32_t k3,
                                                    const uint8_t *S, int q,
                                                    uint32_t *w0, uint32_t *w1,
                                                    uint32_t *w2, uint32_t *w3)
{
    uint32_t t1 = k3 ^ k2;                 /* w[4q-1] */
    uint32_t t2 = k2 ^ k1;                 /* w[4q-2] */
    uint32_t t3 = k1 ^ k0;                 /* w[4q-3] */
    uint32_t t0 = k0 ^ subword(rotr32(t1, 24), S) ^
                  ((uint32_t)RCON[q] << 24); /* w[4q-4] */
    *w0 = t0; *w1 = t3; *w2 = t2; *w3 = t1;
}

static __device__ __forceinline__ uint32_t key_mix(uint32_t x,
                                                   const uint32_t *U0,
                                                   const uint32_t *U1,
                                                   const uint32_t *U2,
                                                   const uint32_t *U3)
{
    return U0[(x >> 24) & 0xff] ^ U1[(x >> 16) & 0xff] ^
           U2[(x >> 8) & 0xff] ^ U3[x & 0xff];
}

/* Both oracle blocks for one key without a 44-word schedule in registers: the
 * rolling forward schedule produces E(K,0) and leaves round key 10; the
 * equivalent-inverse schedule is then walked backwards, deriving and
 * InvMixColumns-transforming each round key on the fly.  Four live key words
 * keep occupancy high. */
static __device__ void fmc_both(const uint8_t key[16],
                                const uint8_t *S, const uint8_t *IS,
                                const uint32_t *T0, const uint32_t *T1,
                                const uint32_t *T2, const uint32_t *T3,
                                const uint32_t *Td0, const uint32_t *Td1,
                                const uint32_t *Td2, const uint32_t *Td3,
                                const uint32_t *U0, const uint32_t *U1,
                                const uint32_t *U2, const uint32_t *U3,
                                uint32_t cw0, uint32_t cw1,
                                uint32_t cw2, uint32_t cw3,
                                uint32_t *ctr, uint32_t *dec)
{
    uint32_t k0 = load_be32(key + 0), k1 = load_be32(key + 4);
    uint32_t k2 = load_be32(key + 8), k3 = load_be32(key + 12);

    /* Forward: AES(K, 0).  After the loop k0..k3 is round key 10. */
    uint32_t s0 = k0, s1 = k1, s2 = k2, s3 = k3;
    for (int r = 1; r <= 10; r++) {
        uint32_t t = subword(rotr32(k3, 24), S) ^ ((uint32_t)RCON[r] << 24);
        uint32_t n0 = k0 ^ t, n1 = k1 ^ n0;
        uint32_t n2 = k2 ^ n1, n3 = k3 ^ n2;
        k0 = n0; k1 = n1; k2 = n2; k3 = n3;
        if (r != 10) {
            uint32_t a0 = T0[(s0 >> 24) & 0xff] ^ T1[(s1 >> 16) & 0xff] ^
                          T2[(s2 >> 8) & 0xff] ^ T3[s3 & 0xff] ^ k0;
            uint32_t a1 = T0[(s1 >> 24) & 0xff] ^ T1[(s2 >> 16) & 0xff] ^
                          T2[(s3 >> 8) & 0xff] ^ T3[s0 & 0xff] ^ k1;
            uint32_t a2 = T0[(s2 >> 24) & 0xff] ^ T1[(s3 >> 16) & 0xff] ^
                          T2[(s0 >> 8) & 0xff] ^ T3[s1 & 0xff] ^ k2;
            uint32_t a3 = T0[(s3 >> 24) & 0xff] ^ T1[(s0 >> 16) & 0xff] ^
                          T2[(s1 >> 8) & 0xff] ^ T3[s2 & 0xff] ^ k3;
            s0 = a0; s1 = a1; s2 = a2; s3 = a3;
        } else {
            uint32_t a0 = ((uint32_t)S[(s0 >> 24) & 0xff] << 24) |
                          ((uint32_t)S[(s1 >> 16) & 0xff] << 16) |
                          ((uint32_t)S[(s2 >> 8) & 0xff] << 8) | S[s3 & 0xff];
            uint32_t a1 = ((uint32_t)S[(s1 >> 24) & 0xff] << 24) |
                          ((uint32_t)S[(s2 >> 16) & 0xff] << 16) |
                          ((uint32_t)S[(s3 >> 8) & 0xff] << 8) | S[s0 & 0xff];
            uint32_t a2 = ((uint32_t)S[(s2 >> 24) & 0xff] << 24) |
                          ((uint32_t)S[(s3 >> 16) & 0xff] << 16) |
                          ((uint32_t)S[(s0 >> 8) & 0xff] << 8) | S[s1 & 0xff];
            uint32_t a3 = ((uint32_t)S[(s3 >> 24) & 0xff] << 24) |
                          ((uint32_t)S[(s0 >> 16) & 0xff] << 16) |
                          ((uint32_t)S[(s1 >> 8) & 0xff] << 8) | S[s2 & 0xff];
            ctr[0] = a0 ^ k0; ctr[1] = a1 ^ k1;
            ctr[2] = a2 ^ k2; ctr[3] = a3 ^ k3;
        }
    }

    /* Inverse: D(K, C0).  k is round 10; each iteration steps back one round,
     * transforms that round key with U, and runs the Td round for it. */
    uint32_t d0 = cw0 ^ k0, d1 = cw1 ^ k1;
    uint32_t d2 = cw2 ^ k2, d3 = cw3 ^ k3;
    for (int r = 9; r >= 1; r--) {
        inv_key_step(k0, k1, k2, k3, S, r + 1, &k0, &k1, &k2, &k3);
        uint32_t e0 = key_mix(k0, U0, U1, U2, U3);
        uint32_t e1 = key_mix(k1, U0, U1, U2, U3);
        uint32_t e2 = key_mix(k2, U0, U1, U2, U3);
        uint32_t e3 = key_mix(k3, U0, U1, U2, U3);
        uint32_t a0 = Td0[(d0 >> 24) & 0xff] ^ Td1[(d3 >> 16) & 0xff] ^
                      Td2[(d2 >> 8) & 0xff] ^ Td3[d1 & 0xff] ^ e0;
        uint32_t a1 = Td0[(d1 >> 24) & 0xff] ^ Td1[(d0 >> 16) & 0xff] ^
                      Td2[(d3 >> 8) & 0xff] ^ Td3[d2 & 0xff] ^ e1;
        uint32_t a2 = Td0[(d2 >> 24) & 0xff] ^ Td1[(d1 >> 16) & 0xff] ^
                      Td2[(d0 >> 8) & 0xff] ^ Td3[d3 & 0xff] ^ e2;
        uint32_t a3 = Td0[(d3 >> 24) & 0xff] ^ Td1[(d2 >> 16) & 0xff] ^
                      Td2[(d1 >> 8) & 0xff] ^ Td3[d0 & 0xff] ^ e3;
        d0 = a0; d1 = a1; d2 = a2; d3 = a3;
    }
    inv_key_step(k0, k1, k2, k3, S, 1, &k0, &k1, &k2, &k3);
    dec[0] = (((uint32_t)IS[(d0 >> 24) & 0xff] << 24) |
              ((uint32_t)IS[(d3 >> 16) & 0xff] << 16) |
              ((uint32_t)IS[(d2 >> 8) & 0xff] << 8) | IS[d1 & 0xff]) ^ k0;
    dec[1] = (((uint32_t)IS[(d1 >> 24) & 0xff] << 24) |
              ((uint32_t)IS[(d0 >> 16) & 0xff] << 16) |
              ((uint32_t)IS[(d3 >> 8) & 0xff] << 8) | IS[d2 & 0xff]) ^ k1;
    dec[2] = (((uint32_t)IS[(d2 >> 24) & 0xff] << 24) |
              ((uint32_t)IS[(d1 >> 16) & 0xff] << 16) |
              ((uint32_t)IS[(d0 >> 8) & 0xff] << 8) | IS[d3 & 0xff]) ^ k2;
    dec[3] = (((uint32_t)IS[(d3 >> 24) & 0xff] << 24) |
              ((uint32_t)IS[(d2 >> 16) & 0xff] << 16) |
              ((uint32_t)IS[(d1 >> 8) & 0xff] << 8) | IS[d0 & 0xff]) ^ k3;
}

static __device__ __forceinline__ uint32_t le32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static __device__ __forceinline__ int is_size(uint32_t v)
{
    return v == 0x37000u || v == 0x46200u || v == 0xE800u || v == 0x30A00u ||
           v == 0x25800u || v == 0xA800u || v == 0xFA00u || v == 0x18000u ||
           v == 0x1000u || v == 0x10000u || v == 0x3EC00u || v == 0x2FC00u ||
           v == 0x33D00u || v == 0x2E800u || v == 0x30500u || v == 0x28600u;
}

static __device__ int fmc_hit(const uint8_t p[16])
{
    uint32_t a = le32(p), b = le32(p + 4);
    uint32_t c = le32(p + 8), d = le32(p + 12);
    if (a == 0x464C457Fu) {                 /* exact ELF ident */
        return (p[4] == 1 || p[4] == 2) && (p[5] == 1 || p[5] == 2) &&
               p[6] == 1 && (p[7] == 0 || p[7] == 3) &&
               p[8] == 0 && p[9] == 0 && p[10] == 0 && p[11] == 0 &&
               p[12] == 0 && p[13] == 0 && p[14] == 0 && p[15] == 0;
    }
    if (a == 0x000010DEu)                   /* nvfw_bin_hdr, 0x10de */
        return b < 0x1000 && c < 0x100000 &&
               (is_size(d) || d < 0x100000);
    if (a == 0x3B1D14F0u)                   /* nvfw new format */
        return b < 0x100000 || is_size(b);
    if (a == 0x00480403u)                   /* FMC container + body size */
        return is_size(b);
    if (a == 0x5746564Eu)                   /* NVFW TLV */
        return b < 0x100000 || is_size(b);
    if (a == 0xFD2FB528u)                   /* zstd, FHD reserved clear */
        return (p[4] & 0x08) == 0;
    if (a == 0x184D2204u)                   /* lz4 frame, version/reserved */
        return (p[4] >> 6) == 1 && (p[4] & 0x02) == 0;
    if (a == 0x184C2102u)                   /* lz4 legacy */
        return b < 0x100000 || is_size(b);
    if (a == 0x587A37FDu)                   /* xz 6-byte magic */
        return p[4] == 0x5a && p[5] == 0x00;
    if (a == 0x00088B1Fu)                   /* gzip, mtime 0 */
        return c == 0;
    if (is_size(a) && (is_size(b) || b == 0)) /* two size fields */
        return 1;
    if (a == 0 && b == 0)                   /* zero header */
        return 1;
    return 0;
}

/* Marginal log-probability of a 16-byte block under the RISC-V parcel model.
 * RISC-V is 16-bit aligned; each 16-bit parcel is one table entry.  A block of
 * real code scores far above a random block. */
static __device__ __forceinline__ int block_score(const uint8_t p[16])
{
    int s = 0;
    #pragma unroll
    for (int i = 0; i < 8; i++) {
        int v = (int)p[2 * i] | ((int)p[2 * i + 1] << 8);
        s += (int)__ldg(&g_logp[v]);
    }
    return s;
}

static __device__ void record_hit_score(uint8_t mode, const uint8_t *key,
                                        uint64_t rank, const uint8_t *p0,
                                        int32_t score)
{
    uint32_t idx = atomicAdd(&g_hitcount, 1);
    if (idx < HITMAX) {
        memcpy(g_hitkey[idx], key, 16);
        g_hitrank[idx] = rank;
        memcpy(g_hitp0[idx], p0, 16);
        g_hitmode[idx] = mode;
        g_hitscore[idx] = score;
    }
}

static __device__ void record_hit(uint8_t mode, const uint8_t *key,
                                  uint64_t rank, const uint8_t *p0)
{
    record_hit_score(mode, key, rank, p0, 0);
}

/* Lexicographic unrank: idx = rank / (15-i)!, rank %= (15-i)!.  The previous
 * version used the colexicographic mixed-radix digits (rank % (16-i)), which
 * does not match next_perm's lexicographic order; thread ranges overlapped and
 * the 16! pass was not exhaustive. */
static __device__ void unrank(uint64_t rank, uint8_t out[16])
{
    uint8_t pool[16];
    memcpy(pool, POOL_D, 16);
    for (int i = 0; i < 16; i++) {
        uint64_t f = FACT_D[15 - i];
        uint64_t idx = rank / f;
        rank %= f;
        out[i] = pool[idx];
        for (int j = (int)idx; j < 15; j++)
            pool[j] = pool[j + 1];
    }
}

static __device__ __forceinline__ int eq16(const uint8_t *a, const uint8_t *b)
{
    for (int i = 0; i < 16; i++)
        if (a[i] != b[i])
            return 0;
    return 1;
}

static __device__ int next_perm(uint8_t *a, int n)
{
    int i = n - 2;
    while (i >= 0 && a[i] >= a[i + 1])
        i--;
    if (i < 0)
        return 0;
    int j = n - 1;
    while (a[j] <= a[i])
        j--;
    uint8_t t = a[i]; a[i] = a[j]; a[j] = t;
    for (int l = i + 1, r = n - 1; l < r; l++, r--) {
        t = a[l]; a[l] = a[r]; a[r] = t;
    }
    return 1;
}

__device__ int g_found = 0;
__device__ uint64_t g_rank = 0;
__device__ uint8_t g_key[16];

__global__ void search_kernel(uint64_t start, uint64_t count)
{
    uint64_t tid = (uint64_t)blockIdx.x * blockDim.x + threadIdx.x;
    uint64_t nthreads = (uint64_t)gridDim.x * blockDim.x;
    uint64_t chunk = count / nthreads;
    uint64_t s = start + tid * chunk;
    uint64_t n = (tid == nthreads - 1) ? (count - tid * chunk) : chunk;
    if (s >= start + count)
        n = 0;
    uint8_t perm[16];
    unrank(s, perm);
    for (uint64_t i = 0; i < n; i++) {
        if ((i & 0xfffff) == 0 && *((volatile int *)&g_found))
            return;
        uint8_t rk[176], st[16];
        key_expand(perm, rk);
        memset(st, 0, 16);
        encrypt_block(rk, st);
        if (eq16(st, KAT_D)) {
            if (atomicCAS(&g_found, 0, 1) == 0) {
                g_rank = s + i;
                memcpy(g_key, perm, 16);
            }
            return;
        }
        if (!next_perm(perm, 16))
            return;
    }
}

__global__ void fmc_oracle_kernel(uint64_t start, uint64_t count)
{
    __shared__ uint8_t S[256], IS[256];
    __shared__ uint32_t T0[256], T1[257], T2[258], T3[259];
    __shared__ uint32_t Td0[256], Td1[257], Td2[258], Td3[259];
    __shared__ uint32_t U0[256], U1[257], U2[258], U3[259];
    for (int i = threadIdx.x; i < 256; i += blockDim.x) {
        uint8_t s = SBOX_D[i];
        uint8_t s2 = xtime(s), s3 = (uint8_t)(s2 ^ s);
        uint32_t t = ((uint32_t)s2 << 24) | ((uint32_t)s << 16) |
                     ((uint32_t)s << 8) | (uint32_t)s3;
        S[i] = s;
        IS[i] = INVSBOX_D[i];
        T0[i] = t;
        T1[i + 1] = rotr32(t, 8);
        T2[i + 2] = rotr32(t, 16);
        T3[i + 3] = rotr32(t, 24);
        uint8_t v = INVSBOX_D[i];
        uint32_t td = ((uint32_t)mul14(v) << 24) | ((uint32_t)mul9(v) << 16) |
                      ((uint32_t)mul13(v) << 8) | (uint32_t)mul11(v);
        Td0[i] = td;
        Td1[i + 1] = rotr32(td, 8);
        Td2[i + 2] = rotr32(td, 16);
        Td3[i + 3] = rotr32(td, 24);
        uint32_t u = ((uint32_t)mul14((uint8_t)i) << 24) |
                     ((uint32_t)mul9((uint8_t)i) << 16) |
                     ((uint32_t)mul13((uint8_t)i) << 8) |
                     (uint32_t)mul11((uint8_t)i);
        U0[i] = u;
        U1[i + 1] = rotr32(u, 8);
        U2[i + 2] = rotr32(u, 16);
        U3[i + 3] = rotr32(u, 24);
    }
    __syncthreads();

    uint64_t tid = (uint64_t)blockIdx.x * blockDim.x + threadIdx.x;
    uint64_t nthreads = (uint64_t)gridDim.x * blockDim.x;
    uint64_t chunk = count / nthreads;
    uint64_t s = start + tid * chunk;
    uint64_t n = (tid == nthreads - 1) ? (count - tid * chunk) : chunk;
    if (s >= start + count)
        n = 0;
    uint8_t perm[16];
    unrank(s, perm);
    for (uint64_t i = 0; i < n; i++) {
        uint32_t w[44];
        key_expand_tt(perm, w, S);

        /* ECB / CBC-with-zero-IV first block: D(K, C0), Td-table inverse. */
        uint32_t q0, q1, q2, q3;
        aes_decrypt_tt(w, load_be32(C0_D + 0), load_be32(C0_D + 4),
                       load_be32(C0_D + 8), load_be32(C0_D + 12),
                       IS, Td0, Td1 + 1, Td2 + 2, Td3 + 3,
                       U0, U1 + 1, U2 + 2, U3 + 3,
                       &q0, &q1, &q2, &q3);
        uint8_t st[16];
        st[0] = kb(q0, 0); st[1] = kb(q0, 1); st[2] = kb(q0, 2); st[3] = kb(q0, 3);
        st[4] = kb(q1, 0); st[5] = kb(q1, 1); st[6] = kb(q1, 2); st[7] = kb(q1, 3);
        st[8] = kb(q2, 0); st[9] = kb(q2, 1); st[10] = kb(q2, 2); st[11] = kb(q2, 3);
        st[12] = kb(q3, 0); st[13] = kb(q3, 1); st[14] = kb(q3, 2); st[15] = kb(q3, 3);
        if (fmc_hit(st))
            record_hit(0, perm, s + i, st);

        /* CTR-zero first block: E(K, 0) XOR C0. */
        uint32_t k0, k1, k2, k3;
        encrypt_tt(w, 0, 0, 0, 0, S, T0, T1 + 1, T2 + 2, T3 + 3,
                   &k0, &k1, &k2, &k3);
        uint8_t p0[16];
        p0[0] = kb(k0,0) ^ C0_D[0]; p0[1] = kb(k0,1) ^ C0_D[1];
        p0[2] = kb(k0,2) ^ C0_D[2]; p0[3] = kb(k0,3) ^ C0_D[3];
        p0[4] = kb(k1,0) ^ C0_D[4]; p0[5] = kb(k1,1) ^ C0_D[5];
        p0[6] = kb(k1,2) ^ C0_D[6]; p0[7] = kb(k1,3) ^ C0_D[7];
        p0[8] = kb(k2,0) ^ C0_D[8]; p0[9] = kb(k2,1) ^ C0_D[9];
        p0[10] = kb(k2,2) ^ C0_D[10]; p0[11] = kb(k2,3) ^ C0_D[11];
        p0[12] = kb(k3,0) ^ C0_D[12]; p0[13] = kb(k3,1) ^ C0_D[13];
        p0[14] = kb(k3,2) ^ C0_D[14]; p0[15] = kb(k3,3) ^ C0_D[15];
        if (fmc_hit(p0))
            record_hit(1, perm, s + i, p0);

        if (!next_perm(perm, 16))
            return;
    }
}

/* Bank-replicated oracle variant (RF=16).  T0/Td0 are stored as tab[i*16 + c]
 * and lane l reads column l & 15, so a warp's 32 lookups land on 16 distinct
 * banks instead of colliding by index mod 32.  T1..T3 and Td1..Td3 are derived
 * with rotates, so only two 16 KB tables replace eight 1 KB ones. */
__global__ void __maxnreg__(128) fmc_oracle_kernel_rf16(uint64_t start, uint64_t count)
{
    __shared__ uint32_t T0r[256 * 16], Td0r[256 * 16];
    __shared__ uint8_t S[256], IS[256];
    __shared__ uint32_t U0[256], U1[257], U2[258], U3[259];
    for (int i = threadIdx.x; i < 256 * 16; i += blockDim.x) {
        int idx = i >> 4;
        uint8_t s = SBOX_D[idx];
        uint8_t s2 = xtime(s), s3 = (uint8_t)(s2 ^ s);
        T0r[i] = ((uint32_t)s2 << 24) | ((uint32_t)s << 16) |
                 ((uint32_t)s << 8) | (uint32_t)s3;
        uint8_t v = INVSBOX_D[idx];
        Td0r[i] = ((uint32_t)mul14(v) << 24) | ((uint32_t)mul9(v) << 16) |
                  ((uint32_t)mul13(v) << 8) | (uint32_t)mul11(v);
    }
    for (int i = threadIdx.x; i < 256; i += blockDim.x) {
        S[i] = SBOX_D[i];
        IS[i] = INVSBOX_D[i];
        uint32_t u = ((uint32_t)mul14((uint8_t)i) << 24) |
                     ((uint32_t)mul9((uint8_t)i) << 16) |
                     ((uint32_t)mul13((uint8_t)i) << 8) |
                     (uint32_t)mul11((uint8_t)i);
        U0[i] = u;
        U1[i + 1] = rotr32(u, 8);
        U2[i + 2] = rotr32(u, 16);
        U3[i + 3] = rotr32(u, 24);
    }
    __syncthreads();

    const int col = threadIdx.x & 15;
    uint64_t tid = (uint64_t)blockIdx.x * blockDim.x + threadIdx.x;
    uint64_t nthreads = (uint64_t)gridDim.x * blockDim.x;
    uint64_t chunk = count / nthreads;
    uint64_t s = start + tid * chunk;
    uint64_t n = (tid == nthreads - 1) ? (count - tid * chunk) : chunk;
    if (s >= start + count)
        n = 0;
    uint8_t perm[16];
    unrank(s, perm);
    for (uint64_t i = 0; i < n; i++) {
        uint32_t w[44];
        key_expand_tt(perm, w, S);

        /* D(K, C0) with rotated single-table lookups. */
        uint32_t d0 = load_be32(C0_D + 0) ^ w[40];
        uint32_t d1 = load_be32(C0_D + 4) ^ w[41];
        uint32_t d2 = load_be32(C0_D + 8) ^ w[42];
        uint32_t d3 = load_be32(C0_D + 12) ^ w[43];
        #pragma unroll
        for (int r = 9; r >= 1; r--) {
            uint32_t e0 = key_mix(w[4*r+0], U0, U1 + 1, U2 + 2, U3 + 3);
            uint32_t e1 = key_mix(w[4*r+1], U0, U1 + 1, U2 + 2, U3 + 3);
            uint32_t e2 = key_mix(w[4*r+2], U0, U1 + 1, U2 + 2, U3 + 3);
            uint32_t e3 = key_mix(w[4*r+3], U0, U1 + 1, U2 + 2, U3 + 3);
            uint32_t a0 = Td0r[(((d0 >> 24) & 0xff) << 4) | col] ^
                          rotr32(Td0r[(((d3 >> 16) & 0xff) << 4) | col], 8) ^
                          rotr32(Td0r[(((d2 >> 8) & 0xff) << 4) | col], 16) ^
                          rotr32(Td0r[(d1 & 0xff) << 4 | col], 24) ^ e0;
            uint32_t a1 = Td0r[(((d1 >> 24) & 0xff) << 4) | col] ^
                          rotr32(Td0r[(((d0 >> 16) & 0xff) << 4) | col], 8) ^
                          rotr32(Td0r[(((d3 >> 8) & 0xff) << 4) | col], 16) ^
                          rotr32(Td0r[(d2 & 0xff) << 4 | col], 24) ^ e1;
            uint32_t a2 = Td0r[(((d2 >> 24) & 0xff) << 4) | col] ^
                          rotr32(Td0r[(((d1 >> 16) & 0xff) << 4) | col], 8) ^
                          rotr32(Td0r[(((d0 >> 8) & 0xff) << 4) | col], 16) ^
                          rotr32(Td0r[(d3 & 0xff) << 4 | col], 24) ^ e2;
            uint32_t a3 = Td0r[(((d3 >> 24) & 0xff) << 4) | col] ^
                          rotr32(Td0r[(((d2 >> 16) & 0xff) << 4) | col], 8) ^
                          rotr32(Td0r[(((d1 >> 8) & 0xff) << 4) | col], 16) ^
                          rotr32(Td0r[(d0 & 0xff) << 4 | col], 24) ^ e3;
            d0 = a0; d1 = a1; d2 = a2; d3 = a3;
        }
        uint8_t st[16];
        st[0] = (uint8_t)(IS[(d0 >> 24) & 0xff] ^ kb(w[0], 0));
        st[1] = (uint8_t)(IS[(d3 >> 16) & 0xff] ^ kb(w[0], 1));
        st[2] = (uint8_t)(IS[(d2 >> 8) & 0xff] ^ kb(w[0], 2));
        st[3] = (uint8_t)(IS[d1 & 0xff] ^ kb(w[0], 3));
        st[4] = (uint8_t)(IS[(d1 >> 24) & 0xff] ^ kb(w[1], 0));
        st[5] = (uint8_t)(IS[(d0 >> 16) & 0xff] ^ kb(w[1], 1));
        st[6] = (uint8_t)(IS[(d3 >> 8) & 0xff] ^ kb(w[1], 2));
        st[7] = (uint8_t)(IS[d2 & 0xff] ^ kb(w[1], 3));
        st[8] = (uint8_t)(IS[(d2 >> 24) & 0xff] ^ kb(w[2], 0));
        st[9] = (uint8_t)(IS[(d1 >> 16) & 0xff] ^ kb(w[2], 1));
        st[10] = (uint8_t)(IS[(d0 >> 8) & 0xff] ^ kb(w[2], 2));
        st[11] = (uint8_t)(IS[d3 & 0xff] ^ kb(w[2], 3));
        st[12] = (uint8_t)(IS[(d3 >> 24) & 0xff] ^ kb(w[3], 0));
        st[13] = (uint8_t)(IS[(d2 >> 16) & 0xff] ^ kb(w[3], 1));
        st[14] = (uint8_t)(IS[(d1 >> 8) & 0xff] ^ kb(w[3], 2));
        st[15] = (uint8_t)(IS[d0 & 0xff] ^ kb(w[3], 3));
        if (fmc_hit(st))
            record_hit(0, perm, s + i, st);

        /* E(K, 0) with rotated single-table lookups. */
        uint32_t s0 = w[0], s1 = w[1], s2 = w[2], s3 = w[3];
        #pragma unroll
        for (int r = 1; r <= 9; r++) {
            uint32_t a0 = T0r[(((s0 >> 24) & 0xff) << 4) | col] ^
                          rotr32(T0r[(((s1 >> 16) & 0xff) << 4) | col], 8) ^
                          rotr32(T0r[(((s2 >> 8) & 0xff) << 4) | col], 16) ^
                          rotr32(T0r[(s3 & 0xff) << 4 | col], 24) ^ w[4*r+0];
            uint32_t a1 = T0r[(((s1 >> 24) & 0xff) << 4) | col] ^
                          rotr32(T0r[(((s2 >> 16) & 0xff) << 4) | col], 8) ^
                          rotr32(T0r[(((s3 >> 8) & 0xff) << 4) | col], 16) ^
                          rotr32(T0r[(s0 & 0xff) << 4 | col], 24) ^ w[4*r+1];
            uint32_t a2 = T0r[(((s2 >> 24) & 0xff) << 4) | col] ^
                          rotr32(T0r[(((s3 >> 16) & 0xff) << 4) | col], 8) ^
                          rotr32(T0r[(((s0 >> 8) & 0xff) << 4) | col], 16) ^
                          rotr32(T0r[(s1 & 0xff) << 4 | col], 24) ^ w[4*r+2];
            uint32_t a3 = T0r[(((s3 >> 24) & 0xff) << 4) | col] ^
                          rotr32(T0r[(((s0 >> 16) & 0xff) << 4) | col], 8) ^
                          rotr32(T0r[(((s1 >> 8) & 0xff) << 4) | col], 16) ^
                          rotr32(T0r[(s2 & 0xff) << 4 | col], 24) ^ w[4*r+3];
            s0 = a0; s1 = a1; s2 = a2; s3 = a3;
        }
        uint32_t c0 = (((uint32_t)S[(s0 >> 24) & 0xff] << 24) |
                       ((uint32_t)S[(s1 >> 16) & 0xff] << 16) |
                       ((uint32_t)S[(s2 >> 8) & 0xff] << 8) | S[s3 & 0xff]) ^ w[40];
        uint32_t c1 = (((uint32_t)S[(s1 >> 24) & 0xff] << 24) |
                       ((uint32_t)S[(s2 >> 16) & 0xff] << 16) |
                       ((uint32_t)S[(s3 >> 8) & 0xff] << 8) | S[s0 & 0xff]) ^ w[41];
        uint32_t c2 = (((uint32_t)S[(s2 >> 24) & 0xff] << 24) |
                       ((uint32_t)S[(s3 >> 16) & 0xff] << 16) |
                       ((uint32_t)S[(s0 >> 8) & 0xff] << 8) | S[s1 & 0xff]) ^ w[42];
        uint32_t c3 = (((uint32_t)S[(s3 >> 24) & 0xff] << 24) |
                       ((uint32_t)S[(s0 >> 16) & 0xff] << 16) |
                       ((uint32_t)S[(s1 >> 8) & 0xff] << 8) | S[s2 & 0xff]) ^ w[43];
        uint8_t p0[16];
        p0[0] = kb(c0,0) ^ C0_D[0]; p0[1] = kb(c0,1) ^ C0_D[1];
        p0[2] = kb(c0,2) ^ C0_D[2]; p0[3] = kb(c0,3) ^ C0_D[3];
        p0[4] = kb(c1,0) ^ C0_D[4]; p0[5] = kb(c1,1) ^ C0_D[5];
        p0[6] = kb(c1,2) ^ C0_D[6]; p0[7] = kb(c1,3) ^ C0_D[7];
        p0[8] = kb(c2,0) ^ C0_D[8]; p0[9] = kb(c2,1) ^ C0_D[9];
        p0[10] = kb(c2,2) ^ C0_D[10]; p0[11] = kb(c2,3) ^ C0_D[11];
        p0[12] = kb(c3,0) ^ C0_D[12]; p0[13] = kb(c3,1) ^ C0_D[13];
        p0[14] = kb(c3,2) ^ C0_D[14]; p0[15] = kb(c3,3) ^ C0_D[15];
        if (fmc_hit(p0))
            record_hit(1, perm, s + i, p0);

        if (!next_perm(perm, 16))
            return;
    }
}

/* ---- RISC-V-validity oracle -------------------------------------------------
 *
 * The GB202 FMC container body was measured to be [code][data][manifest 0xa00]
 * and the code component is shared with the matching GspRmBoot image
 * (measured 2026-10-28).  The body therefore starts with RISC-V code, so the
 * first-block magic oracle can discard the correct key.  Instead of testing one
 * magic, score a plaintext block against a parcel language model trained on the
 * plaintext GSP-RM code segment.  Stage 1 (one block, both modes) is per-key;
 * Stage 2 (nblocks, stronger score) runs only for rows that pass Stage 1.
 */

/* D(K, C) on the RF16 tables, returning the 16 plaintext bytes. */
static __device__ __forceinline__ void dec16_rf16(
    const uint32_t w[44], const uint8_t c[16], int col,
    const uint8_t *IS, const uint32_t *Td0r,
    const uint32_t *U0, const uint32_t *U1,
    const uint32_t *U2, const uint32_t *U3, uint8_t out[16])
{
    uint32_t d0 = load_be32(c + 0) ^ w[40];
    uint32_t d1 = load_be32(c + 4) ^ w[41];
    uint32_t d2 = load_be32(c + 8) ^ w[42];
    uint32_t d3 = load_be32(c + 12) ^ w[43];
    #pragma unroll
    for (int r = 9; r >= 1; r--) {
        uint32_t e0 = key_mix(w[4*r+0], U0, U1 + 1, U2 + 2, U3 + 3);
        uint32_t e1 = key_mix(w[4*r+1], U0, U1 + 1, U2 + 2, U3 + 3);
        uint32_t e2 = key_mix(w[4*r+2], U0, U1 + 1, U2 + 2, U3 + 3);
        uint32_t e3 = key_mix(w[4*r+3], U0, U1 + 1, U2 + 2, U3 + 3);
        uint32_t a0 = Td0r[(((d0 >> 24) & 0xff) << 4) | col] ^
                      rotr32(Td0r[(((d3 >> 16) & 0xff) << 4) | col], 8) ^
                      rotr32(Td0r[(((d2 >> 8) & 0xff) << 4) | col], 16) ^
                      rotr32(Td0r[(d1 & 0xff) << 4 | col], 24) ^ e0;
        uint32_t a1 = Td0r[(((d1 >> 24) & 0xff) << 4) | col] ^
                      rotr32(Td0r[(((d0 >> 16) & 0xff) << 4) | col], 8) ^
                      rotr32(Td0r[(((d3 >> 8) & 0xff) << 4) | col], 16) ^
                      rotr32(Td0r[(d2 & 0xff) << 4 | col], 24) ^ e1;
        uint32_t a2 = Td0r[(((d2 >> 24) & 0xff) << 4) | col] ^
                      rotr32(Td0r[(((d1 >> 16) & 0xff) << 4) | col], 8) ^
                      rotr32(Td0r[(((d0 >> 8) & 0xff) << 4) | col], 16) ^
                      rotr32(Td0r[(d3 & 0xff) << 4 | col], 24) ^ e2;
        uint32_t a3 = Td0r[(((d3 >> 24) & 0xff) << 4) | col] ^
                      rotr32(Td0r[(((d2 >> 16) & 0xff) << 4) | col], 8) ^
                      rotr32(Td0r[(((d1 >> 8) & 0xff) << 4) | col], 16) ^
                      rotr32(Td0r[(d0 & 0xff) << 4 | col], 24) ^ e3;
        d0 = a0; d1 = a1; d2 = a2; d3 = a3;
    }
    out[0]  = (uint8_t)(IS[(d0 >> 24) & 0xff] ^ kb(w[0], 0));
    out[1]  = (uint8_t)(IS[(d3 >> 16) & 0xff] ^ kb(w[0], 1));
    out[2]  = (uint8_t)(IS[(d2 >>  8) & 0xff] ^ kb(w[0], 2));
    out[3]  = (uint8_t)(IS[d1 & 0xff] ^ kb(w[0], 3));
    out[4]  = (uint8_t)(IS[(d1 >> 24) & 0xff] ^ kb(w[1], 0));
    out[5]  = (uint8_t)(IS[(d0 >> 16) & 0xff] ^ kb(w[1], 1));
    out[6]  = (uint8_t)(IS[(d3 >>  8) & 0xff] ^ kb(w[1], 2));
    out[7]  = (uint8_t)(IS[d2 & 0xff] ^ kb(w[1], 3));
    out[8]  = (uint8_t)(IS[(d2 >> 24) & 0xff] ^ kb(w[2], 0));
    out[9]  = (uint8_t)(IS[(d1 >> 16) & 0xff] ^ kb(w[2], 1));
    out[10] = (uint8_t)(IS[(d0 >>  8) & 0xff] ^ kb(w[2], 2));
    out[11] = (uint8_t)(IS[d3 & 0xff] ^ kb(w[2], 3));
    out[12] = (uint8_t)(IS[(d3 >> 24) & 0xff] ^ kb(w[3], 0));
    out[13] = (uint8_t)(IS[(d2 >> 16) & 0xff] ^ kb(w[3], 1));
    out[14] = (uint8_t)(IS[(d1 >>  8) & 0xff] ^ kb(w[3], 2));
    out[15] = (uint8_t)(IS[d0 & 0xff] ^ kb(w[3], 3));
}

/* E(K, P) on the RF16 tables, returning the 16 ciphertext bytes. */
static __device__ __forceinline__ void enc16_rf16(
    const uint32_t w[44], uint32_t p0, uint32_t p1, uint32_t p2, uint32_t p3,
    int col, const uint8_t *S, const uint32_t *T0r, uint8_t out[16])
{
    uint32_t s0 = p0 ^ w[0], s1 = p1 ^ w[1], s2 = p2 ^ w[2], s3 = p3 ^ w[3];
    #pragma unroll
    for (int r = 1; r <= 9; r++) {
        uint32_t a0 = T0r[(((s0 >> 24) & 0xff) << 4) | col] ^
                      rotr32(T0r[(((s1 >> 16) & 0xff) << 4) | col], 8) ^
                      rotr32(T0r[(((s2 >> 8) & 0xff) << 4) | col], 16) ^
                      rotr32(T0r[(s3 & 0xff) << 4 | col], 24) ^ w[4*r+0];
        uint32_t a1 = T0r[(((s1 >> 24) & 0xff) << 4) | col] ^
                      rotr32(T0r[(((s2 >> 16) & 0xff) << 4) | col], 8) ^
                      rotr32(T0r[(((s3 >> 8) & 0xff) << 4) | col], 16) ^
                      rotr32(T0r[(s0 & 0xff) << 4 | col], 24) ^ w[4*r+1];
        uint32_t a2 = T0r[(((s2 >> 24) & 0xff) << 4) | col] ^
                      rotr32(T0r[(((s3 >> 16) & 0xff) << 4) | col], 8) ^
                      rotr32(T0r[(((s0 >> 8) & 0xff) << 4) | col], 16) ^
                      rotr32(T0r[(s1 & 0xff) << 4 | col], 24) ^ w[4*r+2];
        uint32_t a3 = T0r[(((s3 >> 24) & 0xff) << 4) | col] ^
                      rotr32(T0r[(((s2 >> 16) & 0xff) << 4) | col], 8) ^
                      rotr32(T0r[(((s1 >> 8) & 0xff) << 4) | col], 16) ^
                      rotr32(T0r[(s2 & 0xff) << 4 | col], 24) ^ w[4*r+3];
        s0 = a0; s1 = a1; s2 = a2; s3 = a3;
    }
    uint32_t c0 = (((uint32_t)S[(s0 >> 24) & 0xff] << 24) |
                   ((uint32_t)S[(s1 >> 16) & 0xff] << 16) |
                   ((uint32_t)S[(s2 >> 8) & 0xff] << 8) | S[s3 & 0xff]) ^ w[40];
    uint32_t c1 = (((uint32_t)S[(s1 >> 24) & 0xff] << 24) |
                   ((uint32_t)S[(s2 >> 16) & 0xff] << 16) |
                   ((uint32_t)S[(s3 >> 8) & 0xff] << 8) | S[s0 & 0xff]) ^ w[41];
    uint32_t c2 = (((uint32_t)S[(s2 >> 24) & 0xff] << 24) |
                   ((uint32_t)S[(s3 >> 16) & 0xff] << 16) |
                   ((uint32_t)S[(s0 >> 8) & 0xff] << 8) | S[s1 & 0xff]) ^ w[42];
    uint32_t c3 = (((uint32_t)S[(s3 >> 24) & 0xff] << 24) |
                   ((uint32_t)S[(s0 >> 16) & 0xff] << 16) |
                   ((uint32_t)S[(s1 >> 8) & 0xff] << 8) | S[s2 & 0xff]) ^ w[43];
    out[0]  = kb(c0, 0); out[1]  = kb(c0, 1);
    out[2]  = kb(c0, 2); out[3]  = kb(c0, 3);
    out[4]  = kb(c1, 0); out[5]  = kb(c1, 1);
    out[6]  = kb(c1, 2); out[7]  = kb(c1, 3);
    out[8]  = kb(c2, 0); out[9]  = kb(c2, 1);
    out[10] = kb(c2, 2); out[11] = kb(c2, 3);
    out[12] = kb(c3, 0); out[13] = kb(c3, 1);
    out[14] = kb(c3, 2); out[15] = kb(c3, 3);
}

/* Hit modes: 0 = ECB (decrypt), 1 = CBC-zero (decrypt), 2 = CTR-zero. */
__global__ void __maxnreg__(128) fmc_riscv_kernel_rf16(
    uint64_t start, uint64_t count, int t1, int t2, int nblocks)
{
    __shared__ uint32_t T0r[256 * 16], Td0r[256 * 16];
    __shared__ uint8_t S[256], IS[256];
    __shared__ uint32_t U0[256], U1[257], U2[258], U3[259];
    for (int i = threadIdx.x; i < 256 * 16; i += blockDim.x) {
        int idx = i >> 4;
        uint8_t s = SBOX_D[idx];
        uint8_t s2 = xtime(s), s3 = (uint8_t)(s2 ^ s);
        T0r[i] = ((uint32_t)s2 << 24) | ((uint32_t)s << 16) |
                 ((uint32_t)s << 8) | (uint32_t)s3;
        uint8_t v = INVSBOX_D[idx];
        Td0r[i] = ((uint32_t)mul14(v) << 24) | ((uint32_t)mul9(v) << 16) |
                  ((uint32_t)mul13(v) << 8) | (uint32_t)mul11(v);
    }
    for (int i = threadIdx.x; i < 256; i += blockDim.x) {
        S[i] = SBOX_D[i];
        IS[i] = INVSBOX_D[i];
        uint32_t u = ((uint32_t)mul14((uint8_t)i) << 24) |
                     ((uint32_t)mul9((uint8_t)i) << 16) |
                     ((uint32_t)mul13((uint8_t)i) << 8) |
                     (uint32_t)mul11((uint8_t)i);
        U0[i] = u;
        U1[i + 1] = rotr32(u, 8);
        U2[i + 2] = rotr32(u, 16);
        U3[i + 3] = rotr32(u, 24);
    }
    __syncthreads();

    const int col = threadIdx.x & 15;
    uint64_t tid = (uint64_t)blockIdx.x * blockDim.x + threadIdx.x;
    uint64_t nthreads = (uint64_t)gridDim.x * blockDim.x;
    uint64_t chunk = count / nthreads;
    uint64_t s = start + tid * chunk;
    uint64_t n = (tid == nthreads - 1) ? (count - tid * chunk) : chunk;
    if (s >= start + count)
        n = 0;
    uint8_t perm[16];
    unrank(s, perm);
    for (uint64_t i = 0; i < n; i++) {
        uint32_t w[44];
        key_expand_tt(perm, w, S);

        /* Mode 0 stage 1: D(K, C0); identical for ECB and CBC-zero. */
        uint8_t b0[16];
        dec16_rf16(w, CBLK_D[0], col, IS, Td0r, U0, U1, U2, U3, b0);
        if (block_score(b0) > t1) {
            int secb = 0, scbc = 0;
            for (int j = 0; j < nblocks; j++) {
                uint8_t e[16], cbc[16];
                if (j == 0) {
                    for (int k = 0; k < 16; k++)
                        e[k] = b0[k];
                } else {
                    dec16_rf16(w, CBLK_D[j], col, IS, Td0r, U0, U1, U2, U3, e);
                }
                /* CBC-zero decrypts each block with the previous *ciphertext*
                 * (the IV is zero before block 0). */
                for (int k = 0; k < 16; k++)
                    cbc[k] = (uint8_t)(e[k] ^
                                       (j == 0 ? 0 : CBLK_D[j - 1][k]));
                secb += block_score(e);
                scbc += block_score(cbc);
            }
            if (secb > t2)
                record_hit_score(0, perm, s + i, b0, secb);
            if (scbc > t2)
                record_hit_score(1, perm, s + i, b0, scbc);
        }

        /* Mode 1 stage 1: CTR with zero counter, E(K,0) xor C0. */
        uint8_t e0[16], p0[16];
        enc16_rf16(w, 0, 0, 0, 0, col, S, T0r, e0);
        for (int k = 0; k < 16; k++)
            p0[k] = (uint8_t)(e0[k] ^ CBLK_D[0][k]);
        if (block_score(p0) > t1) {
            int sctr = 0;
            for (int j = 0; j < nblocks; j++) {
                uint8_t e[16], blk[16];
                if (j == 0) {
                    for (int k = 0; k < 16; k++)
                        e[k] = e0[k];
                } else {
                    uint32_t jb = (uint32_t)j; /* counter = block index, big-endian low word */
                    enc16_rf16(w, 0, 0, 0, jb, col, S, T0r, e);
                }
                for (int k = 0; k < 16; k++)
                    blk[k] = (uint8_t)(e[k] ^ CBLK_D[j][k]);
                sctr += block_score(blk);
            }
            if (sctr > t2)
                record_hit_score(2, perm, s + i, p0, sctr);
        }

        if (!next_perm(perm, 16))
            return;
    }
}

/* RISC-V oracle on the compact (non-bank-replicated) AES tables.  The RF16
 * kernel's 37.4 KB of shared memory leaves too little unified L1 for the 64 KB
 * parcel table, and the global lookups then miss L1 and dominate.  This variant
 * uses 12.9 KB of shared memory (2 blocks/SM) so the table stays resident. */
static __device__ __forceinline__ void dec16_tt(
    const uint32_t w[44], const uint8_t c[16],
    const uint8_t *IS,
    const uint32_t *Td0, const uint32_t *Td1,
    const uint32_t *Td2, const uint32_t *Td3,
    const uint32_t *U0, const uint32_t *U1,
    const uint32_t *U2, const uint32_t *U3, uint8_t out[16])
{
    uint32_t q0, q1, q2, q3;
    aes_decrypt_tt(w, load_be32(c + 0), load_be32(c + 4),
                   load_be32(c + 8), load_be32(c + 12), IS,
                   Td0, Td1, Td2, Td3, U0, U1, U2, U3,
                   &q0, &q1, &q2, &q3);
    out[0] = kb(q0, 0); out[1] = kb(q0, 1); out[2] = kb(q0, 2); out[3] = kb(q0, 3);
    out[4] = kb(q1, 0); out[5] = kb(q1, 1); out[6] = kb(q1, 2); out[7] = kb(q1, 3);
    out[8] = kb(q2, 0); out[9] = kb(q2, 1); out[10] = kb(q2, 2); out[11] = kb(q2, 3);
    out[12] = kb(q3, 0); out[13] = kb(q3, 1); out[14] = kb(q3, 2); out[15] = kb(q3, 3);
}

static __device__ __forceinline__ void enc16_tt(
    const uint32_t w[44], uint32_t p0, uint32_t p1, uint32_t p2, uint32_t p3,
    const uint8_t *S,
    const uint32_t *T0, const uint32_t *T1,
    const uint32_t *T2, const uint32_t *T3, uint8_t out[16])
{
    uint32_t c0, c1, c2, c3;
    encrypt_tt(w, p0, p1, p2, p3, S, T0, T1, T2, T3, &c0, &c1, &c2, &c3);
    out[0] = kb(c0, 0); out[1] = kb(c0, 1); out[2] = kb(c0, 2); out[3] = kb(c0, 3);
    out[4] = kb(c1, 0); out[5] = kb(c1, 1); out[6] = kb(c1, 2); out[7] = kb(c1, 3);
    out[8] = kb(c2, 0); out[9] = kb(c2, 1); out[10] = kb(c2, 2); out[11] = kb(c2, 3);
    out[12] = kb(c3, 0); out[13] = kb(c3, 1); out[14] = kb(c3, 2); out[15] = kb(c3, 3);
}

__global__ void __launch_bounds__(256, 2) fmc_riscv_kernel(
    uint64_t start, uint64_t count, int t1, int t2, int nblocks)
{
    __shared__ uint8_t S[256], IS[256];
    __shared__ uint32_t T0[256], T1[257], T2[258], T3[259];
    __shared__ uint32_t Td0[256], Td1[257], Td2[258], Td3[259];
    __shared__ uint32_t U0[256], U1[257], U2[258], U3[259];
    for (int i = threadIdx.x; i < 256; i += blockDim.x) {
        uint8_t s = SBOX_D[i];
        uint8_t s2 = xtime(s), s3 = (uint8_t)(s2 ^ s);
        uint32_t t = ((uint32_t)s2 << 24) | ((uint32_t)s << 16) |
                     ((uint32_t)s << 8) | (uint32_t)s3;
        S[i] = s;
        IS[i] = INVSBOX_D[i];
        T0[i] = t;
        T1[i + 1] = rotr32(t, 8);
        T2[i + 2] = rotr32(t, 16);
        T3[i + 3] = rotr32(t, 24);
        uint8_t v = INVSBOX_D[i];
        uint32_t td = ((uint32_t)mul14(v) << 24) | ((uint32_t)mul9(v) << 16) |
                      ((uint32_t)mul13(v) << 8) | (uint32_t)mul11(v);
        Td0[i] = td;
        Td1[i + 1] = rotr32(td, 8);
        Td2[i + 2] = rotr32(td, 16);
        Td3[i + 3] = rotr32(td, 24);
        uint32_t u = ((uint32_t)mul14((uint8_t)i) << 24) |
                     ((uint32_t)mul9((uint8_t)i) << 16) |
                     ((uint32_t)mul13((uint8_t)i) << 8) |
                     (uint32_t)mul11((uint8_t)i);
        U0[i] = u;
        U1[i + 1] = rotr32(u, 8);
        U2[i + 2] = rotr32(u, 16);
        U3[i + 3] = rotr32(u, 24);
    }
    __syncthreads();

    uint64_t tid = (uint64_t)blockIdx.x * blockDim.x + threadIdx.x;
    uint64_t nthreads = (uint64_t)gridDim.x * blockDim.x;
    uint64_t chunk = count / nthreads;
    uint64_t s = start + tid * chunk;
    uint64_t n = (tid == nthreads - 1) ? (count - tid * chunk) : chunk;
    if (s >= start + count)
        n = 0;
    uint8_t perm[16];
    unrank(s, perm);
    for (uint64_t i = 0; i < n; i++) {
        uint32_t w[44];
        key_expand_tt(perm, w, S);

        uint8_t b0[16], b0iv[16];
        dec16_tt(w, CBLK_D[0], IS, Td0, Td1 + 1, Td2 + 2, Td3 + 3,
                 U0, U1 + 1, U2 + 2, U3 + 3, b0);
        for (int k = 0; k < 16; k++)
            b0iv[k] = (uint8_t)(b0[k] ^ HIV_D[k]);
        int sb0 = block_score(b0);
        int sb0iv = block_score(b0iv);
        /* Mode 0: ECB and CBC with a zero IV share block 0; CBC with the
         * header IV differs only at block 0 (later blocks XOR the previous
         * ciphertext), so one stream covers all three. */
        if (sb0 > t1 || sb0iv > t1) {
            int secb = 0, scbc = 0;
            for (int j = 0; j < nblocks; j++) {
                uint8_t e[16], cbc[16];
                if (j == 0) {
                    for (int k = 0; k < 16; k++)
                        e[k] = b0[k];
                } else {
                    dec16_tt(w, CBLK_D[j], IS, Td0, Td1 + 1, Td2 + 2, Td3 + 3,
                             U0, U1 + 1, U2 + 2, U3 + 3, e);
                }
                for (int k = 0; k < 16; k++)
                    cbc[k] = (uint8_t)(e[k] ^
                                       (j == 0 ? 0 : CBLK_D[j - 1][k]));
                secb += block_score(e);
                scbc += block_score(cbc);
            }
            int scbc_iv = scbc - sb0 + sb0iv;
            if (secb > t2)
                record_hit_score(0, perm, s + i, b0, secb);
            if (scbc > t2)
                record_hit_score(1, perm, s + i, b0, scbc);
            if (scbc_iv > t2)
                record_hit_score(3, perm, s + i, b0iv, scbc_iv);
        }

        /* Mode 1: CTR with counter start 0 (mode 2) and 1 (mode 4).  Stage 1
         * needs one encrypt per counter start; counters are the block index
         * plus the start in the low 32 bits of a big-endian block. */
        uint8_t e0[16], e1[16], p0[16], p1[16];
        enc16_tt(w, 0, 0, 0, 0, S, T0, T1 + 1, T2 + 2, T3 + 3, e0);
        enc16_tt(w, 0, 0, 0, 1, S, T0, T1 + 1, T2 + 2, T3 + 3, e1);
        for (int k = 0; k < 16; k++) {
            p0[k] = (uint8_t)(e0[k] ^ CBLK_D[0][k]);
            p1[k] = (uint8_t)(e1[k] ^ CBLK_D[0][k]);
        }
        if (block_score(p0) > t1) {
            int sctr = 0;
            for (int j = 0; j < nblocks; j++) {
                uint8_t e[16], blk[16];
                if (j == 0) {
                    for (int k = 0; k < 16; k++)
                        e[k] = e0[k];
                } else {
                    uint32_t jb = (uint32_t)j;
                    enc16_tt(w, 0, 0, 0, jb, S, T0, T1 + 1, T2 + 2, T3 + 3, e);
                }
                for (int k = 0; k < 16; k++)
                    blk[k] = (uint8_t)(e[k] ^ CBLK_D[j][k]);
                sctr += block_score(blk);
            }
            if (sctr > t2)
                record_hit_score(2, perm, s + i, p0, sctr);
        }
        if (block_score(p1) > t1) {
            int sctr1 = 0;
            for (int j = 0; j < nblocks; j++) {
                uint8_t e[16], blk[16];
                if (j == 0) {
                    for (int k = 0; k < 16; k++)
                        e[k] = e1[k];
                } else {
                    uint32_t jb = (uint32_t)(1 + j);
                    enc16_tt(w, 0, 0, 0, jb, S, T0, T1 + 1, T2 + 2, T3 + 3, e);
                }
                for (int k = 0; k < 16; k++)
                    blk[k] = (uint8_t)(e[k] ^ CBLK_D[j][k]);
                sctr1 += block_score(blk);
            }
            if (sctr1 > t2)
                record_hit_score(4, perm, s + i, p1, sctr1);
        }

        if (!next_perm(perm, 16))
            return;
    }
}

/* Reference oracle path: full 44-word schedule, byte-wise inverse cipher.
 * Kept as the A/B baseline for the Td table version (host flag --fmc-byte). */
__global__ void fmc_oracle_kernel_byte(uint64_t start, uint64_t count)
{
    __shared__ uint8_t S[256], IS[256];
    __shared__ uint32_t T0[256], T1[257], T2[258], T3[259];
    for (int i = threadIdx.x; i < 256; i += blockDim.x) {
        uint8_t s = SBOX_D[i];
        uint8_t s2 = xtime(s), s3 = (uint8_t)(s2 ^ s);
        uint32_t t = ((uint32_t)s2 << 24) | ((uint32_t)s << 16) |
                     ((uint32_t)s << 8) | (uint32_t)s3;
        S[i] = s;
        IS[i] = INVSBOX_D[i];
        T0[i] = t;
        T1[i + 1] = rotr32(t, 8);
        T2[i + 2] = rotr32(t, 16);
        T3[i + 3] = rotr32(t, 24);
    }
    __syncthreads();

    uint64_t tid = (uint64_t)blockIdx.x * blockDim.x + threadIdx.x;
    uint64_t nthreads = (uint64_t)gridDim.x * blockDim.x;
    uint64_t chunk = count / nthreads;
    uint64_t s = start + tid * chunk;
    uint64_t n = (tid == nthreads - 1) ? (count - tid * chunk) : chunk;
    if (s >= start + count)
        n = 0;
    uint8_t perm[16];
    unrank(s, perm);
    for (uint64_t i = 0; i < n; i++) {
        uint32_t w[44];
        key_expand_tt(perm, w, S);

        uint8_t st[16];
        memcpy(st, C0_D, 16);
        aes_decrypt(w, st, IS);
        if (fmc_hit(st))
            record_hit(0, perm, s + i, st);

        uint32_t k0, k1, k2, k3;
        encrypt_tt(w, 0, 0, 0, 0, S, T0, T1 + 1, T2 + 2, T3 + 3,
                   &k0, &k1, &k2, &k3);
        uint8_t p0[16];
        p0[0] = kb(k0,0) ^ C0_D[0]; p0[1] = kb(k0,1) ^ C0_D[1];
        p0[2] = kb(k0,2) ^ C0_D[2]; p0[3] = kb(k0,3) ^ C0_D[3];
        p0[4] = kb(k1,0) ^ C0_D[4]; p0[5] = kb(k1,1) ^ C0_D[5];
        p0[6] = kb(k1,2) ^ C0_D[6]; p0[7] = kb(k1,3) ^ C0_D[7];
        p0[8] = kb(k2,0) ^ C0_D[8]; p0[9] = kb(k2,1) ^ C0_D[9];
        p0[10] = kb(k2,2) ^ C0_D[10]; p0[11] = kb(k2,3) ^ C0_D[11];
        p0[12] = kb(k3,0) ^ C0_D[12]; p0[13] = kb(k3,1) ^ C0_D[13];
        p0[14] = kb(k3,2) ^ C0_D[14]; p0[15] = kb(k3,3) ^ C0_D[15];
        if (fmc_hit(p0))
            record_hit(1, perm, s + i, p0);

        if (!next_perm(perm, 16))
            return;
    }
}

__global__ void search_kernel_tt(uint64_t start, uint64_t count, uint32_t p)
{
    __shared__ uint8_t S[256];
    __shared__ uint32_t T0[256], T1[257], T2[258], T3[259];
    for (int i = threadIdx.x; i < 256; i += blockDim.x) {
        uint8_t s = SBOX_D[i];
        uint8_t s2 = xtime(s), s3 = (uint8_t)(s2 ^ s);
        uint32_t t = ((uint32_t)s2 << 24) | ((uint32_t)s << 16) |
                     ((uint32_t)s << 8) | (uint32_t)s3;
        S[i] = s;
        T0[i] = t;
        T1[i + 1] = rotr32(t, 8);
        T2[i + 2] = rotr32(t, 16);
        T3[i + 3] = rotr32(t, 24);
    }
    __syncthreads();

    uint64_t tid = (uint64_t)blockIdx.x * blockDim.x + threadIdx.x;
    uint64_t nthreads = (uint64_t)gridDim.x * blockDim.x;
    uint64_t chunk = count / nthreads;
    uint64_t s = start + tid * chunk;
    uint64_t n = (tid == nthreads - 1) ? (count - tid * chunk) : chunk;
    if (s >= start + count)
        n = 0;
    uint8_t perm[16];
    unrank(s, perm);
    for (uint64_t i = 0; i < n; i++) {
        if ((i & 0xfffff) == 0 && *((volatile int *)&g_found))
            return;
        uint32_t c0, c1, c2, c3;
        encrypt_tt_roll(perm, p, S, T0, T1 + 1, T2 + 2, T3 + 3,
                        &c0, &c1, &c2, &c3);
        if (c0 == 0x717d1494u && c1 == 0xeaca317fu &&
            c2 == 0xf1061952u && c3 == 0x58b38377u) {
            if (atomicCAS(&g_found, 0, 1) == 0) {
                g_rank = s + i;
                memcpy(g_key, perm, 16);
            }
            return;
        }
        if (!next_perm(perm, 16))
            return;
    }
}

/* Round-key transform: for each IV permutation P, expand P's AES-128 key
 * schedule and use the LAST round key (words 40..43) as the AES key, then test
 * AES(K, p) against the KAT.  This is the literal reading of the cmp170hx
 * "key number sits in the last round key / feed round keys in reverse" note. */
__global__ void search_kernel_rk(uint64_t start, uint64_t count, uint32_t p)
{
    __shared__ uint8_t S[256];
    __shared__ uint32_t T0[256], T1[257], T2[258], T3[259];
    for (int i = threadIdx.x; i < 256; i += blockDim.x) {
        uint8_t s = SBOX_D[i];
        uint8_t s2 = xtime(s), s3 = (uint8_t)(s2 ^ s);
        uint32_t t = ((uint32_t)s2 << 24) | ((uint32_t)s << 16) |
                     ((uint32_t)s << 8) | (uint32_t)s3;
        S[i] = s;
        T0[i] = t;
        T1[i + 1] = rotr32(t, 8);
        T2[i + 2] = rotr32(t, 16);
        T3[i + 3] = rotr32(t, 24);
    }
    __syncthreads();

    uint64_t tid = (uint64_t)blockIdx.x * blockDim.x + threadIdx.x;
    uint64_t nthreads = (uint64_t)gridDim.x * blockDim.x;
    uint64_t chunk = count / nthreads;
    uint64_t s = start + tid * chunk;
    uint64_t n = (tid == nthreads - 1) ? (count - tid * chunk) : chunk;
    if (s >= start + count)
        n = 0;
    uint8_t perm[16];
    unrank(s, perm);
    for (uint64_t i = 0; i < n; i++) {
        if ((i & 0xfffff) == 0 && *((volatile int *)&g_found))
            return;
        uint32_t w[44];
        key_expand_tt(perm, w, S);
        uint8_t K[16];
        for (int j = 0; j < 4; j++) {
            uint32_t x = w[40 + j];
            K[4*j + 0] = (uint8_t)(x >> 24);
            K[4*j + 1] = (uint8_t)(x >> 16);
            K[4*j + 2] = (uint8_t)(x >> 8);
            K[4*j + 3] = (uint8_t)x;
        }
        uint32_t c0, c1, c2, c3;
        encrypt_tt_roll(K, p, S, T0, T1 + 1, T2 + 2, T3 + 3,
                        &c0, &c1, &c2, &c3);
        if (c0 == 0x717d1494u && c1 == 0xeaca317fu &&
            c2 == 0xf1061952u && c3 == 0x58b38377u) {
            if (atomicCAS(&g_found, 0, 1) == 0) {
                g_rank = s + i;
                memcpy(g_key, K, 16);
            }
            return;
        }
        if (!next_perm(perm, 16))
            return;
    }
}

__global__ void aes_test_kernel(const uint8_t *key, const uint8_t *pt, uint8_t *ct)
{
    uint8_t rk[176], st[16];
    memcpy(st, pt, 16);
    key_expand(key, rk);
    encrypt_block(rk, st);
    memcpy(ct, st, 16);
}

__global__ void tt_test_kernel(const uint8_t *key, const uint8_t *pt, uint8_t *ct)
{
    __shared__ uint8_t S[256];
    __shared__ uint32_t T0[256], T1[257], T2[258], T3[259];
    for (int i = threadIdx.x; i < 256; i += blockDim.x) {
        uint8_t s = SBOX_D[i];
        uint8_t s2 = xtime(s), s3 = (uint8_t)(s2 ^ s);
        uint32_t t = ((uint32_t)s2 << 24) | ((uint32_t)s << 16) |
                     ((uint32_t)s << 8) | (uint32_t)s3;
        S[i] = s;
        T0[i] = t;
        T1[i + 1] = rotr32(t, 8);
        T2[i + 2] = rotr32(t, 16);
        T3[i + 3] = rotr32(t, 24);
    }
    __syncthreads();
    if (threadIdx.x != 0)
        return;
    uint32_t w[44];
    key_expand_tt(key, w, S);
    uint32_t p0 = ((uint32_t)pt[0] << 24) | ((uint32_t)pt[1] << 16) |
                  ((uint32_t)pt[2] << 8) | (uint32_t)pt[3];
    uint32_t p1 = ((uint32_t)pt[4] << 24) | ((uint32_t)pt[5] << 16) |
                  ((uint32_t)pt[6] << 8) | (uint32_t)pt[7];
    uint32_t p2 = ((uint32_t)pt[8] << 24) | ((uint32_t)pt[9] << 16) |
                  ((uint32_t)pt[10] << 8) | (uint32_t)pt[11];
    uint32_t p3 = ((uint32_t)pt[12] << 24) | ((uint32_t)pt[13] << 16) |
                  ((uint32_t)pt[14] << 8) | (uint32_t)pt[15];
    uint32_t c0, c1, c2, c3;
    encrypt_tt(w, p0, p1, p2, p3, S, T0, T1 + 1, T2 + 2, T3 + 3, &c0, &c1, &c2, &c3);
    ct[0] = c0 >> 24; ct[1] = c0 >> 16; ct[2] = c0 >> 8; ct[3] = c0;
    ct[4] = c1 >> 24; ct[5] = c1 >> 16; ct[6] = c1 >> 8; ct[7] = c1;
    ct[8] = c2 >> 24; ct[9] = c2 >> 16; ct[10] = c2 >> 8; ct[11] = c2;
    ct[12] = c3 >> 24; ct[13] = c3 >> 16; ct[14] = c3 >> 8; ct[15] = c3;
}

__global__ void tt_roll_test_kernel(const uint8_t *key, uint32_t p, uint8_t *ct)
{
    __shared__ uint8_t S[256];
    __shared__ uint32_t T0[256], T1[257], T2[258], T3[259];
    for (int i = threadIdx.x; i < 256; i += blockDim.x) {
        uint8_t s = SBOX_D[i];
        uint8_t s2 = xtime(s), s3 = (uint8_t)(s2 ^ s);
        uint32_t t = ((uint32_t)s2 << 24) | ((uint32_t)s << 16) |
                     ((uint32_t)s << 8) | (uint32_t)s3;
        S[i] = s;
        T0[i] = t;
        T1[i + 1] = rotr32(t, 8);
        T2[i + 2] = rotr32(t, 16);
        T3[i + 3] = rotr32(t, 24);
    }
    __syncthreads();
    if (threadIdx.x != 0)
        return;
    uint32_t c0, c1, c2, c3;
    encrypt_tt_roll(key, p, S, T0, T1 + 1, T2 + 2, T3 + 3, &c0, &c1, &c2, &c3);
    ct[0] = c0 >> 24; ct[1] = c0 >> 16; ct[2] = c0 >> 8; ct[3] = c0;
    ct[4] = c1 >> 24; ct[5] = c1 >> 16; ct[6] = c1 >> 8; ct[7] = c1;
    ct[8] = c2 >> 24; ct[9] = c2 >> 16; ct[10] = c2 >> 8; ct[11] = c2;
    ct[12] = c3 >> 24; ct[13] = c3 >> 16; ct[14] = c3 >> 8; ct[15] = c3;
}

__global__ void dec_test_kernel(const uint8_t *key, const uint8_t *ct, uint8_t *pt)
{
    __shared__ uint8_t S[256], IS[256];
    for (int i = threadIdx.x; i < 256; i += blockDim.x) {
        S[i] = SBOX_D[i];
        IS[i] = INVSBOX_D[i];
    }
    __syncthreads();
    if (threadIdx.x != 0)
        return;
    uint32_t w[44];
    key_expand_tt(key, w, S);
    uint8_t st[16];
    memcpy(st, ct, 16);
    aes_decrypt(w, st, IS);
    memcpy(pt, st, 16);
}

__global__ void dec_tt_test_kernel(const uint8_t *key, const uint8_t *ct,
                                   uint8_t *pt)
{
    __shared__ uint8_t S[256], IS[256];
    __shared__ uint32_t Td0[256], Td1[257], Td2[258], Td3[259];
    __shared__ uint32_t U0[256], U1[257], U2[258], U3[259];
    for (int i = threadIdx.x; i < 256; i += blockDim.x) {
        uint8_t v = INVSBOX_D[i];
        S[i] = SBOX_D[i];
        IS[i] = v;
        uint32_t td = ((uint32_t)mul14(v) << 24) | ((uint32_t)mul9(v) << 16) |
                      ((uint32_t)mul13(v) << 8) | (uint32_t)mul11(v);
        Td0[i] = td;
        Td1[i + 1] = rotr32(td, 8);
        Td2[i + 2] = rotr32(td, 16);
        Td3[i + 3] = rotr32(td, 24);
        uint32_t u = ((uint32_t)mul14((uint8_t)i) << 24) |
                     ((uint32_t)mul9((uint8_t)i) << 16) |
                     ((uint32_t)mul13((uint8_t)i) << 8) |
                     (uint32_t)mul11((uint8_t)i);
        U0[i] = u;
        U1[i + 1] = rotr32(u, 8);
        U2[i + 2] = rotr32(u, 16);
        U3[i + 3] = rotr32(u, 24);
    }
    __syncthreads();
    if (threadIdx.x != 0)
        return;
    uint32_t w[44];
    key_expand_tt(key, w, S);
    uint32_t q0, q1, q2, q3;
    aes_decrypt_tt(w, load_be32(ct + 0), load_be32(ct + 4),
                   load_be32(ct + 8), load_be32(ct + 12),
                   IS, Td0, Td1 + 1, Td2 + 2, Td3 + 3,
                   U0, U1 + 1, U2 + 2, U3 + 3,
                   &q0, &q1, &q2, &q3);
    pt[0] = kb(q0, 0); pt[1] = kb(q0, 1); pt[2] = kb(q0, 2); pt[3] = kb(q0, 3);
    pt[4] = kb(q1, 0); pt[5] = kb(q1, 1); pt[6] = kb(q1, 2); pt[7] = kb(q1, 3);
    pt[8] = kb(q2, 0); pt[9] = kb(q2, 1); pt[10] = kb(q2, 2); pt[11] = kb(q2, 3);
    pt[12] = kb(q3, 0); pt[13] = kb(q3, 1); pt[14] = kb(q3, 2); pt[15] = kb(q3, 3);
}

__global__ void fmc_both_test_kernel(const uint8_t *key, const uint8_t *ct,
                                     uint8_t *ctr_out, uint8_t *dec_out)
{
    __shared__ uint8_t S[256], IS[256];
    __shared__ uint32_t T0[256], T1[257], T2[258], T3[259];
    __shared__ uint32_t Td0[256], Td1[257], Td2[258], Td3[259];
    __shared__ uint32_t U0[256], U1[257], U2[258], U3[259];
    for (int i = threadIdx.x; i < 256; i += blockDim.x) {
        uint8_t s = SBOX_D[i];
        uint8_t s2 = xtime(s), s3 = (uint8_t)(s2 ^ s);
        uint32_t t = ((uint32_t)s2 << 24) | ((uint32_t)s << 16) |
                     ((uint32_t)s << 8) | (uint32_t)s3;
        S[i] = s;
        IS[i] = INVSBOX_D[i];
        T0[i] = t;
        T1[i + 1] = rotr32(t, 8);
        T2[i + 2] = rotr32(t, 16);
        T3[i + 3] = rotr32(t, 24);
        uint8_t v = INVSBOX_D[i];
        uint32_t td = ((uint32_t)mul14(v) << 24) | ((uint32_t)mul9(v) << 16) |
                      ((uint32_t)mul13(v) << 8) | (uint32_t)mul11(v);
        Td0[i] = td;
        Td1[i + 1] = rotr32(td, 8);
        Td2[i + 2] = rotr32(td, 16);
        Td3[i + 3] = rotr32(td, 24);
        uint32_t u = ((uint32_t)mul14((uint8_t)i) << 24) |
                     ((uint32_t)mul9((uint8_t)i) << 16) |
                     ((uint32_t)mul13((uint8_t)i) << 8) |
                     (uint32_t)mul11((uint8_t)i);
        U0[i] = u;
        U1[i + 1] = rotr32(u, 8);
        U2[i + 2] = rotr32(u, 16);
        U3[i + 3] = rotr32(u, 24);
    }
    __syncthreads();
    if (threadIdx.x != 0)
        return;
    uint32_t ctr[4], dec[4];
    fmc_both(key, S, IS, T0, T1 + 1, T2 + 2, T3 + 3,
             Td0, Td1 + 1, Td2 + 2, Td3 + 3, U0, U1 + 1, U2 + 2, U3 + 3,
             load_be32(ct + 0), load_be32(ct + 4),
             load_be32(ct + 8), load_be32(ct + 12), ctr, dec);
    for (int w = 0; w < 4; w++) {
        ctr_out[4*w+0] = kb(ctr[w], 0); ctr_out[4*w+1] = kb(ctr[w], 1);
        ctr_out[4*w+2] = kb(ctr[w], 2); ctr_out[4*w+3] = kb(ctr[w], 3);
        dec_out[4*w+0] = kb(dec[w], 0); dec_out[4*w+1] = kb(dec[w], 1);
        dec_out[4*w+2] = kb(dec[w], 2); dec_out[4*w+3] = kb(dec[w], 3);
    }
}

__global__ void unrank_test_kernel(uint8_t *out, uint64_t r)
{
    uint8_t p[16];
    unrank(r, p);
    memcpy(out, p, 16);
}

/* Partition window test: each thread enumerates the same rank slice the search
 * kernels use and folds every permutation into an FNV-1a digest.  The host
 * recomputes the window from host_unrank and checks first/last/digest, so this
 * proves the device enumeration covers every rank exactly once: no gaps, no
 * repeats, and the same order as the reference unrank. */
__global__ void enum_window_kernel(uint64_t start, uint64_t count,
                                   uint8_t *first, uint8_t *last,
                                   uint64_t *digest)
{
    uint64_t tid = (uint64_t)blockIdx.x * blockDim.x + threadIdx.x;
    uint64_t nthreads = (uint64_t)gridDim.x * blockDim.x;
    uint64_t chunk = count / nthreads;
    uint64_t s = start + tid * chunk;
    uint64_t n = (tid == nthreads - 1) ? (count - tid * chunk) : chunk;
    if (s >= start + count)
        n = 0;
    uint8_t perm[16];
    unrank(s, perm);
    memcpy(first + tid * 16, perm, 16);
    uint64_t h = 1469598103934665603ULL;
    for (uint64_t i = 0; i < n; i++) {
        if (i == n - 1)
            memcpy(last + tid * 16, perm, 16);
        for (int j = 0; j < 16; j++)
            h = (h ^ perm[j]) * 1099511628211ULL;
        if (i + 1 < n && !next_perm(perm, 16))
            return;
    }
    if (n == 0)
        memcpy(last + tid * 16, perm, 16);
    digest[tid] = h;
}

static const uint64_t FACT_H[16] = {
    1ULL, 1ULL, 2ULL, 6ULL, 24ULL, 120ULL, 720ULL, 5040ULL,
    40320ULL, 362880ULL, 3628800ULL, 39916800ULL, 479001600ULL,
    6227020800ULL, 87178291200ULL, 1307674368000ULL
};
static const uint8_t POOL_H[16] = {
    0x01, 0x10, 0x23, 0x32, 0x45, 0x54, 0x67, 0x76,
    0x89, 0x98, 0xab, 0xba, 0xcd, 0xdc, 0xef, 0xfe
};

static void host_unrank(uint64_t rank, uint8_t out[16])
{
    uint8_t pool[16];
    memcpy(pool, POOL_H, 16);
    for (int i = 0; i < 16; i++) {
        uint64_t f = FACT_H[15 - i];
        uint64_t idx = rank / f;
        rank %= f;
        out[i] = pool[idx];
        for (int j = (int)idx; j < 15; j++)
            pool[j] = pool[j + 1];
    }
}

static int host_next_perm(uint8_t *a, int n)
{
    int i = n - 2;
    while (i >= 0 && a[i] >= a[i + 1])
        i--;
    if (i < 0)
        return 0;
    int j = n - 1;
    while (a[j] <= a[i])
        j--;
    uint8_t t = a[i]; a[i] = a[j]; a[j] = t;
    for (int l = i + 1, r = n - 1; l < r; l++, r--) {
        t = a[l]; a[l] = a[r]; a[r] = t;
    }
    return 1;
}

static void die(const char *msg)
{
    fprintf(stderr, "%s: %s\n", msg, cudaGetErrorString(cudaGetLastError()));
    exit(2);
}

static double wall_now()
{
    return std::chrono::duration<double>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

struct hit_rec {
    uint8_t mode;
    uint8_t key[16];
    uint8_t p0[16];
    uint64_t rank;
    int32_t score;
};

/* Sort by key, then rank, then mode: identical (mode,key,rank) records become
 * adjacent, and so do the two modes of one key/rank. */
static int hit_cmp(const void *va, const void *vb)
{
    const hit_rec *a = (const hit_rec *)va, *b = (const hit_rec *)vb;
    int c = memcmp(a->key, b->key, 16);
    if (c)
        return c;
    if (a->rank < b->rank)
        return -1;
    if (a->rank > b->rank)
        return 1;
    if (a->mode != b->mode)
        return (int)a->mode - (int)b->mode;
    return memcmp(a->p0, b->p0, 16);
}

/* Write unique hits and report duplication.  With a correct bijective
 * enumeration a run must report zero exact duplicates; the counter stays in
 * the output so a partitioning regression cannot hide in the file. */
static uint32_t write_hit_file(hit_rec *r, uint32_t n, const char *path,
                               uint32_t *dups_out, uint32_t *multi_out)
{
    qsort(r, n, sizeof(*r), hit_cmp);
    uint32_t uniq = 0, dups = 0, multimode = 0;
    FILE *f = fopen(path, "w");
    if (!f) {
        fprintf(stderr, "cannot write %s\n", path);
        return 0;
    }
    for (uint32_t i = 0; i < n; i++) {
        if (i > 0) {
            const hit_rec *p = &r[i - 1], *q = &r[i];
            if (memcmp(p->key, q->key, 16) == 0 && p->rank == q->rank) {
                if (p->mode == q->mode && memcmp(p->p0, q->p0, 16) == 0) {
                    dups++;
                    continue;
                }
                if (p->mode != q->mode)
                    multimode++;
            }
        }
        fprintf(f, "%u ", r[i].mode);
        for (int j = 0; j < 16; j++)
            fprintf(f, "%02x", r[i].key[j]);
        fprintf(f, " %llu ", (unsigned long long)r[i].rank);
        for (int j = 0; j < 16; j++)
            fprintf(f, "%02x", r[i].p0[j]);
        fprintf(f, " %d\n", (int)r[i].score);
        uniq++;
    }
    fclose(f);
    printf("fmc hits: %u raw, %u unique, %u exact duplicates, "
           "%u same-key two-mode%s\n",
           n, uniq, dups, multimode,
           dups ? " (DUPLICATES PRESENT)" : "");
    if (dups_out)
        *dups_out = dups;
    if (multi_out)
        *multi_out = multimode;
    return uniq;
}

/* Exercise the hit writer with a known multiset: three exact duplicates and
 * one key whose other mode also hit.  Expected: 3 unique, 3 duplicates, 1
 * two-mode pair. */
static int hit_selftest(const char *path)
{
    hit_rec r[6];
    uint8_t k1[16], k2[16];
    memset(r, 0, sizeof(r));
    for (int i = 0; i < 16; i++) {
        k1[i] = (uint8_t)(0x10 + i);
        k2[i] = (uint8_t)(0x80 - i);
    }
    for (int i = 0; i < 3; i++) {           /* A mode 0, three copies */
        r[i].mode = 0;
        memcpy(r[i].key, k1, 16);
        r[i].rank = 42;
        memset(r[i].p0, 0xa1, 16);
    }
    for (int i = 3; i < 5; i++) {           /* A mode 1, two copies */
        r[i].mode = 1;
        memcpy(r[i].key, k1, 16);
        r[i].rank = 42;
        memset(r[i].p0, 0xb2, 16);
    }
    r[5].mode = 0;                          /* B, distinct */
    memcpy(r[5].key, k2, 16);
    r[5].rank = 7;
    memset(r[5].p0, 0xc3, 16);

    uint32_t dups = 0, multi = 0;
    uint32_t u = write_hit_file(r, 6, path, &dups, &multi);
    if (u != 3 || dups != 3 || multi != 1) {
        fprintf(stderr, "selftest hit dedup: unique=%u dups=%u multi=%u, "
                "want 3/3/1\n", u, dups, multi);
        return 1;
    }
    FILE *f = fopen(path, "r");
    if (!f) {
        fprintf(stderr, "selftest hit dedup: cannot reopen %s\n", path);
        return 1;
    }
    int lines = 0;
    char buf[256];
    while (fgets(buf, sizeof(buf), f))
        lines++;
    fclose(f);
    if (lines != 3) {
        fprintf(stderr, "selftest hit dedup: %d lines, want 3\n", lines);
        return 1;
    }
    printf("selftest: hit dedup OK (3 unique, 3 exact dups collapsed, "
           "1 two-mode pair)\n");
    return 0;
}

static int selftest(int dev)
{
    cudaSetDevice(dev);
    uint8_t key[16], pt[16], want[16] = {
        0x69,0xc4,0xe0,0xd8,0x6a,0x7b,0x04,0x30,
        0xd8,0xcd,0xb7,0x80,0x70,0xb4,0xc5,0x5a
    };
    for (int i = 0; i < 16; i++) { key[i] = (uint8_t)i; pt[i] = (uint8_t)(i * 0x11); }
    uint8_t *dk, *dp, *dc;
    cudaMalloc(&dk, 16); cudaMalloc(&dp, 16); cudaMalloc(&dc, 16);
    cudaMemcpy(dk, key, 16, cudaMemcpyHostToDevice);
    cudaMemcpy(dp, pt, 16, cudaMemcpyHostToDevice);
    uint8_t got[16];
    aes_test_kernel<<<1, 1>>>(dk, dp, dc);
    if (cudaDeviceSynchronize() != cudaSuccess) die("selftest byte kernel");
    cudaMemcpy(got, dc, 16, cudaMemcpyDeviceToHost);
    if (memcmp(got, want, 16) != 0) {
        fprintf(stderr, "selftest: byte AES-128 FIPS FAILED: ");
        for (int i = 0; i < 16; i++) fprintf(stderr, "%02x", got[i]);
        fprintf(stderr, "\n");
        return 1;
    }
    tt_test_kernel<<<1, 256>>>(dk, dp, dc);
    if (cudaDeviceSynchronize() != cudaSuccess) die("selftest tt kernel");
    cudaMemcpy(got, dc, 16, cudaMemcpyDeviceToHost);
    if (memcmp(got, want, 16) != 0) {
        fprintf(stderr, "selftest: T-table AES-128 FIPS FAILED: ");
        for (int i = 0; i < 16; i++) fprintf(stderr, "%02x", got[i]);
        fprintf(stderr, "\n");
        return 1;
    }
    /* Rolling schedule, zero and FF plaintexts: use the FIPS-validated byte
     * kernel as the oracle for both. */
    uint8_t zero16[16] = {0}, want_zero[16], ff16[16], want_ff[16];
    cudaMemcpy(dp, zero16, 16, cudaMemcpyHostToDevice);
    aes_test_kernel<<<1, 1>>>(dk, dp, dc);
    if (cudaDeviceSynchronize() != cudaSuccess) die("selftest zero oracle");
    cudaMemcpy(want_zero, dc, 16, cudaMemcpyDeviceToHost);
    tt_roll_test_kernel<<<1, 256>>>(dk, 0, dc);
    if (cudaDeviceSynchronize() != cudaSuccess) die("selftest roll zero kernel");
    cudaMemcpy(got, dc, 16, cudaMemcpyDeviceToHost);
    if (memcmp(got, want_zero, 16) != 0) {
        fprintf(stderr, "selftest: rolling AES zero-block FAILED: ");
        for (int i = 0; i < 16; i++) fprintf(stderr, "%02x", got[i]);
        fprintf(stderr, "\n");
        return 1;
    }
    memset(ff16, 0xff, 16);
    cudaMemcpy(dp, ff16, 16, cudaMemcpyHostToDevice);
    aes_test_kernel<<<1, 1>>>(dk, dp, dc);
    if (cudaDeviceSynchronize() != cudaSuccess) die("selftest ff oracle");
    cudaMemcpy(want_ff, dc, 16, cudaMemcpyDeviceToHost);
    tt_roll_test_kernel<<<1, 256>>>(dk, 0xffffffffu, dc);
    if (cudaDeviceSynchronize() != cudaSuccess) die("selftest roll ff kernel");
    cudaMemcpy(got, dc, 16, cudaMemcpyDeviceToHost);
    if (memcmp(got, want_ff, 16) != 0) {
        fprintf(stderr, "selftest: rolling AES FF-block FAILED: ");
        for (int i = 0; i < 16; i++) fprintf(stderr, "%02x", got[i]);
        fprintf(stderr, "\n");
        return 1;
    }
    /* Inverse cipher: decrypt the FIPS ciphertext back to the FIPS plaintext. */
    cudaMemcpy(dp, want, 16, cudaMemcpyHostToDevice);
    dec_test_kernel<<<1, 256>>>(dk, dp, dc);
    if (cudaDeviceSynchronize() != cudaSuccess) die("selftest decrypt kernel");
    cudaMemcpy(got, dc, 16, cudaMemcpyDeviceToHost);
    if (memcmp(got, pt, 16) != 0) {
        fprintf(stderr, "selftest: AES decrypt FIPS FAILED: ");
        for (int i = 0; i < 16; i++) fprintf(stderr, "%02x", got[i]);
        fprintf(stderr, "\n");
        cudaFree(dk); cudaFree(dp); cudaFree(dc);
        return 1;
    }
    /* Td-table equivalent inverse cipher must reproduce the FIPS plaintext. */
    dec_tt_test_kernel<<<1, 256>>>(dk, dp, dc);
    if (cudaDeviceSynchronize() != cudaSuccess) die("selftest Td decrypt kernel");
    cudaMemcpy(got, dc, 16, cudaMemcpyDeviceToHost);
    if (memcmp(got, pt, 16) != 0) {
        fprintf(stderr, "selftest: Td-table decrypt FIPS FAILED: ");
        for (int i = 0; i < 16; i++) fprintf(stderr, "%02x", got[i]);
        fprintf(stderr, "\n");
        cudaFree(dk); cudaFree(dp); cudaFree(dc);
        return 1;
    }
    /* And must agree with the byte-wise decrypt on unrelated keys/blocks.
     * The same keys also check fmc_both's rolling forward block and its
     * backwards-derived inverse schedule against the byte kernels. */
    uint8_t *dout = NULL;
    cudaMalloc(&dout, 32);
    for (int t = 0; t < 8; t++) {
        uint8_t kk[16], cc[16], a[16], b[16];
        uint8_t z16[16] = {0}, ce[16], cf[16], df[16];
        for (int i = 0; i < 16; i++) {
            kk[i] = (uint8_t)(t * 41 + i * 7 + 1);
            cc[i] = (uint8_t)(t * 97 + i * 13 + 5);
        }
        cudaMemcpy(dk, kk, 16, cudaMemcpyHostToDevice);
        cudaMemcpy(dp, cc, 16, cudaMemcpyHostToDevice);
        dec_test_kernel<<<1, 256>>>(dk, dp, dc);
        if (cudaDeviceSynchronize() != cudaSuccess) die("selftest decrypt kernel");
        cudaMemcpy(a, dc, 16, cudaMemcpyDeviceToHost);
        dec_tt_test_kernel<<<1, 256>>>(dk, dp, dc);
        if (cudaDeviceSynchronize() != cudaSuccess) die("selftest Td decrypt kernel");
        cudaMemcpy(b, dc, 16, cudaMemcpyDeviceToHost);
        if (memcmp(a, b, 16) != 0) {
            fprintf(stderr, "selftest: byte/Td decrypt disagree on key %d\n", t);
            cudaFree(dk); cudaFree(dp); cudaFree(dc); cudaFree(dout);
            return 1;
        }
        /* Reference AES(K, 0) from the FIPS-checked byte kernel. */
        cudaMemcpy(dp, z16, 16, cudaMemcpyHostToDevice);
        aes_test_kernel<<<1, 1>>>(dk, dp, dc);
        if (cudaDeviceSynchronize() != cudaSuccess) die("selftest zero oracle");
        cudaMemcpy(ce, dc, 16, cudaMemcpyDeviceToHost);
        cudaMemcpy(dp, cc, 16, cudaMemcpyHostToDevice);
        fmc_both_test_kernel<<<1, 256>>>(dk, dp, dout, dout + 16);
        if (cudaDeviceSynchronize() != cudaSuccess) die("selftest fmc_both");
        cudaMemcpy(cf, dout, 16, cudaMemcpyDeviceToHost);
        cudaMemcpy(df, dout + 16, 16, cudaMemcpyDeviceToHost);
        if (memcmp(cf, ce, 16) != 0 || memcmp(df, a, 16) != 0) {
            fprintf(stderr, "selftest: fmc_both mismatch on key %d\n", t);
            cudaFree(dk); cudaFree(dp); cudaFree(dc); cudaFree(dout);
            return 1;
        }
    }
    cudaFree(dout);
    cudaFree(dk); cudaFree(dp); cudaFree(dc);

    /* Lexicographic unrank and next_perm consistency, including the factorial
     * and half-range boundaries where a misordered enumeration would break. */
    uint8_t *du = NULL;
    cudaMalloc(&du, 16);
    uint64_t ranks[16] = {
        0ULL, 1ULL, 2ULL, 3ULL,
        FACT_H[15] - 1, FACT_H[15], FACT_H[15] + 1,
        FACT_H[14], TOTAL / 2 - 1, TOTAL / 2, TOTAL / 2 + 1,
        123456789ULL, 123456789ULL + 1,
        7777777777777ULL, TOTAL - 2, TOTAL - 1
    };
    for (int k = 0; k < 16; k++) {
        uint8_t gu[16], hu[16];
        unrank_test_kernel<<<1, 1>>>(du, ranks[k]);
        if (cudaDeviceSynchronize() != cudaSuccess) die("selftest unrank kernel");
        cudaMemcpy(gu, du, 16, cudaMemcpyDeviceToHost);
        host_unrank(ranks[k], hu);
        if (memcmp(gu, hu, 16) != 0) {
            fprintf(stderr, "selftest: unrank mismatch rank %llu\n",
                    (unsigned long long)ranks[k]);
            return 1;
        }
        if (ranks[k] + 1 < TOTAL) {
            uint8_t gb[16];
            unrank_test_kernel<<<1, 1>>>(du, ranks[k] + 1);
            if (cudaDeviceSynchronize() != cudaSuccess) die("selftest unrank kernel");
            cudaMemcpy(gb, du, 16, cudaMemcpyDeviceToHost);
            host_next_perm(hu, 16);
            /* Device rank r+1 must equal next_perm of the rank-r permutation. */
            if (memcmp(gb, hu, 16) != 0) {
                fprintf(stderr, "selftest: next_perm mismatch rank %llu\n",
                        (unsigned long long)ranks[k]);
                return 1;
            }
        }
    }
    cudaFree(du);

    /* Partition window: 4096 threads x 64 ranks, exactly the slicing used by
     * the search kernels.  Verify thread ranges tile the window, then check
     * first/last permutation and a digest of every rank against host_unrank. */
    {
        const int eblocks = 16, ethreads = 256;
        const int en = eblocks * ethreads;
        const uint64_t estart = 987654321ULL;
        const uint64_t ecount = (uint64_t)en * 64ULL;
        uint8_t *dfirst = NULL, *dlast = NULL;
        uint64_t *ddig = NULL;
        cudaMalloc(&dfirst, (size_t)en * 16);
        cudaMalloc(&dlast, (size_t)en * 16);
        cudaMalloc(&ddig, (size_t)en * 8);
        enum_window_kernel<<<eblocks, ethreads>>>(estart, ecount, dfirst, dlast, ddig);
        if (cudaDeviceSynchronize() != cudaSuccess) die("selftest enum window kernel");
        uint8_t *hfirst = (uint8_t *)malloc((size_t)en * 16);
        uint8_t *hlast = (uint8_t *)malloc((size_t)en * 16);
        uint64_t *hdig = (uint64_t *)malloc((size_t)en * 8);
        if (!hfirst || !hlast || !hdig) die("selftest enum window malloc");
        cudaMemcpy(hfirst, dfirst, (size_t)en * 16, cudaMemcpyDeviceToHost);
        cudaMemcpy(hlast, dlast, (size_t)en * 16, cudaMemcpyDeviceToHost);
        cudaMemcpy(hdig, ddig, (size_t)en * 8, cudaMemcpyDeviceToHost);
        cudaFree(dfirst); cudaFree(dlast); cudaFree(ddig);
        uint64_t chunk = ecount / (uint64_t)en;
        uint64_t prev_end = estart;
        int bad = 0;
        for (int t = 0; t < en; t++) {
            uint64_t s = estart + (uint64_t)t * chunk;
            uint64_t n = (t == en - 1) ? (ecount - (uint64_t)t * chunk) : chunk;
            if (s != prev_end) {
                printf("selftest: partition gap/overlap at thread %d\n", t);
                bad = 1;
                break;
            }
            prev_end = s + n;
            uint8_t wf[16], wl[16], p[16];
            host_unrank(s, wf);
            host_unrank(s + n - 1, wl);
            if (memcmp(hfirst + (size_t)t * 16, wf, 16) != 0 ||
                memcmp(hlast + (size_t)t * 16, wl, 16) != 0) {
                printf("selftest: window first/last mismatch at thread %d\n", t);
                bad = 1;
                break;
            }
            uint64_t h = 1469598103934665603ULL;
            for (uint64_t i = 0; i < n; i++) {
                host_unrank(s + i, p);
                for (int j = 0; j < 16; j++)
                    h = (h ^ p[j]) * 1099511628211ULL;
            }
            if (hdig[t] != h) {
                printf("selftest: window digest mismatch at thread %d\n", t);
                bad = 1;
                break;
            }
        }
        if (!bad && prev_end != estart + ecount) {
            printf("selftest: partition does not cover the window\n");
            bad = 1;
        }
        free(hfirst); free(hlast); free(hdig);
        if (bad)
            return 1;
        printf("selftest: partition window OK (%llu ranks, %d threads, "
               "no gaps/overlaps)\n", (unsigned long long)ecount, en);
    }
    printf("selftest: byte + T-table + rolling + byte/Td inverse AES; "
           "lexicographic unrank/next_perm OK on device %d\n", dev);
    return 0;
}

/* Load the parcel log-probability table and derive default thresholds from its
 * moments: stage 1 at 3.8 sigma of the 8-parcel (one block) random
 * distribution, stage 2 at 9 sigma of the nblocks-parcel random distribution.
 * T is in half-bit units (the table stores round(2*log2 p)).  The stage-2
 * threshold is conditional on stage 1 having passed, which shares block 0 and
 * lifts the tail; the 9-sigma choice gives ~0.5 false records per hypothesis
 * over 16! (exact DP) at 99.92% clean-code recall. */
static void load_logp(const char *path, int *t1io, int *t2io, int nblocks)
{
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "cannot open logp table %s\n", path);
        exit(2);
    }
    int8_t *tab = (int8_t *)malloc(65536);
    if (!tab || fread(tab, 1, 65536, f) != 65536) {
        fclose(f);
        fprintf(stderr, "read logp table %s (need 65536 bytes)\n", path);
        exit(2);
    }
    fclose(f);
    cudaMemcpyToSymbol(g_logp, tab, 65536);
    double mu = 0.0, var = 0.0;
    for (int i = 0; i < 65536; i++)
        mu += (double)tab[i] / 65536.0;
    for (int i = 0; i < 65536; i++) {
        double d = (double)tab[i] - mu;
        var += d * d / 65536.0;
    }
    free(tab);
    int nparcels = 8 * nblocks;
    if (*t1io <= -1000000)
        *t1io = host_round(mu * 8.0 + 3.8 * host_sqrt(var * 8.0));
    if (*t2io <= -1000000)
        *t2io = host_round(mu * (double)nparcels +
                           9.0 * host_sqrt(var * (double)nparcels));
    printf("logp %s: mean %.2f Q sd %.2f Q, blocks=%d, t1=%d t2=%d\n",
           path, mu, host_sqrt(var), nblocks, *t1io, *t2io);
}

/* Short benchmark: keep the GPU continuously busy so clocks stay boosted,
 * warm up for 60% of the budget, then measure the rest.  A measurement is a
 * few seconds instead of a minute. */
static int bench_mode(int dev, int kind, double secs, int blocks, int threads,
                      int t1, int t2, int nblocks)
{
    const double warm = secs * 0.6;
    const uint64_t csz = 1ULL << 27;   /* 134M keys per launch */
    const uint64_t span = 1ULL << 30;
    uint64_t cur = 0, keys = 0;
    double t0 = wall_now(), tm = 0.0;
    int launches = 0;
    for (;;) {
        double now = wall_now();
        if (now - t0 >= secs)
            break;
        if (tm == 0.0 && now - t0 >= warm) {
            tm = now;
            keys = 0;
        }
        if (kind == 0)
            search_kernel_tt<<<blocks, threads>>>(cur % span, csz, 0);
        else if (kind == 1)
            fmc_oracle_kernel<<<blocks, threads>>>(cur % span, csz);
        else if (kind == 3)
            fmc_oracle_kernel_rf16<<<blocks, threads>>>(cur % span, csz);
        else if (kind == 4)
            fmc_riscv_kernel<<<blocks, threads>>>(cur % span, csz,
                                                  t1, t2, nblocks);
        else if (kind == 5)
            fmc_riscv_kernel_rf16<<<blocks, threads>>>(cur % span, csz,
                                                       t1, t2, nblocks);
        else
            fmc_oracle_kernel_byte<<<blocks, threads>>>(cur % span, csz);
        if (cudaDeviceSynchronize() != cudaSuccess)
            die("bench kernel");
        if (tm != 0.0)
            keys += csz;
        cur += csz;
        launches++;
    }
    double end = wall_now();
    if (tm == 0.0) {
        fprintf(stderr, "bench: no measurement window\n");
        return 2;
    }
    double m = end - tm;
    printf("bench %s: warm %.1fs + measured %.2fs, %d launches, %llu keys, "
           "%.1f M/s\n",
           kind == 0 ? "zero" : (kind == 1 ? "fmc-td"
                              : (kind == 3 ? "fmc-rf16"
                                           : (kind == 4 ? "fmc-riscv"
                                                        : (kind == 5 ? "fmc-riscv-rf"
                                                                     : "fmc-byte")))),
           tm - t0, m, launches, (unsigned long long)keys,
           m > 0 ? (double)keys / m / 1e6 : 0.0);
    return 0;
}

int main(int argc, char **argv)
{
    int dev = 0, chunks = 256, blocks = 4096, threads = 256;
    uint64_t start = 0, count = TOTAL, limit = 0;
    int do_selftest = 0, ff = 0, rk = 0, do_hit_selftest = 0;
    int fmc_byte = 0, fmc_rf = 0, fmc_riscv = 0, fmc_riscv_rf = 0;
    int t1 = -1000000, t2 = -1000000, riscv_blocks = 8;
    double bench_secs = 0.0;
    const char *fmcpath = NULL;
    const char *logppath = "riscv_logp_q.bin";
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--selftest")) do_selftest = 1;
        else if (!strcmp(argv[i], "--hit-selftest")) do_hit_selftest = 1;
        else if (!strcmp(argv[i], "--fmc-byte")) fmc_byte = 1;
        else if (!strcmp(argv[i], "--fmc-rf")) fmc_rf = 1;
        else if (!strcmp(argv[i], "--fmc-riscv")) fmc_riscv = 1;
        else if (!strcmp(argv[i], "--fmc-riscv-rf")) { fmc_riscv = 1; fmc_riscv_rf = 1; }
        else if (!strcmp(argv[i], "--logp") && i + 1 < argc) logppath = argv[++i];
        else if (!strcmp(argv[i], "--t1") && i + 1 < argc) t1 = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--t2") && i + 1 < argc) t2 = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--riscv-blocks") && i + 1 < argc) riscv_blocks = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--bench") && i + 1 < argc) bench_secs = atof(argv[++i]);
        else if (!strcmp(argv[i], "--ff")) ff = 1;
        else if (!strcmp(argv[i], "--rk")) rk = 1;
        else if (!strcmp(argv[i], "--fmc") && i + 1 < argc) fmcpath = argv[++i];
        else if (!strcmp(argv[i], "--device") && i + 1 < argc) dev = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--chunks") && i + 1 < argc) chunks = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--blocks") && i + 1 < argc) blocks = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--threads") && i + 1 < argc) threads = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--start") && i + 1 < argc) start = strtoull(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--count") && i + 1 < argc) count = strtoull(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--limit") && i + 1 < argc) limit = strtoull(argv[++i], NULL, 0);
        else { fprintf(stderr, "unknown arg %s\n", argv[i]); return 2; }
    }
    if (do_selftest)
        return selftest(dev);
    if (do_hit_selftest)
        return hit_selftest("key37_hits_selftest.txt");
    if (start >= TOTAL) { fprintf(stderr, "start beyond 16!\n"); return 2; }
    if (count > TOTAL - start) count = TOTAL - start;
    if (limit && limit < count) count = limit;
    if (chunks < 1) chunks = 1;

    cudaSetDevice(dev);
    cudaDeviceProp prop;
    cudaGetDeviceProperties(&prop, dev);
    uint32_t p = ff ? 0xffffffffu : 0u;
    if (fmc_riscv && !fmcpath) {
        fprintf(stderr, "--fmc-riscv needs --fmc <container>\n");
        return 2;
    }
    if (fmc_riscv && (riscv_blocks < 1 || riscv_blocks > 64)) {
        fprintf(stderr, "--riscv-blocks must be 1..64\n");
        return 2;
    }
    if (fmcpath) {
        FILE *f = fopen(fmcpath, "rb");
        if (!f) { fprintf(stderr, "cannot open %s\n", fmcpath); return 2; }
        fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
        if (sz < 0x58) { fclose(f); fprintf(stderr, "short FMC\n"); return 2; }
        uint8_t *d = (uint8_t *)malloc((size_t)sz);
        if (!d || fread(d, 1, (size_t)sz, f) != (size_t)sz) {
            fclose(f); fprintf(stderr, "read FMC\n"); return 2;
        }
        fclose(f);
        if (memcmp(d, "\x03\x04\x48\x00", 4) != 0) {
            fprintf(stderr, "not an FMC container\n"); return 2;
        }
        cudaMemcpyToSymbol(C0_D, d + 0x48, 16);
        if (fmc_riscv) {
            if ((long)(0x48 + 16 * riscv_blocks) > sz) {
                fprintf(stderr, "container too short for %d blocks\n", riscv_blocks);
                return 2;
            }
            cudaMemcpyToSymbol(CBLK_D, d + 0x48, (size_t)16 * riscv_blocks);
            cudaMemcpyToSymbol(HIV_D, d, 16);
            load_logp(logppath, &t1, &t2, riscv_blocks);
            printf("riscv hypotheses: ECB, CBC(0), CBC(hdr), CTR(start 0), "
                   "CTR(start 1); hdrIV=");
            for (int i = 0; i < 16; i++) printf("%02x", d[i]);
            printf("\n");
        }
        printf("fmc %s c0=", fmcpath);
        for (int i = 0; i < 16; i++) printf("%02x", d[0x48 + i]);
        printf("\n");
        free(d);
        int z = 0;
        cudaMemcpyToSymbol(g_hitcount, &z, sizeof(uint32_t));
    }
    printf("device %d: %s sm_%d%d  start=%llu count=%llu chunks=%d blocks=%d threads=%d plain=%s mode=%s\n",
           dev, prop.name, prop.major, prop.minor,
           (unsigned long long)start, (unsigned long long)count, chunks, blocks, threads,
           ff ? "ff" : "zero",
           fmcpath ? (fmc_riscv ? (fmc_riscv_rf ? "fmc-riscv-rf"
                                                : "fmc-riscv")
                              : (fmc_byte ? "fmc-byte"
                                          : (fmc_rf ? "fmc-rf16" : "fmc-td")))
                   : (rk ? "rk" : "iv"));
    fflush(stdout);

    int zero = 0;
    cudaMemcpyToSymbol(g_found, &zero, sizeof(int));
    if (bench_secs > 0.0) {
        if (fmcpath) {
            uint32_t z = 0;
            cudaMemcpyToSymbol(g_hitcount, &z, sizeof(uint32_t));
        }
        return bench_mode(dev,
                          fmcpath ? (fmc_riscv ? (fmc_riscv_rf ? 5 : 4)
                                              : (fmc_byte ? 2
                                                          : (fmc_rf ? 3 : 1)))
                                   : 0,
                          bench_secs, blocks, threads, t1, t2, riscv_blocks);
    }
    double t0 = wall_now();
    uint64_t done = 0;
    for (int c = 0; c < chunks; c++) {
        uint64_t cs = start + (count / (uint64_t)chunks) * (uint64_t)c;
        uint64_t cn = (c == chunks - 1) ? (count - (count / (uint64_t)chunks) * (uint64_t)c)
                                        : (count / (uint64_t)chunks);
        if (!cn) continue;
        if (fmcpath && fmc_riscv) {
            if (fmc_riscv_rf)
                fmc_riscv_kernel_rf16<<<blocks, threads>>>(cs, cn, t1, t2,
                                                           riscv_blocks);
            else
                fmc_riscv_kernel<<<blocks, threads>>>(cs, cn, t1, t2,
                                                      riscv_blocks);
        } else if (fmcpath && fmc_byte)
            fmc_oracle_kernel_byte<<<blocks, threads>>>(cs, cn);
        else if (fmcpath && fmc_rf)
            fmc_oracle_kernel_rf16<<<blocks, threads>>>(cs, cn);
        else if (fmcpath)
            fmc_oracle_kernel<<<blocks, threads>>>(cs, cn);
        else if (rk)
            search_kernel_rk<<<blocks, threads>>>(cs, cn, p);
        else
            search_kernel_tt<<<blocks, threads>>>(cs, cn, p);
        if (cudaDeviceSynchronize() != cudaSuccess) die("search kernel");
        int found = 0;
        cudaMemcpyFromSymbol(&found, g_found, sizeof(int));
        done += cn;
        double now = wall_now();
        printf("  chunk %d/%d: %llu/%llu (%.1f%%) %.1fs %.1f M/s\n",
               c + 1, chunks, (unsigned long long)done, (unsigned long long)count,
               100.0 * (double)done / (double)count, now - t0,
               now > t0 ? (double)done / (now - t0) / 1e6 : 0.0);
        fflush(stdout);
        if (found)
            break;
        if (fmcpath) {
            uint32_t h = 0;
            cudaMemcpyFromSymbol(&h, g_hitcount, sizeof(uint32_t));
            printf("  fmc hits=%u\n", h);
        }
    }

    if (fmcpath) {
        uint32_t hits = 0;
        cudaMemcpyFromSymbol(&hits, g_hitcount, sizeof(uint32_t));
        uint32_t n = hits > HITMAX ? HITMAX : hits;
        uint8_t *keys = (uint8_t *)malloc((size_t)n * 16 + 1);
        uint64_t *ranks = (uint64_t *)malloc((size_t)n * 8 + 8);
        uint8_t *p0 = (uint8_t *)malloc((size_t)n * 16 + 1);
        uint8_t *modes = (uint8_t *)malloc((size_t)n + 1);
        int32_t *scores = (int32_t *)malloc((size_t)n * 4 + 4);
        hit_rec *recs = (hit_rec *)malloc(((size_t)n + 1) * sizeof(hit_rec));
        if (!keys || !ranks || !p0 || !modes || !scores || !recs) die("hit alloc");
        if (n) {
            cudaMemcpyFromSymbol(keys, g_hitkey, (size_t)n * 16);
            cudaMemcpyFromSymbol(ranks, g_hitrank, (size_t)n * 8);
            cudaMemcpyFromSymbol(p0, g_hitp0, (size_t)n * 16);
            cudaMemcpyFromSymbol(modes, g_hitmode, (size_t)n);
            cudaMemcpyFromSymbol(scores, g_hitscore, (size_t)n * 4);
        }
        for (uint32_t i = 0; i < n; i++) {
            recs[i].mode = modes[i];
            memcpy(recs[i].key, keys + (size_t)i * 16, 16);
            memcpy(recs[i].p0, p0 + (size_t)i * 16, 16);
            recs[i].rank = ranks[i];
            recs[i].score = scores[i];
        }
        write_hit_file(recs, n, "fmc_hits.txt", NULL, NULL);
        free(keys); free(ranks); free(p0); free(modes); free(scores); free(recs);
        printf("fmc oracle: %u hits (cap %u), wrote fmc_hits.txt\n", hits, HITMAX);
        return 0;
    }

    int found = 0;
    cudaMemcpyFromSymbol(&found, g_found, sizeof(int));
    if (found) {
        uint64_t rank = 0;
        uint8_t key[16];
        cudaMemcpyFromSymbol(&rank, g_rank, sizeof(uint64_t));
        cudaMemcpyFromSymbol(key, g_key, 16);
        FILE *f = fopen("key37_found.bin", "wb");
        if (f) { fwrite(key, 1, 16, f); fclose(f); }
        printf("FOUND rank=%llu key=", (unsigned long long)rank);
        for (int i = 0; i < 16; i++) printf("%02x", key[i]);
        printf("\nwrote key37_found.bin\n");
        return 0;
    }
    printf("not found in range (%.1fs)\n", wall_now() - t0);
    return 1;
}

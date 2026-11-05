/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Window/candidate scan for the corpus key search: every byte-offset
 * 16-byte window of a set of files (or a materialized candidate list) is
 * tried as an AES-128 key against the first blocks of an FMC code
 * component, scored with the RISC-V parcel log-probability table built by
 * build_riscv_logp.py.  Four scoring paths: ECB (blocks 0..4), CBC with
 * unknown IV (blocks 1..4, IV-insensitive), CTR start 0 and start 1.
 */
/* C22 Phase 2: window scan.
 *
 * Every 16-byte window (byte stride) of a set of shipped artifacts is tried
 * as an AES-128 key against the first blocks of an FMC code component,
 * scored with the 16-bit parcel log-probability table from fmc-tools.
 * Four scoring paths: ECB (blocks 0..4), CBC with unknown IV (blocks 1..4,
 * IV-insensitive), CTR start 0 and CTR start 1 (blocks 0..4).
 *
 * Build: gcc -O3 -march=native -maes -msse4.1 -fopenmp -o window_scan window_scan.c
 * Run:   ./window_scan <logp.bin> <target.bin> <window-file> [<window-file>...]
 */
#include <emmintrin.h>
#include <smmintrin.h>
#include <wmmintrin.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <omp.h>

#define NPATH 4
#define TOPK 8

static signed char logp[65536];

struct top {
    int score;
    int file;
    long off;
};

struct ctx {
    __m128i rk[11];   /* encryption round keys   */
    __m128i dk[11];   /* decryption round keys   */
};

static const unsigned char RCON[10] = {0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36};

static inline void sched(struct ctx *c, const unsigned char *key)
{
    __m128i t = _mm_loadu_si128((const __m128i *)key);
    c->rk[0] = t;
    for (int r = 1; r <= 10; r++) {
        __m128i a = _mm_aeskeygenassist_si128(t, RCON[r - 1]);
        a = _mm_shuffle_epi32(a, 0xFF);
        t = _mm_xor_si128(t, _mm_slli_si128(t, 4));
        t = _mm_xor_si128(t, _mm_slli_si128(t, 8));
        t = _mm_xor_si128(t, a);
        c->rk[r] = t;
    }
    c->dk[0] = c->rk[10];
    for (int r = 1; r <= 9; r++)
        c->dk[r] = _mm_aesimc_si128(c->rk[10 - r]);
    c->dk[10] = c->rk[0];
}

static inline __m128i enc(const struct ctx *c, __m128i x)
{
    x = _mm_xor_si128(x, c->rk[0]);
    for (int r = 1; r <= 9; r++)
        x = _mm_aesenc_si128(x, c->rk[r]);
    return _mm_aesenclast_si128(x, c->rk[10]);
}

static inline __m128i dec(const struct ctx *c, __m128i x)
{
    x = _mm_xor_si128(x, c->dk[0]);
    for (int r = 1; r <= 9; r++)
        x = _mm_aesdec_si128(x, c->dk[r]);
    return _mm_aesdeclast_si128(x, c->dk[10]);
}

static inline int score_block(__m128i x)
{
    unsigned short u[8];
    _mm_storeu_si128((__m128i *)u, x);
    int s = 0;
    for (int i = 0; i < 8; i++)
        s += logp[u[i]];
    return s;
}

struct accum {
    struct top t[NPATH][TOPK];
    long cnt;
    long long sum[NPATH];
    int max[NPATH];
};

static void offer(struct accum *a, int p, int s, int f, long o)
{
    if (s > a->t[p][TOPK - 1].score) {
        int i = TOPK - 1;
        while (i > 0 && a->t[p][i - 1].score < s) {
            a->t[p][i] = a->t[p][i - 1];
            i--;
        }
        a->t[p][i].score = s;
        a->t[p][i].file = f;
        a->t[p][i].off = o;
    }
    if (s > a->max[p])
        a->max[p] = s;
    a->sum[p] += s;
    a->cnt++;
}

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s logp.bin target.bin window-file...\n", argv[0]);
        return 1;
    }
    FILE *f = fopen(argv[1], "rb");
    if (!f || fread(logp, 1, 65536, f) != 65536) {
        fprintf(stderr, "bad logp table\n");
        return 1;
    }
    fclose(f);

    /* selftest: FIPS-197 AES-128 */
    {
        unsigned char k[16] = {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15};
        unsigned char p[16] = {0x00,0x11,0x22,0x33,0x44,0x55,0x66,0x77,
                               0x88,0x99,0xaa,0xbb,0xcc,0xdd,0xee,0xff};
        unsigned char want[16] = {0x69,0xc4,0xe0,0xd8,0x6a,0x7b,0x04,0x30,
                                  0xd8,0xcd,0xb7,0x80,0x70,0xb4,0xc5,0x5a};
        struct ctx c;
        sched(&c, k);
        __m128i x = enc(&c, _mm_loadu_si128((const __m128i *)p));
        __m128i y = dec(&c, x);
        unsigned char got[16], back[16];
        _mm_storeu_si128((__m128i *)got, x);
        _mm_storeu_si128((__m128i *)back, y);
        if (memcmp(got, want, 16) != 0 || memcmp(back, p, 16) != 0) {
            fprintf(stderr, "selftest FAILED\n");
            return 1;
        }
        printf("selftest ok\n");
    }

    unsigned char *tgt = NULL;
    long tlen = 0;
    f = fopen(argv[2], "rb");
    if (!f) { fprintf(stderr, "bad target\n"); return 1; }
    fseek(f, 0, SEEK_END); tlen = ftell(f); fseek(f, 0, SEEK_SET);
    tgt = malloc(tlen);
    if (fread(tgt, 1, tlen, f) != (size_t)tlen) { fprintf(stderr, "target read\n"); return 1; }
    fclose(f);
    if (tlen < 6 * 16) { fprintf(stderr, "target too short\n"); return 1; }

    int nf = argc - 3;
    unsigned char **wd = malloc(nf * sizeof(void *));
    long *wlen = malloc(nf * sizeof(long));
    long long total = 0;
    for (int i = 0; i < nf; i++) {
        f = fopen(argv[3 + i], "rb");
        if (!f) { fprintf(stderr, "cannot open %s\n", argv[3 + i]); return 1; }
        fseek(f, 0, SEEK_END); wlen[i] = ftell(f); fseek(f, 0, SEEK_SET);
        wd[i] = malloc(wlen[i]);
        if (fread(wd[i], 1, wlen[i], f) != (size_t)wlen[i]) { fprintf(stderr, "read %s\n", argv[3 + i]); return 1; }
        fclose(f);
        total += wlen[i] - 15;
        printf("window file %d: %s (%ld B)\n", i, argv[3 + i], wlen[i]);
    }
    printf("target %s: %ld B; windows: %lld\n", argv[2], tlen, total);

    __m128i C[6];
    for (int i = 0; i < 6; i++)
        C[i] = _mm_loadu_si128((const __m128i *)(tgt + 16 * i));

    struct accum *acc = calloc(omp_get_max_threads(), sizeof(struct accum));
    for (int th = 0; th < omp_get_max_threads(); th++)
        for (int p = 0; p < NPATH; p++)
            for (int i = 0; i < TOPK; i++)
                acc[th].t[p][i].score = -100000;

#pragma omp parallel for schedule(static)
    for (int fi = 0; fi < nf; fi++) {
        int tid = omp_get_thread_num();
        struct accum *a = &acc[tid];
        struct ctx c;
        for (long o = 0; o + 16 <= wlen[fi]; o++) {
            sched(&c, wd[fi] + o);
            __m128i D[6];
            int s;
            for (int i = 0; i < 6; i++)
                D[i] = dec(&c, C[i]);
            /* ECB: blocks 0..4 */
            s = 0;
            for (int i = 0; i < 5; i++)
                s += score_block(D[i]);
            offer(a, 0, s, fi, o);
            /* CBC any IV: blocks 1..4 */
            s = 0;
            for (int i = 1; i < 5; i++)
                s += score_block(_mm_xor_si128(D[i], C[i - 1]));
            offer(a, 1, s, fi, o);
            /* CTR start 0 and 1: keystream E(j), P_i = E(j) ^ C_i */
            unsigned char ctr[16];
            __m128i K[7];
            for (int j = 0; j < 7; j++) {
                memset(ctr, 0, 16);
                for (int b = 0; b < 16; b++)   /* big-endian 128-bit j */
                    ctr[15 - b] = (unsigned char)((unsigned long long)j >> (8 * (b < 8 ? b : 7)) & 0);
                /* store j big-endian */
                unsigned long long jj = (unsigned long long)j;
                ctr[8] = (unsigned char)(jj >> 56); ctr[9] = (unsigned char)(jj >> 48);
                ctr[10] = (unsigned char)(jj >> 40); ctr[11] = (unsigned char)(jj >> 32);
                ctr[12] = (unsigned char)(jj >> 24); ctr[13] = (unsigned char)(jj >> 16);
                ctr[14] = (unsigned char)(jj >> 8); ctr[15] = (unsigned char)jj;
                K[j] = enc(&c, _mm_loadu_si128((const __m128i *)ctr));
            }
            int s0 = 0, s1 = 0;
            for (int i = 0; i < 5; i++) {
                s0 += score_block(_mm_xor_si128(K[i], C[i]));
                s1 += score_block(_mm_xor_si128(K[i + 1], C[i]));
            }
            offer(a, 2, s0, fi, o);
            offer(a, 3, s1, fi, o);
        }
    }

    const char *names[NPATH] = {"ecb b0..4", "cbc-anyIV b1..4", "ctr0 b0..4", "ctr1 b0..4"};
    struct accum m;
    memset(&m, 0, sizeof(m));
    for (int p = 0; p < NPATH; p++)
        for (int i = 0; i < TOPK; i++)
            m.t[p][i].score = -100000;
    int nt = omp_get_max_threads();
    for (int th = 0; th < nt; th++) {
        m.cnt += acc[th].cnt;
        for (int p = 0; p < NPATH; p++) {
            m.sum[p] += acc[th].sum[p];
            if (acc[th].max[p] > m.max[p])
                m.max[p] = acc[th].max[p];
            for (int i = 0; i < TOPK; i++)
                if (acc[th].t[p][i].score > -100000)
                    offer(&m, p, acc[th].t[p][i].score,
                          acc[th].t[p][i].file, acc[th].t[p][i].off);
        }
    }
    for (int p = 0; p < NPATH; p++) {
        printf("\n[%s] mean %.1f max %d\n", names[p],
               m.cnt ? (double)m.sum[p] / m.cnt : 0.0, m.max[p]);
        for (int i = 0; i < TOPK; i++)
            if (m.t[p][i].score > -100000)
                printf("  %5d  %s +%ld\n", m.t[p][i].score,
                       argv[3 + m.t[p][i].file], m.t[p][i].off);
    }
    return 0;
}

// SPDX-License-Identifier: GPL-2.0-only
//
// key37_factoradic.c - offline search for NVIDIA's debug test key.
//
// Hypothesis (FACEB13D / cmp170hx): the debug Falcon booter key is a
// permutation of the 16 bytes of the MD5 initialization vector, used as an
// AES-128 key.  The public oracle is
//
//     AES-128-ECB(K, 00*16) == 71 7d 14 94 ea ca 31 7f
//                               f1 06 19 52 58 b3 83 77
//
// (The gist calls the plaintext FF*16; the Ada decoder's independent check
// shows the correct control is the all-zero block.  Encrypting FF*16 instead
// gives fd7e5b57..., so zero is used here.)
//
// Search: all 16! = 20,922,789,888,000 permutations, lexicographic order,
// one range per OpenMP thread.  AES-128 key schedule + one block per candidate
// with AES-NI.  No GPU, no firmware, no device access.
//
// Build:
//   gcc -O3 -march=native -maes -msse4.1 -fopenmp \
//       -o key37_factoradic key37_factoradic.c
//
// Usage:
//   ./key37_factoradic --selftest
//   ./key37_factoradic --threads 32                 # full search
//   ./key37_factoradic --threads 32 --limit 1000000000   # rate test
//   ./key37_factoradic --start N --count M          # one shard
//
// On a match it writes key37_found.bin (16 raw bytes) in the current
// directory and prints the key and rank.  Keep the key and any decoded
// firmware local; do not redistribute NVIDIA firmware.

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <omp.h>
#include <wmmintrin.h>
#include <smmintrin.h>

#define TOTAL 20922789888000ULL  /* 16! */

static const uint8_t IV_BYTES[16] = {
    0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
    0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10
};
/* The same 16 values, sorted ascending, for lexicographic unranking. */
static const uint8_t POOL[16] = {
    0x01, 0x10, 0x23, 0x32, 0x45, 0x54, 0x67, 0x76,
    0x89, 0x98, 0xab, 0xba, 0xcd, 0xdc, 0xef, 0xfe
};
static const uint8_t KAT[16] = {
    0x71, 0x7d, 0x14, 0x94, 0xea, 0xca, 0x31, 0x7f,
    0xf1, 0x06, 0x19, 0x52, 0x58, 0xb3, 0x83, 0x77
};

static volatile int found = 0;
static volatile uint64_t found_rank = 0;
static uint8_t found_key[16];

static inline __m128i aes128_expand(__m128i key, __m128i keygened)
{
    keygened = _mm_shuffle_epi32(keygened, _MM_SHUFFLE(3, 3, 3, 3));
    key = _mm_xor_si128(key, _mm_slli_si128(key, 4));
    key = _mm_xor_si128(key, _mm_slli_si128(key, 4));
    key = _mm_xor_si128(key, _mm_slli_si128(key, 4));
    return _mm_xor_si128(key, keygened);
}

static inline __m128i aes128_encrypt(__m128i key, __m128i block)
{
    __m128i k0 = key;
    __m128i k1 = aes128_expand(k0, _mm_aeskeygenassist_si128(k0, 0x01));
    __m128i k2 = aes128_expand(k1, _mm_aeskeygenassist_si128(k1, 0x02));
    __m128i k3 = aes128_expand(k2, _mm_aeskeygenassist_si128(k2, 0x04));
    __m128i k4 = aes128_expand(k3, _mm_aeskeygenassist_si128(k3, 0x08));
    __m128i k5 = aes128_expand(k4, _mm_aeskeygenassist_si128(k4, 0x10));
    __m128i k6 = aes128_expand(k5, _mm_aeskeygenassist_si128(k5, 0x20));
    __m128i k7 = aes128_expand(k6, _mm_aeskeygenassist_si128(k6, 0x40));
    __m128i k8 = aes128_expand(k7, _mm_aeskeygenassist_si128(k7, 0x80));
    __m128i k9 = aes128_expand(k8, _mm_aeskeygenassist_si128(k8, 0x1b));
    __m128i k10 = aes128_expand(k9, _mm_aeskeygenassist_si128(k9, 0x36));

    block = _mm_xor_si128(block, k0);
    block = _mm_aesenc_si128(block, k1);
    block = _mm_aesenc_si128(block, k2);
    block = _mm_aesenc_si128(block, k3);
    block = _mm_aesenc_si128(block, k4);
    block = _mm_aesenc_si128(block, k5);
    block = _mm_aesenc_si128(block, k6);
    block = _mm_aesenc_si128(block, k7);
    block = _mm_aesenc_si128(block, k8);
    block = _mm_aesenc_si128(block, k9);
    return _mm_aesenclast_si128(block, k10);
}

static const uint64_t FACT[16] = {
    1ULL, 1ULL, 2ULL, 6ULL, 24ULL, 120ULL, 720ULL, 5040ULL,
    40320ULL, 362880ULL, 3628800ULL, 39916800ULL, 479001600ULL,
    6227020800ULL, 87178291200ULL, 1307674368000ULL
};

static void unrank(uint64_t rank, uint8_t out[16])
{
    uint8_t pool[16];
    memcpy(pool, POOL, 16);
    for (int i = 0; i < 16; i++) {
        uint64_t f = FACT[15 - i];
        uint64_t idx = rank / f;
        rank %= f;
        out[i] = pool[idx];
        memmove(&pool[idx], &pool[idx + 1], (size_t)(15 - idx));
    }
}

static int next_perm(uint8_t *a, int n)
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

static int selftest(void)
{
    /* FIPS-197 C.1 AES-128 */
    uint8_t key[16] = {0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x07,
                       0x08,0x09,0x0a,0x0b,0x0c,0x0d,0x0e,0x0f};
    uint8_t pt[16]  = {0x00,0x11,0x22,0x33,0x44,0x55,0x66,0x77,
                       0x88,0x99,0xaa,0xbb,0xcc,0xdd,0xee,0xff};
    uint8_t want[16] = {0x69,0xc4,0xe0,0xd8,0x6a,0x7b,0x04,0x30,
                        0xd8,0xcd,0xb7,0x80,0x70,0xb4,0xc5,0x5a};
    uint8_t got[16];
    __m128i c = aes128_encrypt(_mm_loadu_si128((const __m128i *)key),
                               _mm_loadu_si128((const __m128i *)pt));
    _mm_storeu_si128((__m128i *)got, c);
    if (memcmp(got, want, 16) != 0) {
        fprintf(stderr, "selftest: AES-128 FIPS vector FAILED\n");
        return 1;
    }

    /* 4! enumeration: unrank each rank, walk next_perm, count unique. */
    uint8_t small[4] = {0x01, 0x10, 0x23, 0x32};
    uint8_t seen[24][4];
    int nseen = 0;
    uint8_t a[4];
    memcpy(a, small, 4);
    for (int r = 0; r < 24; r++) {
        int dup = 0;
        for (int i = 0; i < nseen; i++)
            if (memcmp(seen[i], a, 4) == 0) { dup = 1; break; }
        if (dup) { fprintf(stderr, "selftest: duplicate permutation\n"); return 1; }
        memcpy(seen[nseen++], a, 4);
        if (r != 23 && !next_perm(a, 4)) {
            fprintf(stderr, "selftest: next_perm ended early\n");
            return 1;
        }
    }
    if (nseen != 24) {
        fprintf(stderr, "selftest: 4! count %d != 24\n", nseen);
        return 1;
    }

    /* Unrank endpoints: rank 0 is the sorted pool, 16!-1 is the reverse. */
    uint8_t p[16];
    unrank(0, p);
    if (memcmp(p, POOL, 16) != 0) {
        fprintf(stderr, "selftest: unrank(0) != sorted pool\n");
        return 1;
    }
    unrank(TOTAL - 1, p);
    for (int i = 0; i < 16; i++) {
        if (p[i] != POOL[15 - i]) {
            fprintf(stderr, "selftest: unrank(16!-1) != reverse pool\n");
            return 1;
        }
    }

    /* Consecutive-rank chain: next_perm(unrank(r)) == unrank(r+1).  The sharded
     * search unranks a shard's first rank and then walks next_perm, so any
     * mismatch here would skip or repeat keys (the old colex bug).  Check the
     * factorial and half-range boundaries plus random ranks across 16!. */
    {
        const uint64_t bounds[] = {
            0, 1, 2, 3, 4,
            FACT[15] - 1, FACT[15], FACT[15] + 1,
            FACT[14] - 1, FACT[14], FACT[14] + 1,
            TOTAL / 2 - 1, TOTAL / 2, TOTAL / 2 + 1,
            TOTAL - 2, TOTAL - 1
        };
        for (size_t k = 0; k < sizeof(bounds) / sizeof(bounds[0]); k++) {
            uint64_t r = bounds[k];
            if (r + 1 >= TOTAL)
                continue;
            uint8_t a[16], b[16];
            unrank(r, a);
            unrank(r + 1, b);
            if (!next_perm(a, 16) || memcmp(a, b, 16) != 0) {
                fprintf(stderr, "selftest: chain mismatch at rank %llu\n",
                        (unsigned long long)r);
                return 1;
            }
        }
        uint64_t st = 0x243f6a8885a308d3ULL;
        for (int k = 0; k < 20000; k++) {
            st ^= st << 13; st ^= st >> 7; st ^= st << 17;
            uint64_t r = st % (TOTAL - 1);
            uint8_t a[16], b[16];
            unrank(r, a);
            unrank(r + 1, b);
            if (!next_perm(a, 16) || memcmp(a, b, 16) != 0) {
                fprintf(stderr, "selftest: chain mismatch at random rank %llu\n",
                        (unsigned long long)r);
                return 1;
            }
        }
    }

    /* Shard tiling: the OpenMP partition must cover [start, start+count) once,
     * with the last thread taking the remainder. */
    {
        const uint64_t nthr = 64, cnt = 1000000, st0 = 987654321;
        uint64_t csz = cnt / nthr;
        uint64_t prev = st0;
        for (uint64_t t = 0; t < nthr; t++) {
            uint64_t s = st0 + t * csz;
            uint64_t n = (t == nthr - 1) ? (cnt - t * csz) : csz;
            if (s != prev) {
                fprintf(stderr, "selftest: shard gap/overlap at %llu\n",
                        (unsigned long long)t);
                return 1;
            }
            prev = s + n;
        }
        if (prev != st0 + cnt) {
            fprintf(stderr, "selftest: shards do not cover the range\n");
            return 1;
        }
    }

    printf("selftest: AES-128 FIPS OK; 4! enumeration OK (24 unique); "
           "unrank endpoints OK; rank chain OK (boundaries + 20000 random); "
           "shard tiling OK\n");
    return 0;
}

int main(int argc, char **argv)
{
    int threads = omp_get_max_threads();
    uint64_t start = 0, count = TOTAL;
    uint64_t limit = 0;
    int do_selftest = 0;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--selftest")) do_selftest = 1;
        else if (!strcmp(argv[i], "--threads") && i + 1 < argc) threads = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--start") && i + 1 < argc) start = strtoull(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--count") && i + 1 < argc) count = strtoull(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--limit") && i + 1 < argc) limit = strtoull(argv[++i], NULL, 0);
        else { fprintf(stderr, "unknown arg %s\n", argv[i]); return 2; }
    }
    if (do_selftest)
        return selftest();
    if (threads < 1) threads = 1;
    if (threads > 256) threads = 256;
    if (start >= TOTAL) { fprintf(stderr, "start beyond 16!\n"); return 2; }
    if (count > TOTAL - start) count = TOTAL - start;
    if (limit && limit < count) count = limit;

    printf("key37 search: start=%llu count=%llu threads=%d total=16!=%llu\n",
           (unsigned long long)start, (unsigned long long)count, threads,
           (unsigned long long)TOTAL);
    fflush(stdout);

    double t0 = omp_get_wtime();
    uint64_t chunk = count / (uint64_t)threads;
    if (!chunk) chunk = 1;

    #pragma omp parallel num_threads(threads)
    {
        int tid = omp_get_thread_num();
        uint64_t s = start + (uint64_t)tid * chunk;
        uint64_t n = (tid == threads - 1) ? (count - (uint64_t)tid * chunk) : chunk;
        if (s >= start + count) n = 0;
        uint8_t perm[16];
        unrank(s, perm);
        uint64_t local = 0;
        double lt = omp_get_wtime();
        while (local < n && !found) {
            __m128i c = aes128_encrypt(_mm_loadu_si128((const __m128i *)perm),
                                       _mm_setzero_si128());
            if (_mm_movemask_epi8(_mm_cmpeq_epi8(
                    c, _mm_loadu_si128((const __m128i *)KAT))) == 0xffff) {
                #pragma omp critical
                {
                    if (!found) {
                        found = 1;
                        found_rank = s + local;
                        memcpy(found_key, perm, 16);
                    }
                }
            }
            local++;
            if ((local & 0xfffff) == 0 && found)
                break;
            if (!next_perm(perm, 16))
                break;
        }
        double dt = omp_get_wtime() - lt;
        fprintf(stderr, "thread %2d: %llu/%llu in %.1fs (%.2f M/s)\n",
                tid, (unsigned long long)local, (unsigned long long)n, dt,
                dt > 0 ? (double)local / dt / 1e6 : 0.0);
    }

    double dt = omp_get_wtime() - t0;
    if (found) {
        FILE *f = fopen("key37_found.bin", "wb");
        if (f) { fwrite(found_key, 1, 16, f); fclose(f); }
        printf("FOUND rank=%llu key=", (unsigned long long)found_rank);
        for (int i = 0; i < 16; i++) printf("%02x", found_key[i]);
        printf("\n");
        printf("wrote key37_found.bin (16 bytes) in %s\n", "the current directory");
        return 0;
    }
    printf("not found in range; %.1fs (%.2f M/s)\n", dt,
           dt > 0 ? (double)count / dt / 1e6 : 0.0);
    return 1;
}

// A malloc interposer for attributing allocations per request.
//
// `sample` attributes CPU time, which cannot distinguish "allocates a lot" from "does arithmetic a lot".
// This counts the allocations themselves. Counts are process-wide totals printed at exit; the harness is
// run once per scenario with a fixed request count, and the *difference* between two scenarios divided by
// that count is the per-request allocation each one adds.
//
// dyld does not interpose calls made from within the interposing image itself, so calling `malloc` here
// reaches the real one rather than recursing.
#include <stdio.h>
#include <stdlib.h>
#include <stdatomic.h>

static atomic_ullong calls = 0;
static atomic_ullong bytes = 0;

static void *counted_malloc(size_t size) {
    atomic_fetch_add_explicit(&calls, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&bytes, size, memory_order_relaxed);
    return malloc(size);
}

static void *counted_calloc(size_t count, size_t size) {
    atomic_fetch_add_explicit(&calls, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&bytes, count * size, memory_order_relaxed);
    return calloc(count, size);
}

static void *counted_realloc(void *pointer, size_t size) {
    atomic_fetch_add_explicit(&calls, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&bytes, size, memory_order_relaxed);
    return realloc(pointer, size);
}

__attribute__((constructor)) static void announce(void) {
    fprintf(stderr, "ALLOCOUNT loaded\n");
}

__attribute__((destructor)) static void report(void) {
    fprintf(stderr, "ALLOCATIONS %llu calls %llu bytes\n",
            (unsigned long long)atomic_load(&calls), (unsigned long long)atomic_load(&bytes));
}

__attribute__((used)) static struct { const void *replacement; const void *replacee; }
interposers[] __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)counted_malloc,  (const void *)malloc },
    { (const void *)counted_calloc,  (const void *)calloc },
    { (const void *)counted_realloc, (const void *)realloc },
};

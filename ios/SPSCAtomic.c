#include "SPSCAtomic.h"
#include <stdatomic.h>
#include <stdlib.h>

struct spsc_atomic_i64 {
    _Atomic int64_t value;
};

spsc_atomic_i64* spsc_atomic_i64_create(int64_t initial) {
    spsc_atomic_i64* a = (spsc_atomic_i64*)malloc(sizeof(spsc_atomic_i64));
    if (!a) return NULL;
    atomic_init(&a->value, initial);
    return a;
}

void spsc_atomic_i64_destroy(spsc_atomic_i64* a) {
    free(a);
}

int64_t spsc_load_acquire_i64(spsc_atomic_i64* a) {
    return atomic_load_explicit(&a->value, memory_order_acquire);
}

int64_t spsc_load_relaxed_i64(spsc_atomic_i64* a) {
    return atomic_load_explicit(&a->value, memory_order_relaxed);
}

void spsc_store_release_i64(spsc_atomic_i64* a, int64_t v) {
    atomic_store_explicit(&a->value, v, memory_order_release);
}

void spsc_store_relaxed_i64(spsc_atomic_i64* a, int64_t v) {
    atomic_store_explicit(&a->value, v, memory_order_relaxed);
}

int64_t spsc_fetch_add_relaxed_i64(spsc_atomic_i64* a, int64_t delta) {
    return atomic_fetch_add_explicit(&a->value, delta, memory_order_relaxed);
}

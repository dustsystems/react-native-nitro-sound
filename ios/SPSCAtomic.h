#ifndef SPSCAtomic_h
#define SPSCAtomic_h

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque atomic int64 type - Swift never sees the _Atomic internals
typedef struct spsc_atomic_i64 spsc_atomic_i64;

// Lifecycle
spsc_atomic_i64* spsc_atomic_i64_create(int64_t initial);
void spsc_atomic_i64_destroy(spsc_atomic_i64* a);

// Operations
int64_t spsc_load_acquire_i64(spsc_atomic_i64* a);
int64_t spsc_load_relaxed_i64(spsc_atomic_i64* a);
void spsc_store_release_i64(spsc_atomic_i64* a, int64_t v);
void spsc_store_relaxed_i64(spsc_atomic_i64* a, int64_t v);
int64_t spsc_fetch_add_relaxed_i64(spsc_atomic_i64* a, int64_t delta);

#ifdef __cplusplus
}
#endif

#endif /* SPSCAtomic_h */

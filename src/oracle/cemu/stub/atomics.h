/* karabas: stub of CEmu's atomics.h (one thread) */
#pragma once
#include <stdint.h>
#define _Atomic(X) X
#define memory_order_relaxed 0
#define memory_order_acquire 0
#define memory_order_release 0
#define memory_order_acq_rel 0
#define memory_order_seq_cst 0
#define atomic_load_explicit(object, order) (*(object))
static inline uint8_t atomic8_fetch_or_explicit(uint8_t *o, uint8_t a, int m) { uint8_t r = *o; (void)m; *o = r | a; return r; }
static inline uint8_t atomic8_fetch_and_explicit(uint8_t *o, uint8_t a, int m) { uint8_t r = *o; (void)m; *o = r & a; return r; }

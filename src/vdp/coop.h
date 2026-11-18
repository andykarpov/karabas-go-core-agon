/* Cooperative scheduler for the VDP firmware on the soft CPU (no preemption, one core).
   Replaces FreeRTOS tasks / std::thread of userspace-vdp-gl: a task runs until it sleeps or yields.
   Task 0 is the context that called coop_init (main). */
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*coop_fn)(void *arg);

void coop_init(void);
/* New task, runs fn(arg) on its own stack of stack_bytes; returns its id or -1. */
int coop_spawn(coop_fn fn, void *arg, uint32_t stack_bytes);
void coop_yield(void);
void coop_sleep_us(uint64_t us);
uint64_t coop_now_us(void);
int coop_current(void);

#ifdef __cplusplus
}
#endif

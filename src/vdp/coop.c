/* Cooperative scheduler, see coop.h. Round robin over runnable tasks; a sleeping task becomes
   runnable when the microsecond clock passes its wake time. With every task asleep the yield
   spins in the scheduler (the soft CPU has nothing else to do). */
#include <stdio.h>
#include <stdlib.h>
#include "coop.h"
#include "mmio.h"

#define COOP_MAX 8

/* callee-saved context: ra, sp, s0..s11 (coop_switch.S) */
typedef struct { uint32_t r[14]; } coop_ctx;

typedef struct {
    coop_ctx ctx;
    uint64_t wake_us;
    coop_fn fn;
    void *arg;
    void *stack;
    uint32_t stack_bytes;
    const char *name;
    uint8_t used, done;
} coop_task;

void coop_switch(coop_ctx *save, coop_ctx *load);

static coop_task tasks[COOP_MAX];
static int cur;

uint64_t coop_now_us(void) {
    /* 64-bit microsecond counter: read high, low, high again */
    uint32_t hi, lo;
    do {
        hi = MMIO_US_HI;
        lo = MMIO_US_LO;
    } while (hi != MMIO_US_HI);
    return ((uint64_t)hi << 32) | lo;
}

int coop_current(void) { return cur; }

void coop_init(void) {
    tasks[0].used = 1;
    cur = 0;
}

static void coop_entry(void) {
    coop_task *t = &tasks[cur];
    t->fn(t->arg);
    t->done = 1;                 /* never runs again; its stack is leaked (tasks live forever here) */
    for (;;) coop_yield();
}

#define STACK_FILL 0xa5a5a5a5u

int coop_spawn_named(coop_fn fn, void *arg, uint32_t stack_bytes, const char *name) {
    for (int i = 1; i < COOP_MAX; i++) {
        coop_task *t = &tasks[i];
        if (t->used) continue;
        stack_bytes = (stack_bytes + 15u) & ~15u;
        t->stack = malloc(stack_bytes);
        if (!t->stack) break;
        for (uint32_t k = 0; k < stack_bytes / 4; k++) ((uint32_t *)t->stack)[k] = STACK_FILL;
        t->stack_bytes = stack_bytes;
        t->name = name;
        t->fn = fn;
        t->arg = arg;
        t->wake_us = 0;
        t->done = 0;
        for (int k = 0; k < 14; k++) t->ctx.r[k] = 0;
        t->ctx.r[0] = (uint32_t)coop_entry;                       /* ra */
        t->ctx.r[1] = (uint32_t)((char *)t->stack + stack_bytes); /* sp */
        t->used = 1;
        return i;
    }
    /* the callers (std::thread, xTaskCreate) ignore the result: a lost task must not be silent */
    printf("coop: cannot start task %s (%u bytes)\n", name ? name : "?", (unsigned)stack_bytes);
    exit(90);
}

int coop_spawn(coop_fn fn, void *arg, uint32_t stack_bytes) {
    return coop_spawn_named(fn, arg, stack_bytes, 0);
}

void coop_report(void) {
    for (int i = 1; i < COOP_MAX; i++) {
        coop_task *t = &tasks[i];
        if (!t->used) continue;
        uint32_t n = t->stack_bytes / 4, k = 0;
        while (k < n && ((uint32_t *)t->stack)[k] == STACK_FILL) k++;
        printf("coop: task %d %s stack %u of %u bytes used%s\n", i, t->name ? t->name : "?",
               (unsigned)((n - k) * 4), (unsigned)t->stack_bytes, k == 0 ? " OVERFLOW" : "");
    }
}

void coop_yield(void) {
    int from = cur;
    for (;;) {
        uint64_t now = coop_now_us();
        for (int n = 1; n <= COOP_MAX; n++) {
            int i = (from + n) % COOP_MAX;
            coop_task *t = &tasks[i];
            if (!t->used || t->done || t->wake_us > now) continue;
            if (i == from) return;
            cur = i;
            coop_switch(&tasks[from].ctx, &t->ctx);
            return;
        }
    }
}

void coop_sleep_us(uint64_t us) {
    tasks[cur].wake_us = coop_now_us() + us;
    coop_yield();
}

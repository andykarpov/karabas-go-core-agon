/* karabas: stub of CEmu's interrupt.h: no interrupt sources */
#pragma once
#include <stdint.h>
typedef struct interrupt_state {
    uint32_t status   : 22;
    uint32_t          :  2;
    uint32_t enabled  : 22;
    uint32_t          :  2;
} interrupt_state_t;
extern interrupt_state_t intrpt[2];
typedef struct { int im2; } asic_state_t;
extern asic_state_t asic;

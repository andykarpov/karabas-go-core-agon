/* karabas: stub of CEmu's control.h (TI-84 CE protection: never unprivileged here) */
#pragma once
#include <stdint.h>
#include <stdbool.h>
typedef struct { uint8_t protectionStatus; } control_state_t;
extern control_state_t control;
bool unprivileged_code(void);

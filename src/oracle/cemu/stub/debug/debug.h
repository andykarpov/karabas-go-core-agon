/* karabas: stub of CEmu's debug/debug.h without DEBUG_SUPPORT: the register access macros */
#pragma once
#define DBG_REG_TOUCH_W(ID, OLD, NEW) do { (void)(OLD); (void)(NEW); } while (0)
#define REG_READ_EX(ID, EXPR) ((uint32_t)(EXPR))
#define REG_WRITE_EX(ID, LVAL, VAL) (__extension__({ uint32_t __new = (uint32_t)(VAL); (LVAL) = (__new); }))

// Minimal riscv-tests environment for a bare RV32I core (no CSRs, no traps).
// Pass/fail is reported by storing to tohost: 1 = pass, (TESTNUM<<1)|1 = fail.
#ifndef _ENV_BARE_RV32I_H
#define _ENV_BARE_RV32I_H

#define RVTEST_RV32U .macro init; .endm
#define RVTEST_RV64U RVTEST_RV32U

#define TESTNUM gp

#define RVTEST_CODE_BEGIN       \
        .section .text.init;    \
        .align 6;               \
        .globl _start;          \
_start:                         \
        li TESTNUM, 0;

#define RVTEST_CODE_END         \
        unimp

#define RVTEST_PASS             \
        fence;                  \
        li TESTNUM, 1;          \
        la t5, tohost;          \
        sw TESTNUM, 0(t5);      \
1:      j 1b;

#define RVTEST_FAIL             \
        fence;                  \
1:      beqz TESTNUM, 1b;       \
        sll TESTNUM, TESTNUM, 1; \
        or TESTNUM, TESTNUM, 1; \
        la t5, tohost;          \
        sw TESTNUM, 0(t5);      \
2:      j 2b;

#define EXTRA_DATA

#define RVTEST_DATA_BEGIN       \
        EXTRA_DATA              \
        .pushsection .tohost,"aw",@progbits; \
        .align 6; .global tohost; tohost: .dword 0; .size tohost, 8; \
        .align 6; .global fromhost; fromhost: .dword 0; .size fromhost, 8; \
        .popsection;            \
        .align 4; .global begin_signature; begin_signature:

#define RVTEST_DATA_END .align 4; .global end_signature; end_signature:

#endif

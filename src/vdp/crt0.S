/* VDP firmware start (from core-doom / core-pico8): stack at the top of the SRAM, copy .data from the image, clear .bss, run C++ ctors, main, then exit via MMIO. */
    .section .text.start
    .global _start
_start:
    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop
    la      sp, __stack_top
    la      a0, __data_start          /* karabas: .data from its initial copy in the image */
    la      a1, __data_end
    la      a2, __data_load
0:  bgeu    a0, a1, 1f
    lw      t0, 0(a2)
    sw      t0, 0(a0)
    addi    a0, a0, 4
    addi    a2, a2, 4
    j       0b
1:
    la      a0, __bss_start
    la      a1, __bss_end
4:  bgeu    a0, a1, 2f
    sw      zero, 0(a0)
    addi    a0, a0, 4
    j       4b
2:  call    __libc_init_array
    li      a0, 0
    li      a1, 0
    call    main
    call    exit
3:  j       3b

# Bootloader entry (reset vector 0x80010000). Stack at the top of the boot region.
        .section .text.init
        .globl _start
_start:
        li sp, 0x80020000
        call boot_main
1:      j 1b

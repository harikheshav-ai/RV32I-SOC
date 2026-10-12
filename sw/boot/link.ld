/* Bootloader: upper 64 KiB of the SoC BRAM (code from 0x80010000, stack below 0x80020000). */
OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS {
  . = 0x80010000;
  .text : { *(.text.init) *(.text*) }
  .rodata : { *(.rodata*) *(.srodata*) }
  .data : { *(.data*) *(.sdata*) }
  .bss : { *(.bss*) *(.sbss*) *(COMMON) }
  ASSERT(. <= 0x8001F000, "bootloader too large")
}

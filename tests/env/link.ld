/* 64 KiB RAM at 0x80000000; tohost must sit at 0x8000F000 (see mem.bsv). */
OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS {
  . = 0x80000000;
  .text : { *(.text.init) *(.text*) }
  . = ALIGN(16);
  .rodata : { *(.rodata*) *(.srodata*) }
  .data : { *(.data*) *(.sdata*) }
  .bss : { . = ALIGN(4); __bss_start = .; *(.bss*) *(.sbss*) *(COMMON) . = ALIGN(4); __bss_end = .; }
  ASSERT(. <= 0x8000E000, "program too large for 64 KiB RAM")
  . = 0x8000F000;
  .tohost : { *(.tohost) }
  _stack_top = 0x8000F000;
}

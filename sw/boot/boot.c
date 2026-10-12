// UART bootloader.
//
// Protocol (host side: scripts/uart_load.py):
//   host -> 'L'                      boot -> 0x06 (ready)
//   host -> length (4 bytes, LE)     boot -> 0x15 if too large
//   host -> image bytes              boot -> 0x06, checksum (4 bytes LE, sum of bytes)
//   boot jumps to 0x80000000; the program's UART output follows.
//   When the program exits, the SoC resets the core back here and the
//   bootloader sends 0x04 followed by the exit code (0 = pass).

#define UART_TX     (*(volatile unsigned *)0x10000000)
#define UART_RX     (*(volatile int *)0x10000004)
#define SOC_EXIT    (*(volatile unsigned *)0x1000000C)
#define APP_BASE    ((volatile unsigned char *)0x80000000)
#define APP_MAX     0xE000u   /* 0x8000E000 and up: stack and tohost */

#define ACK 0x06
#define NAK 0x15
#define EOT 0x04

static void putb(unsigned c) { UART_TX = c; }

static unsigned getb(void) {
  int c;
  do c = UART_RX; while (c < 0);   // bit 31 set: no data
  return (unsigned)c;
}

static void puts_(const char *s) {
  while (*s) putb(*s++);
}

void boot_main(void) {
  unsigned status = SOC_EXIT;
  if (status & 0x80000000u) {
    putb(EOT);
    putb(status & 0xFF);
  } else {
    puts_("\r\nRV32I bootloader ready\r\n");
  }

  for (;;) {
    while (getb() != 'L')
      ;
    putb(ACK);

    unsigned len = 0;
    for (int i = 0; i < 4; i++) len |= getb() << (8 * i);
    if (len > APP_MAX) {
      putb(NAK);
      continue;
    }

    unsigned sum = 0;
    for (unsigned i = 0; i < len; i++) {
      unsigned b = getb();
      APP_BASE[i] = b;
      sum += b;
    }
    putb(ACK);
    for (int i = 0; i < 4; i++) putb(sum >> (8 * i));

    ((void (*)(void))APP_BASE)();
  }
}

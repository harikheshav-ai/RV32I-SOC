// UART helpers for programs running on the SoC (see soc.bsv for the memory map).
#ifndef UART_H
#define UART_H

void uart_putc(char c);        // '\n' is sent as "\r\n"
int  uart_getc(void);          // blocks until a byte arrives
int  uart_try_getc(void);      // -1 if no byte is waiting
void uart_puts(const char *s);
int  printf(const char *fmt, ...);   // %c %s %d %u %x %p %%, with optional 0/width

#endif

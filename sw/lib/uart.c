#include <stdarg.h>
#include "uart.h"

#define UART_TX (*(volatile unsigned *)0x10000000)
#define UART_RX (*(volatile int *)0x10000004)

void uart_putc(char c) {
  if (c == '\n') UART_TX = '\r';
  UART_TX = (unsigned char)c;
}

int uart_try_getc(void) {
  int c = UART_RX;
  return c < 0 ? -1 : c;
}

int uart_getc(void) {
  int c;
  while ((c = uart_try_getc()) < 0)
    ;
  return c;
}

void uart_puts(const char *s) {
  while (*s) uart_putc(*s++);
}

static int put_num(unsigned v, unsigned base, int neg, int width, char pad) {
  char buf[12];
  int n = 0;
  do {
    unsigned d = v % base;
    buf[n++] = d < 10 ? '0' + d : 'a' + d - 10;
    v /= base;
  } while (v);
  int len = n + neg;
  if (neg && pad == '0') uart_putc('-');
  for (; width > len; width--) uart_putc(pad);
  if (neg && pad != '0') uart_putc('-');
  while (n) uart_putc(buf[--n]);
  return len;
}

int printf(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int count = 0;
  for (; *fmt; fmt++) {
    if (*fmt != '%') {
      uart_putc(*fmt);
      count++;
      continue;
    }
    fmt++;
    char pad = ' ';
    int width = 0;
    if (*fmt == '0') { pad = '0'; fmt++; }
    while (*fmt >= '0' && *fmt <= '9') width = width * 10 + (*fmt++ - '0');
    switch (*fmt) {
      case 'c': uart_putc((char)va_arg(ap, int)); count++; break;
      case 's': {
        const char *s = va_arg(ap, const char *);
        int len = 0;
        while (s[len]) len++;
        for (; width > len; width--, count++) uart_putc(' ');
        uart_puts(s);
        count += len;
        break;
      }
      case 'd': {
        int v = va_arg(ap, int);
        count += put_num(v < 0 ? -(unsigned)v : (unsigned)v, 10, v < 0, width, pad);
        break;
      }
      case 'u': count += put_num(va_arg(ap, unsigned), 10, 0, width, pad); break;
      case 'x': count += put_num(va_arg(ap, unsigned), 16, 0, width, pad); break;
      case 'p': uart_puts("0x"); count += 2 + put_num(va_arg(ap, unsigned), 16, 0, 8, '0'); break;
      case '%': uart_putc('%'); count++; break;
      case '\0': fmt--; break;
      default: uart_putc('%'); uart_putc(*fmt); count += 2; break;
    }
  }
  va_end(ap);
  return count;
}

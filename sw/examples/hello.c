// Prints over the UART; returns 0 (pass) after checking a few results.
#include "uart.h"

static unsigned fib(unsigned n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

int main(void) {
  printf("Hello from RV32I!\n");
  printf("fib:");
  for (unsigned i = 0; i <= 15; i++) printf(" %u", fib(i));
  printf("\n");

  static unsigned char sieve[1000];
  int primes = 0;
  for (int i = 2; i < 1000; i++) {
    if (sieve[i]) continue;
    primes++;
    for (int j = 2 * i; j < 1000; j += i) sieve[j] = 1;
  }
  printf("primes below 1000: %d\n", primes);
  printf("hex: %08x  neg: %d  str: [%5s]\n", 0xC0FFEEu, -42, "abc");
  return (fib(15) == 610 && primes == 168) ? 0 : 1;
}

// Recursion, function pointers, 16-bit/8-bit signed data and division.
static int fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

static int ack(int m, int n) {
  if (m == 0) return n + 1;
  if (n == 0) return ack(m - 1, 1);
  return ack(m - 1, ack(m, n - 1));
}

static int add(int a, int b) { return a + b; }
static int sub(int a, int b) { return a - b; }
static int (*volatile ops[2])(int, int) = { add, sub };

static volatile short hs[4] = { -1, 32767, -32768, 1234 };
static volatile signed char bs[4] = { -128, 127, -1, 5 };

int main(void) {
  if (fib(18) != 2584) return 1;
  if (ack(2, 3) != 9) return 2;
  if (ops[0](40, 2) != 42 || ops[1](40, 2) != 38) return 3;
  int s = 0;
  for (int i = 0; i < 4; i++) s += hs[i] + bs[i];
  if (s != (-1 + 32767 - 32768 + 1234) + (-128 + 127 - 1 + 5)) return 4;
  volatile int n = -1000, d = 7;
  if (n / d != -142 || n % d != -6) return 5;
  volatile unsigned un = 0xFFFFFFF0u, ud = 3;
  if (un / ud != 0x55555550u || un % ud != 0) return 6;
  return 0;
}

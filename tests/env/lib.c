// Runtime helpers the compiler may call on RV32I (no M extension, no libc).
typedef unsigned int u32;

u32 __mulsi3(u32 a, u32 b) {
  u32 r = 0;
  while (b) { if (b & 1) r += a; a <<= 1; b >>= 1; }
  return r;
}

u32 __udivsi3(u32 n, u32 d) {
  u32 q = 0, r = 0;
  if (d == 0) return ~0u;
  for (int i = 31; i >= 0; i--) {
    r = (r << 1) | ((n >> i) & 1);
    if (r >= d) { r -= d; q |= 1u << i; }
  }
  return q;
}

u32 __umodsi3(u32 n, u32 d) { return d ? n - __mulsi3(__udivsi3(n, d), d) : n; }

int __divsi3(int n, int d) {
  int neg = (n < 0) ^ (d < 0);
  u32 q = __udivsi3(n < 0 ? -(u32)n : n, d < 0 ? -(u32)d : d);
  return neg ? -(int)q : (int)q;
}

int __modsi3(int n, int d) { return n - (int)__mulsi3(__divsi3(n, d), d); }

void *memset(void *s, int c, unsigned n) {
  unsigned char *p = s;
  while (n--) *p++ = (unsigned char)c;
  return s;
}

void *memcpy(void *d, const void *s, unsigned n) {
  unsigned char *dp = d;
  const unsigned char *sp = s;
  while (n--) *dp++ = *sp++;
  return d;
}

// Insertion sort of LCG-generated data; checks order and a checksum.
#define N 200
static int a[N];

int main(void) {
  unsigned x = 12345, sum = 0, sorted_sum = 0;
  for (int i = 0; i < N; i++) {
    x = x * 1103515245u + 12345u;
    a[i] = (int)(x >> 8) - (1 << 22);
    sum += a[i];
  }
  for (int i = 1; i < N; i++) {
    int v = a[i], j = i - 1;
    while (j >= 0 && a[j] > v) { a[j + 1] = a[j]; j--; }
    a[j + 1] = v;
  }
  for (int i = 0; i < N; i++) {
    if (i && a[i - 1] > a[i]) return 1;
    sorted_sum += a[i];
  }
  return sum == sorted_sum ? 0 : 2;
}

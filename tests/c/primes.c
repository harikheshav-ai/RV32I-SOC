// Sieve of Eratosthenes: 1229 primes below 10000.
#define N 10000
static unsigned char composite[N];

int main(void) {
  int count = 0;
  for (int i = 2; i < N; i++) {
    if (composite[i]) continue;
    count++;
    for (int j = i * i; j < N; j += i) composite[j] = 1;
  }
  return count == 1229 ? 0 : 1;
}

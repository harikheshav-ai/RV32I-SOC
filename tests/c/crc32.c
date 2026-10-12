// CRC-32 (bitwise and table-driven) of "123456789" must be 0xCBF43926.
static unsigned table[256];

static unsigned crc_bitwise(const char *s) {
  unsigned c = ~0u;
  while (*s) {
    c ^= (unsigned char)*s++;
    for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xEDB88320u & -(c & 1));
  }
  return ~c;
}

static unsigned crc_table(const char *s) {
  for (unsigned i = 0; i < 256; i++) {
    unsigned c = i;
    for (int k = 0; k < 8; k++) c = (c & 1) ? (c >> 1) ^ 0xEDB88320u : c >> 1;
    table[i] = c;
  }
  unsigned c = ~0u;
  while (*s) c = table[(c ^ (unsigned char)*s++) & 0xFF] ^ (c >> 8);
  return ~c;
}

int main(void) {
  const char *msg = "123456789";
  if (crc_bitwise(msg) != 0xCBF43926u) return 1;
  if (crc_table(msg) != 0xCBF43926u) return 2;
  return 0;
}

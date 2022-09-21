#include <stdio.h>
#include <openssl/crypto.h>

int main () {
  int a = OPENSSL_hexchar2int('a');
  printf("%d\n", a);
  return 0;
}

#include <stdio.h>
#include <stdlib.h>

#include "tweetnacl.h"

#define KEY_BYTES 32

/* TweetNaCl references this from unused key-generation functions in the same
   object file. This inspector only derives a public key and never calls it. */
void randombytes(unsigned char *buffer, unsigned long long length)
{
    (void)buffer;
    (void)length;
    abort();
}

static void print_hex(const char *label, const unsigned char *value)
{
    unsigned int index;

    printf("%s=", label);
    for (index = 0; index < KEY_BYTES; index++)
        printf("%02x", value[index]);
    putchar('\n');
}

int main(int argc, char **argv)
{
    const char *path = "/mnt/cfg/wfb/gs.key";
    unsigned char secret[KEY_BYTES];
    unsigned char peer_public[KEY_BYTES];
    unsigned char own_public[KEY_BYTES];
    FILE *file;

    if (argc == 2)
        path = argv[1];
    else if (argc != 1) {
        fprintf(stderr, "usage: %s [key-file]\n", argv[0]);
        return 2;
    }

    file = fopen(path, "rb");
    if (!file) {
        perror(path);
        return 1;
    }
    if (fread(secret, 1, sizeof(secret), file) != sizeof(secret) ||
        fread(peer_public, 1, sizeof(peer_public), file) != sizeof(peer_public) ||
        fgetc(file) != EOF) {
        fclose(file);
        fprintf(stderr, "%s: expected exactly 64 bytes\n", path);
        return 1;
    }
    fclose(file);

    if (crypto_scalarmult_base(own_public, secret) != 0) {
        fprintf(stderr, "%s: cannot derive public key\n", path);
        return 1;
    }

    print_hex("own_public", own_public);
    print_hex("peer_public", peer_public);
    return 0;
}
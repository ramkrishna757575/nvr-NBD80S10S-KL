/*
 * Verifies a detached Ed25519 signature over a firmware image.
 *
 *   verify-sig <sha256-hex> <signature-file>
 *
 * The signed message is the image's raw 32-byte SHA-256 digest, not the image
 * itself: the board would otherwise need the whole 11MB in RAM twice over, once
 * for the signed blob and once for crypto_sign_open's output. Hashing is left to
 * busybox sha256sum, which streams.
 *
 * The public key is compiled in from signing-key.pub. It is no more trusted than
 * the rest of the image -- an attacker who can rewrite flash can rewrite the key
 * too -- but that is not the threat here. This exists so that a board fetching
 * its next image over a connection it cannot authenticate (busybox wget does not
 * validate certificates) still refuses anything the key holder did not sign.
 *
 * Exit status is 0 only for a good signature, so callers can test it directly.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "tweetnacl.h"

/* Pulled in by crypto_sign_keypair, which a verifier never calls. TweetNaCl
   leaves it to the caller to supply, and the link fails without it. */
void randombytes(unsigned char *p, unsigned long long n)
{
	(void)p;
	(void)n;
	fprintf(stderr, "verify-sig: randombytes reached in a verify-only build\n");
	abort();
}

static const unsigned char pubkey[32] = {
#include "signing-pubkey.h"
};

static int unhex(const char *hex, unsigned char *out, size_t outlen)
{
	size_t i;

	if (strlen(hex) != outlen * 2)
		return -1;
	for (i = 0; i < outlen; i++) {
		unsigned int b;
		if (sscanf(hex + i * 2, "%2x", &b) != 1)
			return -1;
		out[i] = (unsigned char)b;
	}
	return 0;
}

int main(int argc, char **argv)
{
	unsigned char digest[32];
	unsigned char sm[crypto_sign_BYTES + sizeof(digest)];
	unsigned char m[sizeof(sm)];
	unsigned long long mlen;
	size_t got;
	FILE *f;

	if (argc != 3) {
		fprintf(stderr, "usage: verify-sig <sha256-hex> <signature-file>\n");
		return 2;
	}

	if (unhex(argv[1], digest, sizeof(digest)) != 0) {
		fprintf(stderr, "verify-sig: expected 64 hex characters\n");
		return 2;
	}

	f = fopen(argv[2], "rb");
	if (!f) {
		fprintf(stderr, "verify-sig: cannot open %s\n", argv[2]);
		return 2;
	}
	got = fread(sm, 1, crypto_sign_BYTES, f);
	/* A trailing byte means this is not the detached signature we expect. */
	if (got == crypto_sign_BYTES)
		got += fread(sm, 1, 1, f);
	fclose(f);
	if (got != crypto_sign_BYTES) {
		fprintf(stderr, "verify-sig: signature must be exactly %d bytes\n",
			crypto_sign_BYTES);
		return 2;
	}

	memcpy(sm + crypto_sign_BYTES, digest, sizeof(digest));

	if (crypto_sign_open(m, &mlen, sm, sizeof(sm), pubkey) != 0) {
		fprintf(stderr, "verify-sig: BAD SIGNATURE\n");
		return 1;
	}
	if (mlen != sizeof(digest) || memcmp(m, digest, sizeof(digest)) != 0) {
		fprintf(stderr, "verify-sig: signature covers different data\n");
		return 1;
	}
	return 0;
}

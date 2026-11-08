#include "CNative.h"
int roam_ocb(int encrypt, const unsigned char *key, const unsigned char *nonce,
             const unsigned char *input, int length, unsigned char *output, unsigned char *tag) {
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) return -1;
    int n = 0, last = 0, ok = 0;
    if (!EVP_CipherInit_ex(ctx, EVP_aes_128_ocb(), NULL, NULL, NULL, encrypt)) goto done;
    if (!EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_IVLEN, 12, NULL)) goto done;
    if (!encrypt && !EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_TAG, 16, tag)) goto done;
    if (!EVP_CipherInit_ex(ctx, NULL, NULL, key, nonce, encrypt)) goto done;
    if (!EVP_CipherUpdate(ctx, output, &n, input, length)) goto done;
    if (!EVP_CipherFinal_ex(ctx, output + n, &last)) goto done;
    if (encrypt && !EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_GET_TAG, 16, tag)) goto done;
    ok = 1;
done:
    EVP_CIPHER_CTX_free(ctx);
    return ok ? n + last : -1;
}
void roam_sha256(const unsigned char *input, size_t length, unsigned char *output) {
    SHA256(input, length, output);
}

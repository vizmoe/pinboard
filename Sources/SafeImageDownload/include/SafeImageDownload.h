#ifndef PINBOARD_SAFE_IMAGE_DOWNLOAD_H
#define PINBOARD_SAFE_IMAGE_DOWNLOAD_H
#include <stddef.h>

/// Returns zero on success; otherwise a stable libcurl error code. The caller
/// owns *bytes and must free it. No bytes are returned after any failure.
int pinboard_download_image(const char *url, size_t limit, unsigned char **bytes, size_t *length);
/// Used for every resolved socket address, including redirect destinations.
int pinboard_image_address_is_public(const char *address);
#endif

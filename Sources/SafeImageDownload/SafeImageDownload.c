#include "SafeImageDownload.h"
#include <arpa/inet.h>
#include <curl/curl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>

static pthread_once_t curl_once = PTHREAD_ONCE_INIT;
static CURLcode curl_init_result;
static void initialize_curl(void) { curl_init_result = curl_global_init(CURL_GLOBAL_DEFAULT); }

static int public_ipv4(uint32_t host) {
    uint8_t a = host >> 24, b = host >> 16;
    if (a == 0 || a == 10 || a == 127 || a >= 224) return 0;
    if (a == 100 && b >= 64 && b <= 127) return 0;
    if (a == 169 && b == 254) return 0;
    if (a == 172 && b >= 16 && b <= 31) return 0;
    if (a == 192 && b == 168) return 0;
    if ((host & 0xffffff00) == 0xc0000000 || (host & 0xffffff00) == 0xc0000200) return 0;
    if ((host & 0xffffff00) == 0xc0586300) return 0; // deprecated 6to4 relay
    if (a == 198 && (b == 18 || b == 19)) return 0;
    if ((host & 0xffffff00) == 0xc6336400 || (host & 0xffffff00) == 0xcb007100) return 0;
    return 1;
}

static int public_ipv6(const struct in6_addr *ip) {
    const unsigned char *b = ip->s6_addr;
    if (IN6_IS_ADDR_V4MAPPED(ip)) {
        uint32_t v4;
        memcpy(&v4, b + 12, sizeof(v4));
        return public_ipv4(ntohl(v4));
    }
    // Only global unicast, excluding transition/documentation ranges which
    // may embed or tunnel private IPv4 destinations.
    if ((b[0] & 0xe0) != 0x20) return 0;
    if (b[0] == 0x20 && b[1] == 0x02) return 0; // 6to4
    if (b[0] == 0x20 && b[1] == 0x01 && b[2] < 2) return 0;
    if (b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8) return 0;
    if (b[0] == 0x3f && (b[1] & 0xf0) == 0xf0) return 0; // documentation 3fff::/20
    return 1;
}

int pinboard_image_address_is_public(const char *address) {
    struct in_addr v4;
    struct in6_addr v6;
    if (inet_pton(AF_INET, address, &v4) == 1) return public_ipv4(ntohl(v4.s_addr));
    if (inet_pton(AF_INET6, address, &v6) == 1) return public_ipv6(&v6);
    return 0;
}

static curl_socket_t open_public_socket(void *context, curlsocktype purpose, struct curl_sockaddr *address) {
    (void)context;
    if (purpose != CURLSOCKTYPE_IPCXN) return CURL_SOCKET_BAD;
    if (address->family == AF_INET) {
        const struct sockaddr_in *ip = (const struct sockaddr_in *)&address->addr;
        if (!public_ipv4(ntohl(ip->sin_addr.s_addr))) return CURL_SOCKET_BAD;
    } else if (address->family == AF_INET6) {
        const struct sockaddr_in6 *ip = (const struct sockaddr_in6 *)&address->addr;
        if (!public_ipv6(&ip->sin6_addr)) return CURL_SOCKET_BAD;
    } else { return CURL_SOCKET_BAD; }
    // Validation applies to the exact resolved address curl connects to:
    // there is no separate DNS lookup that a rebinding host can race.
    return socket(address->family, address->socktype, address->protocol);
}

typedef struct {
    unsigned char *bytes;
    size_t length;
    size_t capacity;
    size_t limit;
} Download;

static size_t receive_bytes(char *incoming, size_t size, size_t count, void *context) {
    Download *download = context;
    if (size && count > SIZE_MAX / size) return 0;
    size_t length = size * count;
    if (length > download->limit - download->length) return 0;
    size_t needed = download->length + length;
    if (needed > download->capacity) {
        size_t capacity = download->capacity ? download->capacity * 2 : 16384;
        if (capacity < needed) capacity = needed;
        if (capacity > download->limit) capacity = download->limit;
        unsigned char *bytes = realloc(download->bytes, capacity);
        if (!bytes) return 0;
        download->bytes = bytes;
        download->capacity = capacity;
    }
    if (length) memcpy(download->bytes + download->length, incoming, length);
    download->length = needed;
    return length;
}

int pinboard_download_image(const char *url, size_t limit, unsigned char **bytes, size_t *length) {
    *bytes = NULL;
    *length = 0;
    pthread_once(&curl_once, initialize_curl);
    if (curl_init_result != CURLE_OK) return curl_init_result;
    CURL *curl = curl_easy_init();
    if (!curl) return CURLE_FAILED_INIT;
    Download download = { .limit = limit };
    CURLcode result;
#define SET_OPTION(option, value) do { result = curl_easy_setopt(curl, option, value); if (result != CURLE_OK) goto cleanup; } while (0)
    SET_OPTION(CURLOPT_URL, url);
    SET_OPTION(CURLOPT_PROTOCOLS, (long)(CURLPROTO_HTTP | CURLPROTO_HTTPS));
    SET_OPTION(CURLOPT_REDIR_PROTOCOLS, (long)(CURLPROTO_HTTP | CURLPROTO_HTTPS));
    SET_OPTION(CURLOPT_FOLLOWLOCATION, 1L);
    SET_OPTION(CURLOPT_MAXREDIRS, 5L);
    SET_OPTION(CURLOPT_PROXY, "");
    SET_OPTION(CURLOPT_NETRC, (long)CURL_NETRC_IGNORED);
    SET_OPTION(CURLOPT_DISALLOW_USERNAME_IN_URL, 1L);
    SET_OPTION(CURLOPT_TIMEOUT, 8L);
    SET_OPTION(CURLOPT_CONNECTTIMEOUT, 5L);
    SET_OPTION(CURLOPT_NOSIGNAL, 1L);
    SET_OPTION(CURLOPT_FAILONERROR, 1L);
    SET_OPTION(CURLOPT_OPENSOCKETFUNCTION, open_public_socket);
    SET_OPTION(CURLOPT_WRITEFUNCTION, receive_bytes);
    SET_OPTION(CURLOPT_WRITEDATA, &download);
    SET_OPTION(CURLOPT_MAXFILESIZE_LARGE, (curl_off_t)limit);
    result = curl_easy_perform(curl);
    if (result == CURLE_OK) {
        long status = 0;
        result = curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
        if (result == CURLE_OK && status != 200) result = CURLE_HTTP_RETURNED_ERROR;
    }
cleanup:
    curl_easy_cleanup(curl);
    if (result == CURLE_OK) { *bytes = download.bytes; *length = download.length; }
    else { free(download.bytes); }
    return result;
#undef SET_OPTION
}

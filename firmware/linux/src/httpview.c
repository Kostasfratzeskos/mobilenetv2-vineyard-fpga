/*============================================================================
 *  httpview.c  -  a two-page web server for the demo screen
 *
 *  Linux only. See httpview.h. One thread, one request at a time, HTTP/1.0
 *  with Connection: close - the browser asks for the next frame when the last
 *  one has loaded, so there is never more than one request in flight anyway.
 *==========================================================================*/
#define _GNU_SOURCE
#include "httpview.h"

#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define HV_MAX_W      1280      /* wider screens are sent at half size      */
#define HV_IDLE_MS    2000.0    /* nobody asked for this long: stop copying */
#define HV_PERIOD_MS  66.0      /* at most ~15 snapshots a second           */

struct httpview {
    int             lfd;
    pthread_t       thr;
    atomic_int      stop;
    pthread_mutex_t mu;
    uint8_t        *bmp;            /* the latest snapshot: a whole BMP file */
    size_t          bmp_len, bmp_cap;
    double          last_request;   /* under mu                              */
    /*  main thread only */
    uint8_t        *scratch;
    size_t          scratch_cap;
    double          last_publish;
};

static const char PAGE[] =
    "<!doctype html><html><head><meta charset=\"utf-8\"><title>vinecam</title>"
    "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
    "<style>html,body{margin:0;height:100%;background:#0d1117}"
    "img{display:block;width:100%;height:100%;object-fit:contain}</style>"
    "</head><body><img id=\"f\" alt=\"waiting for the board\"><script>"
    "const f=document.getElementById('f');"
    "function next(){f.src='/frame.bmp?'+Date.now();}"
    "f.onload=()=>setTimeout(next,15);"
    "f.onerror=()=>setTimeout(next,500);"
    "next();"
    "</script></body></html>";

static double now_ms(void)
{
    struct timespec t;

    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec * 1e3 + (double)t.tv_nsec / 1e6;
}

static void put32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
}

/*  BITMAPFILEHEADER + BITMAPINFOHEADER, 24 bits, bottom-up, uncompressed. */
static void bmp_header(uint8_t *h, unsigned w, unsigned hgt, size_t data)
{
    memset(h, 0, 54);
    h[0] = 'B';
    h[1] = 'M';
    put32(h + 2, (uint32_t)(54u + data));
    put32(h + 10, 54u);
    put32(h + 14, 40u);
    put32(h + 18, w);
    put32(h + 22, hgt);
    h[26] = 1;                         /* planes */
    h[28] = 24;                        /* bits per pixel */
    put32(h + 34, (uint32_t)data);
    put32(h + 38, 2835u);              /* 72 dpi, which nothing reads */
    put32(h + 42, 2835u);
}

void httpview_publish(httpview_t *h, const canvas_t *cv)
{
    unsigned step, w, hh, row, x, y;
    size_t   need;
    double   t = now_ms();
    int      watching;
    uint8_t *swap;

    if (h == NULL || cv->px == NULL)
        return;
    pthread_mutex_lock(&h->mu);
    watching = t - h->last_request < HV_IDLE_MS;
    pthread_mutex_unlock(&h->mu);
    if (!watching || t - h->last_publish < HV_PERIOD_MS)
        return;
    h->last_publish = t;

    step = cv->w > HV_MAX_W ? 2u : 1u;
    w    = cv->w / step;
    hh   = cv->h / step;
    row  = (3u * w + 3u) & ~3u;
    need = 54u + (size_t)row * hh;
    if (need > h->scratch_cap) {
        uint8_t *p = realloc(h->scratch, need);
        if (p == NULL)
            return;
        h->scratch     = p;
        h->scratch_cap = need;
    }

    /*  Built outside the lock; only the pointer swap is inside it. */
    bmp_header(h->scratch, w, hh, (size_t)row * hh);
    for (y = 0; y < hh; y++) {
        const uint32_t *src = cv->px + (size_t)y * step * cv->w;
        uint8_t        *dst = h->scratch + 54u + (size_t)(hh - 1u - y) * row;
        for (x = 0; x < w; x++) {
            uint32_t v = src[x * step];
            dst[3u * x]      = (uint8_t)v;           /* B */
            dst[3u * x + 1u] = (uint8_t)(v >> 8);    /* G */
            dst[3u * x + 2u] = (uint8_t)(v >> 16);   /* R */
        }
        memset(dst + 3u * w, 0, row - 3u * w);
    }

    pthread_mutex_lock(&h->mu);
    swap           = h->bmp;
    h->bmp         = h->scratch;
    h->bmp_len     = need;
    h->scratch     = swap;
    {
        size_t cap     = h->bmp_cap;
        h->bmp_cap     = h->scratch_cap;
        h->scratch_cap = cap;
    }
    pthread_mutex_unlock(&h->mu);
}

static int send_all(int fd, const void *buf, size_t len)
{
    const char *p = buf;

    while (len > 0u) {
        ssize_t n = send(fd, p, len, MSG_NOSIGNAL);
        if (n <= 0) {
            if (n < 0 && errno == EINTR)
                continue;
            return -1;
        }
        p   += n;
        len -= (size_t)n;
    }
    return 0;
}

static void reply(int fd, const char *status, const char *type,
                  const void *body, size_t len)
{
    char hdr[256];
    int  n = snprintf(hdr, sizeof hdr,
                      "HTTP/1.0 %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\n"
                      "Cache-Control: no-store\r\nConnection: close\r\n\r\n",
                      status, type, len);

    if (send_all(fd, hdr, (size_t)n) == 0 && len > 0u)
        (void)send_all(fd, body, len);
}

static void *serve(void *arg)
{
    httpview_t *h   = arg;
    uint8_t    *out = NULL;
    size_t      cap = 0;

    while (!atomic_load(&h->stop)) {
        struct pollfd  p = { h->lfd, POLLIN, 0 };
        struct timeval tv = { 3, 0 };
        char           req[1024];
        size_t         n = 0;
        int            c;

        if (poll(&p, 1, 200) <= 0)
            continue;
        c = accept(h->lfd, NULL, NULL);
        if (c < 0)
            continue;
        (void)setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        (void)setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);

        while (n < sizeof req - 1u) {
            ssize_t r = recv(c, req + n, sizeof req - 1u - n, 0);
            if (r <= 0)
                break;
            n += (size_t)r;
            req[n] = '\0';
            if (strstr(req, "\r\n\r\n"))
                break;
        }
        req[n] = '\0';

        if (strncmp(req, "GET /frame.bmp", 14) == 0 &&
            (req[14] == ' ' || req[14] == '?')) {
            size_t len;
            pthread_mutex_lock(&h->mu);
            h->last_request = now_ms();
            len = h->bmp_len;
            if (len > cap) {
                uint8_t *q = realloc(out, len);
                if (q) {
                    out = q;
                    cap = len;
                } else {
                    len = 0;
                }
            }
            if (len)
                memcpy(out, h->bmp, len);
            pthread_mutex_unlock(&h->mu);
            if (len)
                reply(c, "200 OK", "image/bmp", out, len);
            else
                reply(c, "503 Service Unavailable", "text/plain", "no frame yet\n", 13);
        } else if (strncmp(req, "GET / ", 6) == 0 ||
                   strncmp(req, "GET /index.html ", 16) == 0) {
            pthread_mutex_lock(&h->mu);
            h->last_request = now_ms();         /* start snapshotting now */
            pthread_mutex_unlock(&h->mu);
            reply(c, "200 OK", "text/html; charset=utf-8", PAGE, sizeof PAGE - 1u);
        } else {
            reply(c, "404 Not Found", "text/plain", "not found\n", 10);
        }
        close(c);
    }
    free(out);
    return NULL;
}

httpview_t *httpview_start(int port, char *err, size_t errlen)
{
    struct sockaddr_in a;
    httpview_t        *h = calloc(1, sizeof *h);
    int                one = 1;

    if (h == NULL) {
        snprintf(err, errlen, "out of memory");
        return NULL;
    }
    h->last_request = -1e9;
    h->last_publish = -1e9;
    atomic_init(&h->stop, 0);
    pthread_mutex_init(&h->mu, NULL);

    h->lfd = socket(AF_INET, SOCK_STREAM, 0);
    if (h->lfd < 0) {
        snprintf(err, errlen, "socket: %s", strerror(errno));
        free(h);
        return NULL;
    }
    (void)setsockopt(h->lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    memset(&a, 0, sizeof a);
    a.sin_family      = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    a.sin_port        = htons((uint16_t)port);
    if (bind(h->lfd, (struct sockaddr *)&a, sizeof a) < 0 || listen(h->lfd, 4) < 0) {
        snprintf(err, errlen, "port %d: %s", port, strerror(errno));
        close(h->lfd);
        free(h);
        return NULL;
    }
    if (pthread_create(&h->thr, NULL, serve, h) != 0) {
        snprintf(err, errlen, "cannot start the server thread");
        close(h->lfd);
        free(h);
        return NULL;
    }
    return h;
}

void httpview_stop(httpview_t *h)
{
    if (h == NULL)
        return;
    atomic_store(&h->stop, 1);
    pthread_join(h->thr, NULL);
    close(h->lfd);
    pthread_mutex_destroy(&h->mu);
    free(h->bmp);
    free(h->scratch);
    free(h);
}

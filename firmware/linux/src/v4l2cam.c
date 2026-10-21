/*============================================================================
 *  v4l2cam.c  -  UVC capture, YUYV through mmap'd buffers
 *
 *  Linux only. See v4l2cam.h, in particular for why cam_grab drains.
 *==========================================================================*/
#define _GNU_SOURCE
#include "v4l2cam.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <linux/videodev2.h>

static int xioctl(int fd, unsigned long req, void *arg)
{
    int r;

    do {
        r = ioctl(fd, req, arg);
    } while (r == -1 && errno == EINTR);
    return r;
}

static void fourcc_str(uint32_t f, char out[5])
{
    out[0] = (char)(f & 0xFFu);
    out[1] = (char)((f >> 8) & 0xFFu);
    out[2] = (char)((f >> 16) & 0xFFu);
    out[3] = (char)((f >> 24) & 0xFFu);
    out[4] = '\0';
}

static int qbuf(cam_t *c, unsigned i)
{
    struct v4l2_buffer b;

    memset(&b, 0, sizeof b);
    b.type   = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    b.memory = V4L2_MEMORY_MMAP;
    b.index  = i;
    return xioctl(c->fd, VIDIOC_QBUF, &b);
}

int cam_open(cam_t *c, const char *dev, unsigned w, unsigned h,
             char *err, size_t errlen)
{
    static const uint32_t want[2] = { V4L2_PIX_FMT_YUYV, V4L2_PIX_FMT_UYVY };
    struct v4l2_capability     cap;
    struct v4l2_format         fmt;
    struct v4l2_streamparm     parm;
    struct v4l2_requestbuffers req;
    uint32_t caps;
    unsigned i;
    int      k;

    memset(c, 0, sizeof *c);
    c->fd   = -1;
    c->held = -1;

    c->fd = open(dev, O_RDWR | O_NONBLOCK);
    if (c->fd < 0) {
        snprintf(err, errlen, "%s: %s - is the camera plugged in? "
                 "(`ls /dev/video*`)", dev, strerror(errno));
        return -1;
    }

    if (xioctl(c->fd, VIDIOC_QUERYCAP, &cap) < 0) {
        snprintf(err, errlen, "%s is not a V4L2 device", dev);
        cam_close(c);
        return -1;
    }
    caps = (cap.capabilities & V4L2_CAP_DEVICE_CAPS) ? cap.device_caps
                                                     : cap.capabilities;
    if (!(caps & V4L2_CAP_VIDEO_CAPTURE) || !(caps & V4L2_CAP_STREAMING)) {
        /*  A UVC camera registers a second node for metadata, which cannot
         *  capture video; /dev/video1 is usually that one. */
        snprintf(err, errlen, "%s cannot stream video (a UVC camera's metadata "
                 "node? try the other /dev/video*)", dev);
        cam_close(c);
        return -1;
    }
    snprintf(c->card, sizeof c->card, "%s", (const char *)cap.card);

    for (k = 0; k < 2; k++) {
        memset(&fmt, 0, sizeof fmt);
        fmt.type                = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        fmt.fmt.pix.width       = w;
        fmt.fmt.pix.height      = h;
        fmt.fmt.pix.pixelformat = want[k];
        fmt.fmt.pix.field       = V4L2_FIELD_NONE;
        if (xioctl(c->fd, VIDIOC_S_FMT, &fmt) == 0 &&
            fmt.fmt.pix.pixelformat == want[k])
            break;
    }
    if (k == 2) {
        snprintf(err, errlen, "%s offers neither YUYV nor UYVY - `vinecam "
                 "--list` shows what it does offer", dev);
        cam_close(c);
        return -1;
    }

    c->uyvy   = (k == 1);
    c->w      = fmt.fmt.pix.width;
    c->h      = fmt.fmt.pix.height;
    c->stride = fmt.fmt.pix.bytesperline ? fmt.fmt.pix.bytesperline : 2u * c->w;
    if ((c->w & 1u) || c->stride < 2u * c->w || c->h == 0u) {
        snprintf(err, errlen, "%s chose an unusable format: %ux%u, %u bytes per "
                 "line", dev, c->w, c->h, c->stride);
        cam_close(c);
        return -1;
    }

    /*  30 fps if it will; a camera that refuses keeps its own default. Not an
     *  error: in poor light most webcams lengthen the exposure and drop to 15
     *  regardless, which is a lighting problem, not a software one. */
    memset(&parm, 0, sizeof parm);
    parm.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    parm.parm.capture.timeperframe.numerator   = 1;
    parm.parm.capture.timeperframe.denominator = 30;
    (void)xioctl(c->fd, VIDIOC_S_PARM, &parm);

    memset(&req, 0, sizeof req);
    req.count  = CAM_NBUF;
    req.type   = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    req.memory = V4L2_MEMORY_MMAP;
    if (xioctl(c->fd, VIDIOC_REQBUFS, &req) < 0 || req.count < 2u) {
        snprintf(err, errlen, "%s: cannot get capture buffers", dev);
        cam_close(c);
        return -1;
    }
    c->nbuf = req.count > CAM_NBUF ? CAM_NBUF : req.count;

    for (i = 0; i < c->nbuf; i++) {
        struct v4l2_buffer b;
        void *p;

        memset(&b, 0, sizeof b);
        b.type   = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        b.memory = V4L2_MEMORY_MMAP;
        b.index  = i;
        if (xioctl(c->fd, VIDIOC_QUERYBUF, &b) < 0) {
            snprintf(err, errlen, "%s: QUERYBUF failed", dev);
            cam_close(c);
            return -1;
        }
        p = mmap(NULL, b.length, PROT_READ | PROT_WRITE, MAP_SHARED, c->fd,
                 b.m.offset);
        if (p == MAP_FAILED) {
            snprintf(err, errlen, "%s: mmap of buffer %u failed", dev, i);
            cam_close(c);
            return -1;
        }
        c->buf[i] = p;
        c->len[i] = b.length;
        if (b.length < (size_t)c->stride * c->h) {
            snprintf(err, errlen, "%s: buffer %u is %u bytes, a frame is %u",
                     dev, i, b.length, c->stride * c->h);
            cam_close(c);
            return -1;
        }
    }
    return 0;
}

int cam_start(cam_t *c, char *err, size_t errlen)
{
    enum v4l2_buf_type t = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    unsigned i;

    for (i = 0; i < c->nbuf; i++)
        if (qbuf(c, i) < 0) {
            snprintf(err, errlen, "QBUF failed: %s", strerror(errno));
            return -1;
        }
    if (xioctl(c->fd, VIDIOC_STREAMON, &t) < 0) {
        snprintf(err, errlen, "STREAMON failed: %s - another program using the "
                 "camera?", strerror(errno));
        return -1;
    }
    c->streaming = 1;
    return 0;
}

int cam_grab(cam_t *c, int timeout_ms, const uint8_t **data)
{
    struct pollfd p;
    int           got = -1, r;

    /*  The frame the caller was holding goes back to the camera first. */
    if (c->held >= 0) {
        qbuf(c, (unsigned)c->held);
        c->held = -1;
    }

    p.fd      = c->fd;
    p.events  = POLLIN;
    p.revents = 0;
    r = poll(&p, 1, timeout_ms);
    if (r < 0)
        return errno == EINTR ? 0 : -1;
    if (r == 0)
        return 0;

    /*  Take everything that is ready; keep the newest. */
    for (;;) {
        struct v4l2_buffer b;

        memset(&b, 0, sizeof b);
        b.type   = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        b.memory = V4L2_MEMORY_MMAP;
        if (xioctl(c->fd, VIDIOC_DQBUF, &b) < 0) {
            if (errno == EAGAIN)
                break;
            if (got >= 0)
                break;               /* keep what we have */
            return -1;
        }
        /*  UVC flags a frame whose USB transfer was incomplete; using it
         *  would classify a picture with a torn bottom. */
        if ((b.flags & V4L2_BUF_FLAG_ERROR) ||
            (b.bytesused != 0u && b.bytesused < (size_t)c->stride * c->h)) {
            qbuf(c, b.index);
            continue;
        }
        if (got >= 0)
            qbuf(c, (unsigned)got);
        got = (int)b.index;
    }
    if (got < 0)
        return 0;
    c->held = got;
    *data   = (const uint8_t *)c->buf[got];
    return 1;
}

void cam_close(cam_t *c)
{
    unsigned i;

    if (c->fd >= 0 && c->streaming) {
        enum v4l2_buf_type t = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        (void)xioctl(c->fd, VIDIOC_STREAMOFF, &t);
    }
    for (i = 0; i < c->nbuf; i++)
        if (c->buf[i] != NULL)
            munmap(c->buf[i], c->len[i]);
    if (c->fd >= 0)
        close(c->fd);
    memset(c, 0, sizeof *c);
    c->fd   = -1;
    c->held = -1;
}

int cam_list(const char *dev, FILE *out)
{
    struct v4l2_capability cap;
    struct v4l2_fmtdesc    fd;
    int fdv = open(dev, O_RDWR | O_NONBLOCK);

    if (fdv < 0) {
        fprintf(out, "%s: %s\n", dev, strerror(errno));
        return -1;
    }
    if (xioctl(fdv, VIDIOC_QUERYCAP, &cap) == 0)
        fprintf(out, "%s: %s (driver %s, %s)\n", dev, (const char *)cap.card,
                (const char *)cap.driver, (const char *)cap.bus_info);

    memset(&fd, 0, sizeof fd);
    fd.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    for (fd.index = 0; xioctl(fdv, VIDIOC_ENUM_FMT, &fd) == 0; fd.index++) {
        struct v4l2_frmsizeenum fs;
        char cc[5];
        int  usable = fd.pixelformat == V4L2_PIX_FMT_YUYV ||
                      fd.pixelformat == V4L2_PIX_FMT_UYVY;

        fourcc_str(fd.pixelformat, cc);
        fprintf(out, "  %s  %-28s %s\n", cc, (const char *)fd.description,
                usable ? "<- vinecam uses this" : "");

        memset(&fs, 0, sizeof fs);
        fs.pixel_format = fd.pixelformat;
        for (fs.index = 0; xioctl(fdv, VIDIOC_ENUM_FRAMESIZES, &fs) == 0; fs.index++) {
            if (fs.type == V4L2_FRMSIZE_TYPE_DISCRETE) {
                struct v4l2_frmivalenum fi;
                fprintf(out, "        %4ux%-4u", fs.discrete.width, fs.discrete.height);
                memset(&fi, 0, sizeof fi);
                fi.pixel_format = fd.pixelformat;
                fi.width        = fs.discrete.width;
                fi.height       = fs.discrete.height;
                for (fi.index = 0; xioctl(fdv, VIDIOC_ENUM_FRAMEINTERVALS, &fi) == 0;
                     fi.index++)
                    if (fi.type == V4L2_FRMIVAL_TYPE_DISCRETE && fi.discrete.numerator)
                        fprintf(out, "  %u fps", fi.discrete.denominator /
                                                 fi.discrete.numerator);
                fprintf(out, "\n");
            } else {
                fprintf(out, "        %ux%u to %ux%u\n",
                        fs.stepwise.min_width, fs.stepwise.min_height,
                        fs.stepwise.max_width, fs.stepwise.max_height);
                break;
            }
        }
    }
    close(fdv);
    return 0;
}

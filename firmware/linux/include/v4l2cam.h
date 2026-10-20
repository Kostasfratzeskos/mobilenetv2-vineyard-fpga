/*============================================================================
 *  v4l2cam.h  -  a UVC webcam through Video4Linux2, newest frame first
 *
 *  Any USB webcam that needs no driver of its own is a UVC device, and Linux
 *  exposes it as /dev/videoN. This asks it for packed YUV 4:2:2 (YUYV, or UYVY
 *  as a fallback) - the one format every UVC camera offers uncompressed, and
 *  the one camfront converts - and streams through mmap'd buffers.
 *
 *  ---- why cam_grab drains the queue -------------------------------------
 *
 *  The camera fills buffers at its own rate (30 fps) whether or not anyone is
 *  reading. If the application takes longer than a frame period per frame,
 *  a plain DQBUF hands back the OLDEST waiting buffer, and the picture on the
 *  screen falls further and further behind the leaf in front of the lens - by
 *  up to the number of buffers times the processing time. For a live demo that
 *  lag reads as "the classifier is slow to react", when it is a queue.
 *  cam_grab takes everything that is ready, keeps the newest, and gives the
 *  rest straight back.
 *
 *  MJPEG-only cameras are refused with a list of what they do offer (`vinecam
 *  --list`): decoding JPEG would put a second decoder - and a second source of
 *  colour differences - in front of the classifier, for no gain at 640x480,
 *  where every UVC camera also offers YUYV.
 *==========================================================================*/
#ifndef V4L2CAM_H
#define V4L2CAM_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#define CAM_NBUF 4

typedef struct {
    int       fd;
    unsigned  w, h;            /* what the camera actually agreed to         */
    unsigned  stride;          /* bytes per line, >= 2 * w                   */
    int       uyvy;            /* byte order: 0 = YUYV, 1 = UYVY             */
    unsigned  nbuf;
    void     *buf[CAM_NBUF];
    size_t    len[CAM_NBUF];
    int       held;            /* the buffer the caller holds, or -1         */
    int       streaming;
    char      card[64];        /* the camera's own name, for the screen      */
} cam_t;

/*  Open and configure. The size is a request: the camera picks its nearest,
 *  and c->w, c->h say what it picked. 0, or -1 with the reason in err. */
int  cam_open(cam_t *c, const char *dev, unsigned w, unsigned h,
              char *err, size_t errlen);

/*  Every format and size the camera offers, to `out`. 0, or -1. */
int  cam_list(const char *dev, FILE *out);

int  cam_start(cam_t *c, char *err, size_t errlen);

/*  The newest complete frame, waiting up to timeout_ms for one. 1 with *data
 *  pointing at stride * h bytes of YUV, 0 on timeout, -1 on error. The frame
 *  stays valid until the next cam_grab or cam_close. */
int  cam_grab(cam_t *c, int timeout_ms, const uint8_t **data);

void cam_close(cam_t *c);

#endif /* V4L2CAM_H */

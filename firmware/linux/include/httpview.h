/*============================================================================
 *  httpview.h  -  the same screen, in a browser on the presenting laptop
 *
 *  `vinecam --http 8080` serves two things on the board's Ethernet port:
 *
 *      /            a page that shows the picture full-window and refreshes it
 *      /frame.bmp   the current screen, half size if it is wider than 1280
 *
 *  It exists for the talk, not for the engineering. The board's own output is
 *  DisplayPort, a projector usually wants HDMI from the laptop that has the
 *  slides, and a DisplayPort-to-HDMI adapter for this board must be an ACTIVE
 *  one. A browser window on the laptop needs only an Ethernet cable, and is
 *  one Alt-Tab away from the slides.
 *
 *  BMP rather than JPEG or PNG because it needs no encoder: a 54-byte header
 *  and the pixels. At 960x540 that is 1.5 MB a frame, about 13 ms on the
 *  board's gigabit port. The server is one thread, answers one request at a
 *  time, serves only those two paths, and never blocks the camera loop: the
 *  loop hands it a snapshot under a mutex, and only while someone is watching.
 *==========================================================================*/
#ifndef HTTPVIEW_H
#define HTTPVIEW_H

#include <stddef.h>

#include "canvas.h"

typedef struct httpview httpview_t;

/*  NULL, with the reason in err, if the port cannot be opened. */
httpview_t *httpview_start(int port, char *err, size_t errlen);

/*  Offer the current screen. Cheap when nobody has asked for a frame in the
 *  last two seconds, and rate-limited to about 15 snapshots a second. */
void        httpview_publish(httpview_t *h, const canvas_t *cv);

void        httpview_stop(httpview_t *h);

#endif /* HTTPVIEW_H */

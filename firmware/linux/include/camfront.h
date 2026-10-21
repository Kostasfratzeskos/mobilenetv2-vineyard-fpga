/*============================================================================
 *  camfront.h  -  a camera frame into the 256x256 window preproc_rgb takes
 *
 *  The camera path's front end, in the order it runs:
 *
 *      camfront_yuv422_to_rgb   the camera's YUYV (or UYVY) into RGB888
 *      camfront_window          torchvision's Resize(256), evaluated only on
 *                               the 256x256 window whose centre 224x224 is
 *                               CenterCrop(224) - BIT-EXACT against Pillow
 *
 *  and then firmware/src/preproc.c, unchanged: it crops the centre 224 of that
 *  window at offset 16 and quantises, bit-exactly (DD-033).
 *
 *  ---- why this exists: the gap DD-033 left open on purpose --------------
 *
 *  preproc_rgb REFUSES anything that is not 256x256, because the reference
 *  pipeline (predict.py, export.py) is
 *
 *      Resize(256) -> CenterCrop(224) -> ToTensor -> Normalize
 *
 *  and for a 256x256 dataset image Resize(256) is the identity. A camera frame
 *  is 640x480 or 1280x720, where Resize(256) is Pillow's antialiased BILINEAR
 *  resampler - a filter whose support grows with the reduction ratio. DD-033
 *  named "a full Pillow-compatible resampler" as the extension point if a camera
 *  were ever fitted. This is that resampler.
 *
 *  It is a transcription of Pillow's libImaging/Resample.c for 8-bit RGB and the
 *  BILINEAR filter: the same double-precision coefficient computation, the same
 *  22-bit fixed-point normalisation, the same horizontal-then-vertical order with
 *  the intermediate rounded to uint8, and the same decision to skip a pass whose
 *  size does not change. firmware/linux/test/test_camfront.c checks it against
 *  vectors that scripts/gen_camfront_vectors.py makes with the real torchvision
 *  and Pillow, on twelve frame sizes including every common webcam one.
 *
 *  ---- the window, and why it is enough ----------------------------------
 *
 *  torchvision resizes the SHORT side to 256: 640x480 becomes 341x256. Then
 *  CenterCrop(224) takes its centre, at offsets round((341-224)/2) = 58 (Python's
 *  round: half to EVEN, so 58.5 is 58, not 59) and 16. preproc_rgb crops at 16 in
 *  both axes, so this hands it the 256x256 window starting 16 earlier: (42, 0).
 *  Its centre is then exactly torchvision's crop.
 *
 *  Only the window's outputs are computed. In Pillow each output pixel depends on
 *  its own coefficients - which come from the FULL geometry - and on the source
 *  pixels under them, never on its neighbours' results, so computing a window of
 *  the output is bit-identical to computing all of it and cropping. It is also
 *  a quarter less work, which matters on an A53 at camera rate.
 *
 *  ---- what is NOT claimed ------------------------------------------------
 *
 *  The YUV to RGB conversion. There is no reference to be exact against: the
 *  training images were JPEGs, and the camera's YUV is the camera's. It is the
 *  camera path's equivalent of the JPEG decode on the file path - one named,
 *  bounded step outside the bit-exact chain. The formula is BT.601 limited range
 *  in OpenCV's integer form, so a PC can reproduce it, but nothing depends on
 *  that: a dumped frame is saved AFTER the conversion (see vinecam.c), and the
 *  PC check starts from those RGB bytes.
 *
 *  Run: cd firmware/linux && make test
 *==========================================================================*/
#ifndef CAMFRONT_H
#define CAMFRONT_H

#include <stddef.h>
#include <stdint.h>

#include "quant_params.h"

/*  predict.py's transforms.Resize(int(round(img_size * 256 / 224))). With the
 *  224 crop that is 256, and it is a coincidence worth stating: it is NOT
 *  QP_SRC_SIZE, which is the size of the dataset's images. The two happen to be
 *  equal, which is the only reason the window below can be handed to
 *  preproc_rgb unchanged - so it is asserted in camfront.c, not assumed. */
#define CAMFRONT_RESIZE      256u

/*  The window handed to preproc_rgb: exactly what it accepts. */
#define CAMFRONT_WIN         QP_SRC_SIZE
#define CAMFRONT_WIN_BYTES   ((size_t)CAMFRONT_WIN * CAMFRONT_WIN * QP_CHANNELS)

/*  Large enough for any UVC camera; small enough that a garbage size from a
 *  driver is refused instead of allocated. */
#define CAMFRONT_MAX_SIDE    4096u

typedef struct {
    unsigned src_w, src_h;      /* the camera frame                            */
    unsigned rs_w, rs_h;        /* Resize(256)'s output: short side 256        */
    unsigned crop_x, crop_y;    /* CenterCrop(224)'s offset in the resized one */
    unsigned win_x, win_y;      /* the window: the crop, 16 earlier            */
} camfront_geom_t;

/*  One axis of the resampler, precomputed. Pillow's `bounds` and `kk`. */
typedef struct {
    int       needed;           /* 0 when in == out: Pillow skips the pass     */
    unsigned  n;                /* outputs covered (the window's side)         */
    unsigned  ksize;            /* coefficient slots per output                */
    int      *lo;               /* first input sample of each output (xmin)    */
    int      *cnt;              /* taps of each output (xmax - xmin)           */
    int32_t  *k;                /* n * ksize, fixed point, 22 fractional bits  */
} camfront_axis_t;

typedef struct {
    camfront_geom_t g;
    camfront_axis_t hx;         /* columns: src_w -> rs_w, window win_x..+256  */
    camfront_axis_t vy;         /* rows:    src_h -> rs_h, window win_y..+256  */
    unsigned  tmp_y0;           /* source rows the horizontal pass produces    */
    unsigned  tmp_rows;
    uint8_t  *tmp;              /* tmp_rows x CAMFRONT_WIN x 3                 */
} camfront_t;

/*  torchvision's Resize(256) + CenterCrop(224) geometry for a w x h frame, with
 *  torchvision's own arithmetic: int(256 * long / short) for the long side, and
 *  Python's half-to-even round for the crop offsets. -1 for an unusable size. */
int  camfront_geometry(unsigned w, unsigned h, camfront_geom_t *g);

/*  Precompute everything for one frame size: done once per camera, not per
 *  frame. 0 on success, -1 on a bad size or no memory. */
int  camfront_init(camfront_t *cf, unsigned w, unsigned h);
void camfront_free(camfront_t *cf);

/*  The window of Pillow's BILINEAR resize of `rgb` (src_w x src_h, HWC, rows
 *  `stride` bytes apart) to rs_w x rs_h. `out` is CAMFRONT_WIN_BYTES, HWC -
 *  exactly preproc_rgb's input. */
void camfront_window(const camfront_t *cf, const uint8_t *rgb, size_t stride,
                     uint8_t *out);

/*  The network's 224x224 input as a rectangle of the ORIGINAL frame - x0, y0,
 *  x1, y1, half-open, rounded outwards - for the screen to outline. Display
 *  only: nothing is computed from it. */
void camfront_crop_rect(const camfront_geom_t *g, int r[4]);

/*  Packed 4:2:2 into RGB888, BT.601 limited range, OpenCV's integer constants.
 *  `uyvy` selects U-Y0-V-Y1 byte order; otherwise Y0-U-Y1-V (YUYV). w must be
 *  even, which V4L2 guarantees for both formats. */
void camfront_yuv422_to_rgb(const uint8_t *src, size_t stride,
                            unsigned w, unsigned h, int uyvy, uint8_t *rgb);

#endif /* CAMFRONT_H */

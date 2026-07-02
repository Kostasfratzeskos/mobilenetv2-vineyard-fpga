#ifndef MOBILENET_H
#define MOBILENET_H

#include <stdint.h>
#include <stddef.h>

/* =====================================================================
 *  MobileNetV2 - integer (int8) inference reference, in C
 *
 *  Purpose: a software twin of the FPGA accelerator. INFERENCE ONLY.
 *  All learnable parameters are loaded already-quantized.
 *
 *  Validation order (chain of trust):
 *    1) first goal : bit-exact match with the Python IntExecutor
 *    2) then       : serve as the golden oracle for the RTL
 *
 *  Numeric scheme (mirrors the hardware):
 *    - symmetric int8 everywhere  =>  every zero-point is 0
 *      (so the convolution inner loop has NO zero-point terms)
 *    - activations / weights : int8
 *    - convolution accumulator : int32 here in C.
 *        (the HW uses a 21-bit signed accumulator, sized so it never
 *         overflows; while it does not overflow, int32 and 21-bit agree
 *         bit-for-bit, so this reference stays valid.)
 *    - requantize : multiply by M0 (int32 fixed-point) + right shift
 *                   (Jacob et al. 2018 / gemmlowp scheme)
 *
 *  Memory layout: NHWC internally - matches the HW stream order, where
 *    the channels of one pixel are contiguous (exactly the vector the
 *    1x1 conv accumulates over). The per-layer golden vectors come from
 *    the IntExecutor and are almost certainly NCHW, so we permute
 *    NHWC->NCHW only at the dump/compare boundary (see dump_layer_i8).
 * ===================================================================== */


/* ---------- Tensors -------------------------------------------------
 * Two element types, because the data path is:  i8 (*) i8 -> i32 ,
 * then requantize: i32 -> i8. Making the int32 stage explicit is the
 * whole point - it is where bias-add and requantize happen.          */

typedef struct {
    int8_t *data;      /* length = h*w*c, NHWC order */
    int     h, w, c;
} tensor_i8;

typedef struct {
    int32_t *data;     /* length = h*w*c, NHWC order */
    int      h, w, c;
} tensor_i32;


/* ---------- Per-layer requantize parameters ------------------------
 * requantized = requant(acc):  acc is int32, result is int8.
 * OPEN (confirm from manifest.json): whether M0/shift are one scalar
 * per layer (per-tensor) or one value per output channel (per-channel).
 * Modeled as pointers + len so either works; resolved at load time.  */

typedef struct {
    const int32_t *m0;     /* fixed-point multiplier(s) */
    const int32_t *shift;  /* right-shift amount(s)     */
    int            len;    /* 1 (per-tensor) or out_c (per-channel) */
} requant_params;


/* ---------- Op kinds the controller can dispatch -------------------
 * This small set is the ENTIRE network. It maps 1:1 to the hardware
 * engines - that 1:1 mapping is the reason we chose this structure.  */

typedef enum {
    OP_CONV3x3_STD,   /* stem only: standard 3x3 conv, Cin=3            */
    OP_CONV1x1,       /* pointwise conv (expand / project / classifier) */
    OP_DWCONV3x3,     /* depthwise 3x3 conv                             */
    OP_BIAS_ADD,      /* add int32 bias (per output channel)            */
    OP_REQUANTIZE,    /* i32 -> i8 ; activation flag picks ReLU6/linear */
    OP_RESIDUAL_ADD,  /* i8 + i8 -> i8, with integer-scale alignment    */
    OP_AVGPOOL        /* global average pool: HxWxC -> 1x1xC            */
} op_type;

/* activation fused into a requantize step */
typedef enum {
    ACT_NONE,         /* linear bottleneck / classifier logits */
    ACT_RELU6
} activation;


/* ---------- One entry of the manifest ------------------------------
 * PROVISIONAL schema - to be reconciled with the real manifest.json
 * fields when we implement load_model().                             */

typedef struct {
    op_type op;

    /* shapes */
    int in_h,  in_w,  in_c;
    int out_h, out_w, out_c;

    /* conv geometry (ignored by non-conv ops) */
    int kernel;   /* 1 or 3 */
    int stride;   /* 1 or 2 */
    int pad;

    /* parameters for this layer (NULL when not applicable).
     * convs: weights are int8, bias is int32.                        */
    const int8_t  *weights;
    const int32_t *bias;
    requant_params requant;
    activation     act;

    /* residual bookkeeping: index of the earlier layer whose i8 output
     * is the second addend, or -1 if this layer has no residual.      */
    int residual_src;
} layer_config;


/* ---------- The whole model ----------------------------------------*/

typedef struct {
    layer_config *layers;
    int           num_layers;

    /* opaque handle to the backing parameter storage (the buffers the
     * weight/bias/M0/shift pointers point into). Filled by load_model,
     * freed by free_model. Whether it was read from the exported
     * artifacts at runtime or baked into headers does not change
     * anything above this line.                                       */
    void *param_store;
} model;


/* ---------- The four classes ---------------------------------------*/

enum { CLASS_BLACK_ROT, CLASS_ESCA, CLASS_HEALTHY, CLASS_LEAF_BLIGHT, NUM_CLASSES };
extern const char *const CLASS_NAMES[NUM_CLASSES];


/* =====================================================================
 *  Engines - the leaves. Bodies are stubbed for now; we fill them in
 *  one at a time, each validated against its golden vector.
 *
 *  Convention: convs WRITE int32 (no bias, no requant inside).
 *  bias-add and requantize are SEPARATE steps, matching the HW engines.
 * ===================================================================== */

void conv3x3_std (const tensor_i8 *in, const int8_t *w, const layer_config *cfg, tensor_i32 *out);
void conv1x1     (const tensor_i8 *in, const int8_t *w, const layer_config *cfg, tensor_i32 *out);
void dwconv3x3   (const tensor_i8 *in, const int8_t *w, const layer_config *cfg, tensor_i32 *out);

void bias_add    (tensor_i32 *acc, const int32_t *bias);

void requantize  (const tensor_i32 *acc, const requant_params *rq, activation act, int relu6_qmax, tensor_i8 *out);

void residual_add(const tensor_i8 *a, const tensor_i8 *b, tensor_i8 *out);

void avgpool     (const tensor_i8 *in, tensor_i8 *out);


/* =====================================================================
 *  Model lifecycle + controller + helpers
 * ===================================================================== */

int  load_model (const char *path, model *m);   /* returns 0 on success */
void free_model (model *m);

/* the controller: walks m->layers and dispatches to the engines.
 * `input`  is already int8, NHWC, in the network's input scale.
 * `logits` receives the 1x1xNUM_CLASSES int8 logits.                 */
void run_inference(const model *m, const tensor_i8 *input, tensor_i8 *logits);

int  argmax_i8(const tensor_i8 *logits);

/* validation hook: dump a layer's i8 output (permuted NHWC->NCHW) so it
 * can be diffed against the per-layer golden vector.                 */
void dump_layer_i8(int layer_idx, const tensor_i8 *t);

#endif /* MOBILENET_H */

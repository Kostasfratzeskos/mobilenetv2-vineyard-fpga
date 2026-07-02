#include <stdio.h>
#include <stdlib.h>

#include "mobilenet.h"
#include "requantize.h"

const char *const CLASS_NAMES[NUM_CLASSES] = {
    "black_rot", "esca", "healthy", "leaf_blight"
};


/* ====================================================================
 *  Engines - STUBS.
 *  Each one is a future implementation step; we do them one at a time
 *  and validate against the golden vectors. For now they only let the
 *  program compile and the control flow run end-to-end.
 * ==================================================================== */

void conv3x3_std(const tensor_i8 *in, const int8_t *w,
                 const layer_config *cfg, tensor_i32 *out) {
    (void)in; (void)w; (void)cfg; (void)out;
    /* TODO: standard 3x3 conv, Cin=3, NHWC, accumulate int8*int8 -> int32.
     *       symmetric quant => no zero-point terms. */
}

void conv1x1(const tensor_i8 *in, const int8_t *w,
             const layer_config *cfg, tensor_i32 *out) {
    (void)in; (void)w; (void)cfg; (void)out;
    /* TODO: pointwise conv. For each output pixel, dot product over the
     *       contiguous in_c channels (this is why NHWC is convenient). */
}

void dwconv3x3(const tensor_i8 *in, const int8_t *w,
               const layer_config *cfg, tensor_i32 *out) {
    (void)in; (void)w; (void)cfg; (void)out;
    /* TODO: depthwise 3x3 - one independent 3x3 kernel per channel. */
}

void bias_add(tensor_i32 *acc, const int32_t *bias) {
    (void)acc; (void)bias;
    /* TODO: acc[.,.,k] += bias[k]  (int32). */
}

void requantize(const tensor_i32 *acc, const requant_params *rq,
                activation act, int relu6_qmax, tensor_i8 *out) {
    (void)acc; (void)rq; (void)act; (void)out;

    const int C = acc->c;
    const int n = acc->h * acc->w * acc->c;

    for(int i = 0; i < n; ++i) {
        int c = i % C;                      // NHWC: channell = faster 
        int idx = (rq->len == 1) ? 0 : c;   // Per tensor (res-add gap) vs per channel (conv)
        out->data[i] = requantize_elem(acc->data[i], rq->m0[idx], 
                                      (int)rq->shift[idx], act, relu6_qmax);
    }
}

void residual_add(const tensor_i8 *a, const tensor_i8 *b, tensor_i8 *out) {
    (void)a; (void)b; (void)out;
    /* TODO: integer add. The two inputs live in DIFFERENT scales, so we
     *       must align them (requant one onto the other's scale) before
     *       adding, then requantize the sum to the output scale. */
}

void avgpool(const tensor_i8 *in, tensor_i8 *out) {
    (void)in; (void)out;
    /* TODO: global average over HxW per channel, with requantize. */
}


/* ====================================================================
 *  Model lifecycle - STUBS for now (no manifest parsing yet).
 * ==================================================================== */

int load_model(const char *path, model *m) {
    (void)path;
    /* TODO: read manifest.json + the hex weight/bias/M0/shift artifacts,
     *       allocate param_store, fill m->layers / m->num_layers.
     *       (Runtime-from-artifacts vs baked headers is decided here -
     *        it does not affect any of the structures above.)          */
    m->layers      = NULL;
    m->num_layers  = 0;
    m->param_store = NULL;
    return 0;
}

void free_model(model *m) {
    if (!m) return;
    free(m->layers);
    free(m->param_store);
    m->layers      = NULL;
    m->num_layers  = 0;
    m->param_store = NULL;
}


/* ====================================================================
 *  Controller - this IS implemented (it is the "general idea").
 *  It owns the working buffers and sequences the engines per layer.
 * ==================================================================== */

void run_inference(const model *m, const tensor_i8 *input, tensor_i8 *logits) {
    /* Buffer strategy (kept abstract in the skeleton): a couple of i8
     * ping-pong feature-map buffers + one i32 accumulator scratch, each
     * sized to the largest layer. We wire real buffers when the engines
     * exist. For now the loop shows the dispatch SHAPE.                */

    const tensor_i8 *cur = input;   /* current feature map */
    (void)logits;                   /* filled once the engines exist (see end) */

    for (int i = 0; i < m->num_layers; ++i) {
        const layer_config *L = &m->layers[i];

        switch (L->op) {

        case OP_CONV3x3_STD:
        case OP_CONV1x1:
        case OP_DWCONV3x3:
            /* conv -> int32 acc ; (+bias) ; requant(+act) -> int8 out
             *
             *   tensor_i32 acc = <scratch sized out_h*out_w*out_c>;
             *   tensor_i8  out = <next ping-pong buffer>;
             *
             *   if      (L->op == OP_CONV3x3_STD) conv3x3_std(cur, L->weights, L, &acc);
             *   else if (L->op == OP_CONV1x1)     conv1x1   (cur, L->weights, L, &acc);
             *   else                              dwconv3x3 (cur, L->weights, L, &acc);
             *
             *   if (L->bias) bias_add(&acc, L->bias);
             *   requantize(&acc, &L->requant, L->act, &out);
             *   cur = &out;                                            */
            break;

        case OP_RESIDUAL_ADD:
            /* second addend is the saved output of layer L->residual_src
             *   residual_add(cur, saved[L->residual_src], &out);
             *   cur = &out;                                            */
            break;

        case OP_AVGPOOL:
            /*   avgpool(cur, &out);  cur = &out;                       */
            break;

        case OP_BIAS_ADD:
        case OP_REQUANTIZE:
            /* present as standalone op kinds for completeness; in this
             * controller they are sequenced inside the conv cases.     */
            break;
        }

        /* validation hook (off by default):
         *   dump_layer_i8(i, cur);                                     */
    }

    /* copy the final 1x1xNUM_CLASSES feature map out as the logits */
    (void)cur;
    /* TODO: logits <- cur  (the last layer's int8 output) */
}

int argmax_i8(const tensor_i8 *logits) {
    int    best  = 0;
    int8_t bestv = (logits->data) ? logits->data[0] : 0;
    for (int k = 1; k < logits->c; ++k) {
        if (logits->data && logits->data[k] > bestv) {
            bestv = logits->data[k];
            best  = k;
        }
    }
    return best;
}

void dump_layer_i8(int layer_idx, const tensor_i8 *t) {
    (void)layer_idx; (void)t;
    /* TODO: permute NHWC->NCHW and write to file for golden diff. */
}

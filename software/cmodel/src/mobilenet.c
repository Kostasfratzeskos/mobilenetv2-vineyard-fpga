#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mobilenet.h"
#include "requantize.h"
#include "json.h"
#include "hexio.h"

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
    const int C  = in->c;                 /* input channels  (3 for the stem) */
    const int H  = in->h,  W  = in->w;
    const int OC = out->c;                /* output channels                  */
    const int OH = out->h, OW = out->w;
    const int K  = cfg->kernel;           /* 3                                */
    const int S  = cfg->stride;
    const int P  = cfg->pad;

    for (int oy = 0; oy < OH; ++oy) {
        for (int ox = 0; ox < OW; ++ox) {
            for (int oc = 0; oc < OC; ++oc) {
                int32_t acc = 0;
                for (int ky = 0; ky < K; ++ky) {
                    int iy = oy * S - P + ky;
                    if (iy < 0 || iy >= H) continue;              /* zero pad */
                    for (int kx = 0; kx < K; ++kx) {
                        int ix = ox * S - P + kx;
                        if (ix < 0 || ix >= W) continue;          /* zero pad */
                        for (int ic = 0; ic < C; ++ic) {
                            int8_t a = in->data[(iy * W + ix) * C + ic];
                            int8_t g = w[((oc * C + ic) * K + ky) * K + kx];
                            acc += (int32_t)a * (int32_t)g;       /* i8*i8 -> i32 */
                        }
                    }
                }
                out->data[(oy * OW + ox) * OC + oc] = acc;
            }
        }
    }
}

void conv1x1(const tensor_i8 *in, const int8_t *w,
             const layer_config *cfg, tensor_i32 *out) {
    const int C  = in->c;                 /* input channels                   */
    const int OC = out->c;
    const int OH = out->h, OW = out->w;
    const int W  = in->w;
    const int S  = cfg->stride;           /* 1 for every 1x1 in the network   */
    const int P  = cfg->pad;              /* 0                                */

    for (int oy = 0; oy < OH; ++oy) {
        for (int ox = 0; ox < OW; ++ox) {
            const int8_t *pin = &in->data[((oy * S - P) * W + (ox * S - P)) * C];
            for (int oc = 0; oc < OC; ++oc) {
                const int8_t *pw = &w[oc * C];        /* (OC,IC) weight row   */
                int32_t acc = 0;
                for (int ic = 0; ic < C; ++ic)
                    acc += (int32_t)pin[ic] * (int32_t)pw[ic];
                out->data[(oy * OW + ox) * OC + oc] = acc;
            }
        }
    }
}

void dwconv3x3(const tensor_i8 *in, const int8_t *w,
               const layer_config *cfg, tensor_i32 *out) {
    const int C  = in->c;                 /* depthwise => OC == C, no ic sum  */
    const int H  = in->h,  W  = in->w;
    const int OH = out->h, OW = out->w;
    const int K  = cfg->kernel;           /* 3                                */
    const int S  = cfg->stride;
    const int P  = cfg->pad;

    for (int oy = 0; oy < OH; ++oy) {
        for (int ox = 0; ox < OW; ++ox) {
            for (int c = 0; c < C; ++c) {
                int32_t acc = 0;
                for (int ky = 0; ky < K; ++ky) {
                    int iy = oy * S - P + ky;
                    if (iy < 0 || iy >= H) continue;              /* zero pad */
                    for (int kx = 0; kx < K; ++kx) {
                        int ix = ox * S - P + kx;
                        if (ix < 0 || ix >= W) continue;          /* zero pad */
                        int8_t a = in->data[(iy * W + ix) * C + c];
                        int8_t g = w[(c * K + ky) * K + kx];      /* (C,1,K,K) */
                        acc += (int32_t)a * (int32_t)g;
                    }
                }
                out->data[(oy * OW + ox) * C + c] = acc;
            }
        }
    }
}

void bias_add(tensor_i32 *acc, const int32_t *bias) {
    const int C = acc->c;                 /* NHWC: channel index = i % C */
    const int n = acc->h * acc->w * acc->c;
    for (int i = 0; i < n; ++i) acc->data[i] += bias[i % C];
}

void requantize(const tensor_i32 *acc, const requant_params *rq,
                activation act, int relu6_qmax, tensor_i8 *out) {
    const int C = acc->c;
    const int n = acc->h * acc->w * acc->c;

    for(int i = 0; i < n; ++i) {
        int c = i % C;                      // NHWC: channel = faster
        int idx = (rq->len == 1) ? 0 : c;   // per-tensor (res-add gap) vs per-channel (conv)
        out->data[i] = requantize_elem(acc->data[i], rq->m0[idx],
                                      (int)rq->shift[idx], act, relu6_qmax);
    }
}

void residual_add(const tensor_i8 *target, const tensor_i8 *saved,
                  int32_t m0, int shift, tensor_i8 *out) {
    (void)target; (void)saved; (void)m0; (void)shift; (void)out;
    /* TODO: rescale `saved` onto target's scale via (saved*m0)>>shift,
     *       add to target (int), clamp to int8. */
}

void avgpool(const tensor_i8 *in, int32_t m0, int shift, tensor_i8 *out) {
    (void)in; (void)m0; (void)shift; (void)out;
    /* TODO: sum over HxW per channel -> int32, requantize with (m0,shift). */
}


/* ====================================================================
 *  Parameter storage: load_model owns a bag of malloc'd blocks (weights,
 *  bias, m0, shift). free_model releases them. The layer_config pointers
 *  point into these blocks.
 * ==================================================================== */

typedef struct {
    void **blocks;
    int    n, cap;
} pstore;

static void *pstore_add(pstore *ps, void *blk) {
    if (!blk) return NULL;
    if (ps->n == ps->cap) {
        ps->cap = ps->cap ? ps->cap * 2 : 32;
        ps->blocks = realloc(ps->blocks, (size_t)ps->cap * sizeof *ps->blocks);
    }
    ps->blocks[ps->n++] = blk;
    return blk;
}

static const int8_t *load_i8(pstore *ps, const char *dir, const char *fname, int n) {
    char path[512];
    snprintf(path, sizeof path, "%s/%s", dir, fname);
    int8_t *buf = malloc((size_t)n);
    if (!buf || hex_read_i8(path, buf, n) != n) { free(buf); return NULL; }
    return pstore_add(ps, buf);
}

static const int32_t *load_i32(pstore *ps, const char *dir, const char *fname, int n) {
    char path[512];
    snprintf(path, sizeof path, "%s/%s", dir, fname);
    int32_t *buf = malloc((size_t)n * sizeof *buf);
    if (!buf || hex_read_i32(path, buf, n) != n) { free(buf); return NULL; }
    return pstore_add(ps, buf);
}

static const int32_t *scalar_i32(pstore *ps, long v) {
    int32_t *p = malloc(sizeof *p);
    if (!p) return NULL;
    *p = (int32_t)v;
    return pstore_add(ps, p);
}


/* ====================================================================
 *  load_model - parse manifest.json into layer_config[].
 *
 *  Manifest op kinds map onto the engines like this:
 *    conv (3x3, groups=1)      -> OP_CONV3x3_STD   (the stem only)
 *    conv (3x3, groups=out_c)  -> OP_DWCONV3x3     (depthwise)
 *    conv (1x1) / linear       -> OP_CONV1x1       (expand/project/classifier)
 *    save                      -> not a layer; remembers the current
 *                                 tensor as a future residual addend
 *    res_add                   -> OP_RESIDUAL_ADD  (paired to a save by tag)
 *    gap                       -> OP_AVGPOOL
 *
 *  Spatial dims are propagated forward from the input size; channel/kernel
 *  come from weight_shape. m0/shift are per-output-channel for convs
 *  (loaded from files) and single scalars for res_add/gap (inline).
 * ==================================================================== */

int load_model(const char *dir, model *m) {
    m->layers = NULL; m->num_layers = 0; m->param_store = NULL;

    char mpath[512];
    snprintf(mpath, sizeof mpath, "%s/manifest.json", dir);
    json *root = json_parse_file(mpath);
    if (!root) { fprintf(stderr, "load_model: cannot parse %s\n", mpath); return 1; }

    const json *ops = json_get(root, "ops");
    int nops = json_len(ops);
    int img  = json_get_int(root, "img_size", 224);

    pstore *ps = calloc(1, sizeof *ps);
    layer_config *layers = calloc((size_t)nops, sizeof *layers);
    int nl = 0;

    /* save/res_add pairing: tag -> index of the layer whose output was saved */
    struct { int tag, idx; } saves[32];
    int nsaves = 0;

    int cur_c = 3, cur_h = img, cur_w = img;   /* network input */

    for (int i = 0; i < nops; i++) {
        const json *op   = json_at(ops, i);
        const char *kind = json_get_str(op, "kind");
        const char *name = json_get_str(op, "name");
        if (!kind) continue;

        if (!strcmp(kind, "save")) {
            saves[nsaves].tag = json_get_int(op, "tag", -1);
            saves[nsaves].idx = nl - 1;        /* current tensor = last layer's output */
            if (nsaves < (int)(sizeof saves / sizeof saves[0])) nsaves++;
            continue;                          /* not a compute layer */
        }

        layer_config *L = &layers[nl];
        snprintf(L->name, sizeof L->name, "%s", name ? name : "");
        L->residual_src = -1;
        L->in_h = cur_h; L->in_w = cur_w; L->in_c = cur_c;
        L->requant.len = 1;

        if (!strcmp(kind, "conv") || !strcmp(kind, "linear")) {
            const json *ws  = json_get(op, "weight_shape");
            int oc  = json_int(json_at(ws, 0));
            int icg = json_int(json_at(ws, 1));
            int k   = (json_len(ws) >= 4) ? json_int(json_at(ws, 2)) : 1;
            int groups = json_get_int(op, "groups", 1);
            int stride = 1, pad = 0;
            const json *st = json_get(op, "stride");  if (st) stride = json_int(json_at(st, 0));
            const json *pd = json_get(op, "padding"); if (pd) pad    = json_int(json_at(pd, 0));

            L->kernel = k; L->stride = stride; L->pad = pad; L->out_c = oc;
            if      (k == 3 && groups == 1)  L->op = OP_CONV3x3_STD;
            else if (k == 3 && groups == oc) L->op = OP_DWCONV3x3;
            else                             L->op = OP_CONV1x1;   /* 1x1 conv or classifier */

            L->out_h = (cur_h + 2 * pad - k) / stride + 1;
            L->out_w = (cur_w + 2 * pad - k) / stride + 1;

            const json *files = json_get(op, "files");
            int wcount = oc * icg * k * k;
            L->weights       = load_i8 (ps, dir, json_get_str(files, "w"),     wcount);
            L->bias          = load_i32(ps, dir, json_get_str(files, "b"),     oc);
            L->requant.m0    = load_i32(ps, dir, json_get_str(files, "m0"),    oc);
            L->requant.shift = load_i32(ps, dir, json_get_str(files, "shift"), oc);
            L->requant.len   = oc;
            L->act        = json_get_bool(op, "relu6", 0) ? ACT_RELU6 : ACT_NONE;
            L->relu6_qmax = json_get_int(op, "relu6_qmax", 127);

            if (!L->weights || !L->bias || !L->requant.m0 || !L->requant.shift) {
                fprintf(stderr, "load_model: missing params for %s\n", L->name);
                json_free(root);
                m->param_store = ps; m->layers = layers; m->num_layers = nl;
                free_model(m);
                return 1;
            }
        }
        else if (!strcmp(kind, "res_add")) {
            L->op = OP_RESIDUAL_ADD;
            L->out_h = cur_h; L->out_w = cur_w; L->out_c = cur_c;
            L->requant.m0    = scalar_i32(ps, json_get_long(op, "m0", 0));
            L->requant.shift = scalar_i32(ps, json_get_long(op, "shift", 0));
            L->act = ACT_NONE;
            int blk = -1;
            if (name) sscanf(name, "features.%d.add", &blk);
            for (int s = 0; s < nsaves; s++)
                if (saves[s].tag == blk) { L->residual_src = saves[s].idx; break; }
        }
        else if (!strcmp(kind, "gap")) {
            L->op = OP_AVGPOOL;
            L->out_h = 1; L->out_w = 1; L->out_c = cur_c;
            L->requant.m0    = scalar_i32(ps, json_get_long(op, "m0", 0));
            L->requant.shift = scalar_i32(ps, json_get_long(op, "shift", 0));
            L->act = ACT_NONE;
        }
        else {
            fprintf(stderr, "load_model: unknown op kind '%s'\n", kind);
            continue;
        }

        cur_h = L->out_h; cur_w = L->out_w; cur_c = L->out_c;
        nl++;
    }

    json_free(root);
    m->layers = layers;
    m->num_layers = nl;
    m->param_store = ps;
    return 0;
}

void free_model(model *m) {
    if (!m) return;
    pstore *ps = m->param_store;
    if (ps) {
        for (int i = 0; i < ps->n; i++) free(ps->blocks[i]);
        free(ps->blocks);
        free(ps);
    }
    free(m->layers);
    m->layers = NULL;
    m->num_layers = 0;
    m->param_store = NULL;
}


/* ====================================================================
 *  Controller. Owns per-layer output buffers (so residual sources stay
 *  live and every layer can be dumped) plus one int32 accumulator
 *  scratch sized to the largest layer. Dispatches to the engines; with
 *  the engines stubbed, layers produce zeros - so a golden diff on any
 *  not-yet-implemented layer simply reports a mismatch. That is the
 *  point: implement one engine, watch one more layer go green.
 * ==================================================================== */

void run_inference(const model *m, const tensor_i8 *input, tensor_i8 *logits,
                   const char *dump_dir) {
    int nl = m->num_layers;
    if (nl == 0) return;

    int8_t **out = calloc((size_t)nl, sizeof *out);
    long maxsz = 0;
    for (int i = 0; i < nl; i++) {
        long s = (long)m->layers[i].out_h * m->layers[i].out_w * m->layers[i].out_c;
        if (s > maxsz) maxsz = s;
    }
    int32_t *acc = malloc((size_t)maxsz * sizeof *acc);

    tensor_i8 curbuf;
    const tensor_i8 *cur = input;

    for (int i = 0; i < nl; i++) {
        const layer_config *L = &m->layers[i];
        long osz = (long)L->out_h * L->out_w * L->out_c;
        out[i] = calloc((size_t)osz, 1);

        tensor_i8  o = { out[i], L->out_h, L->out_w, L->out_c };
        tensor_i32 a = { acc,    L->out_h, L->out_w, L->out_c };

        switch (L->op) {
        case OP_CONV3x3_STD:
        case OP_CONV1x1:
        case OP_DWCONV3x3:
            memset(acc, 0, (size_t)osz * sizeof *acc);
            if      (L->op == OP_CONV3x3_STD) conv3x3_std(cur, L->weights, L, &a);
            else if (L->op == OP_CONV1x1)     conv1x1   (cur, L->weights, L, &a);
            else                              dwconv3x3 (cur, L->weights, L, &a);
            if (L->bias) bias_add(&a, L->bias);
            requantize(&a, &L->requant, L->act, L->relu6_qmax, &o);
            break;

        case OP_RESIDUAL_ADD:
            if (L->residual_src >= 0) {
                tensor_i8 saved = { out[L->residual_src], L->out_h, L->out_w, L->out_c };
                residual_add(cur, &saved, L->requant.m0[0], (int)L->requant.shift[0], &o);
            }
            break;

        case OP_AVGPOOL:
            avgpool(cur, L->requant.m0[0], (int)L->requant.shift[0], &o);
            break;

        default:
            break;
        }

        if (dump_dir) {
            char p[512];
            snprintf(p, sizeof p, "%s/%s.hex", dump_dir, L->name);
            dump_layer_i8(p, &o);
        }

        curbuf = o;        /* stable storage for the next iteration's `cur` */
        cur = &curbuf;
    }

    /* logits <- last layer's output (classifier). NOTE: the real logits are
     * int16 (manifest logit_bits=16); this int8 copy is a placeholder until
     * the classifier tail is widened. */
    if (logits && logits->data) {
        int n = logits->c < m->layers[nl - 1].out_c ? logits->c : m->layers[nl - 1].out_c;
        memcpy(logits->data, out[nl - 1], (size_t)n);
    }

    for (int i = 0; i < nl; i++) free(out[i]);
    free(out);
    free(acc);
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

void dump_layer_i8(const char *path, const tensor_i8 *t) {
    hex_write_activation_nchw(path, t->data, t->c, t->h, t->w);
}

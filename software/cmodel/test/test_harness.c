/* Harness tests: the loader + the layout permute. These do NOT need any
 * engine implemented - they prove that load_model parses the manifest into
 * a sane layer table and that the NCHW<->NHWC round-trip is lossless, so a
 * later golden mismatch can be blamed on the engine, not the plumbing.
 *
 * Run from the cmodel/ directory (that is where `make test` runs it), so
 * the manifest/golden paths are relative to there.                        */
#include "../src/mobilenet.h"
#include "../src/hexio.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fails = 0;

static void check(int cond, const char *msg) {
    if (!cond) fails++;
    printf("  [%s] %s\n", cond ? "ok " : "ERR", msg);
}

#define MODEL_DIR  "../export"
#define GOLDEN_DIR "../golden/image_1"

/* find the first layer whose op matches */
static const layer_config *find_op(const model *m, op_type op) {
    for (int i = 0; i < m->num_layers; i++)
        if (m->layers[i].op == op) return &m->layers[i];
    return NULL;
}

static void test_loader(void) {
    printf("loader: parse %s/manifest.json\n", MODEL_DIR);
    model m;
    int rc = load_model(MODEL_DIR, &m);
    check(rc == 0, "load_model returns 0");
    if (rc != 0) return;

    /* 52 conv + 10 res_add + 1 gap + 1 linear = 64 compute layers (10 saves are not layers) */
    check(m.num_layers == 64, "num_layers == 64");

    const layer_config *L0 = &m.layers[0];
    check(strcmp(L0->name, "features.0.0") == 0, "layer 0 is features.0.0");
    check(L0->op == OP_CONV3x3_STD,             "layer 0 op is CONV3x3_STD");
    check(L0->in_c == 3 && L0->in_h == 224 && L0->in_w == 224, "layer 0 input 224x224x3");
    check(L0->out_c == 32 && L0->out_h == 112 && L0->out_w == 112, "layer 0 output 112x112x32");
    check(L0->requant.len == 32, "layer 0 requant is per-channel (len 32)");
    check(L0->act == ACT_RELU6, "layer 0 activation is ReLU6");

    check(find_op(&m, OP_DWCONV3x3) != NULL, "a depthwise layer exists");
    check(find_op(&m, OP_AVGPOOL)   != NULL, "an avgpool layer exists");

    const layer_config *LN = &m.layers[m.num_layers - 1];
    check(strcmp(LN->name, "classifier.1") == 0, "last layer is classifier.1");
    check(LN->op == OP_CONV1x1 && LN->out_c == NUM_CLASSES, "classifier is 1x1 -> 4 classes");

    const layer_config *R = find_op(&m, OP_RESIDUAL_ADD);
    check(R != NULL && R->residual_src >= 0, "residual add is paired to a saved layer");

    free_model(&m);
}

/* load the golden input as NHWC, dump it back as NCHW, and confirm the
 * bytes are identical to the original golden file. */
static void test_roundtrip(void) {
    printf("layout: NCHW->NHWC->NCHW identity on the input vector\n");
    const int C = 3, H = 224, W = 224, N = C * H * W;
    int8_t *nhwc = malloc((size_t)N);
    int8_t *orig = malloc((size_t)N);
    int8_t *back = malloc((size_t)N);

    int ok_in  = hex_read_activation_nhwc(GOLDEN_DIR "/000_input.hex", nhwc, C, H, W) == N;
    int ok_raw = hex_read_i8(GOLDEN_DIR "/000_input.hex", orig, N) == N;
    check(ok_in && ok_raw, "read 000_input.hex (150528 values)");

    hex_write_activation_nchw("build/_roundtrip.hex", nhwc, C, H, W);
    int ok_back = hex_read_i8("build/_roundtrip.hex", back, N) == N;
    check(ok_back, "dumped and re-read round-trip file");

    check(ok_in && ok_raw && ok_back && memcmp(orig, back, (size_t)N) == 0,
          "round-trip bytes == original golden bytes");

    free(nhwc); free(orig); free(back);
}

int main(void) {
    test_loader();
    printf("\n");
    test_roundtrip();
    printf("\n%s\n", fails ? "SOME TESTS FAILED" : "ALL PASS (0 failures)");
    return fails ? 1 : 0;
}

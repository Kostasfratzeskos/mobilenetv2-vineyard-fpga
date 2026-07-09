#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mobilenet.h"
#include "hexio.h"
#include "json.h"

#if defined(_WIN32)
  #include <direct.h>
  #define MAKE_DIR(d) _mkdir(d)
#else
  #include <sys/stat.h>
  #define MAKE_DIR(d) mkdir(d, 0755)
#endif

/* Load the already-quantized int8 input (golden NCHW hex) into an NHWC
 * tensor whose shape is taken from the model's first layer. */
static int load_input_image(const char *golden_dir, const layer_config *first,
                            tensor_i8 *input) {
    char path[512];
    snprintf(path, sizeof path, "%s/000_input.hex", golden_dir);
    int C = first->in_c, H = first->in_h, W = first->in_w;
    int8_t *buf = malloc((size_t)C * H * W);
    if (!buf) return 1;
    if (hex_read_activation_nhwc(path, buf, C, H, W) != C * H * W) { free(buf); return 1; }
    input->data = buf; input->h = H; input->w = W; input->c = C;
    return 0;
}

/* diff two hex files (int8). returns #mismatches, -1 on size mismatch,
 * -2 if a file is missing. `first` gets the index of the first mismatch. */
static int compare_hex(const char *a, const char *b, int bits, int *first) {
    *first = -1;
    long na = hex_count(a), nb = hex_count(b);
    if (na < 0 || nb < 0) return -2;
    if (na != nb) return -1;
    int n = (int)na, mm = 0;
    if (bits == 32) {
        int32_t *A = malloc((size_t)n * 4), *B = malloc((size_t)n * 4);
        hex_read_i32(a, A, n); hex_read_i32(b, B, n);
        for (int i = 0; i < n; i++) if (A[i] != B[i]) { if (*first < 0) *first = i; mm++; }
        free(A); free(B);
    } else if (bits == 16) {
        int16_t *A = malloc((size_t)n * 2), *B = malloc((size_t)n * 2);
        hex_read_i16(a, A, n); hex_read_i16(b, B, n);
        for (int i = 0; i < n; i++) if (A[i] != B[i]) { if (*first < 0) *first = i; mm++; }
        free(A); free(B);
    } else {
        int8_t *A = malloc((size_t)n), *B = malloc((size_t)n);
        hex_read_i8(a, A, n); hex_read_i8(b, B, n);
        for (int i = 0; i < n; i++) if (A[i] != B[i]) { if (*first < 0) *first = i; mm++; }
        free(A); free(B);
    }
    return mm;
}

/* walk golden_manifest.json and diff every int8 layer against its dump */
static void compare_against_golden(const char *golden_dir, const char *dump_dir) {
    char mpath[512];
    snprintf(mpath, sizeof mpath, "%s/golden_manifest.json", golden_dir);
    json *gm = json_parse_file(mpath);
    if (!gm) { fprintf(stderr, "compare: cannot read %s\n", mpath); return; }

    const json *files = json_get(gm, "files");
    int n = json_len(files), pass = 0, total = 0;

    printf("\n seq  layer                              result\n");
    printf(" ---  ---------------------------------  ------------------------\n");
    for (int i = 0; i < n; i++) {
        const json *e   = json_at(files, i);
        int seq         = json_get_int(e, "seq", i);
        int bits        = json_get_int(e, "bits", 8);
        const char *nm  = json_get_str(e, "name");
        const char *gf  = json_get_str(e, "file");
        if (!nm || !gf) continue;

        char gpath[512], dpath[512];
        snprintf(gpath, sizeof gpath, "%s/%s", golden_dir, gf);
        if (!strcmp(nm, "input")) snprintf(dpath, sizeof dpath, "%s/input.hex", dump_dir);
        else                      snprintf(dpath, sizeof dpath, "%s/%s.hex", dump_dir, nm);

        int first = -1, mm = compare_hex(gpath, dpath, bits, &first);
        total++;
        if      (mm == -2) printf(" %3d  %-33s  no dump\n", seq, nm);
        else if (mm == -1) printf(" %3d  %-33s  SIZE MISMATCH\n", seq, nm);
        else if (mm == 0)  { printf(" %3d  %-33s  PASS\n", seq, nm); pass++; }
        else               printf(" %3d  %-33s  FAIL (%d diffs, first @%d)\n", seq, nm, mm, first);
    }
    printf(" ---  ---------------------------------  ------------------------\n");
    printf(" %d / %d layers match golden\n\n", pass, total);
    json_free(gm);
}

int main(int argc, char **argv) {
    const char *model_dir  = (argc > 1) ? argv[1] : "../export";
    const char *golden_dir = (argc > 2) ? argv[2] : "../golden/image_1";
    const char *dump_dir   = "build/dump";

    model m;
    if (load_model(model_dir, &m) != 0) { fprintf(stderr, "load_model failed\n"); return 1; }
    printf("loaded %d layers from %s/manifest.json\n", m.num_layers, model_dir);

    tensor_i8 input = { NULL, 0, 0, 0 };
    if (load_input_image(golden_dir, &m.layers[0], &input) != 0) {
        fprintf(stderr, "load_input_image failed\n"); free_model(&m); return 1;
    }
    printf("input %dx%dx%d (NHWC) loaded from %s\n", input.h, input.w, input.c, golden_dir);

    MAKE_DIR("build"); MAKE_DIR(dump_dir);

    /* round-trip the input back out (NHWC->NCHW) so the identity check in
     * compare_against_golden also exercises the layout permute. */
    { char p[512]; snprintf(p, sizeof p, "%s/input.hex", dump_dir);
      dump_layer_i8(p, &input); }

    int16_t logits[NUM_CLASSES] = {0};
    run_inference(&m, &input, logits, dump_dir);

    int cls = argmax_i16(logits, NUM_CLASSES);
    printf("predicted class: %d (%s)   logits = [%d, %d, %d, %d]\n",
           cls, CLASS_NAMES[cls], logits[0], logits[1], logits[2], logits[3]);

    compare_against_golden(golden_dir, dump_dir);

    free(input.data);
    free_model(&m);
    return 0;
}

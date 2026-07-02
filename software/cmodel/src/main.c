#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mobilenet.h"
#include "requantize.h"

/* Loads the already-quantized int8 input (NHWC), in the network's input
 * scale. For VALIDATION we feed the exact quantized input that produced
 * the golden vectors (not a freshly decoded JPEG) - real preprocessing
 * (decode + normalize + quantize) comes later, and on the board the PS
 * does it. Stubbed for now. */
static int load_input_image(const char *path, tensor_i8 *input) {
    (void)path; (void)input;
    /* TODO: load int8 NHWC tensor (e.g. the input golden vector). */
    return 0;
}

int main(int argc, char **argv) {
    const char *model_path = (argc > 1) ? argv[1] : "artifacts/";
    const char *image_path = (argc > 2) ? argv[2] : "input.bin";

    model m;
    if (load_model(model_path, &m) != 0) {
        fprintf(stderr, "load_model failed\n");
        return 1;
    }

    tensor_i8 input = { NULL, 0, 0, 0 };
    if (load_input_image(image_path, &input) != 0) {
        fprintf(stderr, "load_input_image failed\n");
        free_model(&m);
        return 1;
    }

    int8_t logits_buf[NUM_CLASSES];
    memset(logits_buf, 0, sizeof logits_buf);
    tensor_i8 logits = { logits_buf, 1, 1, NUM_CLASSES };

    run_inference(&m, &input, &logits);

    int cls = argmax_i8(&logits);
    printf("predicted class: %d (%s)\n", cls, CLASS_NAMES[cls]);
    printf("[skeleton] engines not implemented yet - result is a placeholder.\n");

    free_model(&m);
    return 0;
}

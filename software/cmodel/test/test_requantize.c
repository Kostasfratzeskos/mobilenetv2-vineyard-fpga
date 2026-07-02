#include "../src/requantize.h"
#include <stdio.h>

static int fails = 0;

static void check_core(int32_t acc, int32_t m0, int shift, int32_t expect) {
    int32_t got = requant_mul_shift(acc, m0, shift);
    if (got != expect) fails++;
    printf("  [%s] requant_mul_shift(acc=%11d, m0=%11d, shift=%d) = %8d  (expect %8d)\n",
           got == expect ? "ok " : "ERR", acc, m0, shift, got, expect);
}

static void check_elem(int32_t acc, int32_t m0, int shift,
                       activation act, int q6, int expect) {
    int got = requantize_elem(acc, m0, shift, act, q6);
    if (got != expect) fails++;
    printf("  [%s] requantize_elem(acc=%9d, %-5s, q6=%d) = %4d  (expect %4d)\n",
           got == expect ? "ok " : "ERR", acc,
           act == ACT_RELU6 ? "RELU6" : "NONE", q6, got, expect);
}

int main(void) {
    const int32_t M0_HALF = 1 << 30;   /* with shift 31 => M = 0.5 */

    printf("core, M = 0.5  (round-half-up toward +inf):\n");
    check_core(   3, M0_HALF, 31,    2);
    check_core(  -3, M0_HALF, 31,   -1);   /* tie -1.5 -> -1, NOT -2 */
    check_core(   5, M0_HALF, 31,    3);
    check_core(  -5, M0_HALF, 31,   -2);   /* tie -2.5 -> -2, NOT -3 */
    check_core(   7, M0_HALF, 31,    4);
    check_core(  -7, M0_HALF, 31,   -3);
    check_core( 100, M0_HALF, 31,   50);
    check_core(-100, M0_HALF, 31,  -50);
    check_core( 101, M0_HALF, 31,   51);
    check_core(-101, M0_HALF, 31,  -50);   /* tie -50.5 -> -50, NOT -51 */

    printf("core, M = 0.25  (shift 32):\n");
    check_core(  10, M0_HALF, 32,    3);
    check_core( -10, M0_HALF, 32,   -2);
    check_core(   1, M0_HALF, 32,    0);
    check_core(  -1, M0_HALF, 32,    0);

    printf("core, big magnitude  (catches the int32-overflow bug):\n");
    check_core( 1000000, 2000000000, 31,  931323);
    check_core(-1000000, 2000000000, 31, -931323);

    printf("element tail  (clamp + activation):\n");
    check_elem( 1000000, 2000000000, 31, ACT_NONE,  6,  127);  /*  931323 -> sat  127 */
    check_elem(-1000000, 2000000000, 31, ACT_NONE,  6, -128);  /* -931323 -> sat -128 */
    check_elem(      -5, M0_HALF,     31, ACT_RELU6, 6,   0);   /*  -2 -> relu6 floor 0 */
    check_elem(     101, M0_HALF,     31, ACT_RELU6, 6,   6);   /*  51 -> relu6 cap   6 */
    check_elem(       7, M0_HALF,     31, ACT_RELU6, 6,   4);   /*   4 in [0,6]        */

    printf("\n%s (%d failures)\n", fails == 0 ? "ALL PASS" : "FAILED", fails);
    return fails ? 1 : 0;
}

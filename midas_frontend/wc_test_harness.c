/*
 * wc_test_harness.c
 * Small test program to verify WaveCatcher library linkage and basic open/close.
 * Compile and run with the WaveCatcher library in LD_LIBRARY_PATH.
 */

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include "WaveCat64ch_Lib.h"

int main(int argc, char **argv)
{
    int h = -1;
    printf("wc_test_harness: trying to open WaveCatcher...\n");
    WAVECAT64CH_ErrCode r = WAVECAT64CH_OpenDevice(&h);
    if (r != 0) {
        fprintf(stderr, "OpenDevice failed (err=%d)\n", r);
        return 2;
    }
    printf("Opened device handle=%d\n", h);
    sleep(1);
    WAVECAT64CH_CloseDevice();
    printf("Closed device\n");
    return 0;
}

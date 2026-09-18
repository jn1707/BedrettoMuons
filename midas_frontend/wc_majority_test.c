#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "WaveCat64ch_Lib.h"

/*
 * Standalone probe for WAVECAT64CH_TRIGGER_MAJORITY support.
 *
 * Enables channels 0-3 as trigger sources, calls SetTriggerMode(MAJORITY),
 * and attempts to read events for ~5 s.  Prints every API return code so
 * the result is unambiguous even if the call silently returns success while
 * the firmware ignores the mode.
 *
 * Build (from midas_frontend/):
 *   gcc -O2 -I$HOME/.local/include/WaveCatcher \
 *       -o wc_majority_test wc_majority_test.c \
 *       $HOME/.local/lib/wavecatcher/v288/lib/libWaveCatcher64ch_v288.so \
 *       -Wl,-rpath,$HOME/.local/lib/wavecatcher/v288/lib
 *
 * Run via the versioned wrapper so LD_LIBRARY_PATH is correct:
 *   ~/Documents/wc_run_v288.sh ./wc_majority_test
 *
 * Interpretation:
 *   SetTriggerMode(MAJORITY) rc != 0  -> firmware rejects the call outright.
 *   SetTriggerMode(MAJORITY) rc  = 0,
 *     but decoded = 0 after 5 s     -> firmware accepted silently but does
 *                                      not implement majority trigger;
 *                                      use 2-channel coincidence instead.
 *   decoded > 0                      -> majority trigger is functional.
 */

int main(void)
{
    int h = -1;
    WAVECAT64CH_EventStruct evt;
    memset(&evt, 0, sizeof(evt));
    int exit_code = 1;

    WAVECAT64CH_ErrCode rc;

    rc = WAVECAT64CH_OpenDevice(&h);
    printf("OpenDevice rc=%d handle=%d\n", (int)rc, h);
    if (rc != WAVECAT64CH_Success) { fprintf(stderr, "OpenDevice failed\n"); return 2; }

    rc = WAVECAT64CH_ResetDevice();
    printf("ResetDevice rc=%d\n", (int)rc);
    if (rc != WAVECAT64CH_Success) { fprintf(stderr, "ResetDevice failed\n"); goto cleanup; }

    sleep(10); /* settle after reset, same as frontend */

    rc = WAVECAT64CH_SetDefaultParameters();
    printf("SetDefaultParameters rc=%d\n", (int)rc);
    if (rc != WAVECAT64CH_Success) { fprintf(stderr, "SetDefaultParameters failed\n"); goto cleanup; }

    int channels[4] = {0, 1, 2, 3};
    for (int i = 0; i < 4; i++) {
        int ch = channels[i];
        rc = WAVECAT64CH_SetChannelState(WAVECAT64CH_FRONT_CHANNEL, ch, WAVECAT64CH_STATE_ON);
        printf("SetChannelState      ch=%d rc=%d\n", ch, (int)rc);
        rc = WAVECAT64CH_SetTriggerSourceState(WAVECAT64CH_FRONT_CHANNEL, ch, WAVECAT64CH_STATE_ON);
        printf("SetTriggerSourceState ch=%d rc=%d\n", ch, (int)rc);
        rc = WAVECAT64CH_SetTriggerEdge(WAVECAT64CH_FRONT_CHANNEL, ch, WAVECAT64CH_POS_EDGE);
        printf("SetTriggerEdge       ch=%d rc=%d\n", ch, (int)rc);
        rc = WAVECAT64CH_SetTriggerThreshold(WAVECAT64CH_FRONT_CHANNEL, ch, 0.030f);
        printf("SetTriggerThreshold  ch=%d rc=%d\n", ch, (int)rc);
    }

    rc = WAVECAT64CH_SetTriggerMode(WAVECAT64CH_TRIGGER_MAJORITY);
    printf("SetTriggerMode(MAJORITY) rc=%d  <-- key result\n", (int)rc);
    if (rc != WAVECAT64CH_Success) {
        fprintf(stderr, "SetTriggerMode(MAJORITY) failed: firmware rejects the call\n");
        goto cleanup;
    }

    rc = WAVECAT64CH_PrepareEvent();
    printf("PrepareEvent rc=%d\n", (int)rc);
    if (rc != WAVECAT64CH_Success) { fprintf(stderr, "PrepareEvent failed\n"); goto cleanup; }

    rc = WAVECAT64CH_AllocateEventStructure(&evt);
    printf("AllocateEventStructure rc=%d\n", (int)rc);
    if (rc != WAVECAT64CH_Success) { fprintf(stderr, "AllocateEventStructure failed\n"); goto cleanup; }

    rc = WAVECAT64CH_StartRun();
    printf("StartRun rc=%d\n", (int)rc);
    if (rc != WAVECAT64CH_Success) { fprintf(stderr, "StartRun failed\n"); goto cleanup; }

    int decoded = 0;
    for (int i = 0; i < 5000; i++) {
        usleep(1000);
        if (WAVECAT64CH_ReadEventBuffer() == WAVECAT64CH_Success) {
            if (WAVECAT64CH_DecodeEvent(&evt) == WAVECAT64CH_Success) {
                decoded++;
                printf("Event id=%d tdc=%llu samblocks=%d\n",
                       evt.EventID, (unsigned long long)evt.TDC, evt.NbOfSAMBlocksInEvent);
                if (decoded >= 5) break;
            }
        }
    }

    printf("\nDecoded %d events in ~5 s with MAJORITY trigger\n", decoded);
    exit_code = (decoded > 0) ? 0 : 1;

cleanup:
    WAVECAT64CH_StopRun();
    WAVECAT64CH_FreeEventStructure(&evt);
    WAVECAT64CH_CloseDevice();
    return exit_code;
}

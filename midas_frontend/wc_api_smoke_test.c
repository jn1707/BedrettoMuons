#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "WaveCat64ch_Lib.h"

int main(void)
{
    int h = -1;
    WAVECAT64CH_EventStruct evt;
    memset(&evt, 0, sizeof(evt));

    WAVECAT64CH_ErrCode rc = WAVECAT64CH_OpenDevice(&h);
    if (rc != WAVECAT64CH_Success) {
        fprintf(stderr, "OpenDevice failed rc=%d\n", (int)rc);
        return 2;
    }

    rc = WAVECAT64CH_ResetDevice();
    if (rc != WAVECAT64CH_Success) {
        fprintf(stderr, "ResetDevice failed rc=%d\n", (int)rc);
        return 3;
    }

    rc = WAVECAT64CH_SetDefaultParameters();
    if (rc != WAVECAT64CH_Success) {
        fprintf(stderr, "SetDefaultParameters failed rc=%d\n", (int)rc);
        return 4;
    }

    rc = WAVECAT64CH_SetChannelState(WAVECAT64CH_FRONT_CHANNEL, 0, WAVECAT64CH_STATE_ON);
    if (rc != WAVECAT64CH_Success) {
        fprintf(stderr, "SetChannelState failed rc=%d\n", (int)rc);
        return 5;
    }

    rc = WAVECAT64CH_SetTriggerSourceState(WAVECAT64CH_FRONT_CHANNEL, 0, WAVECAT64CH_STATE_ON);
    if (rc != WAVECAT64CH_Success) {
        fprintf(stderr, "SetTriggerSourceState failed rc=%d\n", (int)rc);
        return 6;
    }

    rc = WAVECAT64CH_SetTriggerMode(WAVECAT64CH_TRIGGER_SOFT);
    if (rc != WAVECAT64CH_Success) {
        fprintf(stderr, "SetTriggerMode(soft) failed rc=%d\n", (int)rc);
        return 7;
    }

    rc = WAVECAT64CH_AllocateEventStructure(&evt);
    if (rc != WAVECAT64CH_Success) {
        fprintf(stderr, "AllocateEventStructure failed rc=%d\n", (int)rc);
        return 8;
    }

    rc = WAVECAT64CH_PrepareEvent();
    if (rc != WAVECAT64CH_Success) {
        fprintf(stderr, "PrepareEvent failed rc=%d\n", (int)rc);
        return 9;
    }

    rc = WAVECAT64CH_StartRun();
    if (rc != WAVECAT64CH_Success) {
        fprintf(stderr, "StartRun failed rc=%d\n", (int)rc);
        return 10;
    }

    int decoded = 0;
    for (int i = 0; i < 200; i++) {
        WAVECAT64CH_SendSoftwareTrigger();
        usleep(2000);
        rc = WAVECAT64CH_ReadEventBuffer();
        if (rc == WAVECAT64CH_Success) {
            rc = WAVECAT64CH_DecodeEvent(&evt);
            if (rc == WAVECAT64CH_Success) {
                decoded++;
                printf("Decoded event id=%d tdc=%llu samblocks=%d\n",
                       evt.EventID, evt.TDC, evt.NbOfSAMBlocksInEvent);
                if (decoded >= 3) {
                    break;
                }
            }
        }
    }

    WAVECAT64CH_StopRun();
    WAVECAT64CH_FreeEventStructure(&evt);
    WAVECAT64CH_CloseDevice();

    if (decoded == 0) {
        fprintf(stderr, "No decoded events in smoke test\n");
        return 11;
    }

    printf("Smoke test OK: decoded=%d\n", decoded);
    return 0;
}

#include "bsim4def.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
extern IFparm BSIM4pTable[], BSIM4mPTable[];
extern int BSIM4pTSize, BSIM4mPTSize;
int BSIM4param(int, IFvalue *, GENinstance *, IFvalue *);
int main(void) {
    BSIM4instance instance = {0};
    IFvalue value = {.rValue = 2e-6};
    int sc = -1;
    for (int i = 0; i < BSIM4pTSize; ++i)
        if (!strcmp(BSIM4pTable[i].keyword, "sc")) sc = BSIM4pTable[i].id;
    assert(sc == BSIM4_SCA);
    assert(BSIM4param(sc, &value, (GENinstance *)&instance, NULL) == 0);
    assert(instance.BSIM4sca == 2e-6 && instance.BSIM4scaGiven);
    assert(instance.BSIM4sc == 0 && !instance.BSIM4scGiven);
    assert(BSIM4param(BSIM4_SC, &value, (GENinstance *)&instance, NULL) == 0);
    assert(instance.BSIM4sc == 2e-6 && instance.BSIM4scGiven);
    printf("original45_sc_table_maps_sca=1 direct_sc_setter=1 states=%d noise_sources=%d model_bytes=%zu instance_bytes=%zu\n", BSIM4numStates, BSIM4NSRCS, sizeof(BSIM4model), sizeof(BSIM4instance));
    return 0;
}

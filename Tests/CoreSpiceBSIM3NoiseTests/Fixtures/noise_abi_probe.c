#include "CoreSpiceBSIM3.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    for (int run=0;run<128;run++) {
        int sign=run%2 ? -1 : 1;
        CSBSIM3Handle *handle=cs_bsim3_create(sign,run%3 ? 300.15 : 350.15);
        assert(handle);
        assert(!cs_bsim3_parameter(handle,1,"vth0",sign*.7));
        assert(!cs_bsim3_parameter(handle,1,"tox",1e-8));
        assert(!cs_bsim3_parameter(handle,1,"u0",500));
        assert(!cs_bsim3_parameter(handle,1,"capmod",3));
        assert(!cs_bsim3_parameter(handle,1,"noimod",run%6+1));
        assert(!cs_bsim3_parameter(handle,1,"kf",1e-25));
        assert(!cs_bsim3_parameter(handle,1,"rsh",20));
        assert(!cs_bsim3_parameter(handle,1,"acnqsmod",1));
        assert(!cs_bsim3_parameter(handle,0,"nqsmod",1));
        assert(!cs_bsim3_parameter(handle,0,"l",1e-6));
        assert(!cs_bsim3_parameter(handle,0,"w",1e-5));
        CSBSIM3Topology topology;
        assert(!cs_bsim3_prepare(handle,&topology));
        assert(topology.nodeCount==7);
        double bias[8]={0,sign,sign*1.2,0,sign*-.1,sign*.95,sign*.02,0};
        assert(!cs_bsim3_initialize_history(handle,bias));
        double before[32],after[32],density[4];
        cs_bsim3_accepted_states(handle,before);
        for(int point=0;point<4;point++) {
            CSBSIM3Result trial;
            assert(!cs_bsim3_evaluate(handle,bias,2,0,1e-12,1e-12,&trial));
            assert(!cs_bsim3_noise_spectrum(handle,bias,pow(10,point+2),1e-12,density));
            for(int i=0;i<4;i++)assert(isfinite(density[i])&&density[i]>=0);
            assert(cs_bsim3_commit(handle,trial.token)==CS_BSIM3_HISTORY);
            assert(cs_bsim3_noise_spectrum(handle,bias,0,1e-12,density)!=CS_BSIM3_OK);
            cs_bsim3_accepted_states(handle,after);
            assert(!memcmp(before,after,sizeof(before)));
        }
        cs_bsim3_destroy(handle);
        if(run<2) {
            handle=cs_bsim3_create(sign,300.15);
            assert(handle);
            assert(!cs_bsim3_parameter(handle,1,"vth0",sign*.7));
            assert(!cs_bsim3_parameter(handle,1,"tox",1e-8));
            assert(!cs_bsim3_parameter(handle,1,"rsh",20));
            assert(!cs_bsim3_parameter(handle,1,"noimod",2));
            assert(!cs_bsim3_parameter(handle,1,"noia",-1e308));
            assert(!cs_bsim3_parameter(handle,1,"ef",2));
            assert(!cs_bsim3_parameter(handle,0,"l",1e-6));
            assert(!cs_bsim3_parameter(handle,0,"w",1e-5));
            assert(!cs_bsim3_prepare(handle,&topology));
            assert(!cs_bsim3_initialize_history(handle,bias));
            cs_bsim3_accepted_states(handle,before);
            assert(cs_bsim3_noise_spectrum(handle,bias,100,1e-12,density)==CS_BSIM3_NUMERICAL);
            assert(cs_bsim3_noise_spectrum(handle,bias,1e308,1e-12,density)==CS_BSIM3_NUMERICAL);
            cs_bsim3_accepted_states(handle,after);
            assert(!memcmp(before,after,sizeof(before)));
            cs_bsim3_destroy(handle);
        }
    }
    puts("128 cold series/NQS noise lifecycles, 512 spectra, failed input, smoothing/power overflow and rejected commit preserve history");
    return 0;
}

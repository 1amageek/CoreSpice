/* Run against the actual isolated kernel ABI, including sanitizers and a
   read-only working directory. This fixture contains no process-private PDK. */
#include "CoreSpiceBSIM3.h"
#include <stdio.h>
#include <math.h>
#include <assert.h>
int main(void) {
    for(int run=0;run<128;run++) {
        CSBSIM3Handle *h=cs_bsim3_create(1,300.15);assert(h);
        const char *model[]={"vth0","u0","tox","cj","cjsw","cgdo","cgso"};
        const double value[]={0.7,500,10e-9,1e-3,1e-10,2e-10,3e-10};
        for(int n=0;n<7;n++)assert(cs_bsim3_parameter(h,1,model[n],value[n])==0);
        const char *instance[]={"w","l","ad","as","pd","ps"};
        const double geometry[]={10e-6,1e-6,2e-12,3e-12,12e-6,14e-6};
        for(int n=0;n<6;n++)assert(cs_bsim3_parameter(h,0,instance[n],geometry[n])==0);
        CSBSIM3Topology topology;assert(cs_bsim3_prepare(h,&topology)==0);
        assert(topology.nodeCount==4);
        double bias[]={0,1,1.2,0,-0.1,0,0,0};CSBSIM3Result result;
        assert(cs_bsim3_evaluate(h,bias,0,0,0,1e-12,&result)==0);
        if(run==0)printf("id=%.17g gm=%.17g gds=%.17g gmbs=%.17g qg=%.17g qd=%.17g qb=%.17g\n",
            result.operatingPoint[0],result.operatingPoint[1],result.operatingPoint[2],result.operatingPoint[3],result.charge[2],result.charge[1],result.charge[4]);
        assert(cs_bsim3_initialize_history(h,bias)==0);
        for(int step=0;step<4;step++) {
            bias[2]+=0.01;
            assert(cs_bsim3_evaluate(h,bias,step%2?3:2,0,1e-9,1e-12,&result)==0);
            assert(cs_bsim3_commit(h,result.token)==0);
            assert(cs_bsim3_commit(h,result.token)==CS_BSIM3_HISTORY);
        }
        assert(cs_bsim3_evaluate(h,bias,1,1e9,0,1e-12,&result)==0);
        assert(isfinite(result.imaginary[18]));
        cs_bsim3_destroy(h);
    }
    CSBSIM3Handle *invalid=cs_bsim3_create(1,300.15);assert(invalid);
    assert(cs_bsim3_parameter(invalid,1,"lint",1e-3)==0);CSBSIM3Topology topology;
    assert(cs_bsim3_prepare(invalid,&topology)==CS_BSIM3_PARAMETER);
    assert(cs_bsim3_prepare(invalid,&topology)==CS_BSIM3_PARAMETER);
    double zero[8]={0};CSBSIM3Result rejected;
    assert(cs_bsim3_evaluate(invalid,zero,0,0,0,0,&rejected)==CS_BSIM3_PARAMETER);
    cs_bsim3_destroy(invalid);
    puts("128 cold lifecycles, 512 accepted BE/trapezoidal steps, AC and fatal cleanup passed");
    return 0;
}

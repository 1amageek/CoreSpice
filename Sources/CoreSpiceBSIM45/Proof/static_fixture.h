/* Inputs shared by independent production/original harnesses; no output physics. */
#ifndef CS45_STATIC_FIXTURE_H
#define CS45_STATIC_FIXTURE_H
#include "CoreSpiceBSIM45.h"
#include "bsim4def.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
enum { STATIC_FIXTURES=580, STATIC_BIASES=7 };
typedef struct {int polarity,mob,cap,diode,temp,gate,body,series,nqs,acnqs,igc,igb,wpe,geom,rgeom,minimum,per,bin;double ambient,nf,xpart,ud,ngate;} StaticFixture;
static StaticFixture fixture(int id) {
 StaticFixture f={0};int n=id;
 f.polarity=n%2?1:-1;n/=2;
 if(id<324) {
  f.mob=n%3;n/=3;f.cap=n%3;n/=3;f.diode=n%3;n/=3;f.temp=n%3;n/=3;
  f.ambient=n%2?350:300.15;
  f.gate=(id/2)%4;f.body=(id/8)%3;f.series=(id/24)%2;
  f.nqs=(id/48)%2;f.acnqs=(id/96)%2;
 } else if(id<516) {
  n=(id-324)/2;f.gate=n%4;n/=4;f.body=n%3;n/=3;f.series=n%2;n/=2;f.nqs=n%2;n/=2;f.acnqs=n%2;
  f.mob=id%3;f.cap=(id/3)%3;f.diode=(id/9)%3;f.temp=(id/27)%3;f.ambient=325;
 }
 if(id>=516) {
  n=(id-516)/2;f.mob=n%3;f.cap=(n/3)%3;f.diode=n%3;f.temp=n%3;
  f.gate=n%4;f.body=n%3;f.series=n%2;f.nqs=(n/2)%2;f.acnqs=(n/4)%2;f.ambient=325;
  f.geom=n%11;f.rgeom=n%9;f.minimum=n%2;f.per=n%2;
 }
 f.igc=id<516?1:(id/2)%3;f.igb=id<516?1:(id/2)%2;f.wpe=id<516?1:0;
 f.bin=id<516?1:2;f.ud=id<516?1e14:0;f.ngate=id<516?1e20:0;
 f.nf=id%3==0?1:(id%3==1?2.5:4);f.xpart=id%3==0?0:(id%3==1?0.5:1);
 if(id>=576)f.xpart=-1;
 return f;
}
/* The includer supplies set(role,id,kind,value). */
static void fixture_parameters(StaticFixture f) {
 #define MODEL(id,kind,v) set(1,BSIM4_MOD_##id,CS_BSIM45_##kind,v)
 #define INSTANCE(id,v) set(0,BSIM4_##id,CS_BSIM45_REAL,v)
 MODEL(MOBMOD,INTEGER,f.mob);MODEL(CAPMOD,INTEGER,f.cap);MODEL(DIOMOD,INTEGER,f.diode);MODEL(TEMPMOD,INTEGER,f.temp);
 MODEL(RGATEMOD,INTEGER,f.gate);MODEL(RBODYMOD,INTEGER,f.body);MODEL(RDSMOD,INTEGER,f.series);
 MODEL(TRNQSMOD,INTEGER,f.nqs);MODEL(ACNQSMOD,INTEGER,f.acnqs);MODEL(IGCMOD,INTEGER,f.igc);MODEL(IGBMOD,INTEGER,f.igb);
 MODEL(GEOMOD,INTEGER,f.geom);MODEL(PERMOD,INTEGER,f.per);MODEL(BINUNIT,INTEGER,f.bin);
 set(0,BSIM4_RGEOMOD,CS_BSIM45_INTEGER,f.rgeom);set(0,BSIM4_MIN,CS_BSIM45_INTEGER,f.minimum);
 MODEL(XPART,REAL,f.xpart);MODEL(AT,REAL,0);MODEL(TOXE,REAL,3e-9);MODEL(TOXM,REAL,3e-9);
 MODEL(VTH0,REAL,f.polarity*0.45);MODEL(U0,REAL,0.05);MODEL(NGATE,REAL,f.ngate);MODEL(UD,REAL,f.ud);
 MODEL(RSH,REAL,10);MODEL(RDW,REAL,100);MODEL(RSW,REAL,80);MODEL(RDSW,REAL,120);
 MODEL(RSHG,REAL,10);MODEL(CGSO,REAL,1e-10);MODEL(CGDO,REAL,1.5e-10);MODEL(CGBO,REAL,1e-10);
 MODEL(AGIDL,REAL,2e-9);MODEL(BGIDL,REAL,2e8);MODEL(CGIDL,REAL,0.5);
 MODEL(ALPHA0,REAL,1e-8);MODEL(BETA0,REAL,15);MODEL(KU0,REAL,1e-8);
 MODEL(WPEMOD,REAL,f.wpe);MODEL(KVTH0WE,REAL,0.02);
 INSTANCE(L,0.5e-6);INSTANCE(W,6e-6);INSTANCE(NF,f.nf);INSTANCE(NRD,1);INSTANCE(NRS,1);
 INSTANCE(AD,1e-12);INSTANCE(AS,1.2e-12);INSTANCE(PD,4e-6);INSTANCE(PS,4.5e-6);
 INSTANCE(SA,1e-6);INSTANCE(SB,2e-6);INSTANCE(SD,0.2e-6);INSTANCE(SC,1e-6);
 #undef MODEL
 #undef INSTANCE
}
static void fixture_bias(CSBSIM45PreparedInfo p,int polarity,int point,double out[13]) {
 const double voltages[7][4]={{1,1.2,0,-0.3},{-0.6,1,0,-0.8},{0.1,-0.6,0,-0.2},{0.05,0.5,0,0.1},{1.5,-0.2,0,-0.4},{0.4,1.5,0.2,-0.4},{0,0.45,0,-0.2}};
 memset(out,0,13*sizeof(double));
 for(int n=1;n<=p.nodeCount;n++)out[n]=polarity*voltages[point][3];
 out[1]=polarity*voltages[point][0];out[2]=polarity*voltages[point][1];out[3]=polarity*voltages[point][2];out[4]=polarity*voltages[point][3];
 out[p.drainPrime]=polarity*(voltages[point][0]-0.007);
 out[p.sourcePrime]=polarity*(voltages[point][2]+0.003);
 out[p.gatePrime]=polarity*(voltages[point][1]-0.011);
 out[p.bodyPrime]=polarity*(voltages[point][3]+0.006);
 if(p.gateMid)out[p.gateMid]=polarity*(voltages[point][1]-0.005);
 if(p.drainBody)out[p.drainBody]=polarity*(voltages[point][3]+0.012);
 if(p.sourceBody)out[p.sourceBody]=polarity*(voltages[point][3]+0.009);
 if(point==6) {
  out[1]=out[3]=out[p.drainPrime]=out[p.sourcePrime]=0;
  out[2]=out[p.gatePrime]=polarity*0.45;if(p.gateMid)out[p.gateMid]=polarity*0.45;
 }
 out[0]=0;if(p.chargeNode)out[p.chargeNode]=0;
}
#endif

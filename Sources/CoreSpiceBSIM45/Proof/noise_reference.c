/* Untouched original noise/host services versus public production receipts. */
#include "CoreSpiceBSIM45.h"
#include "bsim4def.h"
#include <assert.h>
#include <stdio.h>
#ifdef ORIGINAL_REFERENCE
static JOB noiseJob={"Noise Analysis",NULL};
static TSKtask task={&noiseJob};
static ReferenceCircuit frontCircuit={&task};ReferenceCircuit *ft_curckt=&frontCircuit;
static void report_error(int severity,const char *format,IFuid *names){assert(0);}
static ReferenceFrontend frontend={report_error};ReferenceFrontend *SPfrontEnd=&frontend;
static BSIM4model m;static BSIM4instance i;static CKTcircuit c;static SMPmatrix matrix;
static double states[3][29],rhs[13],bias[13];
static void set(int role,int id,int kind,double value) {
 IFvalue v={0};if(kind==CS_BSIM45_REAL)v.rValue=value;else v.iValue=(int)value;
 assert((role?BSIM4mParam(id,&v,(GENmodel*)&m):BSIM4param(id,&v,(GENinstance*)&i,NULL))==0);
}
extern int BSIM4acLoad(GENmodel *,CKTcircuit *);
#else
static CSBSIM45Owner *owner;
static void set(int role,int id,int kind,double value){assert((role?cs_bsim45_set_model(owner,id,kind,value):cs_bsim45_set_instance(owner,id,kind,value))==CS_BSIM45_OK);}
#endif
#include "noise_fixture.h"
static void emit(int id,int mode,int point,int index,CSBSIM45NoiseSpectrum *s,double power[14]) {
 printf("NOISE %d %d %d %d",id,mode,point,index);
 for(int n=0;n<14;n++)printf(" %.17g",s->density[n]);
 for(int n=0;n<14;n++)printf(" %.17g",power[n]);printf(" %.17g\n",sqrt(power[13]));
}
#ifdef ORIGINAL_REFERENCE
int NIintegrate(CKTcircuit *ckt,double *g,double *eq,double cap,int q){assert(ckt->CKTag[0]==0);ckt->CKTstate0[q+1]=0;*g=*eq=0;return 0;}
#endif
int main(int argc,char **argv) {
 int end=argc>1?atoi(argv[1]):STATIC_FIXTURES;
 for(int id=0;id<end;id++)for(int thermal=0;thermal<2;thermal++)for(int flicker=0;flicker<2;flicker++) {
  StaticFixture f=fixture(id);CSBSIM45PreparedInfo p={0};
#ifdef ORIGINAL_REFERENCE
  memset(&m,0,sizeof(m));memset(&i,0,sizeof(i));memset(&c,0,sizeof(c));memset(&matrix,0,sizeof(matrix));memset(states,0,sizeof(states));
  m.BSIM4instances=&i;m.BSIM4modName="Reference";m.BSIM4type=f.polarity;m.BSIM4typeGiven=1;m.BSIM4version="4.5.0";m.BSIM4versionGiven=1;
  i.BSIM4modPtr=&m;i.BSIM4name="M1";i.BSIM4dNode=1;i.BSIM4gNodeExt=2;i.BSIM4sNode=3;i.BSIM4bNode=4;
  c.nodeCount=4;c.CKTtemp=f.ambient;c.CKTnomTemp=300.15;c.CKTstate0=states[0];c.CKTstate1=states[1];c.CKTstate2=states[2];c.CKTstates[0]=states[0];c.CKTstates[1]=states[1];c.CKTstates[2]=states[2];c.CKTrhs=rhs;c.CKTrhsOld=bias;
  noise_parameters(id,thermal,flicker);int nstates=0;assert(BSIM4setup(&matrix,(GENmodel*)&m,&c,&nstates)==0);assert(BSIM4temp((GENmodel*)&m,&c)==0);
  p.nodeCount=c.nodeCount;p.drainPrime=i.BSIM4dNodePrime;p.sourcePrime=i.BSIM4sNodePrime;p.gatePrime=i.BSIM4gNodePrime;p.gateMid=i.BSIM4gNodeMid;
  p.bodyPrime=i.BSIM4bNodePrime;p.drainBody=i.BSIM4dbNode;p.sourceBody=i.BSIM4sbNode;p.chargeNode=i.BSIM4qNode;
#else
  CSBSIM45Conditions conditions={cs_bsim45_owner_size(),100,128,f.ambient,300.15,1};
  assert(cs_bsim45_create("4.5.0",2,f.polarity,&conditions,&owner)==CS_BSIM45_OK);noise_parameters(id,thermal,flicker);
  assert(cs_bsim45_prepare(owner)==CS_BSIM45_OK);assert(cs_bsim45_prepared_info(owner,&p)==CS_BSIM45_OK);
  double bias[13];
#endif
  printf("TOPO %d %d %d %d %d %d %d %d %d %d\n",id,thermal*2+flicker,p.nodeCount,p.drainPrime,p.sourcePrime,p.gatePrime,p.gateMid,p.bodyPrime,p.drainBody,p.sourceBody);
  double real[13],imaginary[13];noise_gains(p,real,imaginary);
  for(int point=0;point<STATIC_BIASES;point++) {
   fixture_bias(p,f.polarity,point,bias);CSBSIM45NoiseSpectrum previous={0};double power[14]={0};
#ifdef ORIGINAL_REFERENCE
   memset(states[0],0,sizeof(states[0]));memset(&matrix,0,sizeof(matrix));memset(rhs,0,sizeof(rhs));c.CKTgmin=1e-12;c.CKTmode=MODEINITSMSIG;
   #define BIAS(name,pos,neg) states[0][i.BSIM4##name]=f.polarity*(bias[i.BSIM4##pos]-bias[i.BSIM4##neg])
   BIAS(vbd,bNodePrime,dNodePrime);BIAS(vbs,bNodePrime,sNodePrime);BIAS(vgs,gNodePrime,sNodePrime);BIAS(vds,dNodePrime,sNodePrime);
   BIAS(vdbs,dbNode,sNodePrime);BIAS(vdbd,dbNode,dNodePrime);BIAS(vsbs,sbNode,sNodePrime);BIAS(vges,gNodeExt,sNodePrime);BIAS(vgms,gNodeMid,sNodePrime);
   BIAS(vses,sNode,sNodePrime);BIAS(vdes,dNode,sNodePrime);
   #undef BIAS
   assert(BSIM4load((GENmodel*)&m,&c)==0);c.CKTmode=MODEDCOP;memset(&matrix,0,sizeof(matrix));memset(rhs,0,sizeof(rhs));assert(BSIM4load((GENmodel*)&m,&c)==0);
   c.CKTrhs=real;c.CKTirhs=imaginary;NOISEAN job={1,1};c.CKTcurJob=&job;Ndata data={0};data.GainSqInv=1;data.prtSummary=1;
#endif
   for(int index=0;index<5;index++){
    CSBSIM45NoiseSpectrum spectrum={0};spectrum.frequency=noise_frequencies[index];
#ifdef ORIGINAL_REFERENCE
    data.freq=spectrum.frequency;data.lstFreq=index?noise_frequencies[index-1]:data.freq;
    data.delFreq=data.freq-data.lstFreq;data.lnFreq=log(data.freq);data.lnLastFreq=log(data.lstFreq);data.delLnFreq=data.lnFreq-data.lnLastFreq;
    data.outpVector=spectrum.density;data.outNumber=0;double sum=0;
    assert(BSIM4noise(N_DENS,N_CALC,(GENmodel*)&m,&c,&data,&sum)==0&&data.outNumber==14);
    for(int n=0;n<14;n++)power[n]=i.BSIM4nVar[OUTNOIZ][n];
#else
    CSBSIM45Status status=cs_bsim45_noise_spectrum(owner,bias,13,1e-12,spectrum.frequency,real,imaginary,&spectrum);
    if(status!=CS_BSIM45_OK){fprintf(stderr,"noise id=%d mode=%d point=%d index=%d status=%d\n",id,thermal*2+flicker,point,index,status);abort();}
    if(index){CSBSIM45NoiseIntegral interval;assert(cs_bsim45_integrate_noise(&previous,&spectrum,&interval)==CS_BSIM45_OK);for(int n=0;n<14;n++)power[n]+=interval.power[n];}
#endif
    emit(id,thermal*2+flicker,point,index,&spectrum,power);previous=spectrum;
   }
#ifdef ORIGINAL_REFERENCE
   c.CKTrhs=rhs;
#endif
  }
#ifdef ORIGINAL_REFERENCE
  free(m.pSizeDependParamKnot);
#else
  cs_bsim45_destroy(owner);
#endif
 }
 return 0;
}

/* Independent dynamic ABI driver sharing only the independent DC tool helpers. */
#define OSDI_ORACLE_NO_MAIN
#include "oracle.c"
#include <complex.h>

enum { MAX_FREQUENCIES=16, MAX_STEPS=1000, MAX_KNOTS=64, MAX_NOISE=128 };
typedef struct { double time,h; bool trap; } Step;
typedef struct { double time,value; } Knot;
static double charges[MAX_UNKNOWNS],capacitance[MAX_UNKNOWNS*MAX_UNKNOWNS];
static double raw_c[MAX_DEVICES][MAX_NODES*MAX_NODES];
static double accepted_q[MAX_UNKNOWNS],accepted_f[MAX_UNKNOWNS],accepted_x[MAX_UNKNOWNS];
static double trial_bound=INFINITY;
static double complex y[MAX_UNKNOWNS*MAX_UNKNOWNS],lu[MAX_UNKNOWNS*MAX_UNKNOWNS];
static int pivots[MAX_UNKNOWNS];
static const char *kind="ac",*initialization="operatingPoint",*source_id=NULL,*output_id=NULL,*reference_id="0",*candidate_file=NULL,*op_candidate_file=NULL;
static double frequencies[MAX_FREQUENCIES];static int frequency_count;
static Step steps[MAX_STEPS];static int step_count;static Knot knots[MAX_KNOTS];static int knot_count;
static Assignment uic[MAX_UNKNOWNS];static int uic_count;
static double complex stimulus=1;static double noise_temperature=300.15;
static int source_family=-1,source_index=-1,forced_reject=-1;
static double candidate_real[MAX_STEPS+1][MAX_UNKNOWNS],candidate_imag[MAX_STEPS+1][MAX_UNKNOWNS];
static bool candidate_given[MAX_STEPS+1][MAX_UNKNOWNS];
static double op[MAX_UNKNOWNS];static bool candidate_valid=true;
static unsigned rejected_trials;

static int find_unknown(const char *id) {
    if(!strcmp(id,"0"))return -1;
    for(int i=0;i<circuit.dimension;i++)if(!strcmp(id,circuit.unknowns[i].id))return i;
    fail("input","unknown semantic coordinate");return -1;
}
static void extra(Device *dev) {
    OsdiDescriptor *d=dev->descriptor;int k=(int)(dev-circuit.devices),n=circuit.dimension;
    memset(raw_c[k],0,sizeof raw_c[k]);d->load_jacobian_react(dev->instance,dev->model,1);
    for(uint32_t i=0;i<d->num_nodes;i++) {
        int row=(int)dev->global[i]-1;if(row<0)continue;
        uint32_t offset=d->nodes[i].react_residual_off;
        double q=offset==UINT32_MAX?0:*(double *)span(dev->instance,d->instance_size,offset,sizeof(double));
        if(!isfinite(q))fail("eval","nonfinite charge");charges[row]+=q;
        for(uint32_t j=0;j<d->num_nodes;j++)if(dev->global[j])
            capacitance[(size_t)row*n+dev->global[j]-1]+=raw_c[k][(size_t)i*d->num_nodes+j];
    }
    if(d->bound_step_offset!=UINT32_MAX) {
        double bound=*(double *)span(dev->instance,d->instance_size,d->bound_step_offset,sizeof(double));
        if(isnan(bound)||bound<=0)fail("eval","invalid bound step");trial_bound=fmin(trial_bound,bound);
    }
    for(uint32_t i=0;i<d->num_states;i++)if(!isfinite(dev->next[i]))fail("eval","nonfinite next state");
}
static void setup_dynamic(void) {
    for(int k=0;k<circuit.device_count;k++) {Device *dev=&circuit.devices[k];OsdiDescriptor *d=dev->descriptor;
        if(!d->load_jacobian_react)fail("admission","missing reactive Jacobian");
        for(uint32_t i=0;i<d->num_jacobian_entries;i++) {OsdiJacobianEntry *e=&d->jacobian_entries[i];
            if(e->react_ptr_off!=UINT32_MAX)*(double **)span(dev->instance,d->instance_size,e->react_ptr_off,sizeof(double *))=
                &raw_c[k][(size_t)e->nodes.node_1*d->num_nodes+e->nodes.node_2];}
    }evaluation_extra=extra;
}
static void dynamic_eval(const double *x,uint32_t mode,double time) {
    evaluation_flags=CALC_RESIST_RESIDUAL|CALC_REACT_RESIDUAL|CALC_RESIST_JACOBIAN|CALC_REACT_JACOBIAN|CALC_OP|mode;
    evaluation_time=time;memset(charges,0,sizeof charges);memset(capacitance,0,sizeof capacitance);trial_bound=INFINITY;
    evaluate(x);
    for(int i=0;i<circuit.dimension;i++) {if(!isfinite(charges[i]))fail("eval","assembled charge overflow");
        for(int j=0;j<circuit.dimension;j++)if(!isfinite(capacitance[(size_t)i*circuit.dimension+j]))fail("eval","capacitance overflow");}
}
static void commit_native(void) {for(int k=0;k<circuit.device_count;k++){Device *d=&circuit.devices[k];memcpy(d->previous,d->next,d->descriptor->num_states*sizeof(double));}}
static void complex_factor(double frequency) {
    int n=circuit.dimension;double omega=2*acos(-1.)*frequency;
    for(int i=0;i<n*n;i++){y[i]=circuit.jac[i]+I*omega*capacitance[i];lu[i]=y[i];}
    for(int k=0;k<n;k++) {
        int pivot=k;for(int i=k+1;i<n;i++)if(cabs(lu[(size_t)i*n+k])>cabs(lu[(size_t)pivot*n+k]))pivot=i;
        if(!isfinite(cabs(lu[(size_t)pivot*n+k]))||cabs(lu[(size_t)pivot*n+k])==0)fail("complex solve","singular matrix");
        pivots[k]=pivot;if(pivot!=k)for(int j=0;j<n;j++){double complex t=lu[(size_t)k*n+j];lu[(size_t)k*n+j]=lu[(size_t)pivot*n+j];lu[(size_t)pivot*n+j]=t;}
        for(int i=k+1;i<n;i++){lu[(size_t)i*n+k]/=lu[(size_t)k*n+k];
            for(int j=k+1;j<n;j++)lu[(size_t)i*n+j]-=lu[(size_t)i*n+k]*lu[(size_t)k*n+j];}
    }
}
static void complex_solve(const double complex *rhs,double complex *x) {
    int n=circuit.dimension;memcpy(x,rhs,(size_t)n*sizeof(*x));
    for(int k=0;k<n;k++){int p=pivots[k];double complex t=x[k];x[k]=x[p];x[p]=t;}
    for(int i=1;i<n;i++)for(int j=0;j<i;j++)x[i]-=lu[(size_t)i*n+j]*x[j];
    for(int i=n-1;i>=0;i--){for(int j=i+1;j<n;j++)x[i]-=lu[(size_t)i*n+j]*x[j];x[i]/=lu[(size_t)i*n+i];
        if(!isfinite(creal(x[i]))||!isfinite(cimag(x[i])))fail("complex solve","nonfinite solution");}
}
static void source_rhs(double complex *rhs,double complex value) {
    Element *e=source_family==0?&circuit.voltages[source_index]:&circuit.currents[source_index];
    if(source_family==0)rhs[e->b]+=value;
    else {if(e->p>=0)rhs[e->p]-=value;if(e->n>=0)rhs[e->n]+=value;}
}
static void emit_complex(double complex z) {if(!isfinite(creal(z))||!isfinite(cimag(z)))fail("output","nonfinite complex value");printf("{\"real\":%.17g,\"imag\":%.17g}",creal(z),cimag(z));}
static void emit_unknowns(const double *x,const double complex *z) {
    putchar('[');for(int i=0;i<circuit.dimension;i++){if(i)putchar(',');printf("{\"id\":");json_string(circuit.unknowns[i].id);printf(",\"unit\":");json_string(circuit.unknowns[i].unit);
        if(z){printf(",\"real\":%.17g,\"imag\":%.17g}",creal(z[i]),cimag(z[i]));}else printf(",\"value\":%.17g}",x[i]);}putchar(']');
}
static double complex_residual(const double complex *x,const double complex *rhs) {
    double worst=0;int n=circuit.dimension;
    for(int i=0;i<n;i++){double complex r=-rhs[i];for(int j=0;j<n;j++)r+=y[(size_t)i*n+j]*x[j];
        double normalized=cabs(r)/circuit.equation_atol[unit_index(circuit.unknowns[i].residual_unit,true)];
        if(!isfinite(normalized))fail("validation","nonfinite complex residual");worst=fmax(worst,normalized);}
    return worst;
}
static void load_candidates(void) {
    if(!candidate_file)return;FILE *stream=fopen(candidate_file,"r");if(!stream)fail("candidate","open failed");
    if(fseek(stream,0,SEEK_END)||ftell(stream)>8*1024*1024||fseek(stream,0,SEEK_SET))fail("candidate","file bound exceeded");
    char line[1024],id[256],tag[16],tail;unsigned point;double a,b;
    while(fgets(line,sizeof line,stream)) {
        int fields=sscanf(line,"%15s %u %255s %lf %lf %c",tag,&point,id,&a,&b,&tail);
        bool has_complex=!strcmp(tag,"complex");if((has_complex&&fields!=5)||(!has_complex&&(strcmp(tag,"value")||fields!=4))||point>MAX_STEPS||!isfinite(a)||(has_complex&&!isfinite(b)))fail("candidate","invalid candidate record");
        int index=find_unknown(id);if(index<0||candidate_given[point][index])fail("candidate","duplicate or ground candidate");
        candidate_given[point][index]=true;candidate_real[point][index]=a;candidate_imag[point][index]=has_complex?b:0;
    }if(ferror(stream)||fclose(stream))fail("candidate","read failed");
}
static void require_candidate(int point) {if(candidate_file)for(int i=0;i<circuit.dimension;i++)if(!candidate_given[point][i])fail("candidate","incomplete candidate vector");}
static void resolve_source(void) {
    if(!source_id)fail("input","missing stimulus source");
    for(int i=0;i<circuit.voltage_count;i++)if(!strcmp(source_id,circuit.voltages[i].id)){source_family=0;source_index=i;}
    for(int i=0;i<circuit.current_count;i++)if(!strcmp(source_id,circuit.currents[i].id)){if(source_index>=0)fail("input","ambiguous source");source_family=1;source_index=i;}
    if(source_index<0)fail("input","unknown stimulus source");
}
static void print_frequency(void) {
    bool noise=!strcmp(kind,"noise");double psd[MAX_FREQUENCIES]={0};int out=noise?find_unknown(output_id):-1,ref=noise?find_unknown(reference_id):-1;
    printf(",\"points\":[");
    for(int f=0;f<frequency_count;f++) {
        dynamic_eval(op,ANALYSIS_AC|(noise?(ANALYSIS_NOISE|CALC_NOISE):0),0);complex_factor(frequencies[f]);
        double complex rhs[MAX_UNKNOWNS]={0},z[MAX_UNKNOWNS]={0};source_rhs(rhs,noise?1:stimulus);complex_solve(rhs,z);
        if(candidate_file){require_candidate(f);for(int i=0;i<circuit.dimension;i++)z[i]=candidate_real[f][i]+I*candidate_imag[f][i];}
        double residual=complex_residual(z,rhs);if(residual>1)candidate_valid=false;
        if(f)putchar(',');printf("{\"frequencyHz\":%.17g,\"normalizedResidual\":%.17g,\"unknowns\":",frequencies[f],residual);emit_unknowns(NULL,z);
        if(noise) {
            double complex gain=(out<0?0:z[out])-(ref<0?0:z[ref]);double gain2=creal(gain)*creal(gain)+cimag(gain)*cimag(gain);
            if(!isfinite(gain2)||gain2<=1e-30)fail("noise","zero or nonfinite input transfer");
            printf(",\"inputGain\":");emit_complex(gain);printf(",\"inputReferredUnit\":");json_string(source_family==0?"V^2/Hz":"A^2/Hz");printf(",\"channels\":[");int emitted=0;
            for(int k=0;k<circuit.device_count+circuit.resistor_count;k++) {
                Device *dev=k<circuit.device_count?&circuit.devices[k]:NULL;OsdiDescriptor *d=dev?dev->descriptor:NULL;
                double densities[MAX_NOISE]={0};uint32_t count=dev?d->num_noise_src:1;
                if(count>MAX_NOISE)fail("noise","source count limit exceeded");
                if(dev){if(count&&!d->load_noise)fail("noise","missing load_noise");d->load_noise(dev->instance,dev->model,frequencies[f],densities);}
                else densities[0]=4*1.380649e-23*noise_temperature/circuit.resistors[k-circuit.device_count].value;
                for(uint32_t j=0;j<count;j++) {
                    double raw_density=densities[j];if(!isfinite(raw_density)){fprintf(stderr,"device=%s sourceIndex=%u name=%s frequency=%.17g density=%.17g\n",dev?dev->id:"resistor",j,dev?d->noise_sources[j].name:"thermal",frequencies[f],raw_density);fail("noise","nonfinite source noise");}
                    double density=fabs(raw_density);
                    int a,b;char id[256];const char *name,*unit;
                    if(dev){OsdiNoiseSource *s=&d->noise_sources[j];if(s->nodes.node_1>=d->num_nodes||(s->nodes.node_2!=UINT32_MAX&&s->nodes.node_2>=d->num_nodes))fail("noise","invalid endpoint");
                        a=(int)dev->global[s->nodes.node_1]-1;b=s->nodes.node_2==UINT32_MAX?-1:(int)dev->global[s->nodes.node_2]-1;
                        unit=d->nodes[s->nodes.node_1].residual_units;if(s->nodes.node_2!=UINT32_MAX&&strcmp(unit,d->nodes[s->nodes.node_2].residual_units))fail("noise","endpoint units differ");
                        snprintf(id,sizeof id,"device:%s:noise:%u",dev->id,j);name=s->name;
                        if(d->noise_source_type[j]>NOISE_TYPE_FLICKER)fail("noise","unsupported source kind");
                    }else{Element *e=&circuit.resistors[k-circuit.device_count];a=e->p;b=e->n;unit="A";name="thermal";snprintf(id,sizeof id,"resistor:%s:thermal",e->id);}
                    memset(rhs,0,sizeof rhs);if(a>=0)rhs[a]+=1;if(b>=0)rhs[b]-=1;complex_solve(rhs,z);
                    double complex h=(out<0?0:z[out])-(ref<0?0:z[ref]);double contribution=(creal(h)*creal(h)+cimag(h)*cimag(h))*density;
                    if(!isfinite(contribution)||contribution<0)fail("noise","output PSD overflow");psd[f]+=contribution;
                    if(emitted++)putchar(',');printf("{\"id\":");json_string(id);printf(",\"index\":%u,\"name\":",j);json_string(name);printf(",\"residualUnit\":");json_string(unit);
                    printf(",\"rawSignedDensity\":%.17g,\"density\":%.17g,\"transfer\":",raw_density,density);emit_complex(h);printf(",\"outputDensity\":%.17g}",contribution);
                }
            }
            if(!isfinite(psd[f]))fail("noise","PSD sum overflow");printf("],\"outputDensity\":%.17g,\"inputReferredDensity\":%.17g",psd[f],psd[f]/gain2);
        }putchar('}');
    }putchar(']');
    if(noise){double integral=0;for(int f=1;f<frequency_count;f++)integral+=(frequencies[f]-frequencies[f-1])*(psd[f]+psd[f-1])*.5;
        if(!isfinite(integral)||integral<0)fail("noise","integral overflow");printf(",\"integratedOutputNoise\":%.17g",sqrt(integral));}
}
static double waveform(double t) {
    if(t<=knots[0].time)return knots[0].value;for(int i=1;i<knot_count;i++)if(t<=knots[i].time){double fraction=(t-knots[i-1].time)/(knots[i].time-knots[i-1].time);return knots[i-1].value+fraction*(knots[i].value-knots[i-1].value);}return knots[knot_count-1].value;
}
static void transient_equations(const double *x,Step step) {
    Element *source=source_family==0?&circuit.voltages[source_index]:&circuit.currents[source_index];source->value=waveform(step.time);
    dynamic_eval(x,ANALYSIS_TRAN,step.time);double alpha=(step.trap?2:1)/step.h;
    for(int i=0;i<circuit.dimension;i++){circuit.f[i]+=alpha*(charges[i]-accepted_q[i])+(step.trap?accepted_f[i]:0);
        for(int j=0;j<circuit.dimension;j++)circuit.jac[(size_t)i*circuit.dimension+j]+=alpha*capacitance[(size_t)i*circuit.dimension+j];}
}
static bool transient_solve(Step step) {
    memcpy(circuit.x,accepted_x,sizeof circuit.x);
    for(int iter=0;iter<circuit.max_iterations;iter++) {
        transient_equations(circuit.x,step);double rhs[MAX_UNKNOWNS],delta[MAX_UNKNOWNS]={0},trial[MAX_UNKNOWNS];double old=merit();
        for(int i=0;i<circuit.dimension;i++)rhs[i]=-circuit.f[i];if(!linear_solve(circuit.jac,rhs,delta))return false;
        bool accepted=false;double alpha=1;
        for(int back=0;back<=circuit.max_backtracks;back++,alpha*=.5){for(int i=0;i<circuit.dimension;i++)trial[i]=circuit.x[i]+alpha*delta[i];transient_equations(trial,step);bool native_transition=false;for(int k=0;k<circuit.device_count;k++){Device *d=&circuit.devices[k];for(uint32_t j=0;j<d->descriptor->num_states;j++)native_transition=native_transition||d->next[j]!=d->previous[j];}
            /* A discrete retained-state transition has no derivative across its jump. */
            if(merit()<=1||merit()<old*(1-1e-4*alpha)||(back==0&&native_transition)){accepted=true;break;}}
        if(!accepted)return false;bool small=true;
        for(int i=0;i<circuit.dimension;i++){double tol=circuit.variable_atol[unit_index(circuit.unknowns[i].unit,false)]+circuit.reltol*fabs(trial[i]);if(fabs(trial[i]-circuit.x[i])>tol)small=false;circuit.x[i]=trial[i];}
        if(small&&merit()<=1)return true;
    }return false;
}
static void print_transient(void) {
    bool uic_mode=!strcmp(initialization,"uic");if(uic_mode){memset(circuit.x,0,sizeof circuit.x);assignments(uic,uic_count,circuit.x,false);}
    Element *initial_source=source_family==0?&circuit.voltages[source_index]:&circuit.currents[source_index];initial_source->value=waveform(0);
    dynamic_eval(circuit.x,ANALYSIS_TRAN|ANALYSIS_IC|ANALYSIS_STATIC,0);commit_native();
    memcpy(accepted_x,circuit.x,sizeof accepted_x);memcpy(accepted_q,charges,sizeof accepted_q);memcpy(accepted_f,circuit.f,sizeof accepted_f);
    if(candidate_file){require_candidate(0);for(int i=0;i<circuit.dimension;i++)if(candidate_real[0][i]!=circuit.x[i])candidate_valid=false;}
    printf(",\"initialization\":");json_string(initialization);printf(",\"points\":[{\"timeSeconds\":0,\"unknowns\":");emit_unknowns(circuit.x,NULL);putchar('}');
    double previous_time=0;
    for(int point=0;point<step_count;point++) {
        Step step=steps[point];if(fabs((step.time-previous_time)-step.h)>16*DBL_EPSILON*fmax(step.time,step.h))fail("transient","inconsistent time and h");
        if(point==forced_reject){double saved[MAX_KNOTS];for(int k=0;k<knot_count;k++){saved[k]=knots[k].value;knots[k].value=0;}
            if(!transient_solve(step))fail("transient","forced trial failed before rejection");for(int k=0;k<knot_count;k++)knots[k].value=saved[k];rejected_trials++;}
        if(candidate_file){require_candidate(point+1);memcpy(circuit.x,candidate_real[point+1],sizeof circuit.x);transient_equations(circuit.x,step);}
        else if(!transient_solve(step))fail("transient","Newton failed");
        double residual=merit();if(residual>1)candidate_valid=false;
        if(step.h>trial_bound)fail("transient","current trial exceeds generated bound step");
        printf(",{\"timeSeconds\":%.17g,\"normalizedResidual\":%.17g,\"unknowns\":",step.time,residual);emit_unknowns(circuit.x,NULL);putchar('}');
        Element *source=source_family==0?&circuit.voltages[source_index]:&circuit.currents[source_index];source->value=waveform(step.time);
        dynamic_eval(circuit.x,ANALYSIS_TRAN,step.time);commit_native();memcpy(accepted_x,circuit.x,sizeof accepted_x);memcpy(accepted_q,charges,sizeof accepted_q);memcpy(accepted_f,circuit.f,sizeof accepted_f);previous_time=step.time;
    }
    printf("],\"acceptedSteps\":[");for(int i=0;i<step_count;i++){if(i)putchar(',');printf("{\"timeSeconds\":%.17g,\"timeStepSeconds\":%.17g,\"method\":",steps[i].time,steps[i].h);json_string(steps[i].trap?"trapezoidal":"backwardEuler");putchar('}');}
    printf("],\"rejectedTrials\":%u",rejected_trials);
}
int main(int argc,char **argv) {
    char *base[8192];int count=1;base[0]=argv[0];if(argc>8192)fail("input","argument limit");
    for(int i=1;i<argc;) {const char *flag=argv[i];int width=0;
        if(!strcmp(flag,"--analysis")||!strcmp(flag,"--frequency")||!strcmp(flag,"--initialize")||!strcmp(flag,"--noise-temperature")||!strcmp(flag,"--candidate-file")||!strcmp(flag,"--operating-point-file")||!strcmp(flag,"--force-reject"))width=1;
        else if(!strcmp(flag,"--stimulus")||!strcmp(flag,"--waveform")||!strcmp(flag,"--step"))width=3;
        else if(!strcmp(flag,"--output")||!strcmp(flag,"--uic"))width=2;
        if(!width){base[count++]=argv[i++];continue;}if(argc-i-1<width)fail("input","missing dynamic operand");const char **a=(const char **)&argv[i+1];i+=width+1;
        if(!strcmp(flag,"--analysis"))kind=a[0];else if(!strcmp(flag,"--frequency")){if(frequency_count==MAX_FREQUENCIES)fail("input","frequency limit");double f=number(a[0]);if(f<=0||(frequency_count&&f<=frequencies[frequency_count-1]))fail("input","frequencies must increase");frequencies[frequency_count++]=f;}
        else if(!strcmp(flag,"--stimulus")){source_id=a[0];stimulus=number(a[1])+I*number(a[2]);}
        else if(!strcmp(flag,"--output")){output_id=a[0];reference_id=a[1];}
        else if(!strcmp(flag,"--noise-temperature")){noise_temperature=number(a[0]);if(noise_temperature<=0)fail("input","noise Kelvin must be positive");}
        else if(!strcmp(flag,"--initialize"))initialization=a[0];
        else if(!strcmp(flag,"--candidate-file"))candidate_file=a[0];
        else if(!strcmp(flag,"--operating-point-file"))op_candidate_file=a[0];
        else if(!strcmp(flag,"--force-reject"))forced_reject=(int)integer(a[0],MAX_STEPS-1);
        else if(!strcmp(flag,"--uic")){if(uic_count==MAX_UNKNOWNS)fail("input","UIC limit");uic[uic_count++]=(Assignment){a[0],number(a[1])};}
        else if(!strcmp(flag,"--waveform")){if(knot_count==MAX_KNOTS)fail("input","waveform limit");if(source_id&&strcmp(source_id,a[0]))fail("input","waveform source differs");source_id=a[0];double t=number(a[1]);if(t<0||(knot_count&&t<=knots[knot_count-1].time))fail("input","waveform times must increase");knots[knot_count++]=(Knot){t,number(a[2])};}
        else {if(step_count==MAX_STEPS)fail("input","step limit");double t=number(a[0]),h=number(a[1]);if(t<=0||h<=0||(step_count&&t<=steps[step_count-1].time)||(strcmp(a[2],"backwardEuler")&&strcmp(a[2],"trapezoidal")))fail("input","invalid accepted step");steps[step_count++]=(Step){t,h,!strcmp(a[2],"trapezoidal")};}
    }
    if(strcmp(kind,"ac")&&strcmp(kind,"noise")&&strcmp(kind,"transient"))fail("input","unsupported analysis");
    if(strcmp(initialization,"operatingPoint")&&strcmp(initialization,"uic"))fail("input","unsupported initialization");
    if(!strcmp(kind,"transient")){if(!step_count||!knot_count)fail("input","missing transient schedule");}
    else if(!frequency_count)fail("input","missing frequencies");
    if(!strcmp(kind,"noise")&&!output_id)fail("input","missing output coordinate");
    parse_circuit(count,base);prepare();setup_dynamic();resolve_source();assignments(circuit.initial,circuit.initial_count,circuit.x,false);
    if(strcmp(kind,"transient")||strcmp(initialization,"uic")){int iterations;const char *reason;const char *status=solve_dc(&iterations,&reason);if(strcmp(status,"converged"))fail("operating point",reason);}
    memcpy(op,circuit.x,sizeof op);
    if(op_candidate_file){const char *saved=candidate_file;candidate_file=op_candidate_file;load_candidates();require_candidate(0);memcpy(op,candidate_real[0],sizeof op);dynamic_eval(op,ANALYSIS_DC|ANALYSIS_STATIC,0);if(merit()>1)fail("operating point","candidate physical residual rejected");candidate_file=saved;memset(candidate_given,0,sizeof candidate_given);}
    load_candidates();
    if(candidate_file&&!strcmp(kind,"transient")&&strcmp(initialization,"uic")){require_candidate(0);memcpy(circuit.x,candidate_real[0],sizeof circuit.x);dynamic_eval(circuit.x,ANALYSIS_DC|ANALYSIS_STATIC,0);if(merit()>1)fail("operating point","initial trajectory candidate residual rejected");}
    printf("{\"schema\":\"corespice.osdi.analysis-result.v1\",\"kind\":");json_string(kind);printf(",\"operatingPoint\":");if(!strcmp(kind,"transient")&&!strcmp(initialization,"uic"))printf("null");else emit_unknowns(op,NULL);
    if(!strcmp(kind,"transient"))print_transient();else print_frequency();
    printf(",\"status\":\"%s\"}\n",candidate_valid?"passed":"invalid");cleanup();return candidate_valid?0:3;
}

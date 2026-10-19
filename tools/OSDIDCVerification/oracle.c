/* Independent trusted-native OSDI 0.4 circuit oracle. No COSDI/CoreSpice linkage. */
#include "osdi_0_4.h"
#include <dlfcn.h>
#include <errno.h>
#include <float.h>
#include <limits.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

enum { MAX_DEVICES=16, MAX_NODES=64, MAX_UNKNOWNS=128, MAX_ELEMENTS=64,
       MAX_STATES=128, MAX_PARAMETERS=8192, MAX_ASSIGNMENTS=1024 };
typedef struct { char id[256]; char unit[4], residual_unit[4]; } Unknown;
typedef struct {
    const char *id; void *library, *model, *instance; OsdiDescriptor *descriptor;
    uint32_t connected, parent[MAX_NODES+1], global[MAX_NODES], roots[MAX_NODES];
    bool terminal_given[MAX_NODES], previous_given[MAX_STATES];
    const char *terminal[MAX_NODES]; bool *given;
    double kelvin, solve[MAX_UNKNOWNS+1], raw_g[MAX_NODES*MAX_NODES];
    double previous[MAX_STATES], next[MAX_STATES];
} Device;
typedef struct { const char *id, *positive, *negative; double value; int p,n,b; } Element;
typedef struct { const char *id; double value; } Assignment;
typedef struct {
    Device devices[MAX_DEVICES]; int device_count;
    Element resistors[MAX_ELEMENTS], voltages[MAX_ELEMENTS], currents[MAX_ELEMENTS];
    int resistor_count, voltage_count, current_count;
    Unknown unknowns[MAX_UNKNOWNS]; int dimension;
    Assignment initial[MAX_UNKNOWNS], candidate[MAX_UNKNOWNS]; int initial_count,candidate_count;
    double variable_atol[3], equation_atol[3], reltol;
    bool tolerance_given[6], reltol_given;
    int max_iterations, max_backtracks; const char *mode;
    double x[MAX_UNKNOWNS], f[MAX_UNKNOWNS], jac[MAX_UNKNOWNS*MAX_UNKNOWNS];
    double scale[MAX_UNKNOWNS], roundoff[MAX_UNKNOWNS];
    unsigned evaluations; size_t allocated_bytes;
} Circuit;
static Circuit circuit;
static uint32_t evaluation_flags=CALC_RESIST_RESIDUAL|CALC_RESIST_JACOBIAN|CALC_OP|ANALYSIS_DC|ANALYSIS_STATIC;
static double evaluation_time=0;
static void (*evaluation_extra)(Device *)=NULL;
static char failure_stage[80], failure_reason[160];

static void json_string(const char *s) {
    if(!s) s="";
    putchar('"');
    for(;*s;s++) { unsigned char c=(unsigned char)*s;
        if(c=='"'||c=='\\') {putchar('\\');putchar(c);}
        else if(c<32)printf("\\u%04x",c);else putchar(c);
    } putchar('"');
}
static void fail(const char *stage,const char *reason) {
    snprintf(failure_stage,sizeof failure_stage,"%s",stage);
    snprintf(failure_reason,sizeof failure_reason,"%s",reason);
    fprintf(stderr,"%s: %s\n",stage,reason);
    printf("{\"schema\":\"corespice.osdi.dc-result.v1\",\"status\":\"failed\",\"stage\":");
    json_string(stage);printf(",\"reason\":");json_string(reason);puts("}");exit(2);
}
static void *allocate(size_t count,size_t width) {
    if(width && count>SIZE_MAX/width)fail("allocation","byte count overflow");
    size_t bytes=count*width;
    if(bytes>64*1024*1024 || circuit.allocated_bytes>128*1024*1024-bytes)
        fail("allocation","workspace byte limit exceeded");
    void *p=calloc(count?count:1,width?width:1);if(!p)fail("allocation","allocation failed");
    circuit.allocated_bytes+=bytes;return p;
}
static void *span(void *base,size_t size,uint32_t offset,size_t bytes) {
    if(offset>size||bytes>size-offset)fail("descriptor","instance span out of bounds");
    return (char *)base+offset;
}
static double number(const char *s) {
    char *end;errno=0;double v=strtod(s,&end);
    if(errno||end==s||*end||!isfinite(v))fail("input","invalid finite number");return v;
}
static unsigned integer(const char *s,unsigned maximum) {
    double v=number(s);if(v<0||v>maximum||v!=floor(v))fail("input","invalid bounded integer");return (unsigned)v;
}
static bool identifier(const char *s) {
    size_t count=0;if(!*s)return false;
    for(;*s;s++,count++)if(!((*s>='a'&&*s<='z')||(*s>='A'&&*s<='Z')||
        (*s>='0'&&*s<='9')||*s=='_'||*s=='.'||*s=='-'))return false;
    return count<100;
}
static int unit_index(const char *s,bool equation) {
    const char *units=equation?"AVW":"VAK";
    if(!s[0]||s[1])fail("policy","unsupported unit");
    const char *p=strchr(units,s[0]);if(!p)fail("policy","unsupported unit");return (int)(p-units);
}
static Device *device(const char *id) {
    for(int i=0;i<circuit.device_count;i++)if(!strcmp(circuit.devices[i].id,id))return &circuit.devices[i];
    fail("input","unknown device id");return NULL;
}
static uint32_t root(Device *d,uint32_t i) {
    while(d->parent[i]!=i)i=d->parent[i];return i;
}
static void logger(void *handle,const char *message,uint32_t level) {
    (void)handle;fprintf(stderr,"model[%u] %s\n",level,message?message:"");
    if(message && !(level&LOG_FMT_ERR))free((void *)message);
}
static void setup_ok(OsdiInitInfo *info,const char *stage) {
    if(info->flags||info->num_errors) {
        fprintf(stderr,"flags=%u errors=%u\n",info->flags,info->num_errors);
        fail(stage,"native setup failed");
    }
}
static Device *load_device(const char **args) {
    if(circuit.device_count==MAX_DEVICES||!identifier(args[0]))fail("input","device limit or invalid id");
    for(int i=0;i<circuit.device_count;i++)if(!strcmp(circuit.devices[i].id,args[0]))fail("input","duplicate device id");
    Device *dev=&circuit.devices[circuit.device_count++];dev->id=args[0];
    unsigned selected=integer(args[2],UINT32_MAX);dev->kelvin=number(args[3]);
    dev->connected=integer(args[4],MAX_NODES);if(dev->kelvin<=0)fail("input","Kelvin must be positive");
    dev->library=dlopen(args[1],RTLD_NOW|RTLD_LOCAL);if(!dev->library)fail("loading",dlerror());
    uint32_t *major=dlsym(dev->library,"OSDI_VERSION_MAJOR"),*minor=dlsym(dev->library,"OSDI_VERSION_MINOR");
    uint32_t *count=dlsym(dev->library,"OSDI_NUM_DESCRIPTORS"),*stride=dlsym(dev->library,"OSDI_DESCRIPTOR_SIZE");
    unsigned char *table=dlsym(dev->library,"OSDI_DESCRIPTORS");
    if(!major||!minor||!count||!stride||!table||*major!=0||*minor!=4||
        *stride<sizeof(OsdiDescriptor)||*count>64||selected>=*count)fail("loading","unsupported ABI");
    dev->descriptor=(OsdiDescriptor *)(table+(size_t)selected**stride);OsdiDescriptor *d=dev->descriptor;
    if(!d->num_nodes||d->num_nodes>MAX_NODES||d->num_terminals>d->num_nodes||dev->connected>d->num_terminals||
        d->num_states>MAX_STATES||d->num_params>MAX_PARAMETERS||d->num_jacobian_entries>MAX_NODES*MAX_NODES||
        d->num_collapsible>MAX_NODES*MAX_NODES||d->absdelay_count)fail("descriptor","descriptor limits exceeded");
    if(!d->nodes||!d->eval||!d->setup_model||!d->setup_instance||!d->access||
        !d->load_jacobian_resist||!d->load_residual_resist)fail("descriptor","missing required entry point");
    void (**log_slot)(void *,const char *,uint32_t)=dlsym(dev->library,"osdi_log");if(log_slot)*log_slot=logger;
    dev->model=allocate(d->model_size,1);dev->instance=allocate(d->instance_size,1);
    dev->given=allocate((size_t)d->num_params*2,sizeof(bool));return dev;
}
static uint32_t node_index(Device *dev,const char *name) {
    for(uint32_t i=0;i<dev->descriptor->num_nodes;i++)if(!strcmp(name,dev->descriptor->nodes[i].name))return i;
    fail("input","unknown raw node name");return 0;
}
static void assign_parameter(const char **a) {
    Device *dev=device(a[0]);OsdiDescriptor *d=dev->descriptor;
    unsigned scope=!strcmp(a[1],"model")?0:(!strcmp(a[1],"instance")?1:2);
    unsigned type=!strcmp(a[2],"real")?PARA_TY_REAL:(!strcmp(a[2],"integer")?PARA_TY_INT:(!strcmp(a[2],"string")?PARA_TY_STR:3));
    uint32_t found=UINT32_MAX;
    for(uint32_t i=0;i<d->num_params;i++)for(uint32_t j=0;j<=d->param_opvar[i].num_alias;j++)
        if(!strcmp(a[3],d->param_opvar[i].name[j])) {
            if(found!=UINT32_MAX&&found!=i)fail("parameter","ambiguous parameter");found=i;
        }
    if(found==UINT32_MAX)fail("parameter","unknown parameter");OsdiParamOpvar *p=&d->param_opvar[found];
    if(scope>1||type!=(p->flags&PARA_TY_MASK)||p->len||(scope==1&&(p->flags>>30)!=1))fail("parameter","type or scope mismatch");
    if(dev->given[found*2+scope])fail("parameter","duplicate canonical/alias assignment");dev->given[found*2+scope]=true;
    void *value=d->access(dev->instance,dev->model,found,ACCESS_FLAG_SET|(scope?ACCESS_FLAG_INSTANCE:0));
    if(!value)fail("parameter","assignment refused");
    if(type==PARA_TY_REAL)*(double *)value=number(a[4]);
    else if(type==PARA_TY_STR)*(const char **)value=a[4];
    else {double v=number(a[4]);if(v<INT32_MIN||v>INT32_MAX||v!=floor(v))fail("parameter","invalid Int32");*(int32_t *)value=(int32_t)v;}
}
static int unknown(const char *id,const char *unit,const char *residual) {
    for(int i=0;i<circuit.dimension;i++)if(!strcmp(circuit.unknowns[i].id,id)) {
        if(strcmp(unit,circuit.unknowns[i].unit)||strcmp(residual,circuit.unknowns[i].residual_unit))fail("topology","incompatible unknown units");return i;
    }
    if(circuit.dimension==MAX_UNKNOWNS||strlen(id)>=sizeof circuit.unknowns[0].id)fail("topology","unknown limit exceeded");
    bool supported=(!strcmp(unit,"V")&&!strcmp(residual,"A"))||(!strcmp(unit,"A")&&!strcmp(residual,"V"))||(!strcmp(unit,"K")&&!strcmp(residual,"W"));
    if(!supported)fail("topology","unsupported nature pair");
    int i=circuit.dimension++;strcpy(circuit.unknowns[i].id,id);strcpy(circuit.unknowns[i].unit,unit);strcpy(circuit.unknowns[i].residual_unit,residual);return i;
}
static int net(const char *name) {
    if(!strcmp(name,"0"))return -1;if(!identifier(name))fail("input","invalid net id");
    char id[256];snprintf(id,sizeof id,"net:%s",name);return unknown(id,"V","A");
}
static void prepare(void) {
    char *names[]={"gmin",NULL},*strings[]={NULL};double values[]={0};
    OsdiSimParas paras={names,values,strings,strings};
    for(int k=0;k<circuit.device_count;k++) {
        Device *dev=&circuit.devices[k];OsdiDescriptor *d=dev->descriptor;uint32_t n=d->num_nodes;
        for(uint32_t i=0;i<dev->connected;i++)if(!dev->terminal_given[i])fail("topology","missing connected terminal binding");
        for(uint32_t i=0;i<d->num_states;i++)if(!dev->previous_given[i])fail("state","missing explicit previous state");
        OsdiInitInfo info={0};d->setup_model(NULL,dev->model,&paras,&info);setup_ok(&info,"setup_model");
        info=(OsdiInitInfo){0};d->setup_instance(NULL,dev->instance,dev->model,dev->kelvin,dev->connected,&paras,&info);setup_ok(&info,"setup_instance");
        for(uint32_t i=0;i<=n;i++)dev->parent[i]=i;
        bool *collapsed=span(dev->instance,d->instance_size,d->collapsed_offset,d->num_collapsible*sizeof(bool));
        for(uint32_t i=0;i<d->num_collapsible;i++)if(collapsed[i]) {
            uint32_t a=d->collapsible[i].node_1,b=d->collapsible[i].node_2;
            if(a>=n||(b!=UINT32_MAX&&b>=n))fail("topology","invalid collapse pair");
            a=root(dev,a);b=root(dev,b==UINT32_MAX?n:b);
            if(a==n)dev->parent[b]=a;else if(b==n)dev->parent[a]=b;else if(a<b)dev->parent[b]=a;else dev->parent[a]=b;
        }
        int root_global[MAX_NODES+1];for(uint32_t i=0;i<=n;i++)root_global[i]=-2;root_global[n]=-1;
        for(uint32_t i=0;i<dev->connected;i++) {
            uint32_t r=root(dev,i);int g=net(dev->terminal[i]);
            if(root_global[r]!=-2&&root_global[r]!=g)fail("topology","collapse merges distinct external nets");root_global[r]=g;
        }
        for(uint32_t i=0;i<n;i++) {
            uint32_t r=root(dev,i);OsdiNode *node=&d->nodes[i];
            if(root_global[r]==-2) {char id[256];snprintf(id,sizeof id,"device:%s:node:%s",dev->id,d->nodes[r].name);root_global[r]=unknown(id,node->units,node->residual_units);}
            int g=root_global[r];if(g>=0) {
                Unknown *u=&circuit.unknowns[g];if(strcmp(u->unit,node->units)||strcmp(u->residual_unit,node->residual_units))fail("topology","collapsed nature mismatch");
                if(node->is_flow!=!strcmp(node->units,"A"))fail("topology","flow metadata mismatch");
            }
            dev->global[i]=(uint32_t)(g+1);dev->roots[i]=r;
        }
        uint32_t *state_indices=span(dev->instance,d->instance_size,d->state_idx_off,d->num_states*sizeof(uint32_t));
        for(uint32_t i=0;i<d->num_states;i++)state_indices[i]=i;
        uint32_t *mapping=span(dev->instance,d->instance_size,d->node_mapping_offset,n*sizeof(uint32_t));
        for(uint32_t i=0;i<n;i++)mapping[i]=dev->global[i];
        double **pointers=span(dev->instance,d->instance_size,d->jacobian_ptr_resist_offset,d->num_jacobian_entries*sizeof(double *));
        for(uint32_t i=0;i<d->num_jacobian_entries;i++) {
            OsdiJacobianEntry *e=&d->jacobian_entries[i];if(e->nodes.node_1>=n||e->nodes.node_2>=n)fail("topology","invalid Jacobian pair");
            pointers[i]=&dev->raw_g[(size_t)e->nodes.node_1*n+e->nodes.node_2];
        }
    }
    Element *lists[]={circuit.resistors,circuit.voltages,circuit.currents};
    int counts[]={circuit.resistor_count,circuit.voltage_count,circuit.current_count};
    for(int k=0;k<3;k++)for(int i=0;i<counts[k];i++) {
        Element *e=&lists[k][i];e->p=net(e->positive);e->n=net(e->negative);e->b=-1;
        if(k==1) {char id[256];snprintf(id,sizeof id,"branch:%s",e->id);e->b=unknown(id,"A","V");}
    }
    if(!circuit.dimension)fail("topology","empty circuit");
}
static void add_f(int row,double value) {
    if(row<0)return;if(!isfinite(value))fail("evaluation","nonfinite physical contribution");
    circuit.f[row]+=value;circuit.scale[row]+=fabs(value);
}
static void add_j(int row,int col,double value) {if(row>=0&&col>=0)circuit.jac[(size_t)row*circuit.dimension+col]+=value;}
static double voltage(const double *x,int index) {return index<0?0:x[index];}
static void evaluate(const double *x) {
    int n=circuit.dimension;memset(circuit.f,0,sizeof circuit.f);memset(circuit.scale,0,sizeof circuit.scale);memset(circuit.jac,0,sizeof circuit.jac);
    char *names[]={"gmin",NULL},*strings[]={NULL};double values[]={0};OsdiSimParas paras={names,values,strings,strings};
    for(int k=0;k<circuit.device_count;k++) {
        Device *dev=&circuit.devices[k];OsdiDescriptor *d=dev->descriptor;uint32_t raw=d->num_nodes;
        dev->solve[0]=0;for(int i=0;i<n;i++)dev->solve[i+1]=x[i];
        memset(dev->raw_g,0,sizeof dev->raw_g);memcpy(dev->next,dev->previous,sizeof dev->next);
        OsdiSimInfo info={.paras=paras,.abstime=evaluation_time,.prev_solve=dev->solve,.prev_state=dev->previous,.next_state=dev->next,
            .flags=evaluation_flags};
        uint32_t flags=d->eval(NULL,dev->instance,dev->model,&info);if(flags) {fprintf(stderr,"device %s eval flags=%u\n",dev->id,flags);fail("eval","native model flags");}
        d->load_jacobian_resist(dev->instance,dev->model);
        if(evaluation_extra)evaluation_extra(dev);
        for(uint32_t i=0;i<raw;i++) {
            int row=(int)dev->global[i]-1;uint32_t offset=d->nodes[i].resist_residual_off;
            double f=offset==UINT32_MAX?0:*(double *)span(dev->instance,d->instance_size,offset,sizeof(double));add_f(row,f);
            for(uint32_t j=0;j<raw;j++)add_j(row,(int)dev->global[j]-1,dev->raw_g[(size_t)i*raw+j]);
        }
    }
    for(int i=0;i<circuit.resistor_count;i++) {
        Element *e=&circuit.resistors[i];double g=1/e->value,v=voltage(x,e->p)-voltage(x,e->n),current=g*v;
        add_f(e->p,current);add_f(e->n,-current);add_j(e->p,e->p,g);add_j(e->n,e->n,g);add_j(e->p,e->n,-g);add_j(e->n,e->p,-g);
    }
    for(int i=0;i<circuit.current_count;i++) {Element *e=&circuit.currents[i];add_f(e->p,e->value);add_f(e->n,-e->value);}
    for(int i=0;i<circuit.voltage_count;i++) {
        Element *e=&circuit.voltages[i];add_f(e->p,x[e->b]);add_f(e->n,-x[e->b]);
        add_f(e->b,voltage(x,e->p));add_f(e->b,-voltage(x,e->n));add_f(e->b,-e->value);
        add_j(e->p,e->b,1);add_j(e->n,e->b,-1);add_j(e->b,e->p,1);add_j(e->b,e->n,-1);
    }
    for(int i=0;i<n;i++) {
        if(!isfinite(circuit.f[i])||!isfinite(circuit.scale[i]))fail("evaluation","nonfinite assembled residual");
        for(int j=0;j<n;j++)if(!isfinite(circuit.jac[(size_t)i*n+j]))fail("evaluation","nonfinite assembled Jacobian");
        circuit.roundoff[i]=32*DBL_EPSILON*circuit.scale[i];
    }
    circuit.evaluations++;
}
static double merit(void) {
    double m=0;for(int i=0;i<circuit.dimension;i++) {int unit=unit_index(circuit.unknowns[i].residual_unit,true);
        double q=fabs(circuit.f[i])/circuit.equation_atol[unit];if(q>m)m=q;
    }return m;
}
static bool linear_solve(const double *matrix,const double *rhs,double *solution) {
    int n=circuit.dimension;double a[MAX_UNKNOWNS*MAX_UNKNOWNS],b[MAX_UNKNOWNS];
    for(int i=0;i<n;i++) {
        double scale=0;for(int j=0;j<n;j++)scale=fmax(scale,fabs(matrix[(size_t)i*n+j]));
        if(scale==0||!isfinite(scale))return false;
        for(int j=0;j<n;j++)a[(size_t)i*n+j]=matrix[(size_t)i*n+j]/scale;b[i]=rhs[i]/scale;
    }
    for(int k=0;k<n;k++) {
        int pivot=k;for(int i=k+1;i<n;i++)if(fabs(a[(size_t)i*n+k])>fabs(a[(size_t)pivot*n+k]))pivot=i;
        if(a[(size_t)pivot*n+k]==0)return false;
        if(pivot!=k) {for(int j=k;j<n;j++){double t=a[(size_t)k*n+j];a[(size_t)k*n+j]=a[(size_t)pivot*n+j];a[(size_t)pivot*n+j]=t;}double t=b[k];b[k]=b[pivot];b[pivot]=t;}
        for(int i=k+1;i<n;i++) {double factor=a[(size_t)i*n+k]/a[(size_t)k*n+k];a[(size_t)i*n+k]=0;
            for(int j=k+1;j<n;j++)a[(size_t)i*n+j]-=factor*a[(size_t)k*n+j];b[i]-=factor*b[k];}
    }
    for(int i=n-1;i>=0;i--) {double v=b[i];for(int j=i+1;j<n;j++)v-=a[(size_t)i*n+j]*solution[j];solution[i]=v/a[(size_t)i*n+i];if(!isfinite(solution[i]))return false;}
    return true;
}
static void assignments(Assignment *items,int count,double *x,bool complete) {
    bool given[MAX_UNKNOWNS]={0};
    for(int k=0;k<count;k++) {int index=-1;for(int i=0;i<circuit.dimension;i++)if(!strcmp(items[k].id,circuit.unknowns[i].id))index=i;
        if(index<0||given[index])fail("input","unknown or duplicate semantic assignment");given[index]=true;x[index]=items[k].value;}
    if(complete)for(int i=0;i<circuit.dimension;i++)if(!given[i])fail("input","missing candidate unknown");
}
static void print_result(const char *status,const char *reason,int iterations) {
    bool completed=!strcmp(status,"converged")||!strcmp(status,"valid");
    printf("{\"schema\":\"corespice.osdi.dc-result.v1\",\"status\":");json_string(status);printf(",\"reason\":");json_string(reason);
    printf(",\"iterations\":%d,\"evaluations\":%u,\"dimension\":%d,\"longDoubleMantissaBits\":%d,\"%s\":[",iterations,circuit.evaluations,circuit.dimension,LDBL_MANT_DIG,completed?"unknowns":"candidateUnknowns");
    double absolute_by_unit[3]={0};
    for(int i=0;i<circuit.dimension;i++) {
        Unknown *u=&circuit.unknowns[i];int unit=unit_index(u->residual_unit,true);double normalized=fabs(circuit.f[i])/circuit.equation_atol[unit];
        absolute_by_unit[unit]+=fabs(circuit.f[i]);if(i)putchar(',');
        printf("{\"id\":");json_string(u->id);printf(",\"unit\":");json_string(u->unit);printf(",\"residualUnit\":");json_string(u->residual_unit);
        printf(",\"value\":%.17g,\"residual\":%.17g,\"physicalTermScale\":%.17g,\"assemblyRoundoffAllowance\":%.17g,\"normalizedResidual\":%.17g}",circuit.x[i],circuit.f[i],circuit.scale[i],circuit.roundoff[i],normalized);
    }
    printf("],\"residualAbsoluteSums\":{\"A\":%.17g,\"V\":%.17g,\"W\":%.17g},\"devices\":[",absolute_by_unit[0],absolute_by_unit[1],absolute_by_unit[2]);
    for(int k=0;k<circuit.device_count;k++) {
        Device *dev=&circuit.devices[k];OsdiDescriptor *d=dev->descriptor;if(k)putchar(',');printf("{\"id\":");json_string(dev->id);
        printf(",\"descriptorName\":");json_string(d->name);printf(",\"rawNodes\":[");
        for(uint32_t i=0;i<d->num_nodes;i++) {if(i)putchar(',');printf("{\"index\":%u,\"name\":",i);json_string(d->nodes[i].name);
            printf(",\"unknownID\":");if(dev->global[i])json_string(circuit.unknowns[dev->global[i]-1].id);else printf("null");
            printf(",\"unit\":");json_string(d->nodes[i].units);printf(",\"residualUnit\":");json_string(d->nodes[i].residual_units);printf(",\"isFlow\":%s}",d->nodes[i].is_flow?"true":"false");}
        printf("]}");
    }puts("]}");
}
static void cleanup(void) {
    for(int i=0;i<circuit.device_count;i++) {Device *d=&circuit.devices[i];free(d->model);free(d->instance);free(d->given);if(dlclose(d->library))fail("cleanup","library close failed");}
}
static void parse_circuit(int argc,char **argv) {
    circuit.max_iterations=80;circuit.max_backtracks=24;circuit.mode="solve";
    size_t argv_bytes=0;if(argc>8192)fail("input","argument count limit");
    for(int i=0;i<argc;i++){size_t length=strlen(argv[i]);if(length>4096||argv_bytes>1024*1024-length)fail("input","argument bytes limit");argv_bytes+=length;}
    for(int i=1;i<argc;) {
        const char *flag=argv[i++];int width=0;
        if(!strcmp(flag,"--device")||!strcmp(flag,"--parameter"))width=5;
        else if(!strcmp(flag,"--resistor")||!strcmp(flag,"--voltage-source")||!strcmp(flag,"--current-source"))width=4;
        else if(!strcmp(flag,"--terminal")||!strcmp(flag,"--previous-state"))width=3;
        else if(!strcmp(flag,"--initial")||!strcmp(flag,"--candidate")||!strcmp(flag,"--unknown-atol")||!strcmp(flag,"--equation-atol"))width=2;
        else if(!strcmp(flag,"--mode")||!strcmp(flag,"--reltol")||!strcmp(flag,"--max-iterations")||!strcmp(flag,"--max-backtracks"))width=1;
        else fail("input","unknown option");
        if(argc-i<width)fail("input","missing option operand");const char **a=(const char **)&argv[i];i+=width;
        if(!strcmp(flag,"--device"))load_device(a);
        else if(!strcmp(flag,"--parameter"))assign_parameter(a);
        else if(!strcmp(flag,"--terminal")) {Device *d=device(a[0]);uint32_t n=node_index(d,a[1]);if(n>=d->connected||d->terminal_given[n])fail("input","duplicate or nonterminal binding");d->terminal_given[n]=true;d->terminal[n]=a[2];}
        else if(!strcmp(flag,"--previous-state")) {Device *d=device(a[0]);uint32_t n=integer(a[1],MAX_STATES-1);if(n>=d->descriptor->num_states||d->previous_given[n])fail("input","invalid previous state");d->previous_given[n]=true;d->previous[n]=number(a[2]);}
        else if(!strcmp(flag,"--resistor")||!strcmp(flag,"--voltage-source")||!strcmp(flag,"--current-source")) {
            int *count;Element *list;if(!strcmp(flag,"--resistor")){count=&circuit.resistor_count;list=circuit.resistors;}else if(!strcmp(flag,"--voltage-source")){count=&circuit.voltage_count;list=circuit.voltages;}else{count=&circuit.current_count;list=circuit.currents;}
            if(*count==MAX_ELEMENTS||!identifier(a[0]))fail("input","element limit or invalid id");
            for(int j=0;j<*count;j++)if(!strcmp(list[j].id,a[0]))fail("input","duplicate element id");
            double value=number(a[3]);if(list==circuit.resistors&&value<=0)fail("input","resistance must be positive");
            list[(*count)++]=(Element){.id=a[0],.positive=a[1],.negative=a[2],.value=value};
        }
        else if(!strcmp(flag,"--initial")||!strcmp(flag,"--candidate")) {bool candidate=!strcmp(flag,"--candidate");int *count=candidate?&circuit.candidate_count:&circuit.initial_count;Assignment *items=candidate?circuit.candidate:circuit.initial;
            if(*count==MAX_UNKNOWNS)fail("input","assignment limit");items[(*count)++]=(Assignment){a[0],number(a[1])};}
        else if(!strcmp(flag,"--unknown-atol")||!strcmp(flag,"--equation-atol")) {bool equation=!strcmp(flag,"--equation-atol");int index=unit_index(a[0],equation);int flag_index=index+(equation?3:0);
            if(circuit.tolerance_given[flag_index])fail("policy","duplicate unit policy");double value=number(a[1]);if(value<=0)fail("policy","absolute tolerance must be positive");circuit.tolerance_given[flag_index]=true;(equation?circuit.equation_atol:circuit.variable_atol)[index]=value;}
        else if(!strcmp(flag,"--reltol")){if(circuit.reltol_given)fail("policy","duplicate relative policy");circuit.reltol_given=true;circuit.reltol=number(a[0]);if(circuit.reltol<0)fail("policy","negative relative tolerance");}
        else if(!strcmp(flag,"--max-iterations")){circuit.max_iterations=(int)integer(a[0],1000);if(!circuit.max_iterations)fail("policy","zero iterations");}
        else if(!strcmp(flag,"--max-backtracks"))circuit.max_backtracks=(int)integer(a[0],40);
        else circuit.mode=a[0];
    }
    for(int i=0;i<6;i++)if(!circuit.tolerance_given[i])fail("policy","missing explicit unit tolerance");
    if(!circuit.reltol_given)fail("policy","missing relative tolerance");
    if(strcmp(circuit.mode,"solve")&&strcmp(circuit.mode,"validate"))fail("input","invalid mode");
}
static const char *solve_dc(int *iteration_count,const char **failure) {
    const char *status="nonconvergent",*reason="iteration limit";int iterations=0;
    evaluate(circuit.x);
    for(int iter=0;iter<circuit.max_iterations;iter++) {
        double rhs[MAX_UNKNOWNS],delta[MAX_UNKNOWNS]={0},trial[MAX_UNKNOWNS];double old_merit=merit();
        for(int i=0;i<circuit.dimension;i++)rhs[i]=-circuit.f[i];
        if(!linear_solve(circuit.jac,rhs,delta)){status="singular";reason="zero pivot or nonfinite linear solve";break;}
        double alpha=1;bool accepted=false;
        for(int step=0;step<=circuit.max_backtracks;step++,alpha*=.5) {
            bool finite=true;for(int i=0;i<circuit.dimension;i++){trial[i]=circuit.x[i]+alpha*delta[i];finite=finite&&isfinite(trial[i]);}
            if(!finite)continue;evaluate(trial);double current=merit();
            if(current<=1||current<old_merit*(1-1e-4*alpha)){accepted=true;break;}
        }
        if(!accepted){evaluate(circuit.x);reason="backtracking exhausted";break;}
        bool update_ok=true,changed=false;
        for(int i=0;i<circuit.dimension;i++) {int unit=unit_index(circuit.unknowns[i].unit,false);double tolerance=circuit.variable_atol[unit]+circuit.reltol*fabs(trial[i]);
            if(fabs(trial[i]-circuit.x[i])>tolerance)update_ok=false;changed=changed||trial[i]!=circuit.x[i];circuit.x[i]=trial[i];}
        iterations=iter+1;
        if(update_ok&&merit()<=1){status="converged";reason="update and physical residual accepted";break;}
        if(!changed){reason="stagnated above physical tolerance";break;}
    }
    *iteration_count=iterations;*failure=reason;return status;
}
#ifndef OSDI_ORACLE_NO_MAIN
int main(int argc,char **argv) {
    parse_circuit(argc,argv);prepare();assignments(circuit.initial,circuit.initial_count,circuit.x,false);
    if(!strcmp(circuit.mode,"validate")) {assignments(circuit.candidate,circuit.candidate_count,circuit.x,true);evaluate(circuit.x);bool valid=merit()<=1;print_result(valid?"valid":"invalid",valid?"physical residual accepted":"physical residual rejected",0);cleanup();return valid?0:3;}
    if(circuit.candidate_count)fail("input","candidate requires validate mode");
    int iterations=0;const char *reason;const char *status=solve_dc(&iterations,&reason);
    print_result(status,reason,iterations);cleanup();return !strcmp(status,"converged")?0:3;
}
#endif

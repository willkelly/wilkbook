/* parbench: can a parallel NEON transpose hit <50 ms CONSISTENTLY on the
 * shipped low-power governor?
 *
 * Topology (measured): policy0 covers cpus 0-3, i.e. ONE shared clock domain,
 * so core pinning cannot raise frequency -- it can only avoid migration.
 * conservative has up_threshold=80 and freq_step=5, and the range starts at
 * 408 MHz.  A single-threaded burst is ~25 % system load on 4 cores, which is
 * well under the 80 % up-threshold, so the governor has little reason to ramp:
 * that is why single-threaded times swing 58-97 ms.
 *
 * Parallelising should help twice: N x the compute, and enough load to pull
 * the governor up.  Reports the CPU frequency seen during each run so the two
 * effects can be told apart.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <sched.h>
#include <sys/mman.h>
#include <arm_neon.h>

#define W 1872
#define H 1404
#define STRIDE 7488
#define PITCH  (STRIDE/4)
#define SPITCH H
#define LEN ((size_t)STRIDE*H)

static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);
  return t.tv_sec+t.tv_nsec/1e9;}
static long curfreq(void){
  FILE*f=fopen("/sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq","r");
  if(!f)return -1; long v=-1; if(fscanf(f,"%ld",&v)!=1)v=-1; fclose(f); return v;}

static inline void tr4(uint32x4_t*a,uint32x4_t*b,uint32x4_t*c,uint32x4_t*e){
  uint32x4x2_t p=vtrnq_u32(*a,*b),q=vtrnq_u32(*c,*e);
  *a=vcombine_u32(vget_low_u32 (p.val[0]),vget_low_u32 (q.val[0]));
  *b=vcombine_u32(vget_low_u32 (p.val[1]),vget_low_u32 (q.val[1]));
  *c=vcombine_u32(vget_high_u32(p.val[0]),vget_high_u32(q.val[0]));
  *e=vcombine_u32(vget_high_u32(p.val[1]),vget_high_u32(q.val[1]));}

struct job{uint32_t*d;const uint32_t*s;int y0,y1,T,cpu,pin;};

static void band(uint32_t*d,const uint32_t*s,int y0,int y1,int T){
  for(int yb=y0;yb<y1;yb+=T){int ym=(yb+T<y1)?yb+T:y1; ym-=(ym-yb)%4;
    for(int x0=0;x0<W;x0+=T){int xm=(x0+T<W)?x0+T:W; xm-=(xm-x0)%4;
      for(int y=yb;y<ym;y+=4)
        for(int x=x0;x<xm;x+=4){
          uint32x4_t r0=vld1q_u32(s+(size_t)(x+0)*SPITCH+y);
          uint32x4_t r1=vld1q_u32(s+(size_t)(x+1)*SPITCH+y);
          uint32x4_t r2=vld1q_u32(s+(size_t)(x+2)*SPITCH+y);
          uint32x4_t r3=vld1q_u32(s+(size_t)(x+3)*SPITCH+y);
          tr4(&r0,&r1,&r2,&r3);
          vst1q_u32(d+(size_t)(y+0)*PITCH+x,r0);
          vst1q_u32(d+(size_t)(y+1)*PITCH+x,r1);
          vst1q_u32(d+(size_t)(y+2)*PITCH+x,r2);
          vst1q_u32(d+(size_t)(y+3)*PITCH+x,r3);}}}
  /* ragged tail of this band, scalar */
  for(int y=y0;y<y1;y++){int done=((y-y0)/T)*T; (void)done;
    uint32_t*dr=d+(size_t)y*PITCH;
    for(int x=(W/4)*4;x<W;x++) dr[x]=s[(size_t)x*SPITCH+y];}
}
static void*worker(void*p){struct job*j=p;
  if(j->pin){cpu_set_t m;CPU_ZERO(&m);CPU_SET(j->cpu,&m);
    pthread_setaffinity_np(pthread_self(),sizeof m,&m);}
  band(j->d,j->s,j->y0,j->y1,j->T); return NULL;}

static void par(uint32_t*d,const uint32_t*s,int T,int n,int pin){
  pthread_t th[8]; struct job jb[8];
  int rows=H/n, y=0;
  for(int i=0;i<n;i++){
    jb[i]=(struct job){d,s,y,(i==n-1)?H:y+rows,T,i,pin};
    y+=rows;
    if(i) pthread_create(&th[i],NULL,worker,&jb[i]);}
  worker(&jb[0]);
  for(int i=1;i<n;i++) pthread_join(th[i],NULL);}

static uint32_t*REF;
static void t_ref(uint32_t*d,const uint32_t*s){
  for(int y=0;y<H;y++){uint32_t*dr=d+(size_t)y*PITCH;
    for(int x=0;x<W;x++) dr[x]=s[(size_t)x*SPITCH+y];}}
static int check(uint32_t*d){for(int y=0;y<H;y++)
  if(memcmp(d+(size_t)y*PITCH,REF+(size_t)y*PITCH,(size_t)W*4))return y+1; return 0;}

int main(int argc,char**argv){
  setvbuf(stdout,NULL,_IONBF,0);
  int usefb = (argc>1 && !strcmp(argv[1],"fb"));
  uint32_t*src=aligned_alloc(64,LEN),*ram=aligned_alloc(64,LEN);
  REF=aligned_alloc(64,LEN);
  if(!src||!ram||!REF){fprintf(stderr,"alloc\n");return 1;}
  for(size_t i=0;i<LEN/4;i++) src[i]=(uint32_t)(i*2654435761u);
  t_ref(REF,src);
  uint32_t*dst=ram; int fd=-1;
  if(usefb){fd=open("/dev/fb0",O_RDWR);
    if(fd>=0){void*m=mmap(NULL,LEN,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
      if(m!=MAP_FAILED) dst=m; else {printf("mmap failed\n");return 1;}}
    else {printf("no fb0\n");return 1;}}
  printf("parbench: dest=%s  governor=%s\n", usefb?"FRAMEBUFFER":"RAM", argv[2]?argv[2]:"?");
  printf("  %-28s %8s %8s %8s   %s\n","variant","best_ms","med_ms","worst_ms","MHz@run");
  for(int pin=0;pin<2;pin++)
   for(int n=1;n<=4;n++){
    if(pin&&n==1) continue;
    double v[7]; long fq=0;
    for(int r=0;r<7;r++){
      double a=now(); par(dst,src,64,n,pin); v[r]=(now()-a)*1000.0;
      if(r==3) fq=curfreq();
      usleep(400000);}
    int bad=check(dst);
    for(int i=0;i<7;i++)for(int j=i+1;j<7;j++) if(v[j]<v[i]){double t=v[i];v[i]=v[j];v[j]=t;}
    char nm[40]; snprintf(nm,sizeof nm,"NEON x%d%s",n,pin?" pinned":"");
    printf("  %-28s %8.1f %8.1f %8.1f   %ld%s\n",nm,v[0],v[3],v[6],fq/1000,
           bad?"  WRONG":"");
   }
  if(fd>=0)close(fd);
  return 0;}

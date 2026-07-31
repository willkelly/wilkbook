/* neonbench: can a NEON block transpose of the framebuffer beat 50 ms?
 *
 * Baseline (transbench.c, 2026-07-31): best scalar tiled 64x64 = 67.8 ms into
 * the framebuffer, against the 50 ms deferred-io period.  memcpy of the same
 * bytes is 4.8 ms RAM->RAM, so the transpose sits 14x above the streaming
 * floor: the cost is the strided read, where each column touch pulls a whole
 * 64-byte line for 4 useful bytes.
 *
 * Every variant is checked against a scalar reference before it is timed --
 * a fast wrong transpose is worse than a slow right one.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <arm_neon.h>

#define W 1872
#define H 1404
#define STRIDE 7488
#define PITCH  (STRIDE/4)   /* dest (landscape) pitch: 1872 */
#define SPITCH H            /* src is portrait-shaped: 1404 wide */
#define LEN ((size_t)STRIDE*H)

static double now(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t);
  return t.tv_sec + t.tv_nsec/1e9; }

/* reference: dst[y][x] = src[x][y] */
static void t_ref(uint32_t *d, const uint32_t *s){
  for (int y=0;y<H;y++){ uint32_t *dr=d+(size_t)y*PITCH;
    for (int x=0;x<W;x++) dr[x]=s[(size_t)x*SPITCH+y]; } }

static void t_tiled(uint32_t *d, const uint32_t *s, int T){
  for (int y0=0;y0<H;y0+=T){ int ym=(y0+T<H)?y0+T:H;
    for (int x0=0;x0<W;x0+=T){ int xm=(x0+T<W)?x0+T:W;
      for (int y=y0;y<ym;y++){ uint32_t *dr=d+(size_t)y*PITCH;
        for (int x=x0;x<xm;x++) dr[x]=s[(size_t)x*SPITCH+y]; } } } }
static void w_t64(uint32_t*d,const uint32_t*s,int u){(void)u;t_tiled(d,s,64);}

/* NEON 4x4 block transpose of 32-bit lanes */
static inline void tr4(uint32x4_t *a,uint32x4_t *b,uint32x4_t *c,uint32x4_t *e){
  uint32x4x2_t p=vtrnq_u32(*a,*b), q=vtrnq_u32(*c,*e);
  *a=vcombine_u32(vget_low_u32 (p.val[0]),vget_low_u32 (q.val[0]));
  *b=vcombine_u32(vget_low_u32 (p.val[1]),vget_low_u32 (q.val[1]));
  *c=vcombine_u32(vget_high_u32(p.val[0]),vget_high_u32(q.val[0]));
  *e=vcombine_u32(vget_high_u32(p.val[1]),vget_high_u32(q.val[1]));
}

/* NEON, blocked at T (multiple of 4), 4x4 micro-transposes inside */
static void t_neon(uint32_t *d, const uint32_t *s, int T){
  for (int y0=0;y0<H;y0+=T){ int ym=(y0+T<H)?y0+T:H; ym-=(ym-y0)%4;
    for (int x0=0;x0<W;x0+=T){ int xm=(x0+T<W)?x0+T:W; xm-=(xm-x0)%4;
      for (int y=y0;y<ym;y+=4){
        for (int x=x0;x<xm;x+=4){
          /* read 4 source rows (source row = a dest column) */
          uint32x4_t r0=vld1q_u32(s+(size_t)(x+0)*SPITCH+y);
          uint32x4_t r1=vld1q_u32(s+(size_t)(x+1)*SPITCH+y);
          uint32x4_t r2=vld1q_u32(s+(size_t)(x+2)*SPITCH+y);
          uint32x4_t r3=vld1q_u32(s+(size_t)(x+3)*SPITCH+y);
          tr4(&r0,&r1,&r2,&r3);
          vst1q_u32(d+(size_t)(y+0)*PITCH+x,r0);
          vst1q_u32(d+(size_t)(y+1)*PITCH+x,r1);
          vst1q_u32(d+(size_t)(y+2)*PITCH+x,r2);
          vst1q_u32(d+(size_t)(y+3)*PITCH+x,r3);
        } } } }
  /* ragged edges scalar */
  for (int y=(H/4)*4;y<H;y++){ uint32_t*dr=d+(size_t)y*PITCH;
    for(int x=0;x<W;x++) dr[x]=s[(size_t)x*SPITCH+y]; }
  for (int y=0;y<(H/4)*4;y++){ uint32_t*dr=d+(size_t)y*PITCH;
    for(int x=(W/4)*4;x<W;x++) dr[x]=s[(size_t)x*SPITCH+y]; }
}

/* NEON + software prefetch of the next source column group */
static void t_neon_pf(uint32_t *d, const uint32_t *s, int T){
  for (int y0=0;y0<H;y0+=T){ int ym=(y0+T<H)?y0+T:H; ym-=(ym-y0)%4;
    for (int x0=0;x0<W;x0+=T){ int xm=(x0+T<W)?x0+T:W; xm-=(xm-x0)%4;
      for (int y=y0;y<ym;y+=4){
        for (int x=x0;x<xm;x+=4){
          __builtin_prefetch(s+(size_t)(x+4)*SPITCH+y,0,0);
          __builtin_prefetch(s+(size_t)(x+5)*SPITCH+y,0,0);
          uint32x4_t r0=vld1q_u32(s+(size_t)(x+0)*SPITCH+y);
          uint32x4_t r1=vld1q_u32(s+(size_t)(x+1)*SPITCH+y);
          uint32x4_t r2=vld1q_u32(s+(size_t)(x+2)*SPITCH+y);
          uint32x4_t r3=vld1q_u32(s+(size_t)(x+3)*SPITCH+y);
          tr4(&r0,&r1,&r2,&r3);
          vst1q_u32(d+(size_t)(y+0)*PITCH+x,r0);
          vst1q_u32(d+(size_t)(y+1)*PITCH+x,r1);
          vst1q_u32(d+(size_t)(y+2)*PITCH+x,r2);
          vst1q_u32(d+(size_t)(y+3)*PITCH+x,r3);
        } } } }
  for (int y=(H/4)*4;y<H;y++){ uint32_t*dr=d+(size_t)y*PITCH;
    for(int x=0;x<W;x++) dr[x]=s[(size_t)x*SPITCH+y]; }
  for (int y=0;y<(H/4)*4;y++){ uint32_t*dr=d+(size_t)y*PITCH;
    for(int x=(W/4)*4;x<W;x++) dr[x]=s[(size_t)x*SPITCH+y]; }
}

static uint32_t *REF;
static int check(uint32_t *d){
  for (int y=0;y<H;y++) if (memcmp(d+(size_t)y*PITCH, REF+(size_t)y*PITCH, (size_t)W*4))
      return y+1;
  return 0; }

static double bench(const char*name, void(*fn)(uint32_t*,const uint32_t*,int),
                    uint32_t*d, const uint32_t*s, int T, int reps){
  memset(d,0,LEN); fn(d,s,T);
  int bad=check(d);
  double b=1e9;
  for(int i=0;i<reps;i++){ double a=now(); fn(d,s,T); double e=now()-a; if(e<b)b=e; usleep(200000);}
  printf("  %-38s %7.1f ms   %s%s\n",name,b*1000.0,
         bad?"WRONG at row ":"ok", bad?"":"");
  if(bad) printf("      ^ mismatch first at dest row %d\n",bad-1);
  return b*1000.0; }

int main(void){
  setvbuf(stdout,NULL,_IONBF,0);
  uint32_t *src=aligned_alloc(64,LEN), *dst=aligned_alloc(64,LEN);
  REF=aligned_alloc(64,LEN);
  if(!src||!dst||!REF){fprintf(stderr,"alloc\n");return 1;}
  for(size_t i=0;i<LEN/4;i++) src[i]=(uint32_t)(i*2654435761u);
  memset(REF,0,LEN); t_ref(REF,src);

  printf("neonbench: %dx%d, budget 50 ms (scalar tiled64 baseline was 67.8 ms)\n\n",W,H);
  printf("  --- RAM -> RAM ---\n");
  bench("scalar tiled 64x64",w_t64,dst,src,0,3);
  for(int T=32;T<=128;T*=2){char n[64];snprintf(n,sizeof n,"NEON 4x4, tile %d",T);
    bench(n,t_neon,dst,src,T,3);}
  bench("NEON 4x4 + prefetch, tile 64",t_neon_pf,dst,src,64,3);

  int fd=open("/dev/fb0",O_RDWR);
  if(fd<0){printf("\n  (no /dev/fb0)\n");return 0;}
  uint32_t *fb=mmap(NULL,LEN,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
  if(fb==MAP_FAILED){printf("\n  (mmap failed)\n");return 0;}
  printf("\n  --- RAM -> FRAMEBUFFER (the actual shadow blit) ---\n");
  double best=1e9,v;
  v=bench("scalar tiled 64x64 -> fb",w_t64,fb,src,0,3); if(v<best)best=v;
  for(int T=32;T<=128;T*=2){char n[64];snprintf(n,sizeof n,"NEON 4x4, tile %d -> fb",T);
    v=bench(n,t_neon,fb,src,T,3); if(v<best)best=v;}
  v=bench("NEON 4x4 + prefetch, tile 64 -> fb",t_neon_pf,fb,src,64,3); if(v<best)best=v;
  printf("\n  best into fb: %.1f ms -> %s\n",best,
     best<50.0?"FITS 50 ms: shadow route viable unaided":"still over 50 ms");
  munmap(fb,LEN);close(fd);return 0;
}

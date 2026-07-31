/* transbench: how fast is a bulk framebuffer transpose in C on this SoC?
 *
 * The shadow-buffer fix for the portrait two-pass would render unrotated into
 * RAM and then perform ONE bulk transpose-blit into the framebuffer.  Only
 * that blit is exposed to deferred-io, so it must fit inside the 50 ms period
 * (drm_fbdev_shmem.c:184, fbdefio.delay = HZ/20).  KOReader has no such bulk
 * operation today: setRotation only sets a config bit and every draw is
 * re-addressed per access, so the cost is smeared across the whole repaint.
 *
 * LuaJIT measured 125-207 ms for this, but those are loop-bound per-element
 * loops and say nothing about compiled code.  This is the real number.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

#define W 1872
#define H 1404
#define STRIDE 7488
#define PITCH (STRIDE/4)      /* destination (landscape fb) pitch, 1872 */
#define SPITCH H              /* source is the PORTRAIT-shaped buffer: 1404 wide */
#define LEN ((size_t)STRIDE*H)

static double now(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t);
  return t.tv_sec + t.tv_nsec/1e9; }

/* naive: destination-ordered gather */
static void t_naive(uint32_t *d, const uint32_t *s){
  for (int y=0;y<H;y++){ uint32_t *dr=d+(size_t)y*PITCH;
    for (int x=0;x<W;x++) dr[x]=s[(size_t)x*SPITCH+y]; } }

/* cache-blocked */
static void t_tiled(uint32_t *d, const uint32_t *s, int T){
  for (int y0=0;y0<H;y0+=T){ int ym=(y0+T<H)?y0+T:H;
    for (int x0=0;x0<W;x0+=T){ int xm=(x0+T<W)?x0+T:W;
      for (int y=y0;y<ym;y++){ uint32_t *dr=d+(size_t)y*PITCH;
        for (int x=x0;x<xm;x++) dr[x]=s[(size_t)x*SPITCH+y]; } } } }

static double best_of(int reps, void(*fn)(uint32_t*,const uint32_t*,int),
                      uint32_t*d, const uint32_t*s, int T){
  double b=1e9;
  for(int i=0;i<reps;i++){ double a=now(); fn(d,s,T); double e=now()-a; if(e<b)b=e; usleep(200000);}
  return b*1000.0; }
static void wrap_naive(uint32_t*d,const uint32_t*s,int T){(void)T;t_naive(d,s);}

int main(void){
  uint32_t *src = aligned_alloc(4096, LEN), *ram = aligned_alloc(4096, LEN);
  if(!src||!ram){ fprintf(stderr,"alloc\n"); return 1; }
  memset(src,0x40,LEN); memset(ram,0,LEN);

  setvbuf(stdout,NULL,_IONBF,0);
  printf("transbench: %d x %d, %zu bytes, deferred-io budget 50 ms\n\n",W,H,LEN);
  printf("  --- RAM -> RAM (no framebuffer, isolates the transpose itself) ---\n");
  { double a=now(); memcpy(ram,src,LEN); double e=(now()-a)*1000; usleep(200000);
    printf("  %-42s %7.1f ms\n","memcpy (bandwidth floor)",e); }
  printf("  %-42s %7.1f ms\n","naive gather transpose", best_of(3,wrap_naive,ram,src,0));
  for (int T=16;T<=64;T*=2){ char n[64]; snprintf(n,sizeof n,"tiled transpose %dx%d",T,T);
    printf("  %-42s %7.1f ms\n",n, best_of(3,t_tiled,ram,src,T)); }

  int fd=open("/dev/fb0",O_RDWR);
  if(fd<0){ printf("\n  (no /dev/fb0: skipping framebuffer half)\n"); return 0; }
  uint32_t *fb=mmap(NULL,LEN,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
  if(fb==MAP_FAILED){ printf("\n  (mmap failed)\n"); return 0; }
  printf("\n  --- RAM -> FRAMEBUFFER (what the shadow blit would actually do) ---\n");
  { double a=now(); memcpy(fb,src,LEN); double e=(now()-a)*1000; usleep(300000);
    printf("  %-42s %7.1f ms\n","memcpy RAM->fb (contiguous bound)",e); }
  printf("  %-42s %7.1f ms\n","naive gather transpose -> fb", best_of(3,wrap_naive,fb,src,0));
  double best=1e9;
  for (int T=16;T<=64;T*=2){ char n[64]; snprintf(n,sizeof n,"tiled transpose %dx%d -> fb",T,T);
    double v=best_of(3,t_tiled,fb,src,T); if(v<best)best=v;
    printf("  %-42s %7.1f ms\n",n,v); }
  printf("\n  best bulk transpose into fb: %.1f ms  -> %s\n", best,
         best<50.0 ? "FITS the 50 ms period: shadow route viable"
                   : "exceeds 50 ms: shadow route does NOT fit on its own");
  munmap(fb,LEN); close(fd); return 0;
}

/* gen-testimage: deterministic 64x64 Gray8 PGM (P5) test image.
 *
 * Layout (committed as testdata/gradient-checker.pgm; regenerate with
 * `make regen-goldens`, see README.md):
 *   rows  0..31  horizontal gradient v = x * 255 / 63 (black -> white)
 *   rows 32..47  8x8 black/white checkerboard
 *   rows 48..63  4x4 checkerboard of 64/192 (mid grays, exercises the
 *                fourtone and bw thresholds away from the extremes)
 *
 * Usage: gen-testimage OUTFILE.pgm
 */
#include <stdio.h>

#define W 64
#define H 64

int main(int argc, char **argv)
{
	FILE *f;
	int x, y;

	if (argc != 2) {
		fprintf(stderr, "usage: %s OUTFILE.pgm\n", argv[0]);
		return 2;
	}
	f = fopen(argv[1], "wb");
	if (!f) {
		fprintf(stderr, "cannot open %s\n", argv[1]);
		return 1;
	}
	fprintf(f, "P5\n%d %d\n255\n", W, H);
	for (y = 0; y < H; y++) {
		for (x = 0; x < W; x++) {
			int v;

			if (y < 32)
				v = x * 255 / 63;
			else if (y < 48)
				v = ((x / 8 + y / 8) & 1) ? 255 : 0;
			else
				v = ((x / 4 + y / 4) & 1) ? 192 : 64;
			fputc(v, f);
		}
	}
	if (fflush(f) != 0 || ferror(f)) {
		fprintf(stderr, "write error\n");
		return 1;
	}
	fclose(f);
	return 0;
}

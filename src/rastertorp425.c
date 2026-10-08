/*
 * rastertorp425 - CUPS filter: CUPS raster -> ZPL for the Rongta RP425.
 *
 * The RP425 reports itself as "CMD:ZPL;MODEL:RP425(ZPL 203DPI)", so every page
 * is sent as one ZPL label holding a single ^GFA graphic field. Rows are
 * encoded with ZPL's ASCII run-length compression (fallback: plain hex).
 *
 * Usage (as invoked by CUPS): rastertorp425 job user title copies options [file]
 */

#include <cups/cups.h>
#include <cups/ppd.h>
#include <cups/raster.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAX_DOTS 832 /* 104 mm print head at 8 dots/mm */

typedef struct {
  int darkness;   /* ~SD 0..30, -1 = leave printer setting alone */
  int speed;      /* ^PR 2..6 ips, -1 = printer default */
  char tracking;  /* ^MN Y/N/M, 0 = printer default */
  int dither;     /* 0 = threshold, 1 = Floyd-Steinberg */
  int threshold;  /* 0..255; gray values below this are printed black */
  int rotate;     /* ^POI */
  int compress;   /* ZPL ASCII compression */
  int top;        /* ^LT label top, dots */
  int left;       /* ^LS label shift, dots */
} options_t;

static volatile sig_atomic_t canceled = 0;

static void on_term(int sig) {
  (void)sig;
  canceled = 1;
}

static const char *choice(ppd_file_t *ppd, int num_opts, cups_option_t *opts, const char *name) {
  const char *v = cupsGetOption(name, num_opts, opts);
  if (v) return v;
  if (ppd) {
    ppd_choice_t *c = ppdFindMarkedChoice(ppd, name);
    if (c) return c->choice;
  }
  return NULL;
}

static int int_choice(ppd_file_t *ppd, int n, cups_option_t *o, const char *name, int dflt) {
  const char *v = choice(ppd, n, o, name);
  if (!v || !strcmp(v, "Default")) return dflt;
  return atoi(v);
}

static void load_options(options_t *opt, int num_opts, cups_option_t *opts) {
  ppd_file_t *ppd = NULL;
  const char *path = getenv("PPD");
  if (path && (ppd = ppdOpenFile(path)) != NULL) {
    ppdMarkDefaults(ppd);
    cupsMarkOptions(ppd, num_opts, opts);
  }

  opt->darkness = int_choice(ppd, num_opts, opts, "Darkness", -1);
  opt->speed = int_choice(ppd, num_opts, opts, "PrintSpeed", -1);
  opt->threshold = int_choice(ppd, num_opts, opts, "Threshold", 128);
  opt->top = int_choice(ppd, num_opts, opts, "TopOffset", 0);
  opt->left = int_choice(ppd, num_opts, opts, "LeftOffset", 0);

  const char *v = choice(ppd, num_opts, opts, "MediaTracking");
  opt->tracking = 0;
  if (v && !strcmp(v, "Gap")) opt->tracking = 'Y';
  else if (v && !strcmp(v, "Continuous")) opt->tracking = 'N';
  else if (v && !strcmp(v, "Mark")) opt->tracking = 'M';

  v = choice(ppd, num_opts, opts, "Dither");
  opt->dither = v && !strcmp(v, "FloydSteinberg");

  v = choice(ppd, num_opts, opts, "Rotate180");
  opt->rotate = v && (!strcmp(v, "True") || !strcmp(v, "true") || !strcmp(v, "yes"));

  v = choice(ppd, num_opts, opts, "Compression");
  opt->compress = !(v && !strcmp(v, "None"));

  if (opt->darkness > 30) opt->darkness = 30;
  if (opt->speed != -1 && (opt->speed < 2 || opt->speed > 6)) opt->speed = -1;
  if (opt->threshold < 1 || opt->threshold > 255) opt->threshold = 128;

  if (ppd) ppdClose(ppd);
}

/* ---- ZPL ASCII compression ------------------------------------------------ */

static const char HEX[] = "0123456789ABCDEF";

/* Emit a repeat count prefix: g..z = 20..400 (steps of 20), G..Y = 1..19. */
static void put_count(int n) {
  while (n >= 400) { putchar('z'); n -= 400; }
  if (n >= 20) { putchar('g' + n / 20 - 1); n %= 20; }
  if (n > 0) putchar('G' + n - 1);
}

static int nib(const unsigned char *row, int i) {
  return (i & 1) ? (row[i / 2] & 15) : (row[i / 2] >> 4);
}

static void put_row(const unsigned char *row, const unsigned char *prev, int bytes, int compress) {
  int nibbles = bytes * 2;
  if (!compress) {
    for (int i = 0; i < nibbles; i++) putchar(HEX[nib(row, i)]);
    return;
  }
  if (prev && !memcmp(row, prev, (size_t)bytes)) {
    putchar(':');
    return;
  }

  /* A trailing run of 0s or Fs collapses to ',' or '!'. */
  int end = nibbles;
  char tail = 0;
  int last = nib(row, nibbles - 1);
  if (last == 0 || last == 15) {
    while (end > 0 && nib(row, end - 1) == last) end--;
    if (nibbles - end > 1) tail = last ? '!' : ',';
    else end = nibbles;
  }

  for (int i = 0; i < end;) {
    int n = nib(row, i), run = 1;
    while (i + run < end && nib(row, i + run) == n) run++;
    if (run > 1) put_count(run);
    putchar(HEX[n]);
    i += run;
  }
  if (tail) putchar(tail);
}

/* ---- Pixel conversion ----------------------------------------------------- */

/* Convert one raster line into a packed 1-bit row (1 = burn a dot). */
static void to_mono(const cups_page_header2_t *h, const unsigned char *in, unsigned char *out,
                    int dots, const options_t *opt, int *err, int *err_next) {
  int bytes = (dots + 7) / 8;
  memset(out, 0, (size_t)bytes);

  if (h->cupsBitsPerPixel == 1) {
    /* K: 1 = black. W/sW: 1 = white. */
    int invert = h->cupsColorSpace != CUPS_CSPACE_K;
    for (int x = 0; x < bytes; x++) {
      unsigned char b = (unsigned)x < h->cupsBytesPerLine ? in[x] : (invert ? 0xFF : 0);
      out[x] = invert ? (unsigned char)~b : b;
    }
    if (dots & 7) out[bytes - 1] &= (unsigned char)(0xFF << (8 - (dots & 7)));
    return;
  }

  /* 8-bit: convert to "darkness" 0 (white) .. 255 (black). */
  int ink = h->cupsColorSpace == CUPS_CSPACE_K;
  if (opt->dither) {
    memset(err_next, 0, sizeof(int) * (size_t)(dots + 2));
    for (int x = 0; x < dots; x++) {
      int g = (unsigned)x < h->cupsWidth ? in[x] : (ink ? 0 : 255);
      int dark = (ink ? g : 255 - g) + err[x + 1] / 16;
      int on = dark >= 128;
      int e = dark - (on ? 255 : 0);
      if (on) out[x >> 3] |= (unsigned char)(0x80 >> (x & 7));
      err[x + 2] += e * 7;
      err_next[x] += e * 3;
      err_next[x + 1] += e * 5;
      err_next[x + 2] += e;
    }
    memcpy(err, err_next, sizeof(int) * (size_t)(dots + 2));
  } else {
    int cut = 255 - opt->threshold; /* darkness above this is black */
    for (int x = 0; x < dots; x++) {
      int g = (unsigned)x < h->cupsWidth ? in[x] : (ink ? 0 : 255);
      int dark = ink ? g : 255 - g;
      if (dark > cut) out[x >> 3] |= (unsigned char)(0x80 >> (x & 7));
    }
  }
}

/* ---- Main ----------------------------------------------------------------- */

int main(int argc, char *argv[]) {
  if (argc < 6 || argc > 7) {
    fputs("Usage: rastertorp425 job-id user title copies options [file]\n", stderr);
    return 1;
  }

  int fd = 0;
  if (argc == 7 && (fd = open(argv[6], O_RDONLY)) < 0) {
    perror("ERROR: Unable to open raster file");
    return 1;
  }

  signal(SIGPIPE, SIG_IGN);
  signal(SIGTERM, on_term);

  cups_option_t *opts = NULL;
  int num_opts = cupsParseOptions(argv[5], 0, &opts);
  options_t opt;
  load_options(&opt, num_opts, opts);
  cupsFreeOptions(num_opts, opts);

  cups_raster_t *ras = cupsRasterOpen(fd, CUPS_RASTER_READ);
  cups_page_header2_t h;
  int page = 0;

  while (!canceled && cupsRasterReadHeader2(ras, &h)) {
    page++;
    if (h.cupsBitsPerColor != 1 && h.cupsBitsPerColor != 8) {
      fprintf(stderr, "ERROR: Unsupported raster depth %u\n", h.cupsBitsPerColor);
      break;
    }
    if (h.cupsBitsPerPixel != h.cupsBitsPerColor) {
      fprintf(stderr, "ERROR: Unsupported raster color space %u (need grayscale)\n", h.cupsColorSpace);
      break;
    }
    fprintf(stderr, "PAGE: %d 1\n", page);
    fprintf(stderr, "INFO: Printing label %d (%ux%u dots)\n", page, h.cupsWidth, h.cupsHeight);

    int dots = h.cupsWidth > MAX_DOTS ? MAX_DOTS : (int)h.cupsWidth;
    int bytes = (dots + 7) / 8;
    int rows = (int)h.cupsHeight;
    unsigned char *line = malloc(h.cupsBytesPerLine);
    unsigned char *cur = calloc((size_t)bytes, 1);
    unsigned char *prev = calloc((size_t)bytes, 1);
    int *err = calloc((size_t)dots + 2, sizeof(int));
    int *err_next = calloc((size_t)dots + 2, sizeof(int));
    if (!line || !cur || !prev || !err || !err_next) {
      fputs("ERROR: Out of memory\n", stderr);
      return 1;
    }

    /* Label setup. */
    if (opt.darkness >= 0) printf("~SD%02d\n", opt.darkness);
    fputs("^XA\n", stdout);
    if (opt.tracking) printf("^MN%c\n", opt.tracking);
    if (opt.speed > 0) printf("^PR%d\n", opt.speed);
    printf("^PW%d\n^LL%d\n^LH0,0\n^LT%d\n^LS%d\n^PO%c\n^MMT\n", dots, rows, opt.top, opt.left,
           opt.rotate ? 'I' : 'N');

    int total = bytes * rows;
    printf("^FO0,0^GFA,%d,%d,%d,", total, total, bytes);

    int y = 0;
    for (; y < rows && !canceled; y++) {
      if (cupsRasterReadPixels(ras, line, h.cupsBytesPerLine) < h.cupsBytesPerLine) break;
      to_mono(&h, line, cur, dots, &opt, err, err_next);
      put_row(cur, y ? prev : NULL, bytes, opt.compress);
      unsigned char *t = prev; prev = cur; cur = t;
      if ((y & 255) == 0) fflush(stdout);
    }
    /* Short or canceled page: pad with blank rows so the graphic stays well-formed. */
    for (; y < rows; y++) {
      if (opt.compress) putchar(',');
      else for (int i = 0; i < bytes; i++) fputs("00", stdout);
    }
    fputs("^FS\n^PQ1\n^XZ\n", stdout);
    fflush(stdout);

    free(line); free(cur); free(prev); free(err); free(err_next);
  }

  if (canceled) {
    fputs("~JA\n", stdout); /* drop anything still queued in the printer */
    fflush(stdout);
  }

  cupsRasterClose(ras);
  if (fd) close(fd);

  if (page == 0) {
    fputs("ERROR: No pages found\n", stderr);
    return 1;
  }
  return canceled ? 1 : 0;
}

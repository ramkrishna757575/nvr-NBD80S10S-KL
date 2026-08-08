/*
 * Draw text and a test pattern on /dev/fb0.
 *
 * The MI display layer only gives us a flat background colour (which is why the
 * screen is plain red -- that is MI_DISP's u32BgColor, interpreted as YCbCr).
 * The framebuffer is a separate OSD layer composited on top, so anything drawn
 * here appears over it.
 *
 * Pixel packing is derived from the driver's own var_screeninfo rather than
 * assumed, so this works whether the layer is ARGB1555 (the fbdev.ini default
 * here) or a 32bpp format.
 *
 * usage: fb-splash [-p] [line1] [line2] ...
 *        -p   draw colour bars above the text
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <linux/fb.h>
#include <linux/if.h>

/* 5x7 glyphs, one byte per column, LSB = top row. Only the characters needed
   for status text are included; anything else renders as a blank. */
static const char font_chars[] =
    " !-./0123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZ";

static const unsigned char font_data[][5] = {
    {0x00,0x00,0x00,0x00,0x00}, /*   */
    {0x00,0x00,0x5F,0x00,0x00}, /* ! */
    {0x08,0x08,0x08,0x08,0x08}, /* - */
    {0x00,0x60,0x60,0x00,0x00}, /* . */
    {0x20,0x10,0x08,0x04,0x02}, /* / */
    {0x3E,0x51,0x49,0x45,0x3E}, /* 0 */
    {0x00,0x42,0x7F,0x40,0x00}, /* 1 */
    {0x42,0x61,0x51,0x49,0x46}, /* 2 */
    {0x21,0x41,0x45,0x4B,0x31}, /* 3 */
    {0x18,0x14,0x12,0x7F,0x10}, /* 4 */
    {0x27,0x45,0x45,0x45,0x39}, /* 5 */
    {0x3C,0x4A,0x49,0x49,0x30}, /* 6 */
    {0x01,0x71,0x09,0x05,0x03}, /* 7 */
    {0x36,0x49,0x49,0x49,0x36}, /* 8 */
    {0x06,0x49,0x49,0x29,0x1E}, /* 9 */
    {0x00,0x36,0x36,0x00,0x00}, /* : */
    {0x7E,0x11,0x11,0x11,0x7E}, /* A */
    {0x7F,0x49,0x49,0x49,0x36}, /* B */
    {0x3E,0x41,0x41,0x41,0x22}, /* C */
    {0x7F,0x41,0x41,0x22,0x1C}, /* D */
    {0x7F,0x49,0x49,0x49,0x41}, /* E */
    {0x7F,0x09,0x09,0x01,0x01}, /* F */
    {0x3E,0x41,0x49,0x49,0x7A}, /* G */
    {0x7F,0x08,0x08,0x08,0x7F}, /* H */
    {0x00,0x41,0x7F,0x41,0x00}, /* I */
    {0x20,0x40,0x41,0x3F,0x01}, /* J */
    {0x7F,0x08,0x14,0x22,0x41}, /* K */
    {0x7F,0x40,0x40,0x40,0x40}, /* L */
    {0x7F,0x02,0x04,0x02,0x7F}, /* M */
    {0x7F,0x04,0x08,0x10,0x7F}, /* N */
    {0x3E,0x41,0x41,0x41,0x3E}, /* O */
    {0x7F,0x09,0x09,0x09,0x06}, /* P */
    {0x3E,0x41,0x51,0x21,0x5E}, /* Q */
    {0x7F,0x09,0x19,0x29,0x46}, /* R */
    {0x46,0x49,0x49,0x49,0x31}, /* S */
    {0x01,0x01,0x7F,0x01,0x01}, /* T */
    {0x3F,0x40,0x40,0x40,0x3F}, /* U */
    {0x1F,0x20,0x40,0x20,0x1F}, /* V */
    {0x7F,0x20,0x18,0x20,0x7F}, /* W */
    {0x63,0x14,0x08,0x14,0x63}, /* X */
    {0x03,0x04,0x78,0x04,0x03}, /* Y */
    {0x61,0x51,0x49,0x45,0x43}, /* Z */
};

static struct fb_var_screeninfo vinfo;
static struct fb_fix_screeninfo finfo;
static unsigned char *fbmem;

/* Build a pixel from the driver's own channel offsets, so we do not have to
   hardcode ARGB1555 vs RGB565 vs 32bpp. */
static unsigned long pack(unsigned r, unsigned g, unsigned b)
{
    unsigned long v = 0;

    v |= (unsigned long)(r >> (8 - vinfo.red.length))   << vinfo.red.offset;
    v |= (unsigned long)(g >> (8 - vinfo.green.length)) << vinfo.green.offset;
    v |= (unsigned long)(b >> (8 - vinfo.blue.length))  << vinfo.blue.offset;

    /* Opaque, or the OSD layer blends away to nothing on ARGB1555. */
    if (vinfo.transp.length)
        v |= ((1UL << vinfo.transp.length) - 1) << vinfo.transp.offset;

    return v;
}

static void put_pixel(int x, int y, unsigned long c)
{
    unsigned char *p;

    if (x < 0 || y < 0 || x >= (int)vinfo.xres || y >= (int)vinfo.yres)
        return;

    /* yoffset matters: this panel is double-buffered (yres_virtual = 2 * yres). */
    p = fbmem + (y + vinfo.yoffset) * finfo.line_length
              + (x + vinfo.xoffset) * (vinfo.bits_per_pixel / 8);

    switch (vinfo.bits_per_pixel) {
    case 16:
        *(unsigned short *)p = (unsigned short)c;
        break;
    case 32:
        *(unsigned int *)p = (unsigned int)c;
        break;
    default:
        break;
    }
}

static void fill_rect(int x, int y, int w, int h, unsigned long c)
{
    int i, j;

    for (j = 0; j < h; j++)
        for (i = 0; i < w; i++)
            put_pixel(x + i, y + j, c);
}

static int glyph_index(char ch)
{
    const char *p;

    if (ch >= 'a' && ch <= 'z')
        ch = (char)(ch - 'a' + 'A');

    p = strchr(font_chars, ch);

    return p ? (int)(p - font_chars) : 0;
}

/* scale multiplies both axes; the font is tiny, 1080p needs about 4-6. */
static void draw_text(int x, int y, const char *s, int scale, unsigned long c)
{
    int col, row;

    for (; *s; s++) {
        const unsigned char *g = font_data[glyph_index(*s)];

        for (col = 0; col < 5; col++)
            for (row = 0; row < 7; row++)
                if (g[col] & (1 << row))
                    fill_rect(x + col * scale, y + row * scale,
                              scale, scale, c);

        x += 6 * scale;   /* 5 columns plus one blank */
    }
}

static void colour_bars(int y, int h)
{
    static const unsigned char rgb[8][3] = {
        {255,255,255}, {255,255,0}, {0,255,255}, {0,255,0},
        {255,0,255},   {255,0,0},   {0,0,255},   {0,0,0},
    };
    int i, w = (int)vinfo.xres / 8;

    for (i = 0; i < 8; i++)
        fill_rect(i * w, y, w, h, pack(rgb[i][0], rgb[i][1], rgb[i][2]));
}

/* ---- live stats mode ---------------------------------------------------- */

static unsigned long long read_counter(const char *iface, const char *name)
{
    char path[160], buf[64];
    unsigned long long v = 0;
    int fd, n;

    snprintf(path, sizeof(path), "/sys/class/net/%s/statistics/%s", iface, name);
    fd = open(path, O_RDONLY);
    if (fd < 0)
        return 0;

    n = (int)read(fd, buf, sizeof(buf) - 1);
    if (n > 0) {
        buf[n] = 0;
        v = strtoull(buf, NULL, 10);
    }
    close(fd);
    return v;
}

static void read_operstate(const char *iface, char *out, size_t len)
{
    char path[160];
    int fd, n;

    snprintf(path, sizeof(path), "/sys/class/net/%s/operstate", iface);
    strncpy(out, "UNKNOWN", len - 1);
    out[len - 1] = 0;

    fd = open(path, O_RDONLY);
    if (fd < 0)
        return;

    n = (int)read(fd, out, len - 1);
    if (n > 0) {
        out[n] = 0;
        while (n > 0 && (out[n - 1] == '\n' || out[n - 1] == '\r'))
            out[--n] = 0;
    }
    close(fd);
}

/* The wired interface carrying the telnet console. */
#define MGMT_IFACE "eth0"

static void read_ipv4(const char *iface, char *out, size_t len)
{
    struct ifreq ifr;
    int fd;

    strncpy(out, "NONE", len - 1);
    out[len - 1] = 0;

    fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0)
        return;

    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, iface, IFNAMSIZ - 1);
    ifr.ifr_addr.sa_family = AF_INET;

    if (ioctl(fd, SIOCGIFADDR, &ifr) == 0) {
        struct sockaddr_in *sin = (struct sockaddr_in *)&ifr.ifr_addr;
        const char *s = inet_ntoa(sin->sin_addr);
        if (s) {
            strncpy(out, s, len - 1);
            out[len - 1] = 0;
        }
    }
    close(fd);
}

/*
 * Wi-Fi status, published by apfpv as key=value lines.
 *
 * The OSD is the only display this board has whenever the video plane is idle,
 * and neither serial nor telnet is guaranteed to be attached in the field. An
 * association failure therefore has to be legible here: whether the AP was
 * visible at all, on what band, and why the join was refused.
 */
#define WIFI_STATUS "/tmp/wifi-status"

static void read_kv(const char *path, const char *key, char *out, size_t len)
{
    FILE *f;
    char line[192];
    size_t klen = strlen(key);

    out[0] = 0;
    f = fopen(path, "r");
    if (!f)
        return;

    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, key, klen) != 0 || line[klen] != '=')
            continue;
        line[strcspn(line, "\r\n")] = 0;
        snprintf(out, len, "%s", line + klen + 1);
        break;
    }
    fclose(f);
}

/*
 * Redraw only the stats block rather than the whole screen: a full 1280x720
 * clear every second is both slow on a 1GHz A7 and visibly flickers.
 */
static int stats_loop(const char *iface)
{
    unsigned long long prev_pkts = 0, prev_bytes = 0;
    int scale, line_h, y0, first = 1;

    scale = (int)vinfo.xres / 220;
    if (scale < 2)
        scale = 2;
    line_h = 9 * scale;
    y0 = 30;

    for (;;) {
        unsigned long long pkts  = read_counter(iface, "rx_packets");
        unsigned long long bytes = read_counter(iface, "rx_bytes");
        unsigned long long dp = first ? 0 : pkts - prev_pkts;
        unsigned long long db = first ? 0 : bytes - prev_bytes;
        char state[32], ip[32], mgmt[32], buf[96];
        char ssid[48], freq[16], sig[16], wstate[24], reg[8], note[72];
        int y = y0;

        read_operstate(iface, state, sizeof(state));
        read_ipv4(iface, ip, sizeof(ip));
        read_ipv4(MGMT_IFACE, mgmt, sizeof(mgmt));
        read_kv(WIFI_STATUS, "ssid",   ssid,   sizeof(ssid));
        read_kv(WIFI_STATUS, "freq",   freq,   sizeof(freq));
        read_kv(WIFI_STATUS, "signal", sig,    sizeof(sig));
        read_kv(WIFI_STATUS, "state",  wstate, sizeof(wstate));
        read_kv(WIFI_STATUS, "reg",    reg,    sizeof(reg));
        read_kv(WIFI_STATUS, "note",   note,   sizeof(note));

        /* Clear just the text block. */
        fill_rect(0, 0, (int)vinfo.xres, y0 + line_h * 13, pack(0, 0, 40));

        draw_text(30, y, "OPENIPC GROUND STATION", scale, pack(0, 255, 0));
        y += line_h + scale * 2;

        snprintf(buf, sizeof(buf), "LINK %s %s", iface, state);
        draw_text(30, y, buf, scale,
                  strcmp(state, "up") == 0 ? pack(0, 255, 0) : pack(255, 200, 0));
        y += line_h;

        /* An AP that is not in the scan looks nothing like one that is there
           but refusing us, so distinguish the two rather than just saying
           "not connected". */
        if (ssid[0] && freq[0])
            snprintf(buf, sizeof(buf), "AP %s %sMHZ %sDBM", ssid, freq, sig);
        else if (ssid[0])
            snprintf(buf, sizeof(buf), "AP %s NOT VISIBLE", ssid);
        else
            snprintf(buf, sizeof(buf), "AP SCANNING");
        draw_text(30, y, buf, scale,
                  freq[0] ? pack(255, 255, 255) : pack(255, 80, 80));
        y += line_h;

        if (wstate[0] || reg[0]) {
            snprintf(buf, sizeof(buf), "WPA %s  REG %s",
                     wstate[0] ? wstate : "-", reg[0] ? reg : "-");
            draw_text(30, y, buf, scale,
                      strcmp(wstate, "COMPLETED") == 0 ? pack(0, 255, 0)
                                                       : pack(255, 200, 0));
            y += line_h;
        }

        if (note[0]) {
            snprintf(buf, sizeof(buf), "%s", note);
            draw_text(30, y, buf, scale, pack(255, 200, 0));
            y += line_h;
        }

        /* The address to telnet to. This lives on a different interface from
           the one being counted, and it is the one that goes missing when the
           drone's DHCP collides with it -- so show it explicitly rather than
           leaving the operator to guess where the board went. */
        if (strcmp(iface, MGMT_IFACE) != 0) {
            snprintf(buf, sizeof(buf), "TELNET %s", mgmt);
            draw_text(30, y, buf, scale,
                      strcmp(mgmt, "NONE") == 0 ? pack(255, 80, 80)
                                                : pack(0, 255, 0));
            y += line_h;
        }

        snprintf(buf, sizeof(buf), "%s IP %s", iface, ip);
        draw_text(30, y, buf, scale, pack(255, 255, 255));
        y += line_h;

        snprintf(buf, sizeof(buf), "RX %llu PKTS", pkts);
        draw_text(30, y, buf, scale, pack(255, 255, 255));
        y += line_h;

        snprintf(buf, sizeof(buf), "RATE %llu PPS", dp);
        draw_text(30, y, buf, scale,
                  dp > 0 ? pack(0, 255, 255) : pack(255, 80, 80));
        y += line_h;

        snprintf(buf, sizeof(buf), "%llu KBPS", (db * 8ULL) / 1000ULL);
        draw_text(30, y, buf, scale,
                  db > 0 ? pack(0, 255, 255) : pack(255, 80, 80));

        prev_pkts = pkts;
        prev_bytes = bytes;
        first = 0;
        sleep(1);
    }

    return 0;
}

/* ---- link overlay, drawn over live video -------------------------------- */

/*
 * Zero, not a colour: an all-zero ARGB1555 pixel has alpha 0, so the video
 * plane below shows through. The stats block above can paint a background
 * because it only ever runs with the video plane idle; this one cannot, or it
 * would black out the picture it is annotating.
 */
static void clear_transparent(int x, int y, int w, int h)
{
    int i, j;

    for (j = 0; j < h; j++)
        for (i = 0; i < w; i++)
            put_pixel(x + i, y + j, 0);
}

/* One line, rewritten in place by wfb-start's awk:
   freq mcs bw rssi snr pkt kbps fec lost decerr ants */
#define WFB_STATUS "/tmp/wfb.status"
#define WFB_FIELDS 11

static int read_fields(const char *path, char out[][16], int max)
{
    FILE *f;
    char line[192], *tok;
    int n = 0;

    f = fopen(path, "r");
    if (!f)
        return 0;
    if (!fgets(line, sizeof(line), f)) {
        fclose(f);
        return 0;
    }
    fclose(f);

    for (tok = strtok(line, " \t\r\n"); tok && n < max; tok = strtok(NULL, " \t\r\n"))
        snprintf(out[n++], 16, "%s", tok);

    return n;
}

static int wfb_loop(void)
{
    int scale, line_h, x0, y0, strip_w, strip_h;

    scale = (int)vinfo.xres / 320;
    if (scale < 2)
        scale = 2;
    line_h  = 9 * scale;
    x0      = 20;
    strip_h = line_h * 2 + scale;
    strip_w = (int)vinfo.xres - x0;
    /* Bottom left: the top of the frame is where the picture usually matters. */
    y0      = (int)vinfo.yres - strip_h - 16;
    if (y0 < 0)
        y0 = 0;

    for (;;) {
        char f[WFB_FIELDS][16], buf[96];
        unsigned long white = pack(255, 255, 255);
        unsigned long green = pack(0, 255, 0);
        unsigned long amber = pack(255, 200, 0);
        unsigned long red   = pack(255, 80, 80);
        int n = read_fields(WFB_STATUS, f, WFB_FIELDS);
        int y = y0;

        clear_transparent(x0, y0, strip_w, strip_h);

        /* rssi is "-" until a packet actually decrypts, so it doubles as the
           "is this link real" test -- the same one wfb-start keys the player on. */
        if (n < WFB_FIELDS || strcmp(f[3], "-") == 0) {
            draw_text(x0, y, "NO LINK", scale, red);
        } else {
            int rssi = atoi(f[3]);
            int lost = atoi(f[8]);

            snprintf(buf, sizeof(buf), "%sDBM SNR %s MCS%s", f[3], f[4], f[1]);
            draw_text(x0, y, buf, scale,
                      rssi > -70 ? green : (rssi > -80 ? amber : red));
            y += line_h;

            snprintf(buf, sizeof(buf), "%s KBPS FEC %s LOST %s", f[6], f[7], f[8]);
            draw_text(x0, y, buf, scale, lost > 0 ? red : white);
        }

        sleep(1);
    }

    return 0;
}

int main(int argc, char **argv)
{
    const char *dev = "/dev/fb0";
    int fd, i, bars = 0, y, scale;
    long screensize;

    fd = open(dev, O_RDWR);
    if (fd < 0) {
        perror(dev);
        return 1;
    }

    if (ioctl(fd, FBIOGET_VSCREENINFO, &vinfo) < 0 ||
        ioctl(fd, FBIOGET_FSCREENINFO, &finfo) < 0) {
        perror("FBIOGET_*SCREENINFO");
        close(fd);
        return 1;
    }

    printf("%s: %ux%u virtual %ux%u, %u bpp, line %u\n",
           dev, vinfo.xres, vinfo.yres,
           vinfo.xres_virtual, vinfo.yres_virtual,
           vinfo.bits_per_pixel, finfo.line_length);
    printf("  r%u@%u g%u@%u b%u@%u a%u@%u\n",
           vinfo.red.length, vinfo.red.offset,
           vinfo.green.length, vinfo.green.offset,
           vinfo.blue.length, vinfo.blue.offset,
           vinfo.transp.length, vinfo.transp.offset);

    screensize = (long)finfo.line_length * vinfo.yres_virtual;
    fbmem = mmap(NULL, screensize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (fbmem == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return 1;
    }

    if (argc > 1 && strcmp(argv[1], "-p") == 0) {
        bars = 1;
        argv++;
        argc--;
    }

    /* Overlay on top of running video. Deliberately does not clear the screen:
       everything outside the glyphs has to stay transparent. */
    if (argc > 1 && strcmp(argv[1], "--wfb") == 0)
        return wfb_loop();

    /* Live counters, refreshed once a second, until killed. */
    if (argc > 1 && strcmp(argv[1], "--stats") == 0) {
        const char *iface = (argc > 2) ? argv[2] : "wlan0";

        fill_rect(0, 0, (int)vinfo.xres, (int)vinfo.yres, pack(0, 0, 40));
        return stats_loop(iface);
    }

    /* Dark background rather than black: makes it obvious the OSD layer is
       actually being drawn, instead of just showing the MI_DISP background. */
    fill_rect(0, 0, (int)vinfo.xres, (int)vinfo.yres, pack(0, 0, 40));

    y = 20;
    if (bars) {
        colour_bars(y, (int)vinfo.yres / 4);
        y += (int)vinfo.yres / 4 + 30;
    }

    scale = (int)vinfo.xres / 200;
    if (scale < 2)
        scale = 2;

    if (argc > 1) {
        for (i = 1; i < argc; i++) {
            draw_text(30, y, argv[i], scale, pack(255, 255, 255));
            y += 9 * scale;
        }
    } else {
        char mgmt[32], line[64];

        draw_text(30, y, "OPENIPC GROUND STATION", scale, pack(0, 255, 0));
        y += 11 * scale;
        draw_text(30, y, "SSR621Q - HDMI OK", scale, pack(255, 255, 255));
        y += 9 * scale;
        /* Read it rather than assuming: the wired address is configurable and
           can also be lost to a DHCP collision, and a splash that confidently
           states the wrong address is worse than one that admits it. */
        read_ipv4(MGMT_IFACE, mgmt, sizeof(mgmt));
        snprintf(line, sizeof(line), "IP %s", mgmt);
        draw_text(30, y, line, scale, pack(255, 255, 255));
    }

    munmap(fbmem, screensize);
    close(fd);
    return 0;
}

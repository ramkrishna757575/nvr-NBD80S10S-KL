/*
 * Decode an H.264/H.265 stream and put it on the HDMI display.
 *
 * Pipeline:
 *      UDP (or file/stdin)  ->  MI_VDEC  ->  MI_SYS bind  ->  MI_DISP  ->  HDMI
 *
 * The display half is the same sequence mi-disp-init already proved works,
 * including the raw MI_HDMI ioctls (this SDK ships no libmi_hdmi.so). The new
 * part is VDEC plus the MI_SYS binding that hands decoded frames to the display
 * without any userspace copy.
 *
 * Input can be a file, so the whole path is testable without the drone:
 *      mi-player -f /tmp/test.h264
 *      mi-player -u 5600            (default: UDP on 5600)
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>
#include <stdarg.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <time.h>

#include "mi_common_datatype.h"
#include "mi_sys.h"
#include "mi_disp.h"
#include "mi_vdec.h"
#include "mi_divp.h"
#include "mi_hdmi_datatype.h"

#define DISP_DEV    0
#define DISP_LAYER  0
#define DISP_PORT   0
#define VDEC_CHN    0
#define DIVP_CHN    0

/* ---- raw MI_HDMI ioctl (no libmi_hdmi.so in this SDK) ------------------- */
#define MI_IOC_WRITE 0x40000000u
#define MI_IOC(size, nr)  (MI_IOC_WRITE | ((unsigned)(size) << 16) | (0x69u << 8) | (nr))
#define MI_HDMI_IOC_INIT     MI_IOC(4,  0x00)
#define MI_HDMI_IOC_OPEN     MI_IOC(4,  0x02)
#define MI_HDMI_IOC_SETATTR  MI_IOC(48, 0x04)
#define MI_HDMI_IOC_START    MI_IOC(4,  0x06)

struct mi_ioc {
    uint32_t size;
    uint32_t pad;
    uint64_t ptr;
};

struct hdmi_setattr_args {
    uint32_t eHdmi;
    MI_HDMI_Attr_t stAttr;
};

typedef char assert_hdmi_attr_is_44[(sizeof(MI_HDMI_Attr_t) == 44) ? 1 : -1];
typedef char assert_hdmi_args_is_48[(sizeof(struct hdmi_setattr_args) == 48) ? 1 : -1];

static int hdmi_fd = -1;
static volatile int running = 1;

/* ---- VDEC ioctl renumbering --------------------------------------------
 *
 * The MI userspace libraries here are SDK 18.06 (2020), but the kernel modules
 * that actually work on this board are XiongMai's (2023, sdk_commit f947025).
 * For VDEC the two disagree: the 2023 mi_vdec.ko has no InitDev/DeInitDev in
 * its ioctl dispatch table, so every surviving command shifted down by two.
 * The library's CreateChn (nr 2) therefore lands on the driver's GetChnAttr --
 * which is exactly what the board reported, logging "GetChnAttr: Chn 0 not
 * create" while we were asking it to create the channel.
 *
 * Established by reading the driver's dispatch table (the .data relocations
 * from offset 0x24 are one function pointer per ioctl nr) against the ioctl
 * constants baked into libmi_vdec.so. The names line up one-to-one with a
 * constant shift of 2, from CreateChn through GetOutputPortAttr, and
 * SendStream's underlying CopyEsbufferFromUser (nr 17) maps to entry 15.
 *
 * Reimplementing every VDEC call as a raw ioctl is possible but SendStream's
 * 64-byte argument is assembled across two helper layers, so it is easy to get
 * subtly wrong. Correcting only the command number reuses the library's
 * already-correct payloads. Deliberately scoped to the /dev/mi_vdec fd so
 * MI_SYS, MI_DISP and our own raw HDMI ioctls pass through untouched.
 */
static void fd_path(int fd, char *out, size_t len)
{
    char path[64];
    ssize_t n;

    snprintf(path, sizeof(path), "/proc/self/fd/%d", fd);
    n = readlink(path, out, len - 1);
    if (n <= 0) {
        snprintf(out, len, "?");
        return;
    }
    out[n] = '\0';
}

static int fd_is_vdec(int fd)
{
    char target[128];

    fd_path(fd, target, sizeof(target));

    return strcmp(target, "/dev/mi_vdec") == 0;
}

/*
 * How far to shift VDEC ioctl numbers. Two for XiongMai's 2023 driver, zero for
 * the SDK's own 2020 driver, which matches the library exactly. load-mi records
 * the active module set, so this needs no manual flag.
 */
static int vdec_shift = -1;

static void vdec_shift_init(void)
{
    char set[32] = "";
    FILE *f = fopen("/tmp/mi-set", "r");

    if (f) {
        if (fgets(set, sizeof(set), f))
            set[strcspn(set, "\r\n")] = '\0';
        fclose(f);
    }

    vdec_shift = (strcmp(set, "xm") == 0) ? 2 : 0;
    printf("MI module set '%s': VDEC ioctl shift %d\n",
           set[0] ? set : "unknown", vdec_shift);
}

/* Number of MI ioctls still to be traced. Enough to cover setup plus the first
   few SendStreams; the rest run silently so the console is not flooded. */
static int ioctl_trace_budget = 40;

/*
 * The 2023 driver's CopyEsbufferFromUser wrapper reads a byte at payload offset
 * 4 and passes it as its fourth argument:
 *
 *      r6 = [r1+0]        ; chn
 *      r3 = ldrb [r4+4]   ; <- this byte
 *      r1 = r4+8          ; stream struct
 *      bl MI_VDEC_IMPL_CopyEsbufferFromUser
 *
 * The 2020 library memsets the 64-byte payload and writes only offsets 0, 8-15,
 * 16 and 20 -- offset 4 is never touched, so the driver always sees zero. Its
 * meaning is not documented anywhere we can read; -esflag lets us set it and
 * find out empirically. Negative means leave it alone.
 */
static int es_flag = -1;

int ioctl(int fd, unsigned long request, ...)
{
    static int (*real_ioctl)(int, unsigned long, ...);
    va_list ap;
    void *arg;
    unsigned long sent = request;
    unsigned nr = request & 0xFF;
    int is_mi = ((request >> 8) & 0xFF) == 0x69;
    int is_vdec = is_mi ? fd_is_vdec(fd) : 0;
    int swallowed = 0;
    int ret;

    va_start(ap, request);
    arg = va_arg(ap, void *);
    va_end(ap);

    if (!real_ioctl)
        real_ioctl = (int (*)(int, unsigned long, ...))dlsym(RTLD_NEXT, "ioctl");

    if (vdec_shift > 0 && is_vdec) {
        /* InitDev/DeInitDev no longer exist; the driver self-initialises.
           Swallow them rather than let them fall through onto CreateChn. */
        if (nr < 2)
            swallowed = 1;
        else
            sent = (request & ~0xFFUL) | (nr - vdec_shift);

        /* SendStream (lib nr 17 -> driver nr 15): fill in the flag the 2020
           library does not know about. */
        if (nr == 17 && es_flag >= 0 && arg)
            ((unsigned char *)arg)[4] = (unsigned char)es_flag;
    }

    if (swallowed) {
        ret = 0;
        errno = 0;
    } else {
        ret = real_ioctl(fd, sent, arg);
    }

    if (is_mi && ioctl_trace_budget > 0) {
        char target[128];
        int saved = errno;

        fd_path(fd, target, sizeof(target));
        fprintf(stderr,
                "  ioctl %-14s req=0x%08lx nr=%-2u -> %s nr=%-2u ret=%d errno=%d\n",
                target, request, nr,
                swallowed ? "SWALLOWED" : "sent     ",
                swallowed ? nr : (unsigned)(sent & 0xFF), ret, saved);
        ioctl_trace_budget--;
        errno = saved;
    }

    return ret;
}

static void on_signal(int sig)
{
    (void)sig;
    running = 0;
}

static int step(const char *name, MI_S32 ret)
{
    if (ret == MI_SUCCESS) {
        printf("  %-32s ok\n", name);
        return 0;
    }
    printf("  %-32s FAILED (0x%08x)\n", name, (unsigned)ret);
    return -1;
}

static int hdmi_call(int fd, unsigned long cmd, void *args, size_t len)
{
    struct mi_ioc w;

    w.size = (uint32_t)len;
    w.pad  = 0;
    w.ptr  = (uint64_t)(uintptr_t)args;

    return ioctl(fd, cmd, &w);
}

static int hdmi_start(MI_U32 h)
{
    struct hdmi_setattr_args sa;
    uint32_t id = E_MI_HDMI_ID_0;

    hdmi_fd = open("/dev/mi_hdmi", O_RDWR);
    if (hdmi_fd < 0) {
        perror("  open /dev/mi_hdmi");
        return -1;
    }

    step("MI_HDMI_Init", hdmi_call(hdmi_fd, MI_HDMI_IOC_INIT, &id, 4));
    step("MI_HDMI_Open", hdmi_call(hdmi_fd, MI_HDMI_IOC_OPEN, &id, 4));

    memset(&sa, 0, sizeof(sa));
    sa.eHdmi = E_MI_HDMI_ID_0;
    sa.stAttr.bConnect = 1;
    sa.stAttr.stVideoAttr.bEnableVideo   = 1;
    sa.stAttr.stVideoAttr.eTimingType    = (h == 1080)
                                         ? E_MI_HDMI_TIMING_1080_60P
                                         : E_MI_HDMI_TIMING_720_60P;
    sa.stAttr.stVideoAttr.eOutputMode    = E_MI_HDMI_OUTPUT_MODE_HDMI;
    sa.stAttr.stVideoAttr.eColorType     = E_MI_HDMI_COLOR_TYPE_RGB444;
    sa.stAttr.stVideoAttr.eDeepColorMode = E_MI_HDMI_DEEP_COLOR_24BIT;
    sa.stAttr.stAudioAttr.bEnableAudio   = 0;
    sa.stAttr.stAudioAttr.eSampleRate    = E_MI_HDMI_AUDIO_SAMPLERATE_48K;
    sa.stAttr.stAudioAttr.eBitDepth      = E_MI_HDMI_BIT_DEPTH_16;
    sa.stAttr.stEnInfoFrame.bEnableAviInfoFrame = 1;

    step("MI_HDMI_SetAttr", hdmi_call(hdmi_fd, MI_HDMI_IOC_SETATTR, &sa, sizeof(sa)));
    step("MI_HDMI_Start", hdmi_call(hdmi_fd, MI_HDMI_IOC_START, &id, 4));
    /* fd stays open: closing it releases the client and stops the transmitter */
    return 0;
}

/* ---- input ------------------------------------------------------------- */

static int open_udp(int port)
{
    struct sockaddr_in addr;
    int fd, on = 1;

    fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        perror("socket");
        return -1;
    }

    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));

    /* A big receive buffer matters: video bursts after each keyframe, and the
       default is small enough to drop packets while VDEC is busy. */
    {
        int rcvbuf = 1 << 20;
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
    }

    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons((unsigned short)port);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        close(fd);
        return -1;
    }

    printf("listening for video on UDP %d\n", port);
    return fd;
}

/* ---- RTP depacketisation ------------------------------------------------
 *
 * wfb_rx re-emits the RTP packets the air unit sent, so the normal input here
 * is RTP, not an elementary stream. Simply skipping the RTP header is NOT
 * enough: RTP carries NAL units with the Annex-B start codes removed, and
 * splits large ones across packets (FU-A / FU). VDEC in STREAM mode wants a
 * plain Annex-B byte stream, so fragments have to be rejoined and start codes
 * put back.
 *
 * Reassembled frames accumulate here and are handed to VDEC when the RTP
 * marker bit says the frame is finished.
 */

static uint8_t *frame;
static size_t frame_len;
static size_t frame_cap;
static unsigned lost_packets;

static const uint8_t start_code[4] = { 0x00, 0x00, 0x00, 0x01 };

static void frame_append(const uint8_t *p, size_t n)
{
    if (frame_len + n > frame_cap)
        return;                      /* frame larger than VDEC's buffer; drop tail */
    memcpy(frame + frame_len, p, n);
    frame_len += n;
}

static void append_nal(const uint8_t *p, size_t n)
{
    frame_append(start_code, 4);
    frame_append(p, n);
}

/* Aggregation packets (H.264 STAP-A, H.265 AP): several NALs, each behind a
   16-bit length. */
static void append_aggregate(const uint8_t *p, size_t n, size_t skip)
{
    if (n <= skip)
        return;
    p += skip;
    n -= skip;

    while (n >= 2) {
        size_t sz = ((size_t)p[0] << 8) | p[1];
        p += 2;
        n -= 2;
        if (sz == 0 || sz > n)
            break;
        append_nal(p, sz);
        p += sz;
        n -= sz;
    }
}

static void depacketize_h264(const uint8_t *p, size_t n)
{
    unsigned type = p[0] & 0x1F;

    if (type == 28) {                       /* FU-A fragment */
        if (n < 3)
            return;
        if (p[1] & 0x80) {                  /* first fragment: rebuild NAL header */
            uint8_t nal_hdr = (uint8_t)((p[0] & 0xE0) | (p[1] & 0x1F));
            frame_append(start_code, 4);
            frame_append(&nal_hdr, 1);
        }
        frame_append(p + 2, n - 2);         /* middle/last: payload only */
    } else if (type == 24) {                /* STAP-A */
        append_aggregate(p, n, 1);
    } else if (type >= 1 && type <= 23) {   /* single NAL unit */
        append_nal(p, n);
    }
    /* types 25-27, 29-31 are interleaved modes nothing in this stack emits */
}

static void depacketize_h265(const uint8_t *p, size_t n)
{
    unsigned type = (p[0] >> 1) & 0x3F;

    if (type == 49) {                       /* FU fragment */
        if (n < 4)
            return;
        if (p[2] & 0x80) {                  /* first fragment */
            uint8_t nal_hdr[2];
            nal_hdr[0] = (uint8_t)((p[0] & 0x81) | ((p[2] & 0x3F) << 1));
            nal_hdr[1] = p[1];
            frame_append(start_code, 4);
            frame_append(nal_hdr, 2);
        }
        frame_append(p + 3, n - 3);
    } else if (type == 48) {                /* AP aggregation */
        append_aggregate(p, n, 2);
    } else {
        append_nal(p, n);
    }
}

/*
 * Feed one UDP datagram into the reassembly buffer.
 * Returns 1 when a complete frame is ready in frame/frame_len.
 */
static int rtp_feed(const uint8_t *buf, size_t len, int is_h265)
{
    static int have_seq;
    static unsigned last_seq;
    unsigned seq, marker, cc;
    size_t hdr;

    if (len < 13 || (buf[0] & 0xC0) != 0x80)
        return 0;

    cc  = buf[0] & 0x0F;
    hdr = 12 + cc * 4;

    if (buf[0] & 0x10) {                    /* extension header */
        if (len < hdr + 4)
            return 0;
        hdr += 4 + (((size_t)buf[hdr + 2] << 8 | buf[hdr + 3]) * 4);
    }
    if (hdr >= len)
        return 0;

    if (buf[0] & 0x20) {                    /* padding */
        size_t pad = buf[len - 1];
        if (pad >= len - hdr)
            return 0;
        len -= pad;
    }

    marker = buf[1] >> 7;
    seq    = ((unsigned)buf[2] << 8) | buf[3];

    /* Count gaps but keep feeding: over a lossy FPV link a partial frame still
       decodes better (with artefacts) than dropping it outright. */
    if (have_seq && seq != ((last_seq + 1) & 0xFFFF))
        lost_packets++;
    have_seq = 1;
    last_seq = seq;

    if (is_h265)
        depacketize_h265(buf + hdr, len - hdr);
    else
        depacketize_h264(buf + hdr, len - hdr);

    return marker ? 1 : 0;
}

/* Length of the Annex-B start code at b[i], or 0 if there is none. */
static size_t start_code_len(const uint8_t *b, size_t len, size_t i)
{
    if (i + 4 <= len && b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 0 &&
        b[i + 3] == 1)
        return 4;
    if (i + 3 <= len && b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1)
        return 3;
    return 0;
}

/* End offset of the access unit that starts at pos.
 *
 * VDEC is fed one access unit per SendStream with bEndOfFrame set, so the
 * split has to land on picture boundaries. Handing it the whole file in a
 * single buffer is what produced "1 chunks fed" and no decode at all: the
 * read buffer was larger than the clip, so the entire clip became one frame.
 *
 * A new unit starts at an access unit delimiter, or at a parameter set or
 * slice that follows a slice already taken into this unit.
 */
static size_t au_end(const uint8_t *b, size_t len, size_t pos, int is_h265)
{
    size_t i = pos;
    int seen_vcl = 0;

    while (i < len) {
        size_t sc = start_code_len(b, len, i);
        unsigned type;
        int vcl, starts_au;

        if (!sc) {
            i++;
            continue;
        }
        if (i + sc >= len)
            break;

        if (is_h265) {
            type = (b[i + sc] >> 1) & 0x3F;
            vcl  = type <= 31;
            starts_au = (type == 35) ||                    /* AUD */
                        (seen_vcl && (vcl ||
                                      type == 32 ||        /* VPS */
                                      type == 33 ||        /* SPS */
                                      type == 34));        /* PPS */
        } else {
            type = b[i + sc] & 0x1F;
            vcl  = type >= 1 && type <= 5;
            starts_au = (type == 9) ||                     /* AUD */
                        (seen_vcl && (vcl ||
                                      type == 6 ||         /* SEI */
                                      type == 7 ||         /* SPS */
                                      type == 8));         /* PPS */
        }

        if (i > pos && starts_au)
            return i;
        if (vcl)
            seen_vcl = 1;
        i += sc;
    }
    return len;
}

/* ---- RTSP client --------------------------------------------------------
 *
 * OpenIPC's majestic emits nothing at all until a client has completed
 * DESCRIBE/SETUP/PLAY, so simply listening on a UDP port never sees a packet.
 * This is a deliberately small client: one video track, unicast RTP over UDP,
 * Basic auth (majestic answers 401 with realm "WallyWorld"). No digest, no
 * interleaved TCP, no audio -- none of which this pipeline needs.
 *
 * The SDP is also where the codec comes from, so -h265 stops being a guess.
 */
static int      rtsp_fd = -1;
static char     rtsp_auth[192];
static char     rtsp_session[128];
static char     rtsp_base[512];
static unsigned rtsp_cseq = 1;
static time_t   rtsp_last_ka;

static void b64(const unsigned char *in, size_t n, char *out)
{
    static const char t[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                            "abcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t i, o = 0;

    for (i = 0; i < n; i += 3) {
        unsigned v = (unsigned)in[i] << 16;

        if (i + 1 < n) v |= (unsigned)in[i + 1] << 8;
        if (i + 2 < n) v |= (unsigned)in[i + 2];
        out[o++] = t[(v >> 18) & 63];
        out[o++] = t[(v >> 12) & 63];
        out[o++] = i + 1 < n ? t[(v >> 6) & 63] : '=';
        out[o++] = i + 2 < n ? t[v & 63] : '=';
    }
    out[o] = 0;
}

static int tcp_connect(const char *host, int port)
{
    struct sockaddr_in a;
    int fd = socket(AF_INET, SOCK_STREAM, 0);

    if (fd < 0) {
        perror("socket");
        return -1;
    }
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port   = htons((uint16_t)port);
    if (inet_aton(host, &a.sin_addr) == 0) {
        struct hostent *h = gethostbyname(host);

        if (!h) {
            fprintf(stderr, "cannot resolve %s\n", host);
            close(fd);
            return -1;
        }
        memcpy(&a.sin_addr, h->h_addr, sizeof(a.sin_addr));
    }
    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) < 0) {
        perror("connect");
        close(fd);
        return -1;
    }
    return fd;
}

/* Send one request and collect the reply, including any announced body. */
static int rtsp_req(const char *method, const char *url, const char *extra,
                    char *resp, size_t respsz)
{
    char req[1024];
    size_t off = 0, len = 0;

    off += (size_t)snprintf(req + off, sizeof(req) - off,
                            "%s %s RTSP/1.0\r\nCSeq: %u\r\n",
                            method, url, rtsp_cseq++);
    if (rtsp_auth[0])
        off += (size_t)snprintf(req + off, sizeof(req) - off,
                                "Authorization: %s\r\n", rtsp_auth);
    if (rtsp_session[0])
        off += (size_t)snprintf(req + off, sizeof(req) - off,
                                "Session: %s\r\n", rtsp_session);
    if (extra)
        off += (size_t)snprintf(req + off, sizeof(req) - off, "%s", extra);
    off += (size_t)snprintf(req + off, sizeof(req) - off, "\r\n");

    if (write(rtsp_fd, req, off) != (ssize_t)off) {
        perror("rtsp write");
        return -1;
    }

    for (;;) {
        ssize_t n;
        char *body, *cl;
        long clen;

        if (len + 1 >= respsz)
            break;
        n = read(rtsp_fd, resp + len, respsz - 1 - len);
        if (n <= 0)
            break;
        len += (size_t)n;
        resp[len] = 0;
        body = strstr(resp, "\r\n\r\n");
        if (!body)
            continue;
        body += 4;
        cl   = strcasestr(resp, "Content-Length:");
        clen = cl ? strtol(cl + 15, NULL, 10) : 0;
        if ((long)(len - (size_t)(body - resp)) >= clen)
            break;
    }
    resp[len] = 0;
    return (int)len;
}

/* Copy the value of a header/attribute up to CR, LF or ';'. */
static void field(const char *src, char *dst, size_t dstsz)
{
    size_t i = 0;

    while (*src == ' ')
        src++;
    while (src[i] && src[i] != '\r' && src[i] != '\n' && src[i] != ';' &&
           i + 1 < dstsz) {
        dst[i] = src[i];
        i++;
    }
    dst[i] = 0;
}

/*
 * Returns a bound UDP socket carrying the RTP stream, or -1.
 * url: rtsp://[user:pass@]host[:port][/path]
 */
static int rtsp_open(const char *url, MI_VDEC_CodecType_e *codec, int rtp_port)
{
    char host[128] = "", userinfo[128] = "", path[256] = "";
    char setup_url[700], control[256] = "", extra[256], resp[8192];
    const char *p = url, *at, *slash;
    char *m, *s;
    int port = 554, udp_fd;

    if (!strncmp(p, "rtsp://", 7))
        p += 7;
    slash = strchr(p, '/');
    at    = memchr(p, '@', slash ? (size_t)(slash - p) : strlen(p));
    if (at) {
        snprintf(userinfo, sizeof(userinfo), "%.*s", (int)(at - p), p);
        p = at + 1;
    }
    slash = strchr(p, '/');
    if (slash) {
        snprintf(host, sizeof(host), "%.*s", (int)(slash - p), p);
        snprintf(path, sizeof(path), "%s", slash);
    } else {
        snprintf(host, sizeof(host), "%s", p);
    }
    if ((s = strchr(host, ':')) != NULL) {
        *s = 0;
        port = atoi(s + 1);
    }
    snprintf(rtsp_base, sizeof(rtsp_base), "rtsp://%s:%d%s", host, port, path);

    if (userinfo[0]) {
        char enc[256];

        b64((const unsigned char *)userinfo, strlen(userinfo), enc);
        snprintf(rtsp_auth, sizeof(rtsp_auth), "Basic %s", enc);
    }

    printf("RTSP: %s\n", rtsp_base);
    rtsp_fd = tcp_connect(host, port);
    if (rtsp_fd < 0)
        return -1;

    /* ---- DESCRIBE: learn the codec and the track's control URL ---- */
    if (rtsp_req("DESCRIBE", rtsp_base,
                 "Accept: application/sdp\r\n", resp, sizeof(resp)) <= 0)
        return -1;
    if (strncmp(resp, "RTSP/1.0 200", 12)) {
        char line[128];

        field(resp, line, sizeof(line));
        fprintf(stderr, "RTSP DESCRIBE failed: %s\n", line);
        if (strstr(resp, "401"))
            fprintf(stderr, "  (supply credentials: rtsp://user:pass@host/...)\n");
        return -1;
    }

    m = strstr(resp, "m=video");
    if (!m) {
        fprintf(stderr, "RTSP: no video track in SDP\n");
        return -1;
    }
    if (strcasestr(m, "H265") || strcasestr(m, "HEVC")) {
        *codec = E_MI_VDEC_CODEC_TYPE_H265;
        printf("RTSP: SDP says H.265\n");
    } else if (strcasestr(m, "H264")) {
        *codec = E_MI_VDEC_CODEC_TYPE_H264;
        printf("RTSP: SDP says H.264\n");
    } else {
        printf("RTSP: SDP names no codec we know; keeping the command line\n");
    }
    if ((s = strstr(m, "a=control:")) != NULL)
        field(s + 10, control, sizeof(control));

    /* A relative control attribute hangs off the request URL. */
    if (!control[0] || !strcmp(control, "*"))
        snprintf(setup_url, sizeof(setup_url), "%s", rtsp_base);
    else if (!strncmp(control, "rtsp://", 7))
        snprintf(setup_url, sizeof(setup_url), "%s", control);
    else
        snprintf(setup_url, sizeof(setup_url), "%s%s%s", rtsp_base,
                 rtsp_base[strlen(rtsp_base) - 1] == '/' ? "" : "/", control);

    /* ---- SETUP: bind our port first, the server starts sending on PLAY ---- */
    udp_fd = open_udp(rtp_port);
    if (udp_fd < 0)
        return -1;
    snprintf(extra, sizeof(extra),
             "Transport: RTP/AVP;unicast;client_port=%d-%d\r\n",
             rtp_port, rtp_port + 1);
    if (rtsp_req("SETUP", setup_url, extra, resp, sizeof(resp)) <= 0)
        return -1;
    if (strncmp(resp, "RTSP/1.0 200", 12)) {
        char line[128];

        field(resp, line, sizeof(line));
        fprintf(stderr, "RTSP SETUP failed: %s\n", line);
        close(udp_fd);
        return -1;
    }
    if ((s = strcasestr(resp, "Session:")) != NULL)
        field(s + 8, rtsp_session, sizeof(rtsp_session));

    /* ---- PLAY ---- */
    if (rtsp_req("PLAY", rtsp_base, "Range: npt=0.000-\r\n",
                 resp, sizeof(resp)) <= 0)
        return -1;
    if (strncmp(resp, "RTSP/1.0 200", 12)) {
        char line[128];

        field(resp, line, sizeof(line));
        fprintf(stderr, "RTSP PLAY failed: %s\n", line);
        close(udp_fd);
        return -1;
    }
    printf("RTSP: playing, session %s, RTP on UDP %d\n",
           rtsp_session[0] ? rtsp_session : "(none)", rtp_port);
    rtsp_last_ka = time(NULL);
    return udp_fd;
}

/* The server drops an idle session (typically after 60s), so poke it. */
static void rtsp_keepalive(void)
{
    char resp[1024];
    time_t now = time(NULL);

    if (rtsp_fd < 0 || now - rtsp_last_ka < 25)
        return;
    rtsp_last_ka = now;
    rtsp_req("OPTIONS", rtsp_base, NULL, resp, sizeof(resp));
}

int main(int argc, char **argv)
{
    MI_DISP_PubAttr_t pub;
    MI_DISP_VideoLayerAttr_t layer;
    MI_DISP_InputPortAttr_t port;
    MI_VDEC_InitParam_t vdec_init;
    MI_VDEC_ChnAttr_t vdec_attr;
    MI_VDEC_ChnParam_t vdec_param;
    MI_VDEC_OutputPortAttr_t vdec_out;
    MI_DIVP_ChnAttr_t divp_attr;
    MI_DIVP_OutputPortAttr_t divp_out;
    MI_SYS_ChnPort_t src, dst;
    MI_U32 w = 1920, h = 1080;
    MI_U32 sw = 0, sh = 0;          /* source (stream) size; 0 = same as output */
    int noscale = 0;
    MI_VDEC_CodecType_e codec = E_MI_VDEC_CODEC_TYPE_H264;
    MI_VDEC_VideoMode_e vmode = E_MI_VDEC_VIDEO_MODE_FRAME;
    const char *file = NULL;
    const char *rtsp_url = NULL;
    const char *dump = NULL;
    int dump_fd = -1;
    /* -d writes into /tmp, which is RAM on a board with very little of it, so it
       is capped. -rec writes to mounted storage and sets this to the sentinel
       below, meaning no limit. */
    size_t dump_left = 8u * 1024 * 1024;
    int udp_port = 5600, in_fd = -1, i;
    int raw = 0, raw_forced = 0, detected = 0;
    unsigned long long frames = 0, bytes = 0, loops = 0;
    uint8_t *buf;
    uint8_t *fbuf = NULL;               /* sliding window, for -f */
    const size_t fcap = 1024 * 1024;    /* has to hold one access unit */
    size_t ffill = 0, fpos = 0;
    int fps = 60;                       /* replay rate; -fps overrides */
    unsigned pts_hz;

    setvbuf(stdout, NULL, _IONBF, 0);

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-f") && i + 1 < argc)
            file = argv[++i];
        else if (!strcmp(argv[i], "-r") && i + 1 < argc)
            rtsp_url = argv[++i];
        else if (!strcmp(argv[i], "-u") && i + 1 < argc)
            udp_port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-h265"))
            codec = E_MI_VDEC_CODEC_TYPE_H265;
        else if (!strcmp(argv[i], "-raw"))
            raw_forced = 1;
        else if (!strcmp(argv[i], "-d") && i + 1 < argc)
            dump = argv[++i];
        else if (!strcmp(argv[i], "-rec") && i + 1 < argc) {
            dump = argv[++i];
            dump_left = (size_t)-1;
        }
        else if (!strcmp(argv[i], "-fps") && i + 1 < argc) {
            fps = atoi(argv[++i]);
            if (fps < 1)
                fps = 60;
        }
        else if (!strcmp(argv[i], "-stream"))
            vmode = E_MI_VDEC_VIDEO_MODE_STREAM;
        else if (!strcmp(argv[i], "-noscale"))
            noscale = 1;
        else if (!strcmp(argv[i], "-esflag") && i + 1 < argc)
            es_flag = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-s") && i + 1 < argc) {
            unsigned a, b;
            if (sscanf(argv[++i], "%ux%u", &a, &b) == 2) {
                sw = a;
                sh = b;
            }
        } else if (!strcmp(argv[i], "720")) {
            w = 1280;
            h = 720;
        } else {
            fprintf(stderr,
                "usage: %s [-f file | -u port | -r rtsp://url] [-h265] [-raw]\n"
                "               [-stream] [-d out] [-s WxH] [720]\n"
                "  -f FILE   replay an Annex-B elementary stream from a file,\n"
                "            one access unit per frame, looping (test mode)\n"
                "  -u PORT   listen for UDP video (default 5600)\n"
                "  -r URL    pull via RTSP: rtsp://[user:pass@]host[:port][/path].\n"
                "            OpenIPC/majestic sends nothing until PLAY, so a bare\n"
                "            -u listener stays silent. The SDP sets the codec.\n"
                "  -h265     input is H.265 (default H.264)\n"
                "  -raw      input is Annex-B, not RTP (autodetected otherwise)\n"
                "  -stream   feed VDEC in STREAM mode (default FRAME)\n"
                "  -d OUT    also write the reassembled stream to OUT\n"
                "  -rec OUT  record to OUT, uncapped, for a mounted USB stick.\n"
                "            Same bytes the decoder gets: an Annex-B elementary\n"
                "            stream, playable as-is and remuxable losslessly.\n"
                "  -fps N    replay rate, default 60. Only paces -f.\n"
                "  -s WxH    source resolution, e.g. 1280x720. The decoder\n"
                "            cannot scale up, so it must decode at the stream's\n"
                "            own size; DIVP then scales to the output.\n"
                "  -noscale  skip MI_VDEC_SetOutputPortAttr, leaving the\n"
                "            decoder's scaler off and all scaling to DIVP\n"
                "  -esflag N set byte 4 of the SendStream ioctl payload, which\n"
                "            the 2023 driver reads and the 2020 library never\n"
                "            writes. Omit to leave it zero.\n"
                "  720       output 720p instead of 1080p\n", argv[0]);
            return 1;
        }
    }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    /* RTSP is negotiated before the decoder is configured, because the SDP is
       what says whether this is H.264 or H.265 and VDEC needs the codec in its
       channel attributes up front. Video therefore starts arriving while the
       MI pipeline is still being built; a few early packets may be dropped,
       but majestic repeats its parameter sets, so decoding picks up on the
       next keyframe. */
    if (rtsp_url) {
        in_fd = rtsp_open(rtsp_url, &codec, udp_port);
        if (in_fd < 0)
            return 1;
    }

    vdec_shift_init();

    if (sw == 0 || sh == 0) {
        sw = w;
        sh = h;
    }

    printf("mi-player: decode %ux%u -> display %ux%u, %s\n", sw, sh, w, h,
           codec == E_MI_VDEC_CODEC_TYPE_H264 ? "H.264" : "H.265");

    if (step("MI_SYS_Init", MI_SYS_Init()) != 0)
        return 1;

    /* ---- display ------------------------------------------------------- */
    memset(&pub, 0, sizeof(pub));
    pub.eIntfType = E_MI_DISP_INTF_HDMI;
    pub.eIntfSync = (h == 1080) ? E_MI_DISP_OUTPUT_1080P60 : E_MI_DISP_OUTPUT_720P60;
    pub.u32BgColor = 0x00000000;

    step("MI_DISP_SetPubAttr", MI_DISP_SetPubAttr(DISP_DEV, &pub));
    step("MI_DISP_Enable", MI_DISP_Enable(DISP_DEV));

    memset(&layer, 0, sizeof(layer));
    layer.stVidLayerSize.u16Width = w;
    layer.stVidLayerSize.u16Height = h;
    layer.stVidLayerDispWin.u16Width = w;
    layer.stVidLayerDispWin.u16Height = h;

    step("MI_DISP_BindVideoLayer", MI_DISP_BindVideoLayer(DISP_LAYER, DISP_DEV));
    step("MI_DISP_SetVideoLayerAttr", MI_DISP_SetVideoLayerAttr(DISP_LAYER, &layer));
    step("MI_DISP_EnableVideoLayer", MI_DISP_EnableVideoLayer(DISP_LAYER));

    memset(&port, 0, sizeof(port));
    port.stDispWin.u16X = 0;
    port.stDispWin.u16Y = 0;
    port.stDispWin.u16Width = w;
    port.stDispWin.u16Height = h;
    /* Size of the frames arriving from VDEC. Leaving these zero makes the
       display believe the input is 0x0 and nothing is composited. */
    port.u16SrcWidth = w;
    port.u16SrcHeight = h;

    /* mi-disp-init already enabled this port at boot; an enabled port may
       ignore attribute changes, so cycle it. */
    MI_DISP_DisableInputPort(DISP_LAYER, DISP_PORT);
    step("MI_DISP_SetInputPortAttr", MI_DISP_SetInputPortAttr(DISP_LAYER, DISP_PORT, &port));
    step("MI_DISP_EnableInputPort", MI_DISP_EnableInputPort(DISP_LAYER, DISP_PORT));

    /* ---- decoder ------------------------------------------------------- */
    memset(&vdec_init, 0, sizeof(vdec_init));
    vdec_init.bDisableLowLatency = FALSE;   /* FPV: latency is the whole point */
    step("MI_VDEC_InitDev", MI_VDEC_InitDev(&vdec_init));

    memset(&vdec_attr, 0, sizeof(vdec_attr));
    vdec_attr.eCodecType   = codec;
    vdec_attr.u32BufSize   = 1 * 1024 * 1024;
    vdec_attr.u32Priority  = 0;
    vdec_attr.u32PicWidth  = sw;
    vdec_attr.u32PicHeight = sh;
    /* We hand VDEC exactly one complete frame per SendStream, which is what
       FRAME mode expects. -stream selects STREAM mode for comparison. */
    vdec_attr.eVideoMode   = vmode;
    vdec_attr.eDpbBufMode  = E_MI_VDEC_DPB_MODE_NORMAL;
    vdec_attr.stVdecVideoAttr.u32RefFrameNum = 2;

    step("MI_VDEC_CreateChn", MI_VDEC_CreateChn(VDEC_CHN, &vdec_attr));

    /* Set every channel parameter explicitly rather than relying on whatever
       the 2023 driver leaves in its internal defaults. */
    memset(&vdec_param, 0, sizeof(vdec_param));
    vdec_param.eDecMode     = E_MI_VDEC_DECODE_MODE_ALL;
    vdec_param.eOutputOrder = E_MI_VDEC_OUTPUT_ORDER_DISPLAY;
    vdec_param.eVideoFormat = E_MI_VDEC_VIDEO_FORMAT_TILE;
    step("MI_VDEC_SetChnParam", MI_VDEC_SetChnParam(VDEC_CHN, &vdec_param));

    memset(&vdec_out, 0, sizeof(vdec_out));
    /* Must match the stream's own size. The driver refuses to scale up on this
       port -- "Chn %d not support scaling up" -- so any upscaling has to happen
       downstream in DIVP, which is a scaler.

       Setting this at all turns the decoder's scaler on (bScale=Y in the proc
       dump), even at 1:1. -noscale leaves it off entirely, so the decoder is
       never asked to configure a scaler against a source size it does not yet
       know at sequence-init time. */
    if (noscale) {
        printf("  MI_VDEC_SetOutputPortAttr      skipped (-noscale)\n");
    } else {
        vdec_out.u16Width  = sw;
        vdec_out.u16Height = sh;
        step("MI_VDEC_SetOutputPortAttr",
             MI_VDEC_SetOutputPortAttr(VDEC_CHN, &vdec_out));
    }

    /* PREVIEW keeps latency down; PLAYBACK buffers for smoothness instead. */
    step("MI_VDEC_SetDisplayMode",
         MI_VDEC_SetDisplayMode(VDEC_CHN, E_MI_VDEC_DISPLAY_MODE_PREVIEW));

    /* ---- DIVP, sitting between the decoder and the display --------------
     *
     * mi_vdec declares a module dependency on mi_divp, and the vendor topology
     * on this SoC routes decoded frames through DIVP (format conversion and
     * scaling) rather than straight into DISP. Binding VDEC directly to DISP is
     * accepted but leaves the decoder without a consumer it recognises, which
     * fits what we see: frames accepted, none ever decoded.
     *
     * DIVP needs no ioctl fixup -- its 2020 library and the 2023 XM driver
     * agree one-for-one on numbering and argument sizes, unlike VDEC.
     */
    memset(&divp_attr, 0, sizeof(divp_attr));
    divp_attr.u32MaxWidth  = sw;
    divp_attr.u32MaxHeight = sh;
    divp_attr.eTnrLevel    = E_MI_DIVP_TNR_LEVEL_OFF;
    divp_attr.eDiType      = E_MI_DIVP_DI_TYPE_OFF;
    divp_attr.eRotateType  = E_MI_SYS_ROTATE_NONE;
    divp_attr.bHorMirror   = FALSE;
    divp_attr.bVerMirror   = FALSE;
    /* a zeroed stCropRect means no cropping */

    step("MI_DIVP_CreateChn", MI_DIVP_CreateChn(DIVP_CHN, &divp_attr));

    memset(&divp_out, 0, sizeof(divp_out));
    divp_out.u32Width     = w;
    divp_out.u32Height    = h;
    divp_out.ePixelFormat = E_MI_SYS_PIXEL_FRAME_YUV_SEMIPLANAR_420;
    divp_out.eCompMode    = E_MI_SYS_COMPRESS_MODE_NONE;

    step("MI_DIVP_SetOutputPortAttr",
         MI_DIVP_SetOutputPortAttr(DIVP_CHN, &divp_out));
    step("MI_DIVP_StartChn", MI_DIVP_StartChn(DIVP_CHN));

    /* ---- bind VDEC -> DIVP -> DISP -------------------------------------- */
    memset(&src, 0, sizeof(src));
    src.eModId    = E_MI_MODULE_ID_VDEC;
    src.u32DevId  = 0;
    src.u32ChnId  = VDEC_CHN;
    src.u32PortId = 0;

    memset(&dst, 0, sizeof(dst));
    dst.eModId    = E_MI_MODULE_ID_DIVP;
    dst.u32DevId  = 0;
    dst.u32ChnId  = DIVP_CHN;
    dst.u32PortId = 0;

    /* Give each output port a buffer queue. Without one the port has nowhere
       to put finished frames, so a bind can succeed yet deliver nothing. Zero
       user frames because we never read frames ourselves. */
    step("MI_SYS_SetChnOutputPortDepth(vdec)",
         MI_SYS_SetChnOutputPortDepth(&src, 0, 4));
    step("MI_SYS_BindChnPort(vdec->divp)",
         MI_SYS_BindChnPort(&src, &dst, 30, 30));

    memset(&src, 0, sizeof(src));
    src.eModId    = E_MI_MODULE_ID_DIVP;
    src.u32DevId  = 0;
    src.u32ChnId  = DIVP_CHN;
    src.u32PortId = 0;

    memset(&dst, 0, sizeof(dst));
    dst.eModId    = E_MI_MODULE_ID_DISP;
    dst.u32DevId  = DISP_DEV;
    dst.u32ChnId  = DISP_LAYER;
    dst.u32PortId = DISP_PORT;

    step("MI_SYS_SetChnOutputPortDepth(divp)",
         MI_SYS_SetChnOutputPortDepth(&src, 0, 4));
    step("MI_SYS_BindChnPort(divp->disp)",
         MI_SYS_BindChnPort(&src, &dst, 30, 30));

    /* Start last: the channel is only opened here, so everything it depends on
       (output port geometry, display mode, the bound consumer) must already be
       in place. Starting first left the decoder opening against an
       unconfigured output port. */
    step("MI_VDEC_StartChn", MI_VDEC_StartChn(VDEC_CHN));

    /* ---- HDMI ---------------------------------------------------------- */
    hdmi_start(h);

    /* ---- feed ---------------------------------------------------------- */
    if (file) {
        off_t end;

        /* Streamed through a window rather than read in whole: a recording off
           the DVR is routinely larger than this board has RAM. */
        in_fd = open(file, O_RDONLY);
        if (in_fd < 0) {
            perror(file);
            return 1;
        }
        end = lseek(in_fd, 0, SEEK_END);
        if (end <= 0) {
            fprintf(stderr, "%s: empty\n", file);
            return 1;
        }
        lseek(in_fd, 0, SEEK_SET);
        fbuf = malloc(fcap);
        if (!fbuf) {
            fprintf(stderr, "out of memory\n");
            return 1;
        }
        printf("feeding from %s, %llu bytes, looping\n",
               file, (unsigned long long)end);
    } else if (rtsp_url) {
        /* Already connected above. Time out reads so the session keepalive
           still runs if the video stalls -- otherwise the server drops us. */
        struct timeval tv;

        tv.tv_sec  = 1;
        tv.tv_usec = 0;
        setsockopt(in_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    } else {
        in_fd = open_udp(udp_port);
        if (in_fd < 0)
            return 1;
    }

    buf = malloc(256 * 1024);
    frame_cap = 1024 * 1024;            /* matches VDEC u32BufSize */
    frame = malloc(frame_cap);
    if (!buf || !frame) {
        fprintf(stderr, "out of memory\n");
        return 1;
    }

    /* A file is always an elementary stream; RTP only turns up on the wire. */
    raw = file ? 1 : raw_forced;
    detected = raw;

    /* Only replay follows -fps. Live keeps the 30Hz basis it has always run
       with: the decoder needs this value to move, not to be accurate, and that
       path works today. */
    pts_hz = file ? (unsigned)fps : 30;

    if (dump) {
        dump_fd = open(dump, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (dump_fd < 0)
            perror(dump);
        else
            printf("writing reassembled stream to %s\n", dump);
    }

    printf("\ndecoding -- Ctrl-C to stop\n");

    while (running) {
        MI_VDEC_VideoStream_t vs;
        const uint8_t *out;
        size_t out_len;
        MI_S32 ret;

        if (file) {
            size_t au;
            int wrapped = 0;

            /* Drop what was fed last time, then top the window back up. */
            if (fpos > 0) {
                memmove(fbuf, fbuf + fpos, ffill - fpos);
                ffill -= fpos;
                fpos = 0;
            }
            while (ffill < fcap) {
                ssize_t got = read(in_fd, fbuf + ffill, fcap - ffill);

                if (got > 0) {
                    ffill += (size_t)got;
                    continue;
                }
                if (got < 0) {
                    perror(file);
                    break;
                }
                /* End of the recording. Rewind and keep filling, so the window
                   spans the join and the loop has no gap in it. Once only: a
                   file shorter than the window would otherwise never stop. */
                if (wrapped++)
                    break;
                lseek(in_fd, 0, SEEK_SET);
                loops++;
            }
            if (ffill == 0)
                break;

            au = au_end(fbuf, ffill, 0,
                        codec == E_MI_VDEC_CODEC_TYPE_H265);
            out     = fbuf;
            out_len = au;
            fpos    = au;
            /* Pace it: a decoder fed far faster than it drains just reports a
               full queue, and the display has nowhere to put the frames. */
            usleep(1000000 / (unsigned)fps);
        } else {
            ssize_t n = read(in_fd, buf, 256 * 1024);

            if (n < 0) {
                if (errno == EINTR)
                    continue;
                if (errno == EAGAIN || errno == EWOULDBLOCK) {
                    rtsp_keepalive();
                    continue;
                }
                perror("read");
                break;
            }
            if (n == 0)
                continue;
            rtsp_keepalive();

            /* Decide once, from the first datagram. An Annex-B stream starts
               with a start code, which can never be a valid RTP header (the
               version bits forbid it). */
            if (!detected) {
                detected = 1;
                if (n >= 4 && buf[0] == 0 && buf[1] == 0 &&
                    (buf[2] == 1 || (buf[2] == 0 && buf[3] == 1)))
                    raw = 1;
                printf("input format: %s\n", raw ? "Annex-B" : "RTP");
            }

            if (raw) {
                out = buf;
                out_len = (size_t)n;
            } else {
                if (!rtp_feed(buf, (size_t)n,
                              codec == E_MI_VDEC_CODEC_TYPE_H265))
                    continue;           /* frame not finished yet */
                out = frame;
                out_len = frame_len;
                frame_len = 0;
                if (out_len == 0)
                    continue;
            }
        }

        memset(&vs, 0, sizeof(vs));
        vs.pu8Addr      = (MI_U8 *)out;
        vs.u32Len       = (MI_U32)out_len;
        /* Monotonic presentation time in microseconds. A constant PTS makes
           some vendor decoders treat every frame as a duplicate and drop it
           without reporting an error. */
        vs.u64PTS       = frames * (1000000ull / pts_hz);
        vs.bEndOfFrame  = TRUE;
        vs.bEndOfStream = FALSE;

        if (dump_fd >= 0) {
            if (dump_left == 0) {
                printf("dump limit reached, closing %s\n", dump);
                close(dump_fd);
                dump_fd = -1;
            } else {
                size_t n_w = out_len < dump_left ? out_len : dump_left;

                if (write(dump_fd, out, n_w) < 0) {
                    /* A stick that filled up or was pulled must not take the
                       video down with it: give up writing, keep decoding. */
                    perror(dump);
                    close(dump_fd);
                    dump_fd = -1;
                } else if (dump_left != (size_t)-1) {
                    dump_left -= n_w;
                }
            }
        }

        ret = MI_VDEC_SendStream(VDEC_CHN, &vs, 100);
        if (ret != MI_SUCCESS && frames < 5)
            printf("MI_VDEC_SendStream: 0x%08x\n", (unsigned)ret);

        frames++;
        bytes += (unsigned long long)out_len;

        if ((frames % 100) == 0) {
            /* The 2023 driver's ChnStat layout does not match the 2020 header
               (it reports err=9, which is the enum terminator, and a receive
               count with no sensible relation to what we sent). Dump the raw
               words instead so the real layout can be identified: look for the
               field that tracks our frame count and the one that stays 1. The
               buffer is oversized in case the driver writes more than the
               header's 32 bytes. */
            union {
                MI_VDEC_ChnStat_t st;
                MI_U32 raw[32];
            } u;
            int k;

            if (file)
                printf("fed %llu frames, %llu KB, %llu file loops\n",
                       frames, bytes / 1024, loops);
            else
                printf("fed %llu %s, %llu KB, %u lost pkts\n", frames,
                       raw ? "chunks" : "frames", bytes / 1024, lost_packets);

            memset(&u, 0, sizeof(u));
            if (MI_VDEC_GetChnStat(VDEC_CHN, &u.st) == MI_SUCCESS) {
                printf("  vdec stat:");
                for (k = 0; k < 10; k++)
                    printf(" [%d]=%u", k, (unsigned)u.raw[k]);
                printf("\n");
            }
        }
    }

    printf("\nstopping\n");

    /* Release the session rather than leaving the server to time it out: some
       builds refuse a fresh SETUP while the old one is still live. */
    if (rtsp_fd >= 0) {
        char resp[512];

        rtsp_req("TEARDOWN", rtsp_base, NULL, resp, sizeof(resp));
        close(rtsp_fd);
        rtsp_fd = -1;
    }
    MI_SYS_UnBindChnPort(&src, &dst);      /* divp -> disp */
    MI_DIVP_StopChn(DIVP_CHN);
    MI_DIVP_DestroyChn(DIVP_CHN);
    MI_VDEC_StopChn(VDEC_CHN);
    MI_VDEC_DestroyChn(VDEC_CHN);
    MI_VDEC_DeInitDev();

    free(buf);
    free(frame);
    if (dump_fd >= 0)
        close(dump_fd);
    close(in_fd);
    if (hdmi_fd >= 0)
        close(hdmi_fd);

    return 0;
}

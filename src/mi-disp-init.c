/*
 * Bring the SigmaStar display pipeline up on HDMI.
 *
 * The HDMI transmitter stays dark until userspace creates its driver context --
 * the kernel logs "DrvHdmitxCtxGet: Get Ctx is NULL" and /sys/class/mstar/mhdmitx/clk
 * reports CLK_HDMI ClkRate:0 until then. Neither the sysfs debug knobs nor writing
 * to /dev/fb0 can do it, so this walks the MI_SYS/MI_DISP init sequence instead.
 *
 * Every step reports its return code: the point is to find out where the stack
 * actually stops, not just whether a picture appears.
 */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>
#include <fcntl.h>
#include <sys/ioctl.h>

#include "mi_common_datatype.h"
#include "mi_sys.h"
#include "mi_disp.h"
#include "mi_hdmi_datatype.h"

#define DISP_DEV    0
#define DISP_LAYER  0
#define DISP_PORT   0

/*
 * MI_HDMI has to be driven by raw ioctl: this SDK ships no libmi_hdmi.so (or .a)
 * for Infinity2M, yet without MI_HDMI_Init/Open/SetAttr/Start the transmitter
 * context is never created and the clock stays at 0.
 *
 * The encoding was recovered from the shipped libraries and cross-checked against
 * the stock XM App, which issues exactly these commands:
 *
 *   cmd  = dir | (sizeof(args) << 16) | (0x69 << 8) | nr
 *   arg  = &(struct mi_ioc){ sizeof(args), 0, (uintptr_t)&args }
 *
 * nr comes from the dispatch table in mi_hdmi.ko (.rel.data, base 0x24, one
 * pointer per index) -- Init 0, DeInit 1, Open 2, Close 3, SetAttr 4, GetAttr 5,
 * Start 6, Stop 7. Every args block begins with the device id, except Init which
 * ignores its argument entirely (MI_HDMI_IOCTL_Init calls IMPL_Init() with none).
 */
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

/*
 * The kernel copies exactly the byte count encoded in the ioctl command, so a
 * header that disagrees with this module would overrun a kernel buffer rather
 * than fail cleanly. mi_hdmi.ko's IOCTL_GetAttr copies back 44 bytes of attr,
 * and its SetAttr command encodes 0x30, so pin both here: MI_BOOL is one byte,
 * giving 1+3pad + 20 video + 16 audio + 3 infoframe -> 44, and 4 + 44 -> 48.
 * If a future header changes any field, this fails to compile instead.
 */
typedef char assert_hdmi_attr_is_44[(sizeof(MI_HDMI_Attr_t) == 44) ? 1 : -1];
typedef char assert_hdmi_args_is_48[(sizeof(struct hdmi_setattr_args) == 48) ? 1 : -1];

static int hdmi_call(int fd, unsigned long cmd, void *args, size_t len)
{
    struct mi_ioc w;

    w.size = (uint32_t)len;
    w.pad  = 0;
    w.ptr  = (uint64_t)(uintptr_t)args;

    return ioctl(fd, cmd, &w);
}

/* MI returns 0 on success; anything else is an error code worth printing in hex. */
static int step(const char *name, MI_S32 ret)
{
    if (ret == MI_SUCCESS) {
        printf("  %-34s ok\n", name);
        return 0;
    }
    printf("  %-34s FAILED (0x%08x)\n", name, (unsigned)ret);
    return -1;
}

int main(int argc, char **argv)
{
    MI_DISP_PubAttr_t pub;
    MI_DISP_VideoLayerAttr_t layer;
    MI_DISP_InputPortAttr_t port;
    MI_U32 w = 1920, h = 1080;

    /* This process never exits (it must hold /dev/mi_hdmi open), so with stdout
       redirected to a file the default block buffering would mean nothing is
       ever flushed and the log stays empty. */
    setvbuf(stdout, NULL, _IONBF, 0);

    /* 720p is the fallback if a monitor refuses 1080p60. */
    if (argc > 1 && strcmp(argv[1], "720") == 0) {
        w = 1280;
        h = 720;
    }

    printf("MI display init: %ux%u over HDMI\n", w, h);

    if (step("MI_SYS_Init", MI_SYS_Init()) != 0) {
        printf("\nMI_SYS_Init failed -- the MI stack is not usable yet.\n");
        return 1;
    }

    memset(&pub, 0, sizeof(pub));
    pub.eIntfType = E_MI_DISP_INTF_HDMI;
    pub.eIntfSync = (h == 1080) ? E_MI_DISP_OUTPUT_1080P60 : E_MI_DISP_OUTPUT_720P60;
    pub.u32BgColor = 0x000000ff;   /* blue, so an empty layer is obvious on screen */

    step("MI_DISP_SetPubAttr", MI_DISP_SetPubAttr(DISP_DEV, &pub));
    step("MI_DISP_Enable", MI_DISP_Enable(DISP_DEV));

    memset(&layer, 0, sizeof(layer));
    layer.stVidLayerSize.u16Width = w;
    layer.stVidLayerSize.u16Height = h;
    layer.stVidLayerDispWin.u16X = 0;
    layer.stVidLayerDispWin.u16Y = 0;
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

    step("MI_DISP_SetInputPortAttr", MI_DISP_SetInputPortAttr(DISP_LAYER, DISP_PORT, &port));
    step("MI_DISP_EnableInputPort", MI_DISP_EnableInputPort(DISP_LAYER, DISP_PORT));

    /* ---- HDMI transmitter ------------------------------------------------ */
    {
        int fd = open("/dev/mi_hdmi", O_RDWR);

        if (fd < 0) {
            perror("  open /dev/mi_hdmi");
        } else {
            struct hdmi_setattr_args sa;
            uint32_t id = E_MI_HDMI_ID_0;

            step("MI_HDMI_Init", hdmi_call(fd, MI_HDMI_IOC_INIT, &id, 4));
            step("MI_HDMI_Open", hdmi_call(fd, MI_HDMI_IOC_OPEN, &id, 4));

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
            /* Audio off: nothing feeds it yet and a bad clock can block the link. */
            sa.stAttr.stAudioAttr.bEnableAudio   = 0;
            sa.stAttr.stAudioAttr.eSampleRate    = E_MI_HDMI_AUDIO_SAMPLERATE_48K;
            sa.stAttr.stAudioAttr.eBitDepth      = E_MI_HDMI_BIT_DEPTH_16;
            sa.stAttr.stEnInfoFrame.bEnableAviInfoFrame = 1;

            step("MI_HDMI_SetAttr",
                 hdmi_call(fd, MI_HDMI_IOC_SETATTR, &sa, sizeof(sa)));
            step("MI_HDMI_Start", hdmi_call(fd, MI_HDMI_IOC_START, &id, 4));
            /* Keep the fd open: closing it releases the client and stops the TX. */
        }
    }

    printf("\nDone. Check the monitor and:\n");
    printf("  cat /sys/class/mstar/mhdmitx/clk   (CLK_HDMI should no longer be 0)\n");
    printf("\nLeaving the pipeline enabled; press Ctrl-C to exit.\n");

    /* MI_SYS_Exit() would tear the display straight back down. */
    for (;;)
        sleep(60);

    return 0;
}

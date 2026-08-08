/*
 * Put an RTL8812AU into monitor mode on a given channel, and optionally sniff.
 *
 * wfb-ng normally drives this with `iw`, which needs libnl. That whole
 * dependency chain is avoidable here: the wfb fork of the driver implements
 * IW_MODE_MONITOR directly in its wireless-extensions handler
 * (os_dep/linux/ioctl_linux.c, rtw_wx_set_mode), and the kernel is built with
 * CONFIG_CFG80211_WEXT=y, so SIOCSIWMODE/SIOCSIWFREQ are enough.
 *
 * The sniff mode exists to answer one question before any of wfb-ng is built:
 * are the drone's packets actually reaching this board on this channel?
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <time.h>

#include <sys/ioctl.h>
#include <sys/socket.h>
#include <netinet/in.h>
/* linux/if.h rather than net/if.h: linux/wireless.h drags in the kernel's
   if.h, and including glibc's as well gives duplicate IFF_* enumerators. */
#include <linux/if.h>
#include <linux/wireless.h>
#include <linux/if_packet.h>
#include <linux/if_ether.h>

static int set_flags(int fd, const char *ifname, short set, short clear)
{
    struct ifreq ifr;

    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);

    if (ioctl(fd, SIOCGIFFLAGS, &ifr) < 0)
        return -1;

    ifr.ifr_flags = (ifr.ifr_flags & ~clear) | set;

    return ioctl(fd, SIOCSIFFLAGS, &ifr);
}

static int set_mode(int fd, const char *ifname, int mode)
{
    struct iwreq wrq;

    memset(&wrq, 0, sizeof(wrq));
    strncpy(wrq.ifr_name, ifname, IFNAMSIZ - 1);
    wrq.u.mode = mode;

    return ioctl(fd, SIOCSIWMODE, &wrq);
}

/* e = 0 means "m is a channel number" rather than a frequency in Hz. */
static int set_channel(int fd, const char *ifname, int channel)
{
    struct iwreq wrq;

    memset(&wrq, 0, sizeof(wrq));
    strncpy(wrq.ifr_name, ifname, IFNAMSIZ - 1);
    wrq.u.freq.m = channel;
    wrq.u.freq.e = 0;
    wrq.u.freq.flags = IW_FREQ_FIXED;

    return ioctl(fd, SIOCSIWFREQ, &wrq);
}

static int get_mode(int fd, const char *ifname, int *mode)
{
    struct iwreq wrq;

    memset(&wrq, 0, sizeof(wrq));
    strncpy(wrq.ifr_name, ifname, IFNAMSIZ - 1);

    if (ioctl(fd, SIOCGIWMODE, &wrq) < 0)
        return -1;

    *mode = wrq.u.mode;
    return 0;
}

static int sniff(const char *ifname, int seconds)
{
    unsigned char buf[4096];
    unsigned long packets = 0, bytes = 0;
    unsigned long wfb_packets = 0;
    unsigned int wfb_channels[8] = {0};
    int wfb_channel_count = 0;
    struct sockaddr_ll sll;
    struct ifreq ifr;
    time_t deadline;
    int fd;

    fd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
    if (fd < 0) {
        perror("socket(AF_PACKET)");
        return -1;
    }

    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
    if (ioctl(fd, SIOCGIFINDEX, &ifr) < 0) {
        perror("SIOCGIFINDEX");
        close(fd);
        return -1;
    }

    memset(&sll, 0, sizeof(sll));
    sll.sll_family = AF_PACKET;
    sll.sll_protocol = htons(ETH_P_ALL);
    sll.sll_ifindex = ifr.ifr_ifindex;

    if (bind(fd, (struct sockaddr *)&sll, sizeof(sll)) < 0) {
        perror("bind");
        close(fd);
        return -1;
    }

    /* Time out the read so an idle channel still reports rather than hanging. */
    {
        struct timeval tv = { .tv_sec = 1, .tv_usec = 0 };
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    }

    printf("sniffing %s for %d s ...\n", ifname, seconds);
    deadline = time(NULL) + seconds;

    while (time(NULL) < deadline) {
        ssize_t n = recv(fd, buf, sizeof(buf), 0);
        unsigned rtap;

        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
                continue;
            perror("recv");
            break;
        }

        rtap = (n >= 4) ? (buf[2] | (buf[3] << 8)) : 0;
        if (packets == 0) {
            /* In monitor mode every frame is prefixed with a radiotap header;
               its length is a little-endian u16 at offset 2. Seeing a sane
               value here confirms we really are getting 802.11, not Ethernet. */
            printf("first frame: %zd bytes, radiotap header %u bytes%s\n",
                   n, rtap,
                   (rtap >= 8 && rtap < 128) ? "" : "  <-- not radiotap?");
        }

        /* WFB-NG stores its channel identifier in bytes 12..15 of the
           802.11 header, after the W:B MAC marker at bytes 10..11. */
        if (rtap >= 8 && rtap + 16 <= (unsigned)n &&
            buf[rtap + 10] == 0x57 && buf[rtap + 11] == 0x42) {
            unsigned int channel = ((unsigned int)buf[rtap + 12] << 24) |
                                   ((unsigned int)buf[rtap + 13] << 16) |
                                   ((unsigned int)buf[rtap + 14] << 8) |
                                   buf[rtap + 15];
            int index;

            wfb_packets++;
            for (index = 0; index < wfb_channel_count; index++)
                if (wfb_channels[index] == channel)
                    break;
            if (index == wfb_channel_count && wfb_channel_count < 8) {
                wfb_channels[wfb_channel_count++] = channel;
                printf("WFB stream: channel_id %u (link_id %u, radio_port %u)\n",
                       channel, channel >> 8, channel & 0xff);
            }
        }

        packets++;
        bytes += (unsigned long)n;
    }

    printf("captured %lu packets, %lu bytes\n", packets, bytes);
    printf("captured %lu WFB-NG packets\n", wfb_packets);
    if (packets == 0)
        printf("nothing received: wrong channel, drone not transmitting,"
               " or antenna/RF issue\n");

    close(fd);
    return 0;
}

int main(int argc, char **argv)
{
    const char *ifname;
    int channel, seconds = 0, fd, mode = -1, managed = 0;

    if (argc < 3) {
        fprintf(stderr,
                "usage: %s <iface> <channel> [sniff-seconds]\n"
                "       %s <iface> managed\n"
                "  e.g. %s wlan0 161 10\n"
                "       %s wlan0 managed   (back to station mode for APFPV)\n",
                argv[0], argv[0], argv[0], argv[0]);
        return 1;
    }

    ifname = argv[1];
    if (strcmp(argv[2], "managed") == 0) {
        managed = 1;
        channel = 0;
    } else {
        channel = atoi(argv[2]);
        if (argc > 3)
            seconds = atoi(argv[3]);
    }

    fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        perror("socket");
        return 1;
    }

    /* The interface has to be down to change type, then up before the channel
       can be set -- doing it in the other order fails with EBUSY/EINVAL. */
    if (set_flags(fd, ifname, 0, IFF_UP) < 0)
        perror("  ifdown");

    if (managed) {
        /* APFPV needs the card back in station mode; BusyBox has no iwconfig,
           so this is the only way to undo monitor mode without reloading the
           driver. */
        if (set_mode(fd, ifname, IW_MODE_INFRA) < 0) {
            perror("  SIOCSIWMODE(managed)");
            close(fd);
            return 1;
        }
        printf("  managed mode set\n");

        if (set_flags(fd, ifname, IFF_UP, 0) < 0)
            perror("  ifup");
        else
            printf("  interface up\n");

        if (get_mode(fd, ifname, &mode) == 0)
            printf("  mode now %d (%d = managed)\n", mode, IW_MODE_INFRA);

        close(fd);
        return 0;
    }

    if (set_mode(fd, ifname, IW_MODE_MONITOR) < 0) {
        perror("  SIOCSIWMODE(monitor)");
        close(fd);
        return 1;
    }
    printf("  monitor mode set\n");

    if (set_flags(fd, ifname, IFF_UP, 0) < 0) {
        perror("  ifup");
        close(fd);
        return 1;
    }
    printf("  interface up\n");

    if (set_channel(fd, ifname, channel) < 0)
        perror("  SIOCSIWFREQ(channel)");
    else
        printf("  channel %d set\n", channel);

    if (get_mode(fd, ifname, &mode) == 0)
        printf("  mode now %d (%d = monitor)\n", mode, IW_MODE_MONITOR);

    close(fd);

    if (seconds > 0)
        return sniff(ifname, seconds) < 0 ? 1 : 0;

    return 0;
}

/*
 * Ground-station half of OpenIPC adaptive-link.
 *
 *   alink-gs [-i ip] [-p port] [-s statusfile] [-t ms] [-1] [-v]
 *
 * Scores the downlink from what wfb_rx already measured and tells the air unit,
 * which picks an MCS and bitrate to match. Upstream ships this as a Python
 * daemon reading wfb-ng's aggregator over its own protocol; neither Python nor
 * the aggregator exists here, so the input is /tmp/wfb.status -- the single line
 * wfb-start's awk filter rewrites once a second from wfb_rx's stdout:
 *
 *   freq mcs bw rssi snr pkt kbps fec lost decerr ants
 *
 * The wire format is alink_drone's, byte for byte. process_message() there
 * splits on ':' and reads fixed token positions, so field order and count are
 * load-bearing; a malformed line is dropped without complaint.
 *
 * Silence is meaningful: alink_drone falls back to profile 999 (MCS 0) after
 * about a second without a message. That is the correct end state for a link we
 * cannot measure, so a stale or signal-free status file makes this send nothing
 * rather than invent a score.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#define DEFAULT_IP	"10.5.0.10"
#define DEFAULT_PORT	9999
#define DEFAULT_STATUS	"/tmp/wfb.status"
#define DEFAULT_INTERVAL 100

/* alink_gs.conf defaults. The window ends well above the noise floor: by -85dBm
   this link is already losing packets, so there is nothing to be gained by
   scoring below it. */
#define RSSI_MIN	(-85.0)
#define RSSI_MAX	(-40.0)
#define SNR_MIN		(10.0)
#define SNR_MAX		(36.0)
#define RSSI_WEIGHT	0.5
#define SNR_WEIGHT	0.5

#define SCORE_MIN	1000
#define SCORE_MAX	2000

/* Status is rewritten every second; two missed writes means wfb_rx is wedged or
   gone, and its last reading no longer describes the air. */
#define STALE_SEC	3

static int verbose;

static double clamp01(double v)
{
	if (v < 0.0)
		return 0.0;
	if (v > 1.0)
		return 1.0;
	return v;
}

static int normalise(double v, double lo, double hi)
{
	return SCORE_MIN + (int)(clamp01((v - lo) / (hi - lo)) * (SCORE_MAX - SCORE_MIN));
}

/* Milliseconds, masked to stay positive in a 32-bit signed long. The air unit
   only ever subtracts this from its own clock to get a latency, and full epoch
   milliseconds overflow the long it parses into on 32-bit ARM. */
static long now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_REALTIME, &ts);
	return (long)(((uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000) & 0x7FFFFFFF);
}

/*
 * Reads one status line. Returns 0 if it describes a link carrying video.
 *
 * rssi is the test, not the packet count: wfb_rx records antenna statistics
 * only for packets that decrypted, so packets with no rssi mean the air unit is
 * heard but keyed differently -- nothing worth scoring.
 */
static int read_status(const char *path, double *rssi, double *snr,
		       int *fec, int *lost, int *ants)
{
	char line[256];
	char f_rssi[32], f_snr[32];
	int pkt;
	FILE *fp;
	struct stat st;
	int n;

	if (stat(path, &st) != 0)
		return -1;
	if (time(NULL) - st.st_mtime > STALE_SEC)
		return -1;

	fp = fopen(path, "r");
	if (!fp)
		return -1;
	if (!fgets(line, sizeof(line), fp)) {
		fclose(fp);
		return -1;
	}
	fclose(fp);

	/* freq mcs bw rssi snr pkt kbps fec lost decerr ants -- rssi and snr are
	   read as strings because the filter writes "-" when it has none. */
	n = sscanf(line, "%*s %*s %*s %31s %31s %d %*s %d %d %*s %d",
		   f_rssi, f_snr, &pkt, fec, lost, ants);
	if (n != 6)
		return -1;
	/* Compare whole tokens: the filter's "no reading" placeholder is a bare
	   "-", and every real rssi starts with one. */
	if (pkt == 0 || !strcmp(f_rssi, "-") || !strcmp(f_snr, "-"))
		return -1;

	*rssi = atof(f_rssi);
	*snr = atof(f_snr);
	return 0;
}

int main(int argc, char **argv)
{
	const char *ip = DEFAULT_IP;
	const char *status = DEFAULT_STATUS;
	int port = DEFAULT_PORT;
	int interval = DEFAULT_INTERVAL;
	int once = 0;
	struct sockaddr_in dst;
	int sock;
	int c;

	while ((c = getopt(argc, argv, "i:p:s:t:1vh")) != -1) {
		switch (c) {
		case 'i': ip = optarg; break;
		case 'p': port = atoi(optarg); break;
		case 's': status = optarg; break;
		case 't': interval = atoi(optarg); break;
		case '1': once = 1; break;
		case 'v': verbose = 1; break;
		default:
			fprintf(stderr,
				"usage: %s [-i ip] [-p port] [-s statusfile] [-t ms] [-1] [-v]\n",
				argv[0]);
			return 1;
		}
	}

	if (interval < 10)
		interval = 10;

	memset(&dst, 0, sizeof(dst));
	dst.sin_family = AF_INET;
	dst.sin_port = htons((uint16_t)port);
	if (inet_aton(ip, &dst.sin_addr) == 0) {
		fprintf(stderr, "alink-gs: bad address %s\n", ip);
		return 1;
	}

	sock = socket(AF_INET, SOCK_DGRAM, 0);
	if (sock < 0) {
		perror("alink-gs: socket");
		return 1;
	}

	for (;;) {
		double rssi, snr;
		int fec = 0, lost = 0, ants = 0;

		if (read_status(status, &rssi, &snr, &fec, &lost, &ants) == 0) {
			char msg[192];
			unsigned char buf[4 + sizeof(msg)];
			int score_rssi = normalise(rssi, RSSI_MIN, RSSI_MAX);
			int score_snr = normalise(snr, SNR_MIN, SNR_MAX);
			int score = (int)(score_rssi * RSSI_WEIGHT + score_snr * SNR_WEIGHT);
			int len;

			if (score < SCORE_MIN)
				score = SCORE_MIN;
			if (score > SCORE_MAX)
				score = SCORE_MAX;

			/* Field order is alink_drone's process_message():
			   time:rssi_score:snr_score:recovered:lost:rssi:snr:
			   antennas:penalty:fec_change. The trailing IDR request
			   is optional and we make none. Penalty and fec_change
			   are 0: both drive air-side behaviour we have no way to
			   verify from here yet. */
			len = snprintf(msg, sizeof(msg),
				       "%ld:%d:%d:%d:%d:%d:%d:%d:%d:%d",
				       now_ms(), score, score, fec, lost,
				       (int)rssi, (int)snr, ants, 0, 0);
			if (len > 0 && (size_t)len < sizeof(msg)) {
				/* 4-byte big-endian length prefix, then the
				   text. The drone reads a datagram at a time,
				   but expects the framing regardless. */
				buf[0] = (unsigned char)((len >> 24) & 0xFF);
				buf[1] = (unsigned char)((len >> 16) & 0xFF);
				buf[2] = (unsigned char)((len >> 8) & 0xFF);
				buf[3] = (unsigned char)(len & 0xFF);
				memcpy(buf + 4, msg, (size_t)len);

				if (sendto(sock, buf, (size_t)len + 4, 0,
					   (struct sockaddr *)&dst, sizeof(dst)) < 0 && verbose)
					perror("alink-gs: sendto");
				else if (verbose)
					printf("%s -> %s:%d\n", msg, ip, port);
			}
		} else if (verbose) {
			printf("no link, sending nothing\n");
		}

		if (once)
			break;
		usleep((useconds_t)interval * 1000);
	}

	close(sock);
	return 0;
}

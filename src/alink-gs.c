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
 *
 * Upstream's alink_gs is the specification for everything on the wire here, and
 * is worth reading before changing any of it. It is stdlib-only Python and would
 * have run unmodified given an interpreter and wfb-ng's JSON stats service on
 * 127.0.0.1:8103; this exists because the 11.4MB system partition has room for
 * neither, not because its behaviour needed improving.
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
/* Four a second. Upstream sends one per wfb-ng stats update, which is also the
   air unit's 1000ms fallback window -- close enough to the edge that a single
   late message drops it to MCS 0. */
#define DEFAULT_INTERVAL 250

#define IDR_CODE_LEN	4
#define IDR_MAX_MESSAGES 20

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

/* Epoch SECONDS, matching upstream's int(time.time()). Not milliseconds: some
   air-unit builds feed this straight into settimeofday(), so the wrong unit sets
   the drone's clock to a plausible-looking wrong date rather than failing. */
static long now_s(void)
{
	return (long)time(NULL);
}

/* Four lowercase letters, as upstream generates. The air unit treats the code as
   an opaque tag to dedupe repeats of one request, so it needs to be distinct,
   not unpredictable. */
static void new_idr(char *code, int *left)
{
	int i;

	for (i = 0; i < IDR_CODE_LEN; i++)
		code[i] = (char)('a' + rand() % 26);
	code[IDR_CODE_LEN] = '\0';
	*left = IDR_MAX_MESSAGES;
}

/*
 * Reads one status line. Returns 0 if it describes a link carrying video.
 *
 * rssi is the test, not the packet count: wfb_rx records antenna statistics
 * only for packets that decrypted, so packets with no rssi mean the air unit is
 * heard but keyed differently -- nothing worth scoring.
 */
static int read_status(const char *path, double *rssi, double *snr,
		       int *fec, int *lost, int *ants, struct timespec *mtime)
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
	*mtime = st.st_mtim;

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
	char idr_code[IDR_CODE_LEN + 1] = "";
	int idr_left = 0;
	int had_link = 0;
	struct timespec last_mtime = { 0, 0 };
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

	srand((unsigned)(time(NULL) ^ getpid()));

	for (;;) {
		double rssi, snr;
		int fec = 0, lost = 0, ants = 0;
		struct timespec mtime;

		if (read_status(status, &rssi, &snr, &fec, &lost, &ants, &mtime) == 0) {
			char msg[192];
			unsigned char buf[4 + sizeof(msg)];
			int score_rssi = normalise(rssi, RSSI_MIN, RSSI_MAX);
			int score_snr = normalise(snr, SNR_MIN, SNR_MAX);
			int score = (int)(score_rssi * RSSI_WEIGHT + score_snr * SNR_WEIGHT);
			int fresh = (mtime.tv_sec != last_mtime.tv_sec ||
				     mtime.tv_nsec != last_mtime.tv_nsec);
			int len;

			last_mtime = mtime;

			if (score < SCORE_MIN)
				score = SCORE_MIN;
			if (score > SCORE_MAX)
				score = SCORE_MAX;

			/* A new code on every loss and one when video starts, both
			   as upstream does -- but only once per reading. wfb_rx
			   reports once a second and we send four times a second to
			   stay clear of the air unit's 1000ms fallback, so deciding
			   per send would mint four codes for one reported loss and
			   demand four keyframes where upstream asks for one. */
			if (fresh && (lost > 0 || !had_link))
				new_idr(idr_code, &idr_left);
			had_link = 1;

			/* alink_drone's process_message() token order:
			   time:rssi_score:snr_score:recovered:lost:rssi:snr:
			   antennas:penalty:fec_change[:idr_code]. penalty and
			   fec_change stay 0, matching upstream's shipped
			   allow_penalty=False and allow_fec_increase=False. */
			len = snprintf(msg, sizeof(msg),
				       "%ld:%d:%d:%d:%d:%d:%d:%d:%d:%d",
				       now_s(), score, score, fec, lost,
				       (int)rssi, (int)snr, ants, 0, 0);
			if (len > 0 && (size_t)len < sizeof(msg) && idr_left > 0) {
				int n = snprintf(msg + len, sizeof(msg) - (size_t)len,
						 ":%s", idr_code);
				if (n > 0)
					len += n;
				idr_left--;
			}
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
		} else {
			had_link = 0;
			idr_left = 0;
			if (verbose)
				printf("no link, sending nothing\n");
		}

		if (once)
			break;
		usleep((useconds_t)interval * 1000);
	}

	close(sock);
	return 0;
}

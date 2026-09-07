#include "hawdl_sys.h"

#include <errno.h>
#include <net/if.h>
#include <net/route.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/types.h>

static int hawdl_fill_ifreq(struct ifreq *ifr, const char *ifname) {
    memset(ifr, 0, sizeof(*ifr));
    size_t n = strlen(ifname);
    if (n == 0 || n >= IFNAMSIZ) {
        errno = ENAMETOOLONG;
        return -1;
    }
    memcpy(ifr->ifr_name, ifname, n);
    return 0;
}

int hawdl_if_get_flags(int sockfd, const char *ifname, short *out_flags) {
    struct ifreq ifr;
    if (hawdl_fill_ifreq(&ifr, ifname) != 0) {
        return -1;
    }
    if (ioctl(sockfd, SIOCGIFFLAGS, &ifr) < 0) {
        return -1;
    }
    if (out_flags != NULL) {
        *out_flags = ifr.ifr_flags;
    }
    return 0;
}

int hawdl_if_set_flags(int sockfd, const char *ifname, short flags) {
    struct ifreq ifr;
    if (hawdl_fill_ifreq(&ifr, ifname) != 0) {
        return -1;
    }
    ifr.ifr_flags = flags;
    if (ioctl(sockfd, SIOCSIFFLAGS, &ifr) < 0) {
        return -1;
    }
    return 0;
}

short hawdl_iff_up_mask(void) {
    return (short)IFF_UP;
}

int hawdl_route_socket_open(void) {
    return socket(PF_ROUTE, SOCK_RAW, AF_UNSPEC);
}

long hawdl_route_message_parse(const void *buf,
                               long len,
                               int *out_is_ifinfo,
                               unsigned int *out_index) {
    if (out_is_ifinfo != NULL) {
        *out_is_ifinfo = 0;
    }
    if (out_index != NULL) {
        *out_index = 0;
    }
    if (buf == NULL || len < (long)sizeof(struct rt_msghdr)) {
        return 0;
    }

    struct rt_msghdr hdr;
    memcpy(&hdr, buf, sizeof(hdr));
    if (hdr.rtm_msglen == 0 || (long)hdr.rtm_msglen > len) {
        return 0;
    }

    if (hdr.rtm_type == RTM_IFINFO) {
        if ((long)hdr.rtm_msglen < (long)sizeof(struct if_msghdr)) {
            return (long)hdr.rtm_msglen;
        }
        struct if_msghdr ifm;
        memcpy(&ifm, buf, sizeof(ifm));
        if (out_is_ifinfo != NULL) {
            *out_is_ifinfo = 1;
        }
        if (out_index != NULL) {
            *out_index = (unsigned int)ifm.ifm_index;
        }
    }

    return (long)hdr.rtm_msglen;
}

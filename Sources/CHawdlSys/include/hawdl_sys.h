#ifndef HAWDL_SYS_H
#define HAWDL_SYS_H

#include <stddef.h>

/*
 * Small C shim over the parts of the BSD networking API that Swift cannot
 * import directly:
 *
 *  - SIOCGIFFLAGS / SIOCSIFFLAGS are produced by the _IOWR()/_IOW()
 *    function-like macros, which the Swift importer drops.
 *  - ioctl(2) is C-variadic and therefore not callable from Swift.
 *  - struct ifreq's anonymous union does not import reliably across SDKs.
 *  - struct rt_msghdr / struct if_msghdr layouts are easier to read here than
 *    to hand-compute offsets for in Swift.
 *
 * Every function reports failure the POSIX way: -1 with errno set.
 */

/* Fills *out_flags with the interface's IFF_* flags.
 * sockfd must be a datagram socket (AF_INET/SOCK_DGRAM is what we use). */
int hawdl_if_get_flags(int sockfd, const char *ifname, short *out_flags);

/* Writes the interface's IFF_* flags. */
int hawdl_if_set_flags(int sockfd, const char *ifname, short flags);

/* The IFF_UP bit, as the C compiler sees it. */
short hawdl_iff_up_mask(void);

/* Opens a PF_ROUTE raw socket for RTM_* notifications. Returns the fd, or -1. */
int hawdl_route_socket_open(void);

/* Parses one routing message sitting at the head of buf.
 *
 * Returns the message length in bytes (> 0) on success, or 0 when the buffer
 * is too short or the message is malformed. On success *out_is_ifinfo is set
 * to 1 for RTM_IFINFO messages (0 otherwise) and *out_index receives the
 * interface index those messages carry (0 for every other message type).
 *
 * `long` rather than `size_t` so that Swift sees a plain Int. */
long hawdl_route_message_parse(const void *buf,
                               long len,
                               int *out_is_ifinfo,
                               unsigned int *out_index);

#endif /* HAWDL_SYS_H */

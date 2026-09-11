#define _GNU_SOURCE

#include <dlfcn.h>
#include <errno.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

typedef int (*socket_fn)(int, int, int);

static int bind_source_address(int fd, int domain, const char *source)
{
	struct sockaddr_in addr4;
	struct sockaddr_in6 addr6;

	if (source == NULL || *source == '\0')
		return -1;
	if (domain == AF_INET) {
		memset(&addr4, 0, sizeof(addr4));
		addr4.sin_family = AF_INET;
		if (inet_pton(AF_INET, source, &addr4.sin_addr) != 1)
			return -1;
		return bind(fd, (const struct sockaddr *)&addr4, sizeof(addr4));
	}
	if (domain == AF_INET6) {
		memset(&addr6, 0, sizeof(addr6));
		addr6.sin6_family = AF_INET6;
		if (inet_pton(AF_INET6, source, &addr6.sin6_addr) != 1)
			return -1;
		return bind(fd, (const struct sockaddr *)&addr6, sizeof(addr6));
	}
	return -1;
}

int socket(int domain, int type, int protocol)
{
	static socket_fn real_socket;
	const char *device;
	const char *source;
	int fd;
	int error;

	if (real_socket == NULL) {
		real_socket = (socket_fn)dlsym(RTLD_NEXT, "socket");
		if (real_socket == NULL) {
			errno = ENOSYS;
			return -1;
		}
	}

	fd = real_socket(domain, type, protocol);
	if (fd < 0 || (domain != AF_INET && domain != AF_INET6))
		return fd;

	device = getenv("CAMPUS_REDIAL_DEVICE");
	if (device == NULL || *device == '\0')
		return fd;

	if (setsockopt(fd, SOL_SOCKET, SO_BINDTODEVICE, device,
		       strlen(device) + 1) == 0)
		return fd;

	/* PPP netdevices on some kernels reject SO_BINDTODEVICE even for root.
	 * Binding the socket to that session's negotiated address gives the same
	 * route isolation without changing the router's global policy tables. */
	source = getenv("CAMPUS_REDIAL_SOURCE");
	if (bind_source_address(fd, domain, source) == 0)
		return fd;

	error = errno;
	close(fd);
	errno = error;
	return -1;
}

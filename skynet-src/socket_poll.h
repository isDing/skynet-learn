#ifndef socket_poll_h
#define socket_poll_h

#include <stdbool.h>

typedef int poll_fd;

struct event {
	void * s;      // socket指针
	bool read;     // 可读事件
	bool write;    // 可写事件
	bool error;    // 错误事件
	bool eof;      // 连接关闭事件
};

static bool sp_invalid(poll_fd fd);
static poll_fd sp_create();
static void sp_release(poll_fd fd);
static int sp_add(poll_fd fd, int sock, void *ud);
static void sp_del(poll_fd fd, int sock);
static int sp_enable(poll_fd, int sock, void *ud, bool read_enable, bool write_enable);
static int sp_wait(poll_fd, struct event *e, int max);
static void sp_nonblocking(int sock);

#ifdef __linux__
#include "socket_epoll.h"
#endif

#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined (__NetBSD__)
#include "socket_kqueue.h"
#endif

#endif

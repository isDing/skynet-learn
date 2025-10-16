#ifndef socket_poll_h
#define socket_poll_h

#include <stdbool.h>

/* 
 * 说明：
 *   socket_poll.h 抽象了底层事件驱动实现（epoll/kqueue）。
 *   通过统一的接口，socket_server.c 可以在不同平台复用同一套逻辑。
 */
typedef int poll_fd;

/* 
 * event 结构记录一次 sp_wait 返回的事件信息。
 *   s     : 事件关联的 socket 指针，由底层实现透传。
 *   read  : 是否准备好读取（EPOLLIN / EVFILT_READ）。
 *   write : 是否准备好写入（EPOLLOUT / EVFILT_WRITE）。
 *   error : 是否捕获错误（EPOLLERR / EV_ERROR）。
 *   eof   : 是否触发对端关闭（EPOLLHUP / EV_EOF）。
 */
struct event {
	void * s;
	bool read;
	bool write;
	bool error;
	bool eof;
};

/* 以下函数均由平台相关文件提供实现（epoll 或 kqueue）。 */
static bool sp_invalid(poll_fd fd);                         // 判断 poll_fd 是否有效
static poll_fd sp_create();                                 // 创建事件循环对象
static void sp_release(poll_fd fd);                         // 释放事件循环对象
static int sp_add(poll_fd fd, int sock, void *ud);          // 将 sock 注册到事件表
static void sp_del(poll_fd fd, int sock);                   // 从事件表移除 sock
static int sp_enable(poll_fd, int sock, void *ud, bool read_enable, bool write_enable); // 更新读写关注
static int sp_wait(poll_fd, struct event *e, int max);      // 阻塞等待事件
static void sp_nonblocking(int sock);                       // 设置 fd 为非阻塞

#ifdef __linux__
#include "socket_epoll.h"
#endif

#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined (__NetBSD__)
#include "socket_kqueue.h"
#endif

#endif

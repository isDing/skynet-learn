#ifndef poll_socket_epoll_h
#define poll_socket_epoll_h

#include <netdb.h>
#include <unistd.h>
#include <sys/epoll.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>

/* 
 * 说明：
 *   epoll 版本的抽象实现，配合 socket_poll.h 提供统一接口。
 *   仅包含静态函数，由编译单元内联使用，不会生成独立符号。
 */
static bool 
sp_invalid(int efd) {
	return efd == -1;
}

// 创建epoll实例
static int
sp_create() {
	return epoll_create(1024);
}

static void
sp_release(int efd) {
	close(efd);
}

// 添加socket到epoll
static int 
sp_add(int efd, int sock, void *ud) {
	struct epoll_event ev;
	ev.events = EPOLLIN;	// 默认关注读事件，写事件按需在 sp_enable 中打开
	ev.data.ptr = ud;	// 透传 socket 指针，方便回调识别
	if (epoll_ctl(efd, EPOLL_CTL_ADD, sock, &ev) == -1) {
		return 1;
	}
	return 0;
}

static void 
sp_del(int efd, int sock) {
	epoll_ctl(efd, EPOLL_CTL_DEL, sock , NULL);	// 移除时无需关心回调指针
}

// 修改socket事件
static int
sp_enable(int efd, int sock, void *ud, bool read_enable, bool write_enable) {
	struct epoll_event ev;
	ev.events = (read_enable ? EPOLLIN : 0) | (write_enable ? EPOLLOUT : 0);
	ev.data.ptr = ud;
	if (epoll_ctl(efd, EPOLL_CTL_MOD, sock, &ev) == -1) {
		return 1;
	}
	return 0;
}

// 等待事件
static int 
sp_wait(int efd, struct event *e, int max) {
	struct epoll_event ev[max];
	int n = epoll_wait(efd , ev, max, -1);  // 阻塞等待
	int i;
	for (i=0;i<n;i++) {
		e[i].s = ev[i].data.ptr;  // 回填 socket 指针，供上层还原上下文
		unsigned flag = ev[i].events;
		e[i].write = (flag & EPOLLOUT) != 0;	// 可写
		e[i].read = (flag & EPOLLIN) != 0;		// 可读
		e[i].error = (flag & EPOLLERR) != 0;	// 错误
		e[i].eof = (flag & EPOLLHUP) != 0;		// 对端关闭
	}

	return n;
}

static void
sp_nonblocking(int fd) {
	int flag = fcntl(fd, F_GETFL, 0);
	if ( -1 == flag ) {
		return;	// 获取失败时保持原状态
	}

	fcntl(fd, F_SETFL, flag | O_NONBLOCK);
}

#endif

#ifndef skynet_socket_server_h
#define skynet_socket_server_h

#include <stdint.h>
#include "socket_info.h"
#include "socket_buffer.h"

#define SOCKET_DATA 0		/* 数据到达：result->data 指向 payload，ud 为字节数 */
#define SOCKET_CLOSE 1		/* 连接关闭：本地或远端关闭，data == NULL */
#define SOCKET_OPEN 2		/* 主动连接 / 监听成功：data 可能包含地址 */
#define SOCKET_ACCEPT 3		/* 被动接受新连接：ud 为新 socket id */
#define SOCKET_ERR 4		/* 错误事件：data 指向错误描述字符串 */
#define SOCKET_EXIT 5		/* 网络线程退出（socket_server_exit） */
#define SOCKET_UDP 6		/* UDP 消息，data 末尾附带地址信息 */
#define SOCKET_WARNING 7	/* 写缓冲告警：ud 为 KB，0 表示告警解除 */

/* 内部专用的附加事件类型 */
// Only for internal use
#define SOCKET_RST 8		/* 写入发生错误并触发重置 */
#define SOCKET_MORE 9		/* TCP 多包读取，本次数据尚未完全读完 */

struct socket_server;

struct socket_message {
	int id;
	uintptr_t opaque;
	int ud;	// for accept, ud is new connection id ; for data, ud is size of data 
	char * data;
};

/* 核心接口：创建/释放 socket_server，并在网络线程内轮询事件 */
struct socket_server * socket_server_create(uint64_t time);
void socket_server_release(struct socket_server *);
void socket_server_updatetime(struct socket_server *, uint64_t time);
int socket_server_poll(struct socket_server *, struct socket_message *result, int *more);

/* 基础控制命令：退出、关闭、shutdown、启动读、暂停读等 */
void socket_server_exit(struct socket_server *);
void socket_server_close(struct socket_server *, uintptr_t opaque, int id);
void socket_server_shutdown(struct socket_server *, uintptr_t opaque, int id);
void socket_server_start(struct socket_server *, uintptr_t opaque, int id);
void socket_server_pause(struct socket_server *, uintptr_t opaque, int id);

// return -1 when error
int socket_server_send(struct socket_server *, struct socket_sendbuffer *buffer);
int socket_server_send_lowpriority(struct socket_server *, struct socket_sendbuffer *buffer);

// ctrl command below returns id
int socket_server_listen(struct socket_server *, uintptr_t opaque, const char * addr, int port, int backlog);
int socket_server_connect(struct socket_server *, uintptr_t opaque, const char * addr, int port);
int socket_server_bind(struct socket_server *, uintptr_t opaque, int fd);

// for tcp
void socket_server_nodelay(struct socket_server *, int id);

struct socket_udp_address;

// create an udp socket handle, attach opaque with it . udp socket don't need call socket_server_start to recv message
// if port != 0, bind the socket . if addr == NULL, bind ipv4 0.0.0.0 . If you want to use ipv6, addr can be "::" and port 0.
int socket_server_udp(struct socket_server *, uintptr_t opaque, const char * addr, int port);
// set default dest address, return 0 when success
int socket_server_udp_connect(struct socket_server *, int id, const char * addr, int port);

// create an udp client socket handle, and connect to server addr, return id when success
int socket_server_udp_dial(struct socket_server *ss, uintptr_t opaque, const char* addr, int port);
// create an udp server socket handle, and bind the host port, return id when success
int socket_server_udp_listen(struct socket_server *ss, uintptr_t opaque, const char* addr, int port);

// If the socket_udp_address is NULL, use last call socket_server_udp_connect address instead
// You can also use socket_server_send 
int socket_server_udp_send(struct socket_server *, const struct socket_udp_address *, struct socket_sendbuffer *buffer);
// extract the address of the message, struct socket_message * should be SOCKET_UDP
const struct socket_udp_address * socket_server_udp_address(struct socket_server *, struct socket_message *, int *addrsz);

struct socket_object_interface {
	const void * (*buffer)(const void *);
	size_t (*size)(const void *);
	void (*free)(void *);
};

// if you send package with type SOCKET_BUFFER_OBJECT, use soi.
void socket_server_userobject(struct socket_server *, struct socket_object_interface *soi);

struct socket_info * socket_server_info(struct socket_server *);

#endif

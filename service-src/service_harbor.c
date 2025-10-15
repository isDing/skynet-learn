#include "skynet.h"
#include "skynet_harbor.h"
#include "skynet_socket.h"
#include "skynet_handle.h"

/*
	harbor listen the PTYPE_HARBOR (in text)
	N name : update the global name
	S fd id: connect to new harbor , we should send self_id to fd first , and then recv a id (check it), and at last send queue.
	A fd id: accept new harbor , we should send self_id to fd , and then send queue.

	If the fd is disconnected, send message to slave in PTYPE_TEXT.  D id
	If we don't known a globalname, send message to slave in PTYPE_TEXT. Q name
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include <assert.h>
#include <stdint.h>
#include <unistd.h>

#define HASH_SIZE 4096
#define DEFAULT_QUEUE_SIZE 1024

// 12 is sizeof(struct remote_message_header)
#define HEADER_COOKIE_LENGTH 12

/*
	message type (8bits) is encoded into the high 8 bits of destination.
	注意：这里不会携带目标 harbor id，具体节点由外层连接上下文决定，
	接收端在 forward_local_messsage 中再补写本地 harbor id。
 */
struct remote_message_header {
	uint32_t source;       // 源服务句柄
	uint32_t destination;  // 目标服务句柄（高8位含消息类型）
	uint32_t session;      // 会话ID
};

struct harbor_msg {
	struct remote_message_header header;
	void * buffer;         // 消息内容
	size_t size;           // 消息大小
};

struct harbor_msg_queue {
	int size;
	int head;
	int tail;
	struct harbor_msg * data;
};

struct keyvalue {
	struct keyvalue * next;
	char key[GLOBALNAME_LENGTH];       // 16字节名字
	uint32_t hash;                     // 名字哈希值
	uint32_t value;                    // 服务句柄
	struct harbor_msg_queue * queue;   // 待处理消息队列
};

struct hashmap {
	struct keyvalue *node[HASH_SIZE];
};

// Slave节点状态
#define STATUS_WAIT 0		// 等待连接
#define STATUS_HANDSHAKE 1	// 握手中
#define STATUS_HEADER 2		// 读取消息头
#define STATUS_CONTENT 3	// 读取消息体
#define STATUS_DOWN 4		// 连接断开

// Slave连接信息，某个远端节点连接的状态机上下文
struct slave {
	int fd;                           // Socket文件描述符
	struct harbor_msg_queue *queue;   // 消息队列
	int status;                        // 连接状态
	int length;                        // 当前消息长度
	int read;                          // 已读取字节数
	uint8_t size[4];                   // 消息长度缓冲
	char * recv_buffer;                // 接收缓冲区
};

// Harbor主结构，本服务状态
struct harbor {
	struct skynet_context *ctx;       // 关联的Skynet上下文
	int id;                           // 本节点Harbor ID
	uint32_t slave;                   // Slave服务句柄
	struct hashmap * map;             // 全局名字表
	struct slave s[REMOTE_MAX];       // 所有远程节点连接（最多256个）
};

// hash table

static void
push_queue_msg(struct harbor_msg_queue * queue, struct harbor_msg * m) {
	// If there is only 1 free slot which is reserved to distinguish full/empty
	// of circular buffer, expand it.
	if (((queue->tail + 1) % queue->size) == queue->head) {
		struct harbor_msg * new_buffer = skynet_malloc(queue->size * 2 * sizeof(struct harbor_msg));
		int i;
		for (i=0;i<queue->size-1;i++) {
			new_buffer[i] = queue->data[(i+queue->head) % queue->size];
		}
		skynet_free(queue->data);
		queue->data = new_buffer;
		queue->head = 0;
		queue->tail = queue->size - 1;
		queue->size *= 2;
	}
	struct harbor_msg * slot = &queue->data[queue->tail];
	*slot = *m;
	queue->tail = (queue->tail + 1) % queue->size;
}

static void
push_queue(struct harbor_msg_queue * queue, void * buffer, size_t sz, struct remote_message_header * header) {
	struct harbor_msg m;
	m.header = *header;
	m.buffer = buffer;
	m.size = sz;
	push_queue_msg(queue, &m);
}

static struct harbor_msg *
pop_queue(struct harbor_msg_queue * queue) {
	if (queue->head == queue->tail) {
		return NULL;
	}
	struct harbor_msg * slot = &queue->data[queue->head];
	queue->head = (queue->head + 1) % queue->size;
	return slot;
}

static struct harbor_msg_queue *
new_queue() {
	struct harbor_msg_queue * queue = skynet_malloc(sizeof(*queue));
	queue->size = DEFAULT_QUEUE_SIZE;
	queue->head = 0;
	queue->tail = 0;
	queue->data = skynet_malloc(DEFAULT_QUEUE_SIZE * sizeof(struct harbor_msg));

	return queue;
}

static void
release_queue(struct harbor_msg_queue *queue) {
	if (queue == NULL)
		return;
	struct harbor_msg * m;
	while ((m=pop_queue(queue)) != NULL) {
		skynet_free(m->buffer);
	}
	skynet_free(queue->data);
	skynet_free(queue);
}

static struct keyvalue *
hash_search(struct hashmap * hash, const char name[GLOBALNAME_LENGTH]) {
	uint32_t *ptr = (uint32_t*) name;
	uint32_t h = ptr[0] ^ ptr[1] ^ ptr[2] ^ ptr[3];
	struct keyvalue * node = hash->node[h % HASH_SIZE];
	while (node) {
		if (node->hash == h && strncmp(node->key, name, GLOBALNAME_LENGTH) == 0) {
			return node;
		}
		node = node->next;
	}
	return NULL;
}

/*

// Don't support erase name yet

static struct void
hash_erase(struct hashmap * hash, char name[GLOBALNAME_LENGTH) {
	uint32_t *ptr = name;
	uint32_t h = ptr[0] ^ ptr[1] ^ ptr[2] ^ ptr[3];
	struct keyvalue ** ptr = &hash->node[h % HASH_SIZE];
	while (*ptr) {
		struct keyvalue * node = *ptr;
		if (node->hash == h && strncmp(node->key, name, GLOBALNAME_LENGTH) == 0) {
			_release_queue(node->queue);
			*ptr->next = node->next;
			skynet_free(node);
			return;
		}
		*ptr = &(node->next);
	}
}
*/

static struct keyvalue *
hash_insert(struct hashmap * hash, const char name[GLOBALNAME_LENGTH]) {
	uint32_t *ptr = (uint32_t *)name;
	uint32_t h = ptr[0] ^ ptr[1] ^ ptr[2] ^ ptr[3];
	struct keyvalue ** pkv = &hash->node[h % HASH_SIZE];
	struct keyvalue * node = skynet_malloc(sizeof(*node));
	memcpy(node->key, name, GLOBALNAME_LENGTH);
	node->next = *pkv;
	node->queue = NULL;
	node->hash = h;
	node->value = 0;
	*pkv = node;

	return node;
}

static struct hashmap * 
hash_new() {
	struct hashmap * h = skynet_malloc(sizeof(struct hashmap));
	memset(h,0,sizeof(*h));
	return h;
}

static void
hash_delete(struct hashmap *hash) {
	int i;
	for (i=0;i<HASH_SIZE;i++) {
		struct keyvalue * node = hash->node[i];
		while (node) {
			struct keyvalue * next = node->next;
			release_queue(node->queue);
			skynet_free(node);
			node = next;
		}
	}
	skynet_free(hash);
}

///////////////

static void
close_harbor(struct harbor *h, int id) {
	struct slave *s = &h->s[id];
	s->status = STATUS_DOWN;
	if (s->fd) {
		// 仅关闭 fd，通知 Lua 层的 .cslave 由 report_harbor_down 负责补充业务告警
		skynet_socket_close(h->ctx, s->fd);
		s->fd = 0;
	}
	if (s->queue) {
		release_queue(s->queue);
		s->queue = NULL;
	}
}

static void
report_harbor_down(struct harbor *h, int id) {
	char down[64];
	int n = sprintf(down, "D %d",id);

	// 通过 PTYPE_TEXT 通知 Lua 层 .cslave，触发后续下线处理与重连
	skynet_send(h->ctx, 0, h->slave, PTYPE_TEXT, 0, down, n);
}

struct harbor *
harbor_create(void) {
	struct harbor * h = skynet_malloc(sizeof(*h));
	memset(h,0,sizeof(*h));
	h->map = hash_new();
	return h;
}


static void
close_all_remotes(struct harbor *h) {
	int i;
	for (i=1;i<REMOTE_MAX;i++) {
		close_harbor(h,i);
		// don't call report_harbor_down.
		// never call skynet_send during module exit, because of dead lock
	}
}

void
harbor_release(struct harbor *h) {
	close_all_remotes(h);
	hash_delete(h->map);
	skynet_free(h);
}

static inline void
to_bigendian(uint8_t *buffer, uint32_t n) {
	buffer[0] = (n >> 24) & 0xff;
	buffer[1] = (n >> 16) & 0xff;
	buffer[2] = (n >> 8) & 0xff;
	buffer[3] = n & 0xff;
}

static inline void
header_to_message(const struct remote_message_header * header, uint8_t * message) {
	to_bigendian(message , header->source);
	to_bigendian(message+4 , header->destination);
	to_bigendian(message+8 , header->session);
}

static inline uint32_t
from_bigendian(uint32_t n) {
	union {
		uint32_t big;
		uint8_t bytes[4];
	} u;
	u.big = n;
	return u.bytes[0] << 24 | u.bytes[1] << 16 | u.bytes[2] << 8 | u.bytes[3];
}

static inline void
message_to_header(const uint32_t *message, struct remote_message_header *header) {
	header->source = from_bigendian(message[0]);
	header->destination = from_bigendian(message[1]);
	header->session = from_bigendian(message[2]);
}

// socket package

// 将远程消息转发为本地消息
static void
forward_local_messsage(struct harbor *h, void *msg, int sz) {
	const char * cookie = msg;
	cookie += sz - HEADER_COOKIE_LENGTH;
	struct remote_message_header header;
	message_to_header((const uint32_t *)cookie, &header);

	// 取出消息类型后用本地 harbor id 给句柄补齐高 8 位，恢复完整句柄
	uint32_t destination = header.destination;
	int type = destination >> HANDLE_REMOTE_SHIFT;
	destination = (destination & HANDLE_MASK) | ((uint32_t)h->id << HANDLE_REMOTE_SHIFT);

    // 直接将 payload 作为消息体（不复制），交给本地服务
	if (skynet_send(h->ctx, header.source, destination, type | PTYPE_TAG_DONTCOPY , (int)header.session, (void *)msg, sz-HEADER_COOKIE_LENGTH) < 0) {
		if (type != PTYPE_ERROR) {
			// don't need report error when type is error
			skynet_send(h->ctx, destination, header.source , PTYPE_ERROR, (int)header.session, NULL, 0);
		}
		skynet_error(h->ctx, "Unknown destination :%x from :%x type(%d)", destination, header.source, type);
	}
}

// 发送远程消息
static void
send_remote(struct skynet_context * ctx, int fd, const char * buffer, size_t sz, struct remote_message_header * cookie) {
	size_t sz_header = sz+sizeof(*cookie);
	if (sz_header > UINT32_MAX) {
		skynet_error(ctx, "remote message from :%08x to :%08x is too large.", cookie->source, cookie->destination);
		return;
	}
	// REMOTE 报文格式：
	// [4字节长度(大端)][消息体payload][12字节remote_message_header]
	uint8_t sendbuf[sz_header+4];
	to_bigendian(sendbuf, (uint32_t)sz_header);
	memcpy(sendbuf+4, buffer, sz);
	header_to_message(cookie, sendbuf+4+sz);

	struct socket_sendbuffer tmp;
	tmp.id = fd;
	tmp.type = SOCKET_BUFFER_RAWPOINTER;
	tmp.buffer = sendbuf;
	tmp.sz = sz_header+4;

	// ignore send error, because if the connection is broken, the mainloop will recv a message.
	skynet_socket_sendbuffer(ctx, &tmp);
}

static void
dispatch_name_queue(struct harbor *h, struct keyvalue * node) {
	struct harbor_msg_queue * queue = node->queue;
	uint32_t handle = node->value;
	int harbor_id = handle >> HANDLE_REMOTE_SHIFT;
	struct skynet_context * context = h->ctx;
	struct slave *s = &h->s[harbor_id];
	int fd = s->fd;
	if (fd == 0) {
		if (s->status == STATUS_DOWN) {
			char tmp [GLOBALNAME_LENGTH+1];
			memcpy(tmp, node->key, GLOBALNAME_LENGTH);
			tmp[GLOBALNAME_LENGTH] = '\0';
			skynet_error(context, "Drop message to %s (in harbor %d)",tmp,harbor_id);
		} else {
			if (s->queue == NULL) {
				s->queue = node->queue;
				node->queue = NULL;
			} else {
				struct harbor_msg * m;
				while ((m = pop_queue(queue))!=NULL) {
					push_queue_msg(s->queue, m);
				}
			}
			if (harbor_id == (h->slave >> HANDLE_REMOTE_SHIFT)) {
				// the harbor_id is local
				struct harbor_msg * m;
				while ((m = pop_queue(s->queue)) != NULL) {
					int type = m->header.destination >> HANDLE_REMOTE_SHIFT;
					// 目标就在本节点，直接走本地 fast path，避免数据重新拼包
					skynet_send(context, m->header.source, handle , type | PTYPE_TAG_DONTCOPY, m->header.session, m->buffer, m->size);
				}
				release_queue(s->queue);
				s->queue = NULL;
			}
		}
		return;
	}
	struct harbor_msg * m;
	while ((m = pop_queue(queue)) != NULL) {
		m->header.destination |= (handle & HANDLE_MASK);
		send_remote(context, fd, m->buffer, m->size, &m->header);
		skynet_free(m->buffer);
	}
}

// 发送待发队列
static void
dispatch_queue(struct harbor *h, int id) {
	struct slave *s = &h->s[id];
	int fd = s->fd;
	assert(fd != 0);

	struct harbor_msg_queue *queue = s->queue;
	if (queue == NULL)
		return;

	struct harbor_msg * m;
	while ((m = pop_queue(queue)) != NULL) {
		send_remote(h->ctx, fd, m->buffer, m->size, &m->header);
		skynet_free(m->buffer);
	}
	release_queue(queue);
	s->queue = NULL;
}

static void
push_socket_data(struct harbor *h, const struct skynet_socket_message * message) {
	assert(message->type == SKYNET_SOCKET_TYPE_DATA);
	int fd = message->id;
	int i;
	int id = 0;
	struct slave * s = NULL;
	for (i=1;i<REMOTE_MAX;i++) {
		if (h->s[i].fd == fd) {
			s = &h->s[i];
			id = i;
			break;
		}
	}
	if (s == NULL) {
		skynet_error(h->ctx, "Invalid socket fd (%d) data", fd);
		return;
	}
	uint8_t * buffer = (uint8_t *)message->buffer;
	int size = message->ud;

	for (;;) {
		switch(s->status) {
		case STATUS_HANDSHAKE: {
			// check id
			uint8_t remote_id = buffer[0];
			if (remote_id != id) {
				skynet_error(h->ctx, "Invalid shakehand id (%d) from fd = %d , harbor = %d", id, fd, remote_id);
				close_harbor(h,id);
				return;
			}
			++buffer;
			--size;
			// 握手确认后切换到读取长度阶段
			s->status = STATUS_HEADER;

			// 握手结束后尝试派发此前积压的消息
			dispatch_queue(h, id);

			if (size == 0) {
				break;
			}
			// go though
		}
		case STATUS_HEADER: {
			// big endian 4 bytes length, the first one must be 0.
			int need = 4 - s->read;
			if (size < need) {
				memcpy(s->size + s->read, buffer, size);
				s->read += size;
				return;
			} else {
				memcpy(s->size + s->read, buffer, need);
				buffer += need;
				size -= need;

				if (s->size[0] != 0) {
					skynet_error(h->ctx, "Message is too long from harbor %d", id);
					close_harbor(h,id);
					return;
				}
				// 长度字段是大端 24 bits ，最高位固定为 0 ，意味着单包最大 16MB
				s->length = s->size[1] << 16 | s->size[2] << 8 | s->size[3];
				s->read = 0;
				s->recv_buffer = skynet_malloc(s->length);
				s->status = STATUS_CONTENT;
				if (size == 0) {
					return;
				}
			}
		}
		// go though
		case STATUS_CONTENT: {
			int need = s->length - s->read;
			if (size < need) {
				memcpy(s->recv_buffer + s->read, buffer, size);
				s->read += size;
				return;
			}
			memcpy(s->recv_buffer + s->read, buffer, need);
			forward_local_messsage(h, s->recv_buffer, s->length);
			s->length = 0;
			s->read = 0;
			s->recv_buffer = NULL;
			size -= need;
			buffer += need;
			s->status = STATUS_HEADER;
			if (size == 0)
				return;
			break;
		}
		default:
			return;
		}
	}
}

static void
update_name(struct harbor *h, const char name[GLOBALNAME_LENGTH], uint32_t handle) {
	struct keyvalue * node = hash_search(h->map, name);
	if (node == NULL) {
		node = hash_insert(h->map, name);
	}
	node->value = handle;
	if (node->queue) {
		dispatch_name_queue(h, node);
		release_queue(node->queue);
		node->queue = NULL;
	}
}

// 句柄路由
static int
remote_send_handle(struct harbor *h, uint32_t source, uint32_t destination, int type, int session, const char * msg, size_t sz) {
	int harbor_id = destination >> HANDLE_REMOTE_SHIFT;
	struct skynet_context * context = h->ctx;
	if (harbor_id == h->id) {
        // 本地消息：直接投递，且使用 PTYPE_TAG_DONTCOPY 避免多余拷贝
		// local message
		skynet_send(context, source, destination , type | PTYPE_TAG_DONTCOPY, session, (void *)msg, sz);
		return 1;
	}

	struct slave * s = &h->s[harbor_id];
	if (s->fd == 0 || s->status == STATUS_HANDSHAKE) {
		if (s->status == STATUS_DOWN) {
            // 目标不可达：回报 PTYPE_ERROR 并记录
			// throw an error return to source
			// report the destination is dead
			skynet_send(context, destination, source, PTYPE_ERROR, session, NULL, 0);
			skynet_error(context, "Drop message to harbor %d from %x to %x (session = %d, msgsz = %d)",harbor_id, source, destination,session,(int)sz);
		} else {
            // 连接未就绪：入队待发
			if (s->queue == NULL) {
				s->queue = new_queue();
			}
			struct remote_message_header header;
			header.source = source;
			// 高 8 位存消息类型，低 24 位保留对端本地句柄，等待接收端补齐 harbor id
			header.destination = (type << HANDLE_REMOTE_SHIFT) | (destination & HANDLE_MASK);
			header.session = (uint32_t)session;
			push_queue(s->queue, (void *)msg, sz, &header);
			return 1;
		}
	} else {
        // 连接就绪：立即发送
		struct remote_message_header cookie;
		cookie.source = source;
		// 将消息类型编码到高位，保持与排队时的格式一致
		cookie.destination = (destination & HANDLE_MASK) | ((uint32_t)type << HANDLE_REMOTE_SHIFT);
		cookie.session = (uint32_t)session;
		send_remote(context, s->fd, msg,sz,&cookie);
	}

	return 0;
}

static int
remote_send_name(struct harbor *h, uint32_t source, const char name[GLOBALNAME_LENGTH], int type, int session, const char * msg, size_t sz) {
	struct keyvalue * node = hash_search(h->map, name);
	if (node == NULL) {
		node = hash_insert(h->map, name);
	}
	if (node->value == 0) {
		if (node->queue == NULL) {
			node->queue = new_queue();
		}
		struct remote_message_header header;
		header.source = source;
		header.destination = type << HANDLE_REMOTE_SHIFT;
		header.session = (uint32_t)session;
		push_queue(node->queue, (void *)msg, sz, &header);
		// 名字未知：向 .cslave 发送 Q 命令，请求 Master 查询
		char query[2+GLOBALNAME_LENGTH+1] = "Q ";
		query[2+GLOBALNAME_LENGTH] = 0;
		memcpy(query+2, name, GLOBALNAME_LENGTH);
		skynet_send(h->ctx, 0, h->slave, PTYPE_TEXT, 0, query, strlen(query));
		return 1;
	} else {
		return remote_send_handle(h, source, node->value, type, session, msg, sz);
	}
}

// 发送单字节握手 id
static void
handshake(struct harbor *h, int id) {
	struct slave *s = &h->s[id];
	uint8_t handshake[1] = { (uint8_t)h->id };
	struct socket_sendbuffer tmp;
	tmp.id = s->fd;
	tmp.type = SOCKET_BUFFER_RAWPOINTER;
	tmp.buffer = handshake;
	tmp.sz = 1;
	skynet_socket_sendbuffer(h->ctx, &tmp);
}

static void
harbor_command(struct harbor * h, const char * msg, size_t sz, int session, uint32_t source) {
	const char * name = msg + 2;
	int s = (int)sz;
	s -= 2;
	switch(msg[0]) {
	case 'N' : {	// 更新名字
		if (s <=0 || s>= GLOBALNAME_LENGTH) {
			skynet_error(h->ctx, "Invalid global name %s", name);
			return;
		}
		struct remote_name rn;
		memset(&rn, 0, sizeof(rn));
		memcpy(rn.name, name, s);
		rn.handle = source;
		update_name(h, rn.name, rn.handle);
		break;
	}
	case 'S' :		// 主动连接
	case 'A' : {	// 被动连接
		char buffer[s+1];
		memcpy(buffer, name, s);
		buffer[s] = 0;
		int fd=0, id=0;
		sscanf(buffer, "%d %d",&fd,&id);
		if (fd == 0 || id <= 0 || id>=REMOTE_MAX) {
			skynet_error(h->ctx, "Invalid command %c %s", msg[0], buffer);
			return;
		}
		struct slave * slave = &h->s[id];
		if (slave->fd != 0) {
			skynet_error(h->ctx, "Harbor %d alreay exist", id);
			return;
		}
		slave->fd = fd;

		// 将 fd 纳入 socket 事件循环并发出本节点 harbor id 完成双向握手
		skynet_socket_start(h->ctx, fd);
		handshake(h, id);
		if (msg[0] == 'S') {
			slave->status = STATUS_HANDSHAKE;
		} else {
			slave->status = STATUS_HEADER;
			// 被动 accept 的连接已经拿到对方 ID，可直接派发排队消息
			dispatch_queue(h,id);
		}
		break;
	}
	default:
		skynet_error(h->ctx, "Unknown command %s", msg);
		return;
	}
}

static int
harbor_id(struct harbor *h, int fd) {
	int i;
	for (i=1;i<REMOTE_MAX;i++) {
		struct slave *s = &h->s[i];
		if (s->fd == fd) {
			return i;
		}
	}
	return 0;
}

static int
mainloop(struct skynet_context * context, void * ud, int type, int session, uint32_t source, const void * msg, size_t sz) {
	struct harbor * h = ud;
	switch (type) {
	case PTYPE_SOCKET: {
		// 接收远端
		const struct skynet_socket_message * message = msg;
		switch(message->type) {
		case SKYNET_SOCKET_TYPE_DATA:
			push_socket_data(h, message);
			skynet_free(message->buffer);
			break;
		case SKYNET_SOCKET_TYPE_ERROR:
		case SKYNET_SOCKET_TYPE_CLOSE: {
			int id = harbor_id(h, message->id);
			if (id) {
				report_harbor_down(h,id);
			} else {
				skynet_error(context, "Unknown fd (%d) closed", message->id);
			}
			break;
		}
		case SKYNET_SOCKET_TYPE_CONNECT:
			// fd forward to this service
			break;
		// 拥塞告警
		case SKYNET_SOCKET_TYPE_WARNING: {
			int id = harbor_id(h, message->id);
			if (id) {
				skynet_error(context, "message havn't send to Harbor (%d) reach %d K", id, message->ud);
			}
			break;
		}
		default:
			skynet_error(context, "recv invalid socket message type %d", type);
			break;
		}
		return 0;
	}
	case PTYPE_HARBOR: {
		// 来自 Lua 层 .cslave 的控制命令（N/S/A）
		harbor_command(h, msg,sz,session,source);
		return 0;
	}
	case PTYPE_SYSTEM : {
		// 发送至远端
		// remote message out
		const struct remote_message *rmsg = msg;
		if (rmsg->destination.handle == 0) {
			if (remote_send_name(h, source , rmsg->destination.name, rmsg->type, session, rmsg->message, rmsg->sz)) {
				return 0;
			}
		} else {
			if (remote_send_handle(h, source , rmsg->destination.handle, rmsg->type, session, rmsg->message, rmsg->sz)) {
				return 0;
			}
		}
		skynet_free((void *)rmsg->message);
		return 0;
	}
	default:
		skynet_error(context, "recv invalid message from %x,  type = %d", source, type);
		if (session != 0 && type != PTYPE_ERROR) {
			skynet_send(context,0,source,PTYPE_ERROR, session, NULL, 0);
		}
		return 0;
	}
}

int
harbor_init(struct harbor *h, struct skynet_context *ctx, const char * args) {
	h->ctx = ctx;
	int harbor_id = 0;
	uint32_t slave = 0;
	sscanf(args,"%d %u", &harbor_id, &slave);
	if (slave == 0) {
		// Lua 层必须传入 .cslave 句柄，否则直接报错终止
		return 1;
	}
	h->id = harbor_id;
	h->slave = slave;
	if (harbor_id == 0) {
		close_all_remotes(h);
	}
	// 注册消息派发回调，并启动 socket 子系统轮询
	skynet_callback(ctx, h, mainloop);
	skynet_harbor_start(ctx);

	return 0;
}

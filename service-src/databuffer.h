// 说明（C 层工具：databuffer）
//  - 供 gate 等网络服务进行“流式缓冲 + 长度前缀解包”的公共结构。
//  - 设计：将来自 socket 的零散数据块（message）串接成链表，维护 head/tail、size、offset 与 header 状态。
//  - 典型使用：
//      databuffer_push(db, mp, data, sz)    // 推入一段新数据（由 skynet_socket 分配）
//      databuffer_readheader(db, mp, 2|4)   // 读取 2/4 字节包头（大端），不足返回 -1
//      databuffer_read(db, mp, buf, body)   // 读取 body 字节到 buf，并回收 message
//      databuffer_reset(db)                 // 重置 header 状态，准备下一包
//      databuffer_clear(db, mp)             // 清空所有数据并释放 message
//  - 内存：messagepool 以链表管理批量分配的 message 槽，freelist 复用以降低 malloc/free 频率
//  - 线程：仅在工作线程上下文内使用（不涉及锁）。
#ifndef skynet_databuffer_h
#define skynet_databuffer_h

#include <stdlib.h>
#include <string.h>
#include <assert.h>

#define MESSAGEPOOL 1023

struct message {
	char * buffer;
	int size;
	struct message * next;
};

struct databuffer {
	int header;
	int offset;
	int size;
	struct message * head;
	struct message * tail;
};

struct messagepool_list {
	struct messagepool_list *next;
	struct message pool[MESSAGEPOOL];
};

struct messagepool {
	struct messagepool_list * pool;
	struct message * freelist;
};

// use memset init struct 

// 释放整个消息池链表（通常服务退出时调用）
static void 
messagepool_free(struct messagepool *pool) {
	struct messagepool_list *p = pool->pool;
	while(p) {
		struct messagepool_list *tmp = p;
		p=p->next;
		skynet_free(tmp);
	}
	pool->pool = NULL;
	pool->freelist = NULL;
}

// 回收 db->head 指向的一个 message，将其挂回 freelist
static inline void
_return_message(struct databuffer *db, struct messagepool *mp) {
	struct message *m = db->head;
	if (m->next == NULL) {
		assert(db->tail == m);
		db->head = db->tail = NULL;
	} else {
		db->head = m->next;
	}
	skynet_free(m->buffer);
	m->buffer = NULL;
	m->size = 0;
	m->next = mp->freelist;
	mp->freelist = m;
}

// 从缓冲读取 sz 字节到 buffer，并逐步回收完全消耗的 message
static void
databuffer_read(struct databuffer *db, struct messagepool *mp, char * buffer, int sz) {
	assert(db->size >= sz);
	db->size -= sz;
	for (;;) {
		struct message *current = db->head;
		int bsz = current->size - db->offset;
		if (bsz > sz) {
			memcpy(buffer, current->buffer + db->offset, sz);
			db->offset += sz;
			return;
		}
		if (bsz == sz) {
			memcpy(buffer, current->buffer + db->offset, sz);
			db->offset = 0;
			_return_message(db, mp);
			return;
		} else {
			memcpy(buffer, current->buffer + db->offset, bsz);
			_return_message(db, mp);
			db->offset = 0;
			buffer+=bsz;
			sz-=bsz;
		}
	}
}

// 将一段 data(sz) 推入缓冲：
//  - 优先从 freelist 取槽；若无可用，批量分配 MESSAGEPOOL 个 message
//  - 尾插到链表并累加 size
static void
databuffer_push(struct databuffer *db, struct messagepool *mp, void *data, int sz) {
	struct message * m;
	if (mp->freelist) {
		m = mp->freelist;
		mp->freelist = m->next;
	} else {
		struct messagepool_list * mpl = skynet_malloc(sizeof(*mpl));
		struct message * temp = mpl->pool;
		int i;
		for (i=1;i<MESSAGEPOOL;i++) {
			temp[i].buffer = NULL;
			temp[i].size = 0;
			temp[i].next = &temp[i+1];
		}
		temp[MESSAGEPOOL-1].next = NULL;
		mpl->next = mp->pool;
		mp->pool = mpl;
		m = &temp[0];
		mp->freelist = &temp[1];
	}
	m->buffer = data;
	m->size = sz;
	m->next = NULL;
	db->size += sz;
	if (db->head == NULL) {
		assert(db->tail == NULL);
		db->head = db->tail = m;
	} else {
		db->tail->next = m;
		db->tail = m;
	}
}

// 读取 2/4 字节包头：
//  - 当 db->header==0，尝试从缓冲读取 header_size 字节并以大端解析长度
//  - 若当前 size < header_size 或 size < header，返回 -1 表示“数据不足”
//  - 若足够则返回 header（包体大小），并保持 db->header = header，直到 reset
static int
databuffer_readheader(struct databuffer *db, struct messagepool *mp, int header_size) {
	if (db->header == 0) {
		// parser header (2 or 4)
		if (db->size < header_size) {
			return -1;
		}
		uint8_t plen[4];
		databuffer_read(db,mp,(char *)plen,header_size);
		// big-endian
		if (header_size == 2) {
			db->header = plen[0] << 8 | plen[1];
		} else {
			db->header = plen[0] << 24 | plen[1] << 16 | plen[2] << 8 | plen[3];
		}
	}
	if (db->size < db->header)
		return -1;
	return db->header;
}

// 完成一个包的读取后，重置 header 状态，以便下一包再次读 header
static inline void
databuffer_reset(struct databuffer *db) {
	db->header = 0;
}

// 清空缓冲链表并将所有 message 回收至 freelist
static void
databuffer_clear(struct databuffer *db, struct messagepool *mp) {
	while (db->head) {
		_return_message(db,mp);
	}
	memset(db, 0, sizeof(*db));
}

#endif

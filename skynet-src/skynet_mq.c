#include "skynet.h"
#include "skynet_mq.h"
#include "skynet_handle.h"
#include "spinlock.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <stdbool.h>

#define DEFAULT_QUEUE_SIZE 64
#define MAX_GLOBAL_MQ 0x10000

// 0 means mq is not in global mq.
// 1 means mq is in global mq , or the message is dispatching.

#define MQ_IN_GLOBAL 1
#define MQ_OVERLOAD 1024

struct message_queue {
    // 并发控制
	// 自旋锁，可能存在多个线程，向同一个队列写入的情况，加上自旋锁避免并发带来的发现，
	struct spinlock lock;

    // 队列标识
	uint32_t handle;		// 拥有此消息队列的服务的id
    // 环形缓冲区
	int cap;				// 消息大小
	int head;				// 头部index
	int tail;				// 尾部index
    // 状态标志
	int release;			// 是否能释放消息
	int in_global;			// 是否在全局消息队列中，0表示不是，1表示是
    // 过载检测
	int overload;			// 是否过载
	int overload_threshold;
    // 链表指针
	struct skynet_message *queue;	// 消息队列
	struct message_queue *next;		// 下一个次级消息队列的指针
};

struct global_queue {
	struct message_queue *head;     // 链表头
	struct message_queue *tail;     // 链表尾
	struct spinlock lock;           // 自旋锁保护
};

static struct global_queue *Q = NULL;

void 
skynet_globalmq_push(struct message_queue * queue) {
	struct global_queue *q= Q;

	SPIN_LOCK(q)
	assert(queue->next == NULL);
	if(q->tail) {
        // 队列非空，加到尾部
		q->tail->next = queue;
		q->tail = queue;
	} else {
        // 队列为空，成为唯一元素
		q->head = q->tail = queue;
	}
	SPIN_UNLOCK(q)
}

struct message_queue * 
skynet_globalmq_pop() {
	struct global_queue *q = Q;

	SPIN_LOCK(q)
	struct message_queue *mq = q->head;
	if(mq) {
        // 1. 移除队头
		q->head = mq->next;
        // 2. 更新队尾（如果队列变空）
		if(q->head == NULL) {
			assert(mq == q->tail);
			q->tail = NULL;
		}
        // 3. 断开链接
		mq->next = NULL;
	}
	SPIN_UNLOCK(q)

	return mq;
}

struct message_queue * 
skynet_mq_create(uint32_t handle) {
	struct message_queue *q = skynet_malloc(sizeof(*q));
    // 基本属性初始化
	q->handle = handle;             // 绑定服务句柄
	q->cap = DEFAULT_QUEUE_SIZE;	// 初始容量 64
	q->head = 0;
	q->tail = 0;
    // 自旋锁初始化
	SPIN_INIT(q)
    // 关键：初始设置 in_global 为 1
    // 原因：队列创建时服务还未初始化完成，避免过早加入全局队列
    // 服务初始化成功后，会调用 skynet_mq_push 真正激活队列
	// When the queue is create (always between service create and service init) ,
	// set in_global flag to avoid push it to global queue .
	// If the service init success, skynet_context_new will call skynet_mq_push to push it to global queue.
	q->in_global = MQ_IN_GLOBAL;
    // 释放标志和过载检测
	q->release = 0;
	q->overload = 0;
	q->overload_threshold = MQ_OVERLOAD;    // 初始阈值 1024
    // 分配消息数组
	q->queue = skynet_malloc(sizeof(struct skynet_message) * q->cap);
	q->next = NULL;

	return q;
}

static void 
_release(struct message_queue *q) {
	assert(q->next == NULL);
	SPIN_DESTROY(q)
	skynet_free(q->queue);
	skynet_free(q);
}

uint32_t 
skynet_mq_handle(struct message_queue *q) {
	return q->handle;
}

int
skynet_mq_length(struct message_queue *q) {
	int head, tail,cap;

	SPIN_LOCK(q)
	head = q->head;
	tail = q->tail;
	cap = q->cap;
	SPIN_UNLOCK(q)
	
	if (head <= tail) {
		return tail - head;
	}
	return tail + cap - head;
}

// 获取过载信息
int
skynet_mq_overload(struct message_queue *q) {
	if (q->overload) {
		int overload = q->overload;
		q->overload = 0;           // 清除标记
		return overload;           // 返回过载数量
	} 
	return 0;
}

int
skynet_mq_pop(struct message_queue *q, struct skynet_message *message) {
	int ret = 1;  // 返回值：0成功，1失败（队列空）
	SPIN_LOCK(q)

	if (q->head != q->tail) {
        // 1. 取出队头消息
		*message = q->queue[q->head++];
        // 2. 处理环形回绕
		ret = 0;
		int head = q->head;
		int tail = q->tail;
		int cap = q->cap;

		if (head >= cap) {
			q->head = head = 0;
		}
        // 3. 计算队列长度用于过载检测
		int length = tail - head;
		if (length < 0) {
			length += cap;
		}
        // 4. 动态调整过载阈值
		// 过载检测，这个机制可以让 Skynet 在日志中打印出服务阻塞或堆积严重的警告，帮助定位性能瓶颈。
		// 在 skynet_context_message_dispatch 时调用 skynet_mq_overload
		while (length > q->overload_threshold) {
			q->overload = length;
			q->overload_threshold *= 2;  // 阈值翻倍
		}
	} else {
        // 队列空时重置过载阈值
		// reset overload_threshold when queue is empty
		q->overload_threshold = MQ_OVERLOAD;
	}

    // 5. 队列空时清除 in_global 标志
	if (ret) {
		q->in_global = 0;
	}
	
	SPIN_UNLOCK(q)

	return ret;
}

static void
expand_queue(struct message_queue *q) {
    // 1. 分配双倍容量的新数组
	struct skynet_message *new_queue = skynet_malloc(sizeof(struct skynet_message) * q->cap * 2);
    // 2. 将旧数据按顺序复制到新数组
    // 关键：需要处理环形缓冲区的回绕情况
	int i;
	for (i=0;i<q->cap;i++) {
		new_queue[i] = q->queue[(q->head + i) % q->cap];
	}
    // 3. 重置索引
	q->head = 0;
	q->tail = q->cap;  // 原有元素数量
	q->cap *= 2;       // 容量翻倍
	
    // 4. 释放旧数组，使用新数组
	skynet_free(q->queue);
	q->queue = new_queue;
}

void 
skynet_mq_push(struct message_queue *q, struct skynet_message *message) {
	assert(message);
	SPIN_LOCK(q)

    // 1. 消息入队到环形缓冲区
	q->queue[q->tail] = *message;
	if (++ q->tail >= q->cap) {
		q->tail = 0;  // 环形回绕
	}

    // 2. 检查是否需要扩容（队列满）
	if (q->head == q->tail) {
		expand_queue(q);
	}

    // 3. 如果队列不在全局队列中，加入全局队列
	if (q->in_global == 0) {
		q->in_global = MQ_IN_GLOBAL;
		skynet_globalmq_push(q);  // 关键：激活队列调度
	}
	
	SPIN_UNLOCK(q)
}

void 
skynet_mq_init() {
	struct global_queue *q = skynet_malloc(sizeof(*q));
	memset(q,0,sizeof(*q));
	SPIN_INIT(q);
	Q=q;
}

// 延迟释放策略
void 
skynet_mq_mark_release(struct message_queue *q) {
	SPIN_LOCK(q)
	assert(q->release == 0);
	q->release = 1;  // 仅标记，不立即释放
	if (q->in_global != MQ_IN_GLOBAL) {
		skynet_globalmq_push(q);  // 确保剩余消息被处理
	}
	SPIN_UNLOCK(q)
}

static void
_drop_queue(struct message_queue *q, message_drop drop_func, void *ud) {
	struct skynet_message msg;
    // 处理所有剩余消息
	while(!skynet_mq_pop(q, &msg)) {
		drop_func(&msg, ud);  // 调用回调清理消息
	}
	_release(q);  // 释放队列内存
}

void 
skynet_mq_release(struct message_queue *q, message_drop drop_func, void *ud) {
	SPIN_LOCK(q)
	
	if (q->release) {
        // 如果已标记释放，执行真正的释放
		SPIN_UNLOCK(q)
		_drop_queue(q, drop_func, ud);
	} else {
        // 否则加入全局队列，等待处理完剩余消息
		skynet_globalmq_push(q);
		SPIN_UNLOCK(q)
	}
}

#include "skynet.h"

#include "skynet_timer.h"
#include "skynet_mq.h"
#include "skynet_server.h"
#include "skynet_handle.h"
#include "spinlock.h"

#include <time.h>
#include <assert.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>

typedef void (*timer_execute_func)(void *ud,void *arg);

/*
 * Skynet 定时器采用“分层时间轮”算法，将未来的触发时间按照不同粒度
 * 切分到多个数组槽位中。最底层 near 队列提供 1 个时间单位的精度，
 * 四层 level 数组分别以 2^(8+n*6) 的跨度覆盖更久远的将来。
 * 通过位运算即可在 O(1) 时间内决定一个定时器应当放入的槽位。
 */
#define TIME_NEAR_SHIFT 8                 // near 层使用低 8 位，覆盖最近 256 个时间单位
#define TIME_NEAR (1 << TIME_NEAR_SHIFT)
#define TIME_LEVEL_SHIFT 6                // 每一层 level 以 6 位表示 64 个槽位
#define TIME_LEVEL (1 << TIME_LEVEL_SHIFT)
#define TIME_NEAR_MASK (TIME_NEAR-1)
#define TIME_LEVEL_MASK (TIME_LEVEL-1)

/*
 * timer_event 通过内嵌的方式存放在 timer_node 之后，避免额外分配。
 * handle 指定消息最终投递的服务，session 用于在 Lua 层匹配回调。
 */
struct timer_event {
	uint32_t handle;    // 目标服务句柄（接收定时器消息的服务）
	int session;        // 会话ID（用于识别是哪个定时器）
};

/*
 * timer_node 既充当链表节点，也承担记录绝对过期时间的职责。
 * 将 expire 与当前时间比较即可决定定时器是否到期。
 */
struct timer_node {
	struct timer_node *next;  // 下一个节点
	uint32_t expire;          // 过期时间（绝对时间，单位 centisecond）
};

/*
 * link_list 以哨兵节点 + tail 指针的方式实现 O(1) 追加。
 * 所有时间轮槽位都使用该结构来存储待触发的定时器。
 */
struct link_list {
	struct timer_node head;
	struct timer_node *tail;
};

/*
 * timer 是时间轮的主体结构：
 * - near 保存最近的 256 个时间单位，粒度最细；
 * - t[4][TIME_LEVEL] 对应四层更粗粒度的时间轮；
 * - time/current/current_point 三个字段配合计算当前时间。
 */
struct timer {
	struct link_list near[TIME_NEAR];       // 近期时间轮（256个槽位），处理最近256个时间单位的定时器
	struct link_list t[4][TIME_LEVEL];      // 4层分层时间轮（每层64个槽位）
	struct spinlock lock;                   // 自旋锁
	uint32_t time;                          // 当前时间（百分之一秒）
	uint32_t starttime;                     // 启动时间（秒）
	uint64_t current;                       // 当前累计时间
	uint64_t current_point;                 // 当前时间点
};

static struct timer * TI = NULL;

// link_clear 把链表中的节点一次性取出并重置哨兵状态，返回原链表的首节点。
static inline struct timer_node *
link_clear(struct link_list *list) {
	struct timer_node * ret = list->head.next;
	list->head.next = 0;
	list->tail = &(list->head);

	return ret;
}

// link 在尾部追加一个节点；由于使用尾指针，复杂度为 O(1)。
static inline void
link(struct link_list *list,struct timer_node *node) {
	list->tail->next = node;
	list->tail = node;
	node->next=0;
}

/*
 * 根据定时器的绝对过期时间决定放入 near 还是某层 level：
 * - 如果高位与当前时间一致，说明将在 256 个时间单位内触发，放入 near；
 * - 否则逐层检查，找到最精确的层级后落入对应槽位。
 */
static void
add_node(struct timer *T,struct timer_node *node) {
	uint32_t time=node->expire;
	uint32_t current_time=T->time;
	
	if ((time|TIME_NEAR_MASK)==(current_time|TIME_NEAR_MASK)) {
		link(&T->near[time&TIME_NEAR_MASK],node);
	} else {
		int i;
		uint32_t mask=TIME_NEAR << TIME_LEVEL_SHIFT;
		for (i=0;i<3;i++) {
			if ((time|(mask-1))==(current_time|(mask-1))) {
				break;
			}
			mask <<= TIME_LEVEL_SHIFT;
		}

		link(&T->t[i][((time>>(TIME_NEAR_SHIFT + i*TIME_LEVEL_SHIFT)) & TIME_LEVEL_MASK)],node);	
	}
}

/*
 * timer_add 创建定时器节点并写入指定时间轮。
 * 为了降低锁竞争，节点内的事件数据在加锁前即完成拷贝；
 * 持锁期间仅做简单的指针操作，从而使临界区尽可能短。
 */
static void
timer_add(struct timer *T,void *arg,size_t sz,int time) {
	struct timer_node *node = (struct timer_node *)skynet_malloc(sizeof(*node)+sz);
	memcpy(node+1,arg,sz);

	SPIN_LOCK(T);

		node->expire=time+T->time;
		add_node(T,node);

	SPIN_UNLOCK(T);
}

/*
 * move_list 将 level 数组中的一个槽位全部搬迁到更细的层级。
 * 搬迁后会重新调用 add_node，因此节点最终仍会落到正确的 near 槽位。
 */
static void
move_list(struct timer *T, int level, int idx) {
	struct timer_node *current = link_clear(&T->t[level][idx]);
	while (current) {
		struct timer_node *temp=current->next;
		add_node(T,current);
		current=temp;
	}
}

/*
 * timer_shift 推进时间指针。当 near 已经循环一圈时，需要把更高层的定时器
 * 下放到低层；如果所有层级都回绕，则意味着时间溢出，需要把最顶层的槽位
 * 整体下放（相当于 32 位时间戳回绕的情况）。
 */
static void
timer_shift(struct timer *T) {
	int mask = TIME_NEAR;
	uint32_t ct = ++T->time;
	if (ct == 0) {
		move_list(T, 3, 0);
	} else {
		uint32_t time = ct >> TIME_NEAR_SHIFT;
		int i=0;

		while ((ct & (mask-1))==0) {
			int idx=time & TIME_LEVEL_MASK;
			if (idx!=0) {
				move_list(T, i, idx);
				break;				
			}
			mask <<= TIME_LEVEL_SHIFT;
			time >>= TIME_LEVEL_SHIFT;
			++i;
		}
	}
}

/*
 * dispatch_list 将同一槽位中的所有定时器转化为 Skynet 消息：
 * - PTYPE_RESPONSE 类型对应 Lua 层的 timeout/sleep 回调；
 * - 这里无需持有定时器锁，以免阻塞其他线程在 timer_add 中的插入。
 */
static inline void
dispatch_list(struct timer_node *current) {
	do {
		struct timer_event * event = (struct timer_event *)(current+1);
		struct skynet_message message;
		message.source = 0;
		message.session = event->session;
		message.data = NULL;
		message.sz = (size_t)PTYPE_RESPONSE << MESSAGE_TYPE_SHIFT;

		skynet_context_push(event->handle, &message);
		
		struct timer_node * temp = current;
		current=current->next;
		skynet_free(temp);	
	} while (current);
}

/*
 * timer_execute 针对当前时间指针所指向的 near 槽位进行触发。
 * 通过在进入 dispatch_list 前释放自旋锁，缩短持锁时间，
 * 使得其他线程可以继续添加新的定时器。
 */
static inline void
timer_execute(struct timer *T) {
	int idx = T->time & TIME_NEAR_MASK;
	
	while (T->near[idx].head.next) {
		struct timer_node *current = link_clear(&T->near[idx]);
		SPIN_UNLOCK(T);
		// dispatch_list don't need lock T
		dispatch_list(current);
		SPIN_LOCK(T);
	}
}

/*
 * timer_update 是定时器线程的核心入口：
 * 1. 先尝试处理当前 near 槽位的定时器（针对立即触发的情况）；
 * 2. 推进时间指针并将需要搬迁的定时器向下一级派发；
 * 3. 再处理一次 near 槽位，以确保搬迁下来的定时器能在正确的时间触发。
 */
static void 
timer_update(struct timer *T) {
	SPIN_LOCK(T);

	// try to dispatch timeout 0 (rare condition)
	timer_execute(T);

	// shift time first, and then dispatch timer message
	timer_shift(T);

	timer_execute(T);

	SPIN_UNLOCK(T);
}

static struct timer *
timer_create_timer() {
	struct timer *r=(struct timer *)skynet_malloc(sizeof(struct timer));
	memset(r,0,sizeof(*r));

	int i,j;

	for (i=0;i<TIME_NEAR;i++) {
		link_clear(&r->near[i]);
	}

	for (i=0;i<4;i++) {
		for (j=0;j<TIME_LEVEL;j++) {
			link_clear(&r->t[i][j]);
		}
	}

	SPIN_INIT(r)

	r->current = 0;

	return r;
}

int
skynet_timeout(uint32_t handle, int time, int session) {
	// time<=0 视为立即触发，直接压入目标服务的消息队列
	if (time <= 0) {
		struct skynet_message message;
		message.source = 0;
		message.session = session;
		message.data = NULL;
		message.sz = (size_t)PTYPE_RESPONSE << MESSAGE_TYPE_SHIFT;

		if (skynet_context_push(handle, &message)) {
			return -1;
		}
	} else {
		// time>0 时构造 timer_event，在 timer_add 中写入时间轮
		struct timer_event event;
		event.handle = handle;
		event.session = session;
		timer_add(TI, &event, sizeof(event), time);
	}

	return session;
}

// centisecond: 1/100 second
// systime 读取真实时间（wall clock），用于记录进程启动时刻以及当前秒的小数部分。
static void
systime(uint32_t *sec, uint32_t *cs) {
	struct timespec ti;
	clock_gettime(CLOCK_REALTIME, &ti);
	*sec = (uint32_t)ti.tv_sec;
	*cs = (uint32_t)(ti.tv_nsec / 10000000);
}

// gettime 使用单调时钟，避免系统时间跳变造成的倒退。
// 返回值单位同样是 centisecond，保证与时间轮精度一致。
static uint64_t
gettime() {
	uint64_t t;
	struct timespec ti;
	clock_gettime(CLOCK_MONOTONIC, &ti);
	t = (uint64_t)ti.tv_sec * 100;
	t += ti.tv_nsec / 10000000;
	return t;
}

void
skynet_updatetime(void) {
	uint64_t cp = gettime();
	// 如果系统时间被调小（极少发生），直接同步 current_point，
	// 避免 diff 为负导致 unsigned underflow。
	if(cp < TI->current_point) {
		skynet_error(NULL, "time diff error: change from %lld to %lld", cp, TI->current_point);
		TI->current_point = cp;
	} else if (cp != TI->current_point) {
		uint32_t diff = (uint32_t)(cp - TI->current_point);
		TI->current_point = cp;
		TI->current += diff;
		// diff 代表经过的 centisecond 数，逐次推进时间轮并触发到期定时器
		int i;
		for (i=0;i<diff;i++) {
			timer_update(TI);
		}
	}
}

uint32_t
skynet_starttime(void) {
	return TI->starttime;
}

uint64_t 
skynet_now(void) {
	return TI->current;
}

void 
skynet_timer_init(void) {
	// 启动时构造全局定时器实例，并记录启动基准时间
	TI = timer_create_timer();
	uint32_t current = 0;
	systime(&TI->starttime, &current);
	TI->current = current;
	TI->current_point = gettime();
}

// for profile

#define NANOSEC 1000000000
#define MICROSEC 1000000

uint64_t
skynet_thread_time(void) {
	struct timespec ti;
	clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ti);

	return (uint64_t)ti.tv_sec * MICROSEC + (uint64_t)ti.tv_nsec / (NANOSEC / MICROSEC);
}

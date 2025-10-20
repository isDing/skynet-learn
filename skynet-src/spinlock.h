#ifndef SKYNET_SPINLOCK_H
#define SKYNET_SPINLOCK_H

#define SPIN_INIT(q) spinlock_init(&(q)->lock);
#define SPIN_LOCK(q) spinlock_lock(&(q)->lock);
#define SPIN_UNLOCK(q) spinlock_unlock(&(q)->lock);
#define SPIN_DESTROY(q) spinlock_destroy(&(q)->lock);

#ifndef USE_PTHREAD_LOCK
// 默认情况下优先使用忙等待的自旋锁，保证临界区极短时的高性能。

#ifdef __STDC_NO_ATOMICS__

// 退化路径：缺乏 stdatomic 时，继续使用 GCC 提供的原子标志。
// 实质是 test-and-set 较忙的实现，适用于教学理解原理。
#define atomic_flag_ int
#define ATOMIC_FLAG_INIT_ 0
#define atomic_flag_test_and_set_(ptr) __sync_lock_test_and_set(ptr, 1)
#define atomic_flag_clear_(ptr) __sync_lock_release(ptr)

struct spinlock {
	atomic_flag_ lock;
};

static inline void
spinlock_init(struct spinlock *lock) {
	atomic_flag_ v = ATOMIC_FLAG_INIT_;
	lock->lock = v;
}

static inline void
spinlock_lock(struct spinlock *lock) {
	while (atomic_flag_test_and_set_(&lock->lock)) {}
}

static inline int
spinlock_trylock(struct spinlock *lock) {
	return atomic_flag_test_and_set_(&lock->lock) == 0;
}

static inline void
spinlock_unlock(struct spinlock *lock) {
	atomic_flag_clear_(&lock->lock);
}

static inline void
spinlock_destroy(struct spinlock *lock) {
	(void) lock;
}

#else  // __STDC_NO_ATOMICS__

#include "atomic.h"

// 使用 C11 原子操作实现轻量级自旋锁；多核环境下性能更好、语义清晰。
#define atomic_test_and_set_(ptr) STD_ atomic_exchange_explicit(ptr, 1, STD_ memory_order_acquire)
#define atomic_clear_(ptr) STD_ atomic_store_explicit(ptr, 0, STD_ memory_order_release);
#define atomic_load_relaxed_(ptr) STD_ atomic_load_explicit(ptr, STD_ memory_order_relaxed)

#if defined(__x86_64__)
#include <immintrin.h> // For _mm_pause
#define atomic_pause_() _mm_pause()
#else
#define atomic_pause_() ((void)0)
#endif

struct spinlock {
	STD_ atomic_int lock;
};

// 初始化
static inline void
spinlock_init(struct spinlock *lock) {
	STD_ atomic_init(&lock->lock, 0);
}

// 加锁（优化版本，减少总线竞争）
static inline void
spinlock_lock(struct spinlock *lock) {
	for (;;) {
		if (!atomic_test_and_set_(&lock->lock))
			return;
		// 进入等待环节时仅执行 relaxed load，加上 _mm_pause()
		// 可以减少总线竞争与功耗，是典型的指数退避雏形。
		while (atomic_load_relaxed_(&lock->lock))
			atomic_pause_();  // CPU 暂停指令，节能
	}
}

// 尝试加锁
static inline int
spinlock_trylock(struct spinlock *lock) {
	return !atomic_load_relaxed_(&lock->lock) &&
		!atomic_test_and_set_(&lock->lock);
}

// 解锁
static inline void
spinlock_unlock(struct spinlock *lock) {
	atomic_clear_(&lock->lock);
}

static inline void
spinlock_destroy(struct spinlock *lock) {
	(void) lock;
}

#endif  // __STDC_NO_ATOMICS__

#else

#include <pthread.h>

// 在调试或嵌入式环境下，可定义 USE_PTHREAD_LOCK 把自旋锁换成互斥锁，
// 这样系统不会在持锁期间完整占用 CPU，便于观察和诊断。

// we use mutex instead of spinlock for some reason
// you can also replace to pthread_spinlock

struct spinlock {
	pthread_mutex_t lock;
};

static inline void
spinlock_init(struct spinlock *lock) {
	pthread_mutex_init(&lock->lock, NULL);
}

static inline void
spinlock_lock(struct spinlock *lock) {
	pthread_mutex_lock(&lock->lock);
}

static inline int
spinlock_trylock(struct spinlock *lock) {
	return pthread_mutex_trylock(&lock->lock) == 0;
}

static inline void
spinlock_unlock(struct spinlock *lock) {
	pthread_mutex_unlock(&lock->lock);
}

static inline void
spinlock_destroy(struct spinlock *lock) {
	pthread_mutex_destroy(&lock->lock);
}

#endif

#endif

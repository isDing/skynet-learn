#ifndef SKYNET_ATOMIC_H
#define SKYNET_ATOMIC_H

#include <stddef.h>
#include <stdint.h>

#ifdef __STDC_NO_ATOMICS__
// 如果编译器/标准库不支持 C11 原子（如老旧 GCC），退回到 GCC 内建原子操作。
// 这些宏以 __sync_* 为基础，语义简单粗暴但兼容性最好。

#define ATOM_INT volatile int
#define ATOM_POINTER volatile uintptr_t
#define ATOM_SIZET volatile size_t
#define ATOM_ULONG volatile unsigned long
#define ATOM_INIT(ptr, v) (*(ptr) = v)
#define ATOM_LOAD(ptr) (*(ptr))
#define ATOM_STORE(ptr, v) (*(ptr) = v)
#define ATOM_CAS(ptr, oval, nval) __sync_bool_compare_and_swap(ptr, oval, nval)
#define ATOM_CAS_ULONG(ptr, oval, nval) __sync_bool_compare_and_swap(ptr, oval, nval)
#define ATOM_CAS_SIZET(ptr, oval, nval) __sync_bool_compare_and_swap(ptr, oval, nval)
#define ATOM_CAS_POINTER(ptr, oval, nval) __sync_bool_compare_and_swap(ptr, oval, nval)
#define ATOM_FINC(ptr) __sync_fetch_and_add(ptr, 1)
#define ATOM_FDEC(ptr) __sync_fetch_and_sub(ptr, 1)
#define ATOM_FADD(ptr,n) __sync_fetch_and_add(ptr, n)
#define ATOM_FSUB(ptr,n) __sync_fetch_and_sub(ptr, n)
#define ATOM_FAND(ptr,n) __sync_fetch_and_and(ptr, n)

#else
// 默认分支：使用 C11 stdatomic（或 C++ std::atomic），具备更细粒度的内存序语义。
// STD_ 宏用来在 C/C++ 之间复用同一份代码。

#if defined (__cplusplus)
#include <atomic>
#define STD_ std::
#define atomic_value_type_(p, v) decltype((p)->load())(v) 
#else
#include <stdatomic.h>
#define STD_
#define atomic_value_type_(p, v) v
#endif

#define ATOM_INT  STD_ atomic_int
#define ATOM_POINTER STD_ atomic_uintptr_t
#define ATOM_SIZET STD_ atomic_size_t
#define ATOM_ULONG STD_ atomic_ulong
#define ATOM_INIT(ref, v) STD_ atomic_init(ref, v)
#define ATOM_LOAD(ptr) STD_ atomic_load(ptr)
#define ATOM_STORE(ptr, v) STD_ atomic_store(ptr, v)

static inline int
ATOM_CAS(STD_ atomic_int *ptr, int oval, int nval) {
	// 这里使用弱 CAS，配合外层循环可获得较好的性能；
	// 学习时注意 weak CAS 允许失败即便值未变化，需要循环重试。
	return STD_ atomic_compare_exchange_weak(ptr, &(oval), nval);
}

static inline int
ATOM_CAS_SIZET(STD_ atomic_size_t *ptr, size_t oval, size_t nval) {
	return STD_ atomic_compare_exchange_weak(ptr, &(oval), nval);
}

static inline int
ATOM_CAS_ULONG(STD_ atomic_ulong *ptr, unsigned long oval, unsigned long nval) {
	return STD_ atomic_compare_exchange_weak(ptr, &(oval), nval);
}

static inline int
ATOM_CAS_POINTER(STD_ atomic_uintptr_t *ptr, uintptr_t oval, uintptr_t nval) {
	return STD_ atomic_compare_exchange_weak(ptr, &(oval), nval);
}

#define ATOM_FINC(ptr) STD_ atomic_fetch_add(ptr, atomic_value_type_(ptr,1))
#define ATOM_FDEC(ptr) STD_ atomic_fetch_sub(ptr, atomic_value_type_(ptr, 1))
#define ATOM_FADD(ptr,n) STD_ atomic_fetch_add(ptr, atomic_value_type_(ptr, n))
#define ATOM_FSUB(ptr,n) STD_ atomic_fetch_sub(ptr, atomic_value_type_(ptr, n))
#define ATOM_FAND(ptr,n) STD_ atomic_fetch_and(ptr, atomic_value_type_(ptr, n))

#endif

#endif

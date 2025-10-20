#include <stdio.h>
#include <string.h>
#include <assert.h>
#include <stdlib.h>
#include <lua.h>
#include <stdio.h>

#include "malloc_hook.h"
#include "skynet.h"
#include "atomic.h"

// 打开 MEMORY_CHECK 可以启用额外的内存校验（如检测重复释放），学习调试阶段非常有用；生产环境一般保持关闭避免额外开销。
// turn on MEMORY_CHECK can do more memory check, such as double free
// #define MEMORY_CHECK

#define MEMORY_ALLOCTAG 0x20140605
#define MEMORY_FREETAG 0x0badf00d

static ATOM_SIZET _used_memory = 0;     // 总使用内存
static ATOM_SIZET _memory_block = 0;    // 内存块数量

// mem_data 用于以句柄（服务 ID）为键记录每个服务的当前内存占用量，
// 结合 ATOM_* 原子操作，确保多线程统计结果一致。
struct mem_data {
	ATOM_ULONG handle;      // 服务句柄
	ATOM_SIZET allocated;   // 已分配内存
};

// mem_cookie 是所有分配块统一加的“前缀”结构，
// 在真实内存块前侧保存元信息，便于统计和调试。
struct mem_cookie {
	size_t size;            // 分配大小
	uint32_t handle;        // 所属服务
#ifdef MEMORY_CHECK
	uint32_t dogtag;        // 内存标记（用于检测）
#endif
	uint32_t cookie_size;	// should be the last
};

#define SLOT_SIZE 0x10000
#define PREFIX_SIZE sizeof(struct mem_cookie)

static struct mem_data mem_stats[SLOT_SIZE];  // 服务内存统计表


#ifndef NOUSE_JEMALLOC

#include "jemalloc.h"

// for skynet_lalloc use
#define raw_realloc je_realloc
#define raw_free je_free

static ATOM_SIZET *
get_allocated_field(uint32_t handle) {
	// 通过句柄低位做哈希，定位到 mem_stats 中的槽位；
	// 在高并发环境下，这个结构提供了“近似准确”的 per-service 内存统计。
	int h = (int)(handle & (SLOT_SIZE - 1));
	struct mem_data *data = &mem_stats[h];
	uint32_t old_handle = data->handle;
	ssize_t old_alloc = (ssize_t)data->allocated;
	if(old_handle == 0 || old_alloc <= 0) {
		// data->allocated may less than zero, because it may not count at start.
		if(!ATOM_CAS_ULONG(&data->handle, old_handle, handle)) {
			return 0;
		}
		if (old_alloc < 0) {
			ATOM_CAS_SIZET(&data->allocated, (size_t)old_alloc, 0);
		}
	}
	if(data->handle != handle) {
		return 0;
	}
	return &data->allocated;
}

inline static void
update_xmalloc_stat_alloc(uint32_t handle, size_t __n) {
	// 统计逻辑拆成全局计数和服务级计数两部分：
	// 全局使用 _used_memory / _memory_block，服务级通过 get_allocated_field 获取 slot。
	ATOM_FADD(&_used_memory, __n);
	ATOM_FINC(&_memory_block);
	ATOM_SIZET * allocated = get_allocated_field(handle);
	if(allocated) {
		ATOM_FADD(allocated, __n);
	}
}

inline static void
update_xmalloc_stat_free(uint32_t handle, size_t __n) {
	ATOM_FSUB(&_used_memory, __n);
	ATOM_FDEC(&_memory_block);
	ATOM_SIZET * allocated = get_allocated_field(handle);
	if(allocated) {
		ATOM_FSUB(allocated, __n);
	}
}

inline static void*
fill_prefix(char* ptr, size_t sz, uint32_t cookie_size) {
	// 每次分配都会把服务句柄、分配大小写入前缀，从而实现“谁申请，谁负责”。
	// 返回的 ret 指针跳过 cookie 区域，对上层透明。
	uint32_t handle = skynet_current_handle();
	struct mem_cookie *p = (struct mem_cookie *)ptr;
	char * ret = ptr + cookie_size;
	p->size = sz;
	p->handle = handle;
#ifdef MEMORY_CHECK
	p->dogtag = MEMORY_ALLOCTAG;
#endif
	update_xmalloc_stat_alloc(handle, sz);
	memcpy(ret - sizeof(uint32_t), &cookie_size, sizeof(cookie_size));
	return ret;
}

inline static uint32_t
get_cookie_size(char *ptr) {
	uint32_t cookie_size;
	memcpy(&cookie_size, ptr - sizeof(cookie_size), sizeof(cookie_size));
	return cookie_size;
}

inline static void*
clean_prefix(char* ptr) {
	// 释放时逆向读取 cookie，实现统计回收；
	// 如果启用 MEMORY_CHECK，还会检查 dogtag 防止重复 free 或越界写。
	uint32_t cookie_size = get_cookie_size(ptr);
	struct mem_cookie *p = (struct mem_cookie *)(ptr - cookie_size);
	uint32_t handle = p->handle;
#ifdef MEMORY_CHECK
	uint32_t dogtag = p->dogtag;
    // 检查双重释放
	if (dogtag == MEMORY_FREETAG) {
		fprintf(stderr, "xmalloc: double free in :%08x\n", handle);
	}
    // 检查内存越界
	assert(dogtag == MEMORY_ALLOCTAG);	// memory out of bounds
    // 标记为已释放
	p->dogtag = MEMORY_FREETAG;
#endif
	update_xmalloc_stat_free(handle, p->size);
	return p;
}

static void malloc_oom(size_t size) {
	fprintf(stderr, "xmalloc: Out of memory trying to allocate %zu bytes\n",
		size);
	fflush(stderr);
	abort();
}

void
memory_info_dump(const char* opts) {
	je_malloc_stats_print(0,0, opts);
}

bool
mallctl_bool(const char* name, bool* newval) {
	bool v = 0;
	size_t len = sizeof(v);
	if(newval) {
		je_mallctl(name, &v, &len, newval, sizeof(bool));
	} else {
		je_mallctl(name, &v, &len, NULL, 0);
	}
	return v;
}

int
mallctl_cmd(const char* name) {
	return je_mallctl(name, NULL, NULL, NULL, 0);
}

size_t
mallctl_int64(const char* name, size_t* newval) {
	size_t v = 0;
	size_t len = sizeof(v);
	if(newval) {
		je_mallctl(name, &v, &len, newval, sizeof(size_t));
	} else {
		je_mallctl(name, &v, &len, NULL, 0);
	}
	// skynet_error(NULL, "name: %s, value: %zd\n", name, v);
	return v;
}

int
mallctl_opt(const char* name, int* newval) {
	int v = 0;
	size_t len = sizeof(v);
	if(newval) {
		int ret = je_mallctl(name, &v, &len, newval, sizeof(int));
		if(ret == 0) {
			skynet_error(NULL, "set new value(%d) for (%s) succeed\n", *newval, name);
		} else {
			skynet_error(NULL, "set new value(%d) for (%s) failed: error -> %d\n", *newval, name, ret);
		}
	} else {
		je_mallctl(name, &v, &len, NULL, 0);
	}

	return v;
}

// hook : malloc, realloc, free, calloc

void *
skynet_malloc(size_t size) {
	// Skynet 全局统一入口：所有 C 层非临时内存都应走这里，
	// 这样才能被统计与监控（jemalloc 负责真正分配）。
	void* ptr = je_malloc(size + PREFIX_SIZE);
	if(!ptr) malloc_oom(size);
	return fill_prefix(ptr, size, PREFIX_SIZE);
}

void *
skynet_realloc(void *ptr, size_t size) {
	// 重新分配时需要先取出旧 cookie 做统计回收，再写入新 cookie。
	if (ptr == NULL) return skynet_malloc(size);

	uint32_t cookie_size = get_cookie_size(ptr);
	void* rawptr = clean_prefix(ptr);
	void *newptr = je_realloc(rawptr, size+cookie_size);
	if(!newptr) malloc_oom(size);
	return fill_prefix(newptr, size, cookie_size);
}

void
skynet_free(void *ptr) {
	// 清理流程与分配对称：还原原始指针，更新统计，交给 jemalloc 释放。
	if (ptr == NULL) return;
	void* rawptr = clean_prefix(ptr);
	je_free(rawptr);
}

void *
skynet_calloc(size_t nmemb, size_t size) {
	// calloc 需要保证额外 cookie 区域也被初始化（使用 cookie_n 计算前缀大小）。
	uint32_t cookie_n = (PREFIX_SIZE+size-1)/size;
	void* ptr = je_calloc(nmemb + cookie_n, size);
	if(!ptr) malloc_oom(nmemb * size);
	return fill_prefix(ptr, nmemb * size, cookie_n * size);
}

// 计算对齐的 Cookie 大小
static inline uint32_t
alignment_cookie_size(size_t alignment) {
	if (alignment >= PREFIX_SIZE)
		return alignment;
	switch (alignment) {
	case 4 :
		return (PREFIX_SIZE + 3) / 4 * 4;
	case 8 :
		return (PREFIX_SIZE + 7) / 8 * 8;
	case 16 :
		return (PREFIX_SIZE + 15) / 16 * 16;
	}
	return (PREFIX_SIZE + alignment - 1) / alignment * alignment;
}

// 对齐内存分配
void *
skynet_memalign(size_t alignment, size_t size) {
	// 针对内存对齐的需求（如 SSE/缓存行），预先调整 cookie 大小以满足对齐约束。
	uint32_t cookie_size = alignment_cookie_size(alignment);
	void* ptr = je_memalign(alignment, size + cookie_size);
	if(!ptr) malloc_oom(size);
	return fill_prefix(ptr, size, cookie_size);
}

void *
skynet_aligned_alloc(size_t alignment, size_t size) {
	// C11 aligned_alloc 的封装，同样复用 cookie 对齐逻辑。
	uint32_t cookie_size = alignment_cookie_size(alignment);
	void* ptr = je_aligned_alloc(alignment, size + cookie_size);
	if(!ptr) malloc_oom(size);
	return fill_prefix(ptr, size, cookie_size);
}

int
skynet_posix_memalign(void **memptr, size_t alignment, size_t size) {
	uint32_t cookie_size = alignment_cookie_size(alignment);
	int err = je_posix_memalign(memptr, alignment, size + cookie_size);
	if (err) malloc_oom(size);
	fill_prefix(*memptr, size, cookie_size);
	return err;
}

#else

// for skynet_lalloc use
#define raw_realloc realloc
#define raw_free free

void
memory_info_dump(const char* opts) {
	skynet_error(NULL, "No jemalloc");
}

size_t
mallctl_int64(const char* name, size_t* newval) {
	skynet_error(NULL, "No jemalloc : mallctl_int64 %s.", name);
	return 0;
}

int
mallctl_opt(const char* name, int* newval) {
	skynet_error(NULL, "No jemalloc : mallctl_opt %s.", name);
	return 0;
}

bool
mallctl_bool(const char* name, bool* newval) {
	skynet_error(NULL, "No jemalloc : mallctl_bool %s.", name);
	return 0;
}

int
mallctl_cmd(const char* name) {
	skynet_error(NULL, "No jemalloc : mallctl_cmd %s.", name);
	return 0;
}

#endif

size_t
malloc_used_memory(void) {
	return ATOM_LOAD(&_used_memory);
}

size_t
malloc_memory_block(void) {
	return ATOM_LOAD(&_memory_block);
}

// 输出所有服务的内存使用
void
dump_c_mem() {
	int i;
	size_t total = 0;
	skynet_error(NULL, "dump all service mem:");
	for(i=0; i<SLOT_SIZE; i++) {
		struct mem_data* data = &mem_stats[i];
		if(data->handle != 0 && data->allocated != 0) {
			total += data->allocated;
			skynet_error(NULL, ":%08x -> %zdkb %db", data->handle, data->allocated >> 10, (int)(data->allocated % 1024));
		}
	}
	skynet_error(NULL, "+total: %zdkb",total >> 10);
}

void *
skynet_lalloc(void *ptr, size_t osize, size_t nsize) {
	// 兼容 Lua allocator 接口：当 nsize 为 0 表示 free，否则 realloc。
	// 这里不做统计，留给 Lua VM 自己控制（仅用于 Lua 内部内存）。
	if (nsize == 0) {
		raw_free(ptr);
		return NULL;
	} else {
		return raw_realloc(ptr, nsize);
	}
}

// Lua 接口导出
int
dump_mem_lua(lua_State *L) {
	// 将所有服务的内存占用以 Lua table 形式返回，
	// 便于在 Lua 世界里进一步统计或排序。
	int i;
	lua_newtable(L);
	for(i=0; i<SLOT_SIZE; i++) {
		struct mem_data* data = &mem_stats[i];
		if(data->handle != 0 && data->allocated != 0) {
			lua_pushinteger(L, data->allocated);
			lua_rawseti(L, -2, (lua_Integer)data->handle);
		}
	}
	return 1;
}

size_t
malloc_current_memory(void) {
	// 快速查询当前服务对应 slot 的数据（线性扫描），
	// 常用于在服务内部打印 debugging 信息。
	uint32_t handle = skynet_current_handle();
	int i;
	for(i=0; i<SLOT_SIZE; i++) {
		struct mem_data* data = &mem_stats[i];
		if(data->handle == (uint32_t)handle && data->allocated != 0) {
			return (size_t) data->allocated;
		}
	}
	return 0;
}

void
skynet_debug_memory(const char *info) {
	// for debug use
	// 简易调试入口：直接向 stderr 打印当前服务的内存，配合自定义关键字便于追踪泄露。
	uint32_t handle = skynet_current_handle();
	size_t mem = malloc_current_memory();
	fprintf(stderr, "[:%08x] %s %p\n", handle, info, (void *)mem);
}

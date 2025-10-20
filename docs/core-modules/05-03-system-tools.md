# Skynet C核心层 - 系统工具模块 (System Tools Module)

## 模块概述

系统工具模块提供了 Skynet 运行所需的底层工具支持，包括内存管理、原子操作、自旋锁实现等关键基础设施。这些工具为整个框架提供了高性能、线程安全的基础操作支持。

### 模块定位
- **层次**：C 核心层最底层
- **作用**：提供基础工具和系统级支持
- **特点**：高性能、无锁设计、跨平台兼容

## 核心组件

### 1. 内存管理系统 (malloc_hook.c)

#### 1.1 设计理念

内存管理系统通过 Hook 机制拦截所有内存分配操作，实现了：
- **内存统计**：精确跟踪每个服务的内存使用
- **内存调试**：检测内存泄露和越界访问
- **性能优化**：使用 jemalloc 提升分配效率

#### 1.2 核心数据结构

```c
// 内存统计数据
struct mem_data {
    ATOM_ULONG handle;      // 服务句柄
    ATOM_SIZET allocated;   // 已分配内存
};

// 内存 Cookie（前缀）
struct mem_cookie {
    size_t size;            // 分配大小
    uint32_t handle;        // 所属服务
#ifdef MEMORY_CHECK
    uint32_t dogtag;        // 内存标记（用于检测）
#endif
    uint32_t cookie_size;   // Cookie 大小
};

// 全局统计
static ATOM_SIZET _used_memory = 0;     // 总使用内存
static ATOM_SIZET _memory_block = 0;    // 内存块数量
static struct mem_data mem_stats[SLOT_SIZE];  // 服务内存统计表
```

#### 1.3 内存分配流程

```
用户请求分配内存
    ↓
skynet_malloc()
    ↓
je_malloc(size + PREFIX_SIZE)  // jemalloc 实际分配
    ↓
fill_prefix()  // 填充内存前缀
    ├── 记录服务句柄
    ├── 记录分配大小
    ├── 更新统计信息
    └── 返回用户指针（跳过前缀）
```

#### 1.4 关键实现

```c
// 内存分配 Hook
void *skynet_malloc(size_t size) {
    // 分配额外空间存储前缀
    void* ptr = je_malloc(size + PREFIX_SIZE);
    if(!ptr) malloc_oom(size);
    // 填充前缀并返回用户指针
    return fill_prefix(ptr, size, PREFIX_SIZE);
}

// 填充内存前缀
static void* fill_prefix(char* ptr, size_t sz, uint32_t cookie_size) {
    uint32_t handle = skynet_current_handle();
    struct mem_cookie *p = (struct mem_cookie *)ptr;
    char * ret = ptr + cookie_size;  // 用户指针
    
    // 记录元信息
    p->size = sz;
    p->handle = handle;
#ifdef MEMORY_CHECK
    p->dogtag = MEMORY_ALLOCTAG;  // 内存标记
#endif
    
    // 更新统计
    update_xmalloc_stat_alloc(handle, sz);
    
    // 在用户指针前记录 cookie_size，用于 free 时定位
    memcpy(ret - sizeof(uint32_t), &cookie_size, sizeof(cookie_size));
    return ret;
}

// 内存释放
void skynet_free(void *ptr) {
    if (ptr == NULL) return;
    void* rawptr = clean_prefix(ptr);  // 恢复原始指针
    je_free(rawptr);
}
```

#### 1.5 内存统计机制

```c
// 获取服务的内存统计字段
static ATOM_SIZET* get_allocated_field(uint32_t handle) {
    int h = (int)(handle & (SLOT_SIZE - 1));  // Hash 索引
    struct mem_data *data = &mem_stats[h];
    
    // CAS 操作确保线程安全
    uint32_t old_handle = data->handle;
    if(old_handle == 0) {
        if(!ATOM_CAS_ULONG(&data->handle, old_handle, handle)) {
            return 0;
        }
    }
    
    if(data->handle != handle) {
        return 0;  // Hash 冲突
    }
    return &data->allocated;
}

// 更新分配统计
static void update_xmalloc_stat_alloc(uint32_t handle, size_t __n) {
    ATOM_FADD(&_used_memory, __n);      // 总内存增加
    ATOM_FINC(&_memory_block);          // 块数增加
    
    ATOM_SIZET * allocated = get_allocated_field(handle);
    if(allocated) {
        ATOM_FADD(allocated, __n);      // 服务内存增加
    }
}
```

### 2. 原子操作抽象 (atomic.h)

#### 2.1 设计目标

提供跨平台的原子操作抽象层，支持：
- **C11 原子操作**：优先使用标准原子操作
- **GCC 内建函数**：在不支持 C11 时的后备方案
- **C++ 兼容**：支持 C++ std::atomic

#### 2.2 核心宏定义

```c
#ifdef __STDC_NO_ATOMICS__
// 不支持 C11 原子操作，使用 GCC 内建函数
#define ATOM_INT volatile int
#define ATOM_CAS(ptr, oval, nval) \
    __sync_bool_compare_and_swap(ptr, oval, nval)
#define ATOM_FINC(ptr) __sync_fetch_and_add(ptr, 1)
#define ATOM_FDEC(ptr) __sync_fetch_and_sub(ptr, 1)
#define ATOM_FADD(ptr,n) __sync_fetch_and_add(ptr, n)
#define ATOM_FSUB(ptr,n) __sync_fetch_and_sub(ptr, n)
#else
// 支持 C11/C++ 原子操作
#define ATOM_INT STD_ atomic_int
#define ATOM_LOAD(ptr) STD_ atomic_load(ptr)
#define ATOM_STORE(ptr, v) STD_ atomic_store(ptr, v)
// CAS 操作封装
static inline int ATOM_CAS(atomic_int *ptr, int oval, int nval) {
    return atomic_compare_exchange_weak(ptr, &(oval), nval);
}
#endif
```

#### 2.3 原子操作分类

| 操作类型 | 宏定义 | 说明 |
|---------|--------|------|
| 加载 | ATOM_LOAD | 原子读取 |
| 存储 | ATOM_STORE | 原子写入 |
| CAS | ATOM_CAS | 比较并交换 |
| 增减 | ATOM_FINC/FDEC | 原子增减 |
| 算术 | ATOM_FADD/FSUB | 原子加减 |
| 位操作 | ATOM_FAND | 原子与操作 |

### 3. 自旋锁实现 (spinlock.h)

#### 3.1 实现策略

根据编译配置提供三种分支：

1. **C11 原子版本（默认）**：依赖 `atomic_exchange_explicit`/`atomic_load_explicit`，在 x86_64 平台配合 `_mm_pause()` 缓解忙等。
2. **GCC 原子内建版本**：当定义 `__STDC_NO_ATOMICS__` 时，退化到 `__sync_lock_test_and_set` 与 `__sync_lock_release`。
3. **pthread 版本**：显式定义 `USE_PTHREAD_LOCK` 时改用 `pthread_mutex`，方便在调试或不允许忙等的场景下使用。

#### 3.2 标准自旋锁实现

```c
#ifndef USE_PTHREAD_LOCK

struct spinlock {
    atomic_int lock;
};

// 初始化
static inline void spinlock_init(struct spinlock *lock) {
    atomic_init(&lock->lock, 0);
}

// 加锁（优化版本，减少总线竞争）
static inline void spinlock_lock(struct spinlock *lock) {
    for (;;) {
        // 尝试获取锁
        if (!atomic_test_and_set_(&lock->lock))
            return;
        
        // 等待锁释放（只读操作，减少总线流量）
        while (atomic_load_relaxed_(&lock->lock)) {
#ifdef __x86_64__
            _mm_pause();  // CPU 暂停指令，节能
#endif
        }
    }
}

// 尝试加锁
static inline int spinlock_trylock(struct spinlock *lock) {
    return !atomic_load_relaxed_(&lock->lock) &&
           !atomic_test_and_set_(&lock->lock);
}

// 解锁
static inline void spinlock_unlock(struct spinlock *lock) {
    atomic_store_explicit(&lock->lock, 0, memory_order_release);
}
#endif
```

#### 3.3 性能优化技巧

1. **两阶段获取**：
   - 第一阶段：atomic_test_and_set（写操作）
   - 第二阶段：atomic_load（只读操作）
   - 减少缓存行竞争

2. **CPU 暂停指令**：
   - x86_64 使用 _mm_pause()
   - 降低功耗，提高超线程性能

3. **内存序控制**：
   - acquire-release 语义保证正确性
   - relaxed 读取减少开销

### 4. 内存对齐分配

#### 4.1 对齐分配支持

```c
// 计算对齐的 Cookie 大小
static inline uint32_t alignment_cookie_size(size_t alignment) {
    if (alignment >= PREFIX_SIZE)
        return alignment;
    
    // 根据对齐要求调整 Cookie 大小
    switch (alignment) {
    case 4:
        return (PREFIX_SIZE + 3) / 4 * 4;
    case 8:
        return (PREFIX_SIZE + 7) / 8 * 8;
    case 16:
        return (PREFIX_SIZE + 15) / 16 * 16;
    }
    return (PREFIX_SIZE + alignment - 1) / alignment * alignment;
}

// 对齐内存分配
void *skynet_memalign(size_t alignment, size_t size) {
    uint32_t cookie_size = alignment_cookie_size(alignment);
    void* ptr = je_memalign(alignment, size + cookie_size);
    if(!ptr) malloc_oom(size);
    return fill_prefix(ptr, size, cookie_size);
}
```

### 5. 内存调试功能

#### 5.1 双重释放检测

```c
#ifdef MEMORY_CHECK
static void* clean_prefix(char* ptr) {
    struct mem_cookie *p = /* 获取 Cookie */;
    uint32_t dogtag = p->dogtag;
    
    // 检查双重释放
    if (dogtag == MEMORY_FREETAG) {
        fprintf(stderr, "xmalloc: double free in :%08x\n", 
                p->handle);
    }
    
    // 检查内存越界
    assert(dogtag == MEMORY_ALLOCTAG);
    
    // 标记为已释放
    p->dogtag = MEMORY_FREETAG;
    
    return p;
}
#endif
```

#### 5.2 内存泄露检测

```c
// 输出所有服务的内存使用
void dump_c_mem() {
    int i;
    size_t total = 0;
    skynet_error(NULL, "dump all service mem:");
    
    for(i=0; i<SLOT_SIZE; i++) {
        struct mem_data* data = &mem_stats[i];
        if(data->handle != 0 && data->allocated != 0) {
            total += data->allocated;
            skynet_error(NULL, ":%08x -> %zdkb %db", 
                data->handle, 
                data->allocated >> 10, 
                (int)(data->allocated % 1024));
        }
    }
    skynet_error(NULL, "+total: %zdkb", total >> 10);
}
```

## 性能优化

### 1. 内存分配优化

#### jemalloc 集成
- **线程缓存**：减少锁竞争
- **大小类管理**：减少内部碎片
- **Arena 分离**：NUMA 优化

#### 统计开销优化
- **原子操作**：无锁更新统计
- **Hash 索引**：O(1) 查找服务统计
- **延迟更新**：批量统计输出

### 2. 自旋锁优化

#### 总线流量优化
```c
// 优化前：持续尝试 CAS
while (!CAS(&lock, 0, 1)) {}

// 优化后：先读后写
while (lock || !CAS(&lock, 0, 1)) {
    pause();  // 等待时暂停
}
```

#### 公平性注意事项
- 当前实现为简化自旋锁，未内建 FIFO 公平策略。
- 对需要公平性的场景，可自行换成 ticket lock 或在调用侧设计退避/优先级策略。
- 配合 `spinlock_trylock` 做退避能降低长时间占用导致的锁护送。

### 3. 原子操作优化

#### 内存序优化
- **relaxed**：计数器操作
- **acquire-release**：同步操作
- **seq_cst**：仅在必要时使用

## 最佳实践

### 1. 内存管理

#### 正确使用内存 Hook
```c
// 正确：使用 skynet 的内存函数
void* ptr = skynet_malloc(size);
skynet_free(ptr);

// 错误：直接使用标准库函数
void* ptr = malloc(size);  // 不会被统计
free(ptr);
```

#### 内存调试技巧
- 在需要的 C 模块中定义 `#define MEMORY_CHECK` 以开启额外检测。
- Lua 层通过 `local memory = require "skynet.memory"; memory.dump()` 查看各服务内存。
- C 层可调用 `dump_c_mem();` 输出统计。
- 在自定义 C 服务中调用 `skynet_debug_memory("checkpoint");` 辅助定位泄露。

### 2. 锁使用指南

#### 选择合适的锁类型
```c
// 短临界区：使用自旋锁
SPIN_LOCK(q);
// 快速操作
SPIN_UNLOCK(q);

// 长临界区：使用互斥锁
pthread_mutex_lock(&mutex);
// 可能阻塞的操作
pthread_mutex_unlock(&mutex);
```

#### 避免死锁
```c
// 正确：固定加锁顺序
lock_A();
lock_B();
unlock_B();
unlock_A();

// 使用 trylock 避免死锁
if (spinlock_trylock(&lock)) {
    // 处理
    spinlock_unlock(&lock);
} else {
    // 稍后重试
}
```

### 3. 原子操作使用

#### 选择合适的原子操作
```c
// 简单计数器
ATOM_FINC(&counter);

// 条件更新
int old = ATOM_LOAD(&value);
while (!ATOM_CAS(&value, old, new_value)) {
    old = ATOM_LOAD(&value);
    new_value = compute(old);
}
```

## 架构图

### 内存管理架构

```
┌─────────────────────────────────────────┐
│          用户代码 (User Code)            │
├─────────────────────────────────────────┤
│       内存 Hook 层 (Memory Hook)         │
│  ┌──────────┬──────────┬──────────┐    │
│  │ malloc   │ realloc  │  free    │    │
│  └──────────┴──────────┴──────────┘    │
├─────────────────────────────────────────┤
│      前缀管理 (Prefix Management)        │
│  ┌──────────┬──────────┬──────────┐    │
│  │ Cookie   │ Stats    │ Check    │    │
│  └──────────┴──────────┴──────────┘    │
├─────────────────────────────────────────┤
│        jemalloc / 标准分配器             │
└─────────────────────────────────────────┘
```

### 原子操作层次

```
┌─────────────────────────────────────────┐
│         应用层原子操作接口                │
│    ATOM_CAS, ATOM_FINC, ATOM_FADD...    │
├─────────────────────────────────────────┤
│          平台抽象层                       │
│  ┌──────────┬──────────┬──────────┐    │
│  │ C11      │ GCC      │ MSVC     │    │
│  │ Atomics  │ Builtins │ Intrin   │    │
│  └──────────┴──────────┴──────────┘    │
├─────────────────────────────────────────┤
│          硬件原子指令                     │
│    CAS, XADD, LOCK prefix...            │
└─────────────────────────────────────────┘
```

## 与其他模块的交互

### 1. 与服务管理模块
- 提供服务级内存统计
- 服务句柄关联内存分配
- 服务退出时的内存检查

### 2. 与消息队列模块
- 自旋锁保护队列操作
- 原子操作更新队列状态
- 内存池管理消息对象

### 3. 与网络模块
- Socket 缓冲区内存管理
- 原子操作管理连接计数
- 自旋锁保护 Socket 池

## 调试与诊断

### 1. 内存诊断

```c
// 获取当前服务的内存使用
size_t malloc_current_memory(void) {
    uint32_t handle = skynet_current_handle();
    // 查找服务的内存统计
    for(int i=0; i<SLOT_SIZE; i++) {
        struct mem_data* data = &mem_stats[i];
        if(data->handle == handle) {
            return (size_t) data->allocated;
        }
    }
    return 0;
}

// Lua 接口导出
int dump_mem_lua(lua_State *L) {
    lua_newtable(L);
    for(int i=0; i<SLOT_SIZE; i++) {
        struct mem_data* data = &mem_stats[i];
        if(data->handle != 0 && data->allocated != 0) {
            lua_pushinteger(L, data->allocated);
            lua_rawseti(L, -2, (lua_Integer)data->handle);
        }
    }
    return 1;
}
```

### 2. jemalloc 控制

```c
// 内存统计输出
void memory_info_dump(const char* opts) {
    je_malloc_stats_print(0, 0, opts);
}

// 动态调整参数
bool mallctl_bool(const char* name, bool* newval) {
    bool v = 0;
    size_t len = sizeof(v);
    je_mallctl(name, &v, &len, newval, sizeof(bool));
    return v;
}

// 触发内存整理
mallctl_cmd("arena.0.purge");
```

## 总结

系统工具模块为 Skynet 提供了高效、可靠的底层支持：

1. **内存管理**：
   - 精确的内存统计
   - 高效的 jemalloc 集成
   - 完善的调试支持

2. **同步原语**：
   - 高性能自旋锁
   - 跨平台原子操作
   - 优化的锁实现

3. **性能优化**：
   - 无锁设计
   - 缓存友好
   - 平台特定优化

这些工具构成了 Skynet 高性能的基础，确保了框架在高并发环境下的稳定运行。通过精心设计的内存管理和同步机制，Skynet 能够支持数千个服务的并发执行，同时保持较低的系统开销。

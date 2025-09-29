# Skynet C-Lua桥接层 - C服务模块 (C Service Modules)

## 模块概述

C服务模块是 Skynet 中用 C 语言编写的核心服务组件，作为 C 核心层和 Lua 框架层之间的重要桥梁。这些服务提供了高性能的底层功能，包括 Lua 服务容器、网络网关、日志记录和跨节点通信等关键能力。

### 模块定位
- **层次**：C-Lua 桥接层
- **作用**：提供核心服务实现，支撑 Lua 层功能
- **特点**：高性能、直接访问底层 API、内存安全

## 核心服务组件

### 1. SNLua 服务 (service_snlua.c)

#### 1.1 设计理念

SNLua（Skynet Lua）是 Skynet 中最重要的 C 服务，它为 Lua 代码提供运行容器。每个 Lua 服务都运行在独立的 SNLua 实例中，实现了服务隔离和独立性。

#### 1.2 核心数据结构

```c
struct snlua {
    lua_State * L;              // 主 Lua 状态机
    struct skynet_context * ctx;  // 关联的 skynet 上下文
    size_t mem;                 // 当前内存使用量
    size_t mem_report;          // 内存报警阈值
    size_t mem_limit;           // 内存限制
    lua_State * activeL;        // 当前活跃的 Lua 协程
    ATOM_INT trap;              // 信号陷阱（用于中断）
};
```

#### 1.3 初始化流程

```
snlua_create()
    ↓
创建 Lua 状态机 (lua_newstate)
    ↓
设置自定义内存分配器 (lalloc)
    ↓
launch_cb() [第一条消息触发]
    ↓
init_cb()
    ├── 加载标准库 (luaL_openlibs)
    ├── 注册 profile 库
    ├── 设置环境变量 (LUA_PATH, LUA_CPATH)
    ├── 加载 loader.lua
    └── 执行服务代码
```

#### 1.4 内存管理机制

```c
// 自定义内存分配器
static void *lalloc(void * ud, void *ptr, size_t osize, size_t nsize) {
    struct snlua *l = ud;
    size_t mem = l->mem;
    
    // 更新内存统计
    l->mem += nsize;
    if (ptr)
        l->mem -= osize;
    
    // 内存限制检查
    if (l->mem_limit != 0 && l->mem > l->mem_limit) {
        if (ptr == NULL || nsize > osize) {
            l->mem = mem;  // 回滚
            return NULL;    // 分配失败
        }
    }
    
    // 内存警告
    if (l->mem > l->mem_report) {
        l->mem_report *= 2;
        skynet_error(l->ctx, "Memory warning %.2f M", 
                    (float)l->mem / (1024 * 1024));
    }
    
    return skynet_lalloc(ptr, osize, nsize);
}
```

#### 1.5 协程性能分析

SNLua 实现了协程执行的性能分析功能：

```c
// 带性能分析的协程恢复
static int timing_resume(lua_State *L, int co_index, int n) {
    lua_State *co = lua_tothread(L, co_index);
    lua_Number start_time = 0;
    
    // 记录开始时间
    if (timing_enable(L, co_index, &start_time)) {
        start_time = get_time();
        lua_pushvalue(L, co_index);
        lua_pushnumber(L, start_time);
        lua_rawset(L, lua_upvalueindex(1));
    }
    
    // 恢复协程
    int r = auxresume(L, co, n);
    
    // 计算执行时间
    if (timing_enable(L, co_index, &start_time)) {
        double total_time = timing_total(L, co_index);
        double diff = diff_time(start_time);
        total_time += diff;
        
        lua_pushvalue(L, co_index);
        lua_pushnumber(L, total_time);
        lua_rawset(L, lua_upvalueindex(2));
    }
    
    return r;
}
```

#### 1.6 信号中断机制

```c
// 信号处理
void snlua_signal(struct snlua *l, int signal) {
    if (signal == 0) {
        // 设置中断陷阱
        if (ATOM_LOAD(&l->trap) == 0) {
            if (!ATOM_CAS(&l->trap, 0, 1))
                return;
            
            // 设置 Lua hook，每执行一条指令检查一次
            lua_sethook(l->activeL, signal_hook, LUA_MASKCOUNT, 1);
            ATOM_CAS(&l->trap, 1, -1);
        }
    } else if (signal == 1) {
        // 查询内存使用
        skynet_error(l->ctx, "Current Memory %.3fK", 
                    (float)l->mem / 1024);
    }
}

// Hook 函数
static void signal_hook(lua_State *L, lua_Debug *ar) {
    void *ud = NULL;
    lua_getallocf(L, &ud);
    struct snlua *l = (struct snlua *)ud;
    
    lua_sethook(L, NULL, 0, 0);  // 移除 hook
    if (ATOM_LOAD(&l->trap)) {
        ATOM_STORE(&l->trap, 0);
        luaL_error(L, "signal 0");  // 触发 Lua 错误
    }
}
```

### 2. Gate 服务 (service_gate.c)

#### 2.1 功能概述

Gate 服务是 Skynet 的网络网关服务，负责管理客户端连接，接收网络数据包，并将其转发给相应的代理服务。

#### 2.2 核心数据结构

```c
// 连接信息
struct connection {
    int id;                     // socket ID
    uint32_t agent;            // 代理服务句柄
    uint32_t client;           // 客户端服务句柄
    char remote_name[32];      // 远程地址
    struct databuffer buffer;   // 数据缓冲区
};

// Gate 服务结构
struct gate {
    struct skynet_context *ctx;
    int listen_id;              // 监听 socket
    uint32_t watchdog;          // watchdog 服务句柄
    uint32_t broker;            // broker 服务句柄
    int client_tag;             // 消息类型标记
    int header_size;            // 包头大小
    int max_connection;         // 最大连接数
    struct hashid hash;         // 连接 ID 映射
    struct connection *conn;    // 连接数组
    struct messagepool mp;      // 消息池
};
```

#### 2.3 数据转发机制

```c
static void _forward(struct gate *g, struct connection * c, int size) {
    struct skynet_context * ctx = g->ctx;
    int fd = c->id;
    
    // broker 模式：转发给 broker 服务
    if (g->broker) {
        void * temp = skynet_malloc(size);
        databuffer_read(&c->buffer, &g->mp, temp, size);
        skynet_send(ctx, 0, g->broker, 
                   g->client_tag | PTYPE_TAG_DONTCOPY, 
                   fd, temp, size);
        return;
    }
    
    // agent 模式：转发给指定 agent
    if (c->agent) {
        void * temp = skynet_malloc(size);
        databuffer_read(&c->buffer, &g->mp, temp, size);
        skynet_send(ctx, c->client, c->agent, 
                   g->client_tag | PTYPE_TAG_DONTCOPY, 
                   fd, temp, size);
    } 
    // watchdog 模式：转发给 watchdog
    else if (g->watchdog) {
        char * tmp = skynet_malloc(size + 32);
        int n = snprintf(tmp, 32, "%d data ", c->id);
        databuffer_read(&c->buffer, &g->mp, tmp+n, size);
        skynet_send(ctx, 0, g->watchdog, 
                   PTYPE_TEXT | PTYPE_TAG_DONTCOPY, 
                   fd, tmp, size + n);
    }
}
```

#### 2.4 消息分包处理

```c
static void dispatch_message(struct gate *g, struct connection *c, 
                            int id, void * data, int sz) {
    // 将数据推入缓冲区
    databuffer_push(&c->buffer, &g->mp, data, sz);
    
    // 循环处理完整的数据包
    for (;;) {
        // 读取包头，获取包大小
        int size = databuffer_readheader(&c->buffer, 
                                        &g->mp, 
                                        g->header_size);
        if (size < 0) {
            return;  // 数据不足
        }
        if (size > 0) {
            _forward(g, c, size);  // 转发完整包
            databuffer_reset(&c->buffer);
        }
    }
}
```

#### 2.5 控制命令处理

```c
static void _ctrl(struct gate * g, const void * msg, int sz) {
    // kick: 踢出连接
    if (memcmp(command, "kick", i) == 0) {
        int uid = strtol(command, NULL, 10);
        int id = hashid_lookup(&g->hash, uid);
        if (id >= 0) {
            skynet_socket_close(ctx, uid);
        }
    }
    
    // forward: 设置转发目标
    if (memcmp(command, "forward", i) == 0) {
        // 解析参数：fd agent_handle client_handle
        _forward_agent(g, id, agent_handle, client_handle);
    }
    
    // broker: 设置 broker 服务
    if (memcmp(command, "broker", i) == 0) {
        g->broker = skynet_queryname(ctx, command);
    }
    
    // start: 开始接收数据
    if (memcmp(command, "start", i) == 0) {
        int uid = strtol(command, NULL, 10);
        skynet_socket_start(ctx, uid);
    }
    
    // close: 关闭监听
    if (memcmp(command, "close", i) == 0) {
        if (g->listen_id >= 0) {
            skynet_socket_close(ctx, g->listen_id);
            g->listen_id = -1;
        }
    }
}
```

### 3. Logger 服务 (service_logger.c)

#### 3.1 功能设计

Logger 服务提供集中式的日志记录功能，支持日志文件管理、日志轮转和异步写入。

#### 3.2 核心结构

```c
struct logger {
    FILE * handle;              // 文件句柄
    char * filename;            // 日志文件名
    struct skynet_context * ctx;
    int close;                  // 关闭标志
};
```

#### 3.3 日志处理流程

```c
static int logger_cb(struct skynet_context * context, void *ud, 
                    int type, int session, uint32_t source, 
                    const void * msg, size_t sz) {
    struct logger * inst = ud;
    switch (type) {
    case PTYPE_SYSTEM:
        // 系统消息：重新打开日志文件（日志轮转）
        if (inst->filename) {
            FILE *f = freopen(inst->filename, "a", inst->handle);
            if (f == NULL) {
                skynet_error(context, "Open log file %s failed", 
                           inst->filename);
            }
        }
        break;
    case PTYPE_TEXT:
        // 文本日志：写入文件
        fprintf(inst->handle, "[%08x] ", source);
        fwrite(msg, sz, 1, inst->handle);
        fprintf(inst->handle, "\n");
        fflush(inst->handle);
        break;
    }
    return 0;
}
```

### 4. Harbor 服务 (service_harbor.c)

#### 4.1 功能概述

Harbor 服务负责处理跨节点通信，管理远程服务的消息转发和节点间连接。

#### 4.2 核心数据结构

```c
struct harbor {
    struct skynet_context *ctx;
    int id;                     // Harbor ID
    uint32_t slave;            // 从节点句柄
    struct hashmap * map;      // 远程服务映射
    struct queue * queue;      // 消息队列
};
```

#### 4.3 消息转发机制

```c
static int harbor_cb(struct skynet_context * context, void *ud,
                    int type, int session, uint32_t source, 
                    const void * msg, size_t sz) {
    struct harbor * h = ud;
    
    // 判断目标地址
    uint32_t destination = skynet_harbor_message_dest(msg);
    uint32_t harbor_id = destination >> HANDLE_REMOTE_SHIFT;
    
    if (harbor_id == h->id) {
        // 本地消息，直接处理
        return local_send(h, source, destination, msg, sz, type);
    } else {
        // 远程消息，转发给对应的 slave
        return remote_send(h, source, destination, msg, sz, type);
    }
}
```

## C 服务接口规范

### 1. 服务生命周期

所有 C 服务都遵循统一的生命周期模型：

```c
// 1. 创建函数
struct service_name * service_name_create(void);

// 2. 初始化函数
int service_name_init(struct service_name *, 
                     struct skynet_context *, 
                     const char * args);

// 3. 释放函数
void service_name_release(struct service_name *);

// 4. 信号处理函数（可选）
void service_name_signal(struct service_name *, int signal);
```

### 2. 消息回调接口

```c
typedef int (*skynet_cb)(struct skynet_context * context, 
                         void *ud, 
                         int type, 
                         int session, 
                         uint32_t source, 
                         const void * msg, 
                         size_t sz);
```

参数说明：
- `context`: 服务上下文
- `ud`: 用户数据（服务实例）
- `type`: 消息类型
- `session`: 会话 ID
- `source`: 源服务句柄
- `msg`: 消息内容
- `sz`: 消息大小

### 3. 模块导出

```c
// 服务模块必须导出的符号
void * service_name_create(void);
int service_name_init(void *, struct skynet_context *, const char *);
void service_name_release(void *);
void service_name_signal(void *, int);
```

## 内存管理

### 1. SNLua 内存控制

```c
// 内存限制设置
lua_pushinteger(L, limit);
lua_setfield(L, LUA_REGISTRYINDEX, "memlimit");

// 内存报警机制
#define MEMORY_WARNING_REPORT (1024 * 1024 * 32)  // 32MB

if (l->mem > l->mem_report) {
    l->mem_report *= 2;  // 指数增长
    skynet_error(l->ctx, "Memory warning %.2f M", 
                (float)l->mem / (1024 * 1024));
}
```

### 2. Gate 消息池

```c
// 消息池管理
struct messagepool {
    struct message_queue * freelist;
    // 批量分配，减少内存碎片
};

// 缓冲区管理
struct databuffer {
    int header;
    int offset;
    int size;
    struct message * head;
    struct message * tail;
};
```

## 性能优化

### 1. 协程调度优化

```c
// 活跃协程切换
static void switchL(lua_State *L, struct snlua *l) {
    l->activeL = L;
    if (ATOM_LOAD(&l->trap)) {
        // 仅在需要时设置 hook
        lua_sethook(L, signal_hook, LUA_MASKCOUNT, 1);
    }
}
```

### 2. 零拷贝转发

```c
// Gate 服务使用 PTYPE_TAG_DONTCOPY 避免拷贝
skynet_send(ctx, 0, g->broker, 
           g->client_tag | PTYPE_TAG_DONTCOPY, 
           fd, temp, size);
```

### 3. 批量处理

```c
// Gate 批量处理数据包
for (;;) {
    int size = databuffer_readheader(&c->buffer, 
                                    &g->mp, 
                                    g->header_size);
    if (size < 0) break;
    if (size > 0) {
        _forward(g, c, size);
        databuffer_reset(&c->buffer);
    }
}
```

## 错误处理

### 1. Lua 错误捕获

```c
// 错误追踪函数
static int traceback(lua_State *L) {
    const char *msg = lua_tostring(L, 1);
    if (msg)
        luaL_traceback(L, L, msg, 1);
    else
        lua_pushliteral(L, "(no error message)");
    return 1;
}

// 使用 pcall 保护调用
r = lua_pcall(L, 1, 0, 1);  // 1 是 traceback 函数索引
if (r != LUA_OK) {
    skynet_error(ctx, "lua error : %s", lua_tostring(L, -1));
    report_launcher_error(ctx);
}
```

### 2. 内存错误处理

```c
// 内存分配失败
if (l->mem_limit != 0 && l->mem > l->mem_limit) {
    if (ptr == NULL || nsize > osize) {
        l->mem = mem;  // 回滚统计
        return NULL;   // 触发 Lua 错误
    }
}
```

## 调试支持

### 1. 性能分析

```lua
-- Lua 中使用 profile 库
local profile = require "skynet.profile"

profile.start()  -- 开始分析
-- 执行代码
local time = profile.stop()  -- 获取执行时间
```

### 2. 内存查询

```c
// 通过信号查询内存
void snlua_signal(struct snlua *l, int signal) {
    if (signal == 1) {
        skynet_error(l->ctx, "Current Memory %.3fK", 
                    (float)l->mem / 1024);
    }
}
```

### 3. 日志跟踪

```c
// Gate 服务报告
static void _report(struct gate * g, const char * data, ...) {
    if (g->watchdog == 0) return;
    
    va_list ap;
    va_start(ap, data);
    char tmp[1024];
    int n = vsnprintf(tmp, sizeof(tmp), data, ap);
    va_end(ap);
    
    skynet_send(ctx, 0, g->watchdog, PTYPE_TEXT, 0, tmp, n);
}
```

## 架构图

### C 服务架构

```
┌─────────────────────────────────────────────┐
│              Lua Services                    │
├─────────────────────────────────────────────┤
│           C Service Layer                    │
│  ┌──────────┬──────────┬──────────┐        │
│  │  SNLua   │   Gate   │  Logger  │        │
│  │          │          │          │        │
│  │ Lua VM   │ Network  │   File   │        │
│  │ Manager  │ Gateway  │   I/O    │        │
│  └──────────┴──────────┴──────────┘        │
├─────────────────────────────────────────────┤
│          Skynet Core Framework              │
│     (Context, Message Queue, Timer)         │
└─────────────────────────────────────────────┘
```

### SNLua 内部结构

```
┌─────────────────────────────────────────────┐
│                SNLua Service                 │
├─────────────────────────────────────────────┤
│         Lua State Management                 │
│  ┌──────────────────────────────────┐       │
│  │   Main Lua State (L)             │       │
│  │   ├── Standard Libraries         │       │
│  │   ├── Skynet Libraries           │       │
│  │   └── User Service Code          │       │
│  └──────────────────────────────────┘       │
├─────────────────────────────────────────────┤
│         Memory Management                    │
│  ┌──────────────────────────────────┐       │
│  │   Custom Allocator (lalloc)      │       │
│  │   ├── Memory Tracking            │       │
│  │   ├── Memory Limit               │       │
│  │   └── Memory Warning             │       │
│  └──────────────────────────────────┘       │
├─────────────────────────────────────────────┤
│         Coroutine Management                 │
│  ┌──────────────────────────────────┐       │
│  │   Profile Support                │       │
│  │   ├── Timing                     │       │
│  │   ├── Hook Mechanism             │       │
│  │   └── Signal Handling            │       │
│  └──────────────────────────────────┘       │
└─────────────────────────────────────────────┘
```

## 总结

C 服务模块是 Skynet 的核心组件，提供了：

1. **SNLua**：完整的 Lua 运行环境，包括内存管理、性能分析和错误处理
2. **Gate**：高性能的网络网关，支持灵活的消息路由
3. **Logger**：可靠的日志服务，支持日志轮转
4. **Harbor**：跨节点通信支持

这些 C 服务通过直接调用 Skynet 核心 API，提供了高性能的底层功能，为上层 Lua 服务提供了坚实的基础。通过精心设计的内存管理、错误处理和性能优化，确保了整个系统的稳定性和高效性。
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
lua_newstate + 绑定自定义分配器 lalloc
    ↓
snlua_init(ctx, args)
    ├── 注册 launch_cb 作为服务回调
    └── 通过 REG 获得自身句柄并发送首条 PTYPE_TAG_DONTCOPY 消息
    ↓
launch_cb()   // 接收首条消息（type=0, session=0）
    ↓
init_cb()
    ├── 暂停 GC、加载标准库 (luaL_openlibs)
    ├── 注入 profile 库并替换 coroutine.resume/wrap
    ├── 设置 LUA_PATH/LUA_CPATH/LUA_SERVICE 等环境变量
    ├── 加载 lualoader（默认 ./lualib/loader.lua）
    └── 执行具体 Lua 服务代码
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
    skynet_error(l->ctx, "recv a signal %d", signal);
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

`_ctrl` 负责解析 `PTYPE_TEXT` 控制指令，核心命令包括：

- `kick <fd>`：根据 `hashid_lookup` 找到连接并关闭；未找到时忽略。
- `forward <fd> :<agent> :<client>`：通过 `strsep` 拆出参数，调用 `_forward_agent` 设置后续数据包的转发目标。
- `broker <name>`：用 `skynet_queryname` 将网关切换到 broker 模式。
- `start <fd>`：只有当连接已记录在 `hashid` 中时才调用 `skynet_socket_start` 启动读写。
- `close`：关闭监听 socket 并将 `listen_id` 重置为 `-1`。

无法识别的命令会通过 `skynet_error` 记录，方便定位配置错误。

### 3. Logger 服务 (service_logger.c)

#### 3.1 功能设计

Logger 服务提供集中式的日志记录功能，负责将 `PTYPE_TEXT` 文本落盘或输出到标准输出。写入流程为同步阻塞方式，同时支持通过 `PTYPE_SYSTEM` 消息触发重新打开文件，便于配合外部日志轮转。

#### 3.2 核心结构

```c
struct logger {
    FILE * handle;              // 当前写入目标（文件或 stdout）
    char * filename;            // 当写入文件时保存路径
    uint32_t starttime;         // 服务启动时间（用于格式化时间戳）
    int close;                  // 是否需要在释放时关闭句柄
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
        // 轮转：重新打开同一路径，追加写模式
        if (inst->filename) {
            inst->handle = freopen(inst->filename, "a", inst->handle);
        }
        break;
    case PTYPE_TEXT:
        if (inst->filename) {
            char tmp[SIZETIMEFMT];
            int csec = timestring(inst, tmp);
            fprintf(inst->handle, "%s.%02d ", tmp, csec);
        }
        fprintf(inst->handle, "[:%08x] ", source);
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
struct remote_message_header {
    uint32_t source;
    uint32_t destination;   // 高 8 位为消息类型
    uint32_t session;
};

struct harbor_msg {
    struct remote_message_header header;
    void * buffer;
    size_t size;
};

struct harbor_msg_queue {
    int size, head, tail;
    struct harbor_msg * data;
};

struct keyvalue {
    struct keyvalue * next;
    char key[GLOBALNAME_LENGTH];
    uint32_t hash;
    uint32_t value;                // 远程服务句柄
    struct harbor_msg_queue * queue; // 名称解析前的待发队列
};

struct hashmap {
    struct keyvalue *node[HASH_SIZE];
};

struct slave {
    int fd;
    struct harbor_msg_queue *queue;
    int status;            // STATUS_WAIT / STATUS_HANDSHAKE / STATUS_HEADER / STATUS_CONTENT / STATUS_DOWN
    int length;
    int read;
    uint8_t size[4];
    char * recv_buffer;
};

struct harbor {
    struct skynet_context *ctx;
    int id;
    uint32_t slave;              // 对应的 .cslave 句柄
    struct hashmap * map;        // 全局名字缓存
    struct slave s[REMOTE_MAX];  // 所有远程节点连接
};
```

`STATUS_*` 常量驱动收包状态机：握手阶段校验远端 Harbor ID，随后进入包头读取（4 字节大端长度）与包体读取；连接断开时释放队列并向 `watchdog`（即 `slave` 服务）报告。

#### 4.3 消息转发机制

`mainloop` 是 Harbor 的统一回调，处理三类消息：

```c
static int mainloop(struct skynet_context * context, void * ud,
                    int type, int session, uint32_t source,
                    const void * msg, size_t sz) {
    struct harbor * h = ud;
    switch (type) {
    case PTYPE_SOCKET:
        // SKYNET_SOCKET_TYPE_DATA -> push_socket_data(h, message);
        // SKYNET_SOCKET_TYPE_CLOSE/ERROR -> report_harbor_down
        // SKYNET_SOCKET_TYPE_ACCEPT -> 完成握手并派发缓存队列
        break;
    case PTYPE_HARBOR:
        harbor_command(h, msg, sz, session, source);   // N/S/A/Q 等控制指令
        break;
    case PTYPE_SYSTEM: {
        const struct remote_message *rmsg = msg;
        if (rmsg->destination.handle == 0)
            return remote_send_name(h, source, rmsg->destination.name,
                                    rmsg->type, session, rmsg->message, rmsg->sz);
        return remote_send_handle(h, source, rmsg->destination.handle,
                                  rmsg->type, session, rmsg->message, rmsg->sz);
    }
    default:
        // 未知类型：记录错误并回发 PTYPE_ERROR
        break;
    }
    return 0;
}
```

- **本地落地**：当 `push_socket_data` 解包后发现目标属于本地 Harbor，会调用 `forward_local_messsage`，直接把 payload 交给目标服务（携带 `PTYPE_TAG_DONTCOPY`）。
- **远程发送**：`remote_send_handle`/`remote_send_name` 在本地未命中句柄时，会把消息打包成 `remote_message_header + body`，通过 `send_remote` 写入对应 `slave` 的 fd；若连接未就绪则暂存于 `harbor_msg_queue`。
- **名字绑定**：`harbor_command` 处理 `N name handle` 指令，建立哈希表映射并触发挂起队列派发。

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

初始化过程中，模块通常会在 `*_init` 内调用：

```c
skynet_callback(ctx, instance, module_callback);
```

以便将消息循环挂接到 Skynet 内核。C 服务实现的业务逻辑基本都在该回调中完成。

## 内存管理

### 1. SNLua 内存控制

Lua 层通过 `skynet.memlimit` 设置限制，真实实现位于 `lualib/skynet.lua`：

```lua
function skynet.memlimit(bytes)
    debug.getregistry().memlimit = bytes
    skynet.memlimit = nil    -- 仅允许设置一次
end
```

`init_cb` 在加载完 `loader.lua` 后读取 `LUA_REGISTRYINDEX` 的 `memlimit` 字段，并将值写入 `snlua::mem_limit`，随后由 `lalloc` 在每次分配时做上限校验。内存报警由 `MEMORY_WARNING_REPORT (32MB)` 阈值驱动，每次触发翻倍，避免频繁输出。

### 2. Gate 消息池

```c
struct messagepool_list {
    struct messagepool_list *next;
    struct message pool[MESSAGEPOOL];
};

struct messagepool {
    struct messagepool_list * pool;
    struct message * freelist;
};

struct databuffer {
    int header;
    int offset;
    int size;
    struct message * head;
    struct message * tail;
};
```

`databuffer_push` 优先复用 `freelist` 中的 `struct message`，不足时才批量申请 `MESSAGEPOOL`（默认 1023）个节点，显著降低频繁 malloc 带来的碎片化。

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

# Skynet架构概览与设计模式

## 目录
- [1. 架构总览](#1-架构总览)
- [2. 多层架构设计](#2-多层架构设计)
- [3. 核心设计模式](#3-核心设计模式)
- [4. 并发模型设计](#4-并发模型设计)
- [5. 消息系统架构](#5-消息系统架构)
- [6. 分布式架构](#6-分布式架构)
- [7. 性能优化策略](#7-性能优化策略)
- [8. 架构决策与权衡](#8-架构决策与权衡)

## 1. 架构总览

### 1.1 系统定位

Skynet是一个基于Actor模型的轻量级游戏服务器框架，具有以下核心特征：

```
特征矩阵：
┌─────────────────┬──────────────────────────────┐
│ 架构特征        │ 实现方式                     │
├─────────────────┼──────────────────────────────┤
│ 并发模型        │ Actor模型 + 协程             │
│ 通信机制        │ 消息传递（无共享内存）       │
│ 语言栈          │ C核心 + Lua业务              │
│ 扩展性          │ 服务化 + 插件化              │
│ 分布式          │ Harbor(进程内) + Cluster(跨进程) │
│ 性能优化        │ 零拷贝 + 内存池 + 无锁设计   │
└─────────────────┴──────────────────────────────┘
```

### 1.2 整体架构图

```
┌──────────────────────────────────────────────────────────┐
│                     应用层 (Application)                  │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐  │
│  │ Game     │ │ Web      │ │ Chat     │ │ Custom   │  │
│  │ Logic    │ │ Service  │ │ Service  │ │ Service  │  │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘  │
└────────────────────────┬─────────────────────────────────┘
                         │
┌────────────────────────┴─────────────────────────────────┐
│                  系统服务层 (System Services)             │
│  ┌──────────────────────────────────────────────────┐  │
│  │ Bootstrap│Launcher│Console│Gate│Harbor│Cluster  │  │
│  └──────────────────────────────────────────────────┘  │
└────────────────────────┬─────────────────────────────────┘
                         │
┌────────────────────────┴─────────────────────────────────┐
│                   Lua框架层 (Lua Framework)              │
│  ┌──────────────────────────────────────────────────┐  │
│  │ skynet.lua │ manager │ socket │ cluster │ snax  │  │
│  └──────────────────────────────────────────────────┘  │
└────────────────────────┬─────────────────────────────────┘
                         │
┌────────────────────────┴─────────────────────────────────┐
│              C-Lua桥接层 (Bridge Layer)                  │
│  ┌──────────────────────────────────────────────────┐  │
│  │ lua-skynet.c │ lua-socket.c │ lua-cluster.c     │  │
│  └──────────────────────────────────────────────────┘  │
└────────────────────────┬─────────────────────────────────┘
                         │
┌────────────────────────┴─────────────────────────────────┐
│                    C核心层 (C Core)                      │
│  ┌──────────────────────────────────────────────────┐  │
│  │ Server │ MQ │ Timer │ Socket │ Harbor │ Monitor │  │
│  └──────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

## 2. 多层架构设计

### 2.1 分层原则

```lua
-- 分层职责定义
LAYER_RESPONSIBILITIES = {
    ["C Core"] = {
        "内存管理",
        "线程调度",
        "消息队列",
        "网络I/O",
        "定时器",
        "监控统计"
    },
    ["Bridge"] = {
        "C-Lua接口",
        "类型转换",
        "内存安全",
        "API封装"
    },
    ["Lua Framework"] = {
        "服务框架",
        "协程管理",
        "RPC机制",
        "协议处理"
    },
    ["System Services"] = {
        "服务启动",
        "服务管理",
        "网关服务",
        "分布式协调"
    },
    ["Application"] = {
        "业务逻辑",
        "游戏玩法",
        "数据处理"
    }
}
```

### 2.2 层间交互模式

```c
// C层向上提供的核心API
struct skynet_context;

// 服务管理
struct skynet_context * skynet_context_new(const char * name, const char * parm);
int skynet_context_push(uint32_t handle, struct skynet_message *message);
void skynet_context_release(struct skynet_context *ctx);

// 消息发送
int skynet_send(struct skynet_context * context, uint32_t source, 
                uint32_t destination, int type, int session, 
                void * data, size_t sz);

// 定时器
int skynet_timeout(uint32_t handle, int time, int session);

// 网络
int skynet_socket_listen(struct skynet_context *ctx, 
                        const char *host, int port, int backlog);
```

### 2.3 数据流向

```
用户请求 → Gate Service → Business Service → Database Service → Response
     ↓          ↓              ↓                    ↓              ↓
  Socket    Message Queue   Coroutine          ShareData      Socket
  Server     (C Core)      (Lua Layer)        (Lua Layer)     Server
```

## 3. 核心设计模式

### 3.1 Actor模型

```lua
-- Actor模型实现
Actor = {
    -- 1. 封装状态
    state = {},
    
    -- 2. 消息处理
    dispatch = function(session, source, cmd, ...)
        -- 每个Actor独立处理消息
        -- 无共享状态，通过消息通信
    end,
    
    -- 3. 异步通信
    send = function(addr, ...)
        skynet.send(addr, "lua", ...)
    end,
    
    -- 4. 并发执行
    -- 多个Actor可以同时运行，由框架调度
}
```

**Actor模型特点：**

```
┌─────────────────────────────────────┐
│            Actor Properties          │
├─────────────────────────────────────┤
│ • 状态封装 (State Encapsulation)    │
│ • 消息驱动 (Message Driven)         │
│ • 位置透明 (Location Transparency)  │
│ • 并发执行 (Concurrent Execution)   │
│ • 故障隔离 (Failure Isolation)      │
└─────────────────────────────────────┘
```

### 3.2 生产者-消费者模式

```c
// 消息队列实现
struct message_queue {
    struct spinlock lock;      // 自旋锁
    uint32_t handle;           // 服务句柄
    int cap;                   // 容量
    int head;                  // 队头
    int tail;                  // 队尾
    int release;              // 释放标记
    int in_global;            // 全局队列标记
    int overload;             // 过载计数
    int overload_threshold;   // 过载阈值
    struct skynet_message *queue;  // 消息数组
    struct message_queue *next;    // 链表指针
};

// 生产者：推送消息
void skynet_mq_push(struct message_queue *q, struct skynet_message *message) {
    assert(message);
    SPIN_LOCK(q)
    q->queue[q->tail] = *message;
    if (++ q->tail >= q->cap) {
        q->tail = 0;
    }
    if (q->head == q->tail) {
        expand_queue(q);
    }
    if (q->in_global == 0) {
        q->in_global = MQ_IN_GLOBAL;
        skynet_globalmq_push(q);
    }
    SPIN_UNLOCK(q)
}

// 消费者：弹出消息
int skynet_mq_pop(struct message_queue *q, struct skynet_message *message) {
    int ret = 1;
    SPIN_LOCK(q)
    if (q->head != q->tail) {
        *message = q->queue[q->head];
        ret = 0;
        if ( ++ q->head >= q->cap) {
            q->head = 0;
        }
    }
    SPIN_UNLOCK(q)
    return ret;
}
```

### 3.3 观察者模式

```lua
-- 广播/订阅机制
local multicast = require "skynet.multicast"

-- 创建频道（Subject）
local channel = multicast.new()

-- 订阅（Observer注册）
channel:subscribe()

-- 发布（通知所有Observer）
channel:publish(...)

-- 实现原理
MulticastChannel = {
    subscribers = {},  -- 观察者列表
    
    subscribe = function(self, addr)
        self.subscribers[addr] = true
    end,
    
    publish = function(self, ...)
        for addr in pairs(self.subscribers) do
            skynet.send(addr, "multicast", ...)
        end
    end
}
```

### 3.4 代理模式

```lua
-- Cluster代理实现
function cluster.proxy(node, name)
    local fullname = node .. "." .. name
    local p = proxy[fullname]
    if p then
        return p
    end
    
    -- 创建代理服务
    p = skynet.newservice("clusterproxy", node, name)
    proxy[fullname] = p
    
    return p  -- 返回代理，透明访问远程服务
end

-- 使用代理
local proxy = cluster.proxy("node1", "gameserver")
skynet.call(proxy, "lua", "battle", ...)  -- 像本地调用一样
```

### 3.5 单例模式

```lua
-- 唯一服务实现
local skynet = require "skynet.manager"

function skynet.uniqueservice(global, ...)
    if global == true then
        return assert(skynet.call(".service", "lua", 
                     "GLAUNCH", ...))
    else
        return assert(skynet.call(".service", "lua", 
                     "LAUNCH", global, ...))
    end
end

-- 保证全局只有一个实例
local launcher = skynet.uniqueservice("launcher")
```

### 3.6 工厂模式

```lua
-- 服务创建工厂
ServiceFactory = {
    -- 服务创建映射表
    creators = {
        ["snlua"] = function(param)
            return snlua.create(param)
        end,
        ["gate"] = function(param) 
            return gate.create(param)
        end,
        ["harbor"] = function(param)
            return harbor.create(param)
        end
    },
    
    -- 工厂方法
    create = function(name, param)
        local creator = creators[name]
        if creator then
            return creator(param)
        end
        error("Unknown service type: " .. name)
    end
}
```

### 3.7 策略模式

```lua
-- 消息分发策略
local PROTOCOL = {
    -- Lua消息处理策略
    [PTYPE_LUA] = {
        unpack = skynet.unpack,
        dispatch = function(session, address, ...)
            -- Lua消息处理逻辑
        end
    },
    
    -- 网络消息处理策略
    [PTYPE_SOCKET] = {
        unpack = socket.unpack,
        dispatch = function(fd, message, ...)
            -- Socket消息处理逻辑
        end
    },
    
    -- 集群消息处理策略
    [PTYPE_CLUSTER] = {
        unpack = cluster.unpack,
        dispatch = function(sender, ...)
            -- Cluster消息处理逻辑
        end
    }
}

-- 根据消息类型选择策略
function dispatch_message(type, ...)
    local protocol = PROTOCOL[type]
    if protocol then
        protocol.dispatch(protocol.unpack(...))
    end
end
```

### 3.8 责任链模式

```lua
-- 中间件链式处理
MiddlewareChain = {
    middlewares = {},
    
    use = function(self, middleware)
        table.insert(self.middlewares, middleware)
    end,
    
    execute = function(self, context)
        local index = 1
        local function next()
            if index <= #self.middlewares then
                local middleware = self.middlewares[index]
                index = index + 1
                middleware(context, next)
            end
        end
        next()
    end
}

-- 使用示例
chain:use(function(ctx, next)
    -- 认证中间件
    if not ctx.authenticated then
        error("Not authenticated")
    end
    next()
end)

chain:use(function(ctx, next)
    -- 日志中间件
    log("Processing request", ctx)
    next()
end)
```

## 4. 并发模型设计

### 4.1 线程模型

```c
// 工作线程结构
struct worker_parm {
    struct monitor *m;      // 监控器
    int id;                // 线程ID
    int weight;            // 权重
};

static void * thread_worker(void *p) {
    struct worker_parm *wp = p;
    int id = wp->id;
    int weight = wp->weight;
    struct monitor *m = wp->m;
    struct skynet_monitor *sm = m->m[id];
    skynet_initthread(THREAD_WORKER);
    
    // 消息循环
    struct message_queue * q = NULL;
    while (!m->quit) {
        q = skynet_context_message_dispatch(sm, q, weight);
        if (q == NULL) {
            if (pthread_mutex_lock(&m->mutex) == 0) {
                ++ m->sleep;
                // 休眠等待
                if (!m->quit)
                    pthread_cond_wait(&m->cond, &m->mutex);
                -- m->sleep;
                if (pthread_mutex_unlock(&m->mutex)) {
                    fprintf(stderr, "unlock mutex error");
                    exit(1);
                }
            }
        }
    }
    return NULL;
}
```

**线程模型特点：**

```
┌──────────────────────────────────────┐
│          Thread Model                 │
├──────────────────────────────────────┤
│ • Monitor Thread (1)                 │
│   - 监控所有工作线程                 │
│   - 检测死锁和无限循环               │
├──────────────────────────────────────┤
│ • Timer Thread (1)                   │
│   - 管理定时器                       │
│   - 触发超时事件                     │
├──────────────────────────────────────┤
│ • Socket Thread (1)                  │
│   - 处理网络I/O                      │
│   - epoll/kqueue事件循环             │
├──────────────────────────────────────┤
│ • Worker Threads (N)                 │
│   - 执行服务逻辑                     │
│   - 消息分发和处理                   │
└──────────────────────────────────────┘
```

### 4.2 协程模型

```lua
-- 协程池实现
local coroutine_pool = {}
local coroutine_yield = coroutine.yield

function co_create(f)
    local co = table.remove(coroutine_pool)
    if co == nil then
        co = coroutine.create(function(...)
            local ret = {f(...)}
            while true do
                f = nil
                coroutine_pool[#coroutine_pool+1] = co
                f = coroutine_yield("EXIT", table.unpack(ret))
                ret = {f(coroutine_yield())}
            end
        end)
    else
        coroutine.resume(co, f)
    end
    return co
end
```

### 4.3 无锁设计

```c
// 自旋锁实现
struct spinlock {
    int lock;
};

static inline void
spinlock_init(struct spinlock *lock) {
    lock->lock = 0;
}

static inline void
spinlock_lock(struct spinlock *lock) {
    while (__sync_lock_test_and_set(&lock->lock,1)) {}
}

static inline int
spinlock_trylock(struct spinlock *lock) {
    return __sync_lock_test_and_set(&lock->lock,1) == 0;
}

static inline void
spinlock_unlock(struct spinlock *lock) {
    __sync_lock_release(&lock->lock);
}

// CAS操作
#define ATOM_CAS(ptr, oval, nval) \
    __sync_bool_compare_and_swap(ptr, oval, nval)

#define ATOM_INC(ptr) \
    __sync_add_and_fetch(ptr, 1)

#define ATOM_DEC(ptr) \
    __sync_sub_and_fetch(ptr, 1)
```

## 5. 消息系统架构

### 5.1 消息类型体系

```c
// 消息类型定义
#define PTYPE_TEXT 0       // 文本（已废弃）
#define PTYPE_RESPONSE 1   // 响应
#define PTYPE_MULTICAST 2  // 广播
#define PTYPE_CLIENT 3     // 客户端
#define PTYPE_SYSTEM 4     // 系统
#define PTYPE_HARBOR 5     // Harbor
#define PTYPE_SOCKET 6     // Socket
#define PTYPE_ERROR 7      // 错误
#define PTYPE_QUEUE 8      // 队列
#define PTYPE_DEBUG 9      // 调试
#define PTYPE_LUA 10       // Lua
#define PTYPE_SNAX 11      // SNAX

// 消息结构
struct skynet_message {
    uint32_t source;       // 源服务
    int session;          // 会话ID
    void * data;          // 数据指针
    size_t sz;           // 数据大小
};
```

### 5.2 消息路由

```
消息路由流程：
┌──────────┐     ┌──────────┐     ┌──────────┐
│  发送方   │────>│  消息队列  │────>│  接收方   │
└──────────┘     └──────────┘     └──────────┘
     │                 │                 │
     ↓                 ↓                 ↓
  打包消息         入队/调度         解包处理

跨节点路由：
┌──────────┐     ┌──────────┐     ┌──────────┐
│  本地服务  │────>│  Harbor   │────>│  远程服务  │
└──────────┘     └──────────┘     └──────────┘
                       │
                       ↓
                  地址转换/转发
```

### 5.3 零拷贝设计

```lua
-- 消息共享机制
local mc = require "skynet.multicast.core"

-- 创建共享消息
local pack = mc.pack(data)

-- 绑定引用计数
mc.bind(pack, count)

-- 多个接收者共享同一消息内存
for receiver in receivers do
    -- 只传递指针，不复制数据
    skynet.redirect(receiver, source, "multicast", channel, pack)
end

-- 引用计数归零时自动释放
mc.close(pack)
```

## 6. 分布式架构

### 6.1 分布式方案对比

```
┌─────────────┬──────────────┬──────────────────────────┐
│   方案       │   Harbor     │        Cluster           │
├─────────────┼──────────────┼──────────────────────────┤
│ 通信方式     │ 进程内通信    │ TCP/IP                   │
│ 节点限制     │ 255个        │ 无限制                    │
│ 地址空间     │ 共享         │ 独立                      │
│ 性能        │ 高           │ 中                        │
│ 容错性      │ 低           │ 高                        │
│ 使用场景     │ 单进程多节点  │ 多进程分布式              │
└─────────────┴──────────────┴──────────────────────────┘
```

### 6.2 Harbor架构

```lua
-- Harbor主从架构
HARBOR_ARCHITECTURE = {
    master = {
        role = "协调者",
        responsibilities = {
            "全局名字注册",
            "节点管理",
            "消息转发"
        }
    },
    slave = {
        role = "工作节点",
        responsibilities = {
            "本地服务管理",
            "消息路由",
            "与master同步"
        }
    }
}

-- 地址格式：harbor_id(8bit) + local_id(24bit)
function make_address(harbor_id, local_id)
    return (harbor_id << 24) | local_id
end
```

### 6.3 Cluster架构

```lua
-- Cluster组件架构
CLUSTER_COMPONENTS = {
    clusterd = {
        role = "管理服务",
        functions = {
            "节点连接管理",
            "服务注册",
            "代理创建"
        }
    },
    clusteragent = {
        role = "请求处理",
        functions = {
            "接收远程请求",
            "大消息处理",
            "响应返回"
        }
    },
    clustersender = {
        role = "发送代理",
        functions = {
            "请求发送",
            "连接维护",
            "会话管理"
        }
    },
    clusterproxy = {
        role = "服务代理",
        functions = {
            "透明代理",
            "协议转换",
            "地址映射"
        }
    }
}
```

## 7. 性能优化策略

### 7.1 内存优化

```c
// 内存池实现
struct memory_pool {
    struct block *freelist;
    size_t block_size;
    int total_blocks;
    int free_blocks;
};

// Jemalloc集成
void * 
skynet_malloc(size_t size) {
    void* ptr = je_malloc(size + PREFIX_SIZE);
    if(!ptr) skynet_error(NULL, "malloc error");
    return fill_prefix(ptr);
}

void 
skynet_free(void *ptr) {
    if (ptr == NULL) return;
    void* rawptr = clean_prefix(ptr);
    je_free(rawptr);
}
```

### 7.2 网络优化

```c
// 批量处理
static int 
forward_message_tcp(struct socket_server *ss, 
                   struct socket *s, 
                   struct socket_message *result) {
    int sz = s->p.size;
    char * buffer = MALLOC(sz);
    int n = (int)read(s->fd, buffer, sz);
    
    if (n<0) {
        FREE(buffer);
        switch(errno) {
        case EINTR:
            break;
        case AGAIN_WOULDBLOCK:
            fprintf(stderr, "socket-server: EAGAIN capture");
            break;
        default:
            return -1;
        }
        return 0;
    }
    
    // 批量处理数据
    if (n == sz) {
        s->p.buffer = buffer;
        return filter_data(s, result);
    }
    // ...
}
```

### 7.3 调度优化

```lua
-- 服务权重调度
local function weighted_dispatch()
    local services = {...}
    local weights = {10, 5, 3, 1}  -- 权重分配
    
    while true do
        for i, service in ipairs(services) do
            for j = 1, weights[i] do
                dispatch_one_message(service)
            end
        end
    end
end
```

### 7.4 并发优化

```lua
-- 批量并发处理
local function batch_process(tasks)
    local cos = {}
    for i, task in ipairs(tasks) do
        cos[i] = skynet.fork(function()
            return process_task(task)
        end)
    end
    
    -- 等待所有任务完成
    local results = {}
    for i, co in ipairs(cos) do
        results[i] = skynet.wait(co)
    end
    return results
end
```

## 8. 架构决策与权衡

### 8.1 设计决策

```lua
DESIGN_DECISIONS = {
    {
        decision = "使用Actor模型",
        pros = {
            "天然并发性",
            "故障隔离",
            "易于理解"
        },
        cons = {
            "消息传递开销",
            "调试困难"
        },
        rationale = "游戏服务器的业务逻辑天然适合Actor模型"
    },
    {
        decision = "C核心 + Lua业务",
        pros = {
            "高性能核心",
            "灵活的业务开发",
            "热更新支持"
        },
        cons = {
            "语言边界开销",
            "调试复杂性"
        },
        rationale = "平衡性能和开发效率"
    },
    {
        decision = "自研消息队列",
        pros = {
            "完全控制",
            "针对性优化",
            "零拷贝设计"
        },
        cons = {
            "维护成本",
            "生态较小"
        },
        rationale = "游戏服务器的特殊需求"
    }
}
```

### 8.2 架构权衡

```
性能 vs 易用性：
┌────────────────────────────────────┐
│ • C层追求极致性能                  │
│ • Lua层追求开发效率                │
│ • 通过分层设计平衡两者              │
└────────────────────────────────────┘

扩展性 vs 复杂性：
┌────────────────────────────────────┐
│ • Harbor简单但受限                 │
│ • Cluster灵活但复杂                │
│ • 提供两种方案供选择                │
└────────────────────────────────────┘

一致性 vs 性能：
┌────────────────────────────────────┐
│ • 最终一致性模型                   │
│ • 异步消息传递                     │
│ • 牺牲强一致性换取高吞吐            │
└────────────────────────────────────┘
```

### 8.3 最佳实践

```lua
-- 1. 服务设计原则
SERVICE_PRINCIPLES = {
    "单一职责：每个服务只做一件事",
    "无状态化：尽可能设计无状态服务",
    "异步优先：使用异步调用而非同步阻塞",
    "批量处理：合并小消息为批量操作",
    "缓存策略：合理使用本地缓存"
}

-- 2. 性能优化原则
PERFORMANCE_PRINCIPLES = {
    "测量先行：先分析瓶颈再优化",
    "避免热点：分散负载到多个服务",
    "减少拷贝：使用零拷贝和引用传递",
    "池化资源：连接池、协程池、内存池",
    "异步I/O：避免阻塞操作"
}

-- 3. 容错设计原则
FAULT_TOLERANCE = {
    "服务隔离：故障不扩散",
    "超时控制：设置合理超时",
    "重试机制：幂等操作可重试",
    "降级策略：优雅降级",
    "监控告警：及时发现问题"
}
```

### 8.4 架构演进方向

```
未来演进路线：
┌──────────────────────────────────────┐
│ 1. 容器化部署                        │
│    - Docker/K8s支持                  │
│    - 自动扩缩容                      │
├──────────────────────────────────────┤
│ 2. 服务网格                          │
│    - 服务发现                        │
│    - 负载均衡                        │
│    - 熔断限流                        │
├──────────────────────────────────────┤
│ 3. 可观测性                          │
│    - 分布式追踪                      │
│    - 指标采集                        │
│    - 日志聚合                        │
├──────────────────────────────────────┤
│ 4. 云原生                            │
│    - 无服务器架构                    │
│    - 边缘计算                        │
│    - 多云部署                        │
└──────────────────────────────────────┘
```

## 总结

Skynet通过精心设计的多层架构、Actor并发模型、高效的消息系统和灵活的分布式方案，构建了一个高性能、可扩展的游戏服务器框架。其架构设计充分体现了：

1. **分层解耦**：清晰的层次结构，各层职责明确
2. **模式运用**：恰当运用设计模式解决具体问题
3. **性能优先**：从底层到应用层的全方位优化
4. **扩展灵活**：支持多种部署和扩展方案
5. **实用主义**：根据实际需求做出合理权衡

这些设计理念和实现方式，使Skynet成为游戏服务器开发的优秀选择，同时也为其他高并发服务提供了参考价值。
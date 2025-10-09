# Skynet 服务管理模块技术文档

## 目录

1. [模块概述](#1-模块概述)
2. [skynet_server.c 深度分析](#2-skynet_serverc-深度分析)
3. [skynet_handle.c 深度分析](#3-skynet_handlec-深度分析)
4. [skynet_module.c 深度分析](#4-skynet_modulec-深度分析)
5. [设计要点](#5-设计要点)

## 1. 模块概述

### 1.1 Actor 模型在 Skynet 中的实现

Skynet 的服务管理模块是整个框架的核心，它实现了 Actor 并发模型。每个服务（Actor）具有以下特征：

- **独立状态**：每个服务拥有独立的内存空间和状态（`skynet_context`）
- **消息驱动**：服务之间通过异步消息传递进行通信
- **并发安全**：无共享内存，避免了传统多线程编程的竞态条件
- **位置透明**：通过句柄系统，服务可以透明地进行本地或远程通信

```mermaid
graph TD
    A[服务A<br/>skynet_context] -->|消息| MQ[消息队列]
    B[服务B<br/>skynet_context] -->|消息| MQ
    C[服务C<br/>skynet_context] -->|消息| MQ
    MQ -->|分发| A
    MQ -->|分发| B
    MQ -->|分发| C
    
    subgraph "Actor 模型特征"
        D[独立状态]
        E[消息通信]
        F[无共享内存]
    end
```

### 1.2 三个子模块的协作机制

```mermaid
graph LR
    subgraph "skynet_module.c"
        M1[模块加载器]
        M2[动态库管理]
        M3[函数符号绑定]
    end
    
    subgraph "skynet_server.c"
        S1[服务上下文]
        S2[消息分发]
        S3[生命周期管理]
    end
    
    subgraph "skynet_handle.c"
        H1[句柄分配]
        H2[名字服务]
        H3[句柄查找]
    end
    
    M1 --> S1
    S1 --> H1
    H3 --> S2
    S3 --> M3
```

**协作流程**：
1. `skynet_module.c` 负责加载动态库（.so 文件），获取服务的创建、初始化、释放和信号处理函数
2. `skynet_server.c` 调用模块接口创建服务实例，管理服务上下文和消息分发
3. `skynet_handle.c` 为每个服务分配唯一标识符（handle），并提供名字服务功能

### 1.3 服务的概念和生命周期

```mermaid
stateDiagram-v2
    [*] --> Loading: skynet_context_new()
    Loading --> Creating: 加载模块(.so)
    Creating --> Initializing: 创建实例
    Initializing --> Running: 初始化成功
    Initializing --> Failed: 初始化失败
    Running --> Terminating: skynet_handle_retire()
    Terminating --> [*]: 释放资源
    Failed --> [*]: 清理资源
```

### 1.4 与其他模块的交互

```c
// 与消息队列模块的交互
#include "skynet_mq.h"         // 消息队列管理
// 与定时器模块的交互  
#include "skynet_timer.h"      // 定时服务
// 与网络模块的交互
#include "skynet_harbor.h"     // 分布式节点通信
// 与监控模块的交互
#include "skynet_monitor.h"    // 服务监控
```

## 2. skynet_server.c 深度分析

### 2.1 struct skynet_context 数据结构详解

```c
struct skynet_context {
    void * instance;                 // 服务实例指针（由 module->create() 创建）
    struct skynet_module * mod;      // 指向服务模块的指针
    void * cb_ud;                    // 回调函数的用户数据
    skynet_cb cb;                    // 消息回调函数
    struct message_queue *queue;     // 服务专属的消息队列
    ATOM_POINTER logfile;           // 日志文件句柄（原子指针）
    uint64_t cpu_cost;              // CPU 消耗时间（微秒）
    uint64_t cpu_start;             // CPU 开始时间（微秒）
    char result[32];                // 命令执行结果缓冲区
    uint32_t handle;                // 服务的唯一标识符
    int session_id;                 // 会话 ID 生成器
    ATOM_INT ref;                   // 引用计数（原子操作）
    size_t message_count;           // 已处理消息计数
    bool init;                      // 初始化标志
    bool endless;                   // 消息阻塞标志
    bool profile;                   // 性能分析开关
    CHECKCALLING_DECL              // 调用检查（调试用）
};
```

**字段含义详解**：

| 字段 | 类型 | 说明 |
|------|------|------|
| `instance` | `void*` | 存储服务的实际数据，每个服务类型可以有多个实例 |
| `mod` | `skynet_module*` | 指向模块结构，包含 create/init/release/signal 函数指针 |
| `cb` / `cb_ud` | 函数指针/数据 | 消息处理回调函数及其用户数据 |
| `queue` | `message_queue*` | 服务独占的次级消息队列 |
| `handle` | `uint32_t` | 全局唯一的服务标识符 |
| `ref` | `ATOM_INT` | 原子引用计数，为 0 时释放内存 |
| `session_id` | `int` | 用于匹配请求和响应的会话标识 |

### 2.2 服务创建：skynet_context_new 完整流程

> 相关源码：`skynet-src/skynet_server.c:130`

```c
struct skynet_context * 
skynet_context_new(const char * name, const char *param) {
    // 第一步：查询模块
    struct skynet_module * mod = skynet_module_query(name);
    if (mod == NULL) return NULL;

    // 第二步：创建服务实例
    void *inst = skynet_module_instance_create(mod);
    if (inst == NULL) return NULL;
    
    // 第三步：分配上下文内存
    struct skynet_context * ctx = skynet_malloc(sizeof(*ctx));
    CHECKCALLING_INIT(ctx)
    
    // 第四步：初始化上下文字段
    ctx->mod = mod;
    ctx->instance = inst;
    ATOM_INIT(&ctx->ref , 2);      // 引用计数初始为 2
    ctx->cb = NULL;
    ctx->cb_ud = NULL;
    ctx->session_id = 0;
    ATOM_INIT(&ctx->logfile, (uintptr_t)NULL);
    ctx->init = false;
    ctx->endless = false;
    ctx->cpu_cost = 0;
    ctx->cpu_start = 0;
    ctx->message_count = 0;
    ctx->profile = G_NODE.profile;

    // 第五步：注册句柄
    ctx->handle = 0;  // 先设为 0，避免 skynet_handle_retireall 读取未初始化句柄
    ctx->handle = skynet_handle_register(ctx);
    
    // 第六步：创建消息队列
    struct message_queue * queue = ctx->queue = skynet_mq_create(ctx->handle);
    
    // 第七步：增加全局服务计数（init 可能用到 handle，因此放到后面）
    context_inc();

    // 第八步：调用服务初始化函数
    CHECKCALLING_BEGIN(ctx)
    int r = skynet_module_instance_init(mod, inst, ctx, param);
    CHECKCALLING_END(ctx)
    
    // 第九步：处理初始化结果
    if (r == 0) {
        struct skynet_context * ret = skynet_context_release(ctx);
        if (ret) {
            ctx->init = true;
        }
        skynet_globalmq_push(queue);
        if (ret) {
            skynet_error(ret, "LAUNCH %s %s", name, param ? param : "");
        }
        return ret;
    } else {
        // 初始化失败，清理资源
        skynet_error(ctx, "error: launch %s FAILED", name);
        uint32_t handle = ctx->handle;
        skynet_context_release(ctx);
        skynet_handle_retire(handle);
        struct drop_t d = { handle };
        skynet_mq_release(queue, drop_message, &d);
        return NULL;
    }
}
```

**创建流程图**：

```mermaid
flowchart TD
    A[开始] --> B[查询模块<br/>skynet_module_query]
    B --> C{模块存在?}
    C -->|否| D[返回 NULL]
    C -->|是| E[创建实例<br/>module->create]
    E --> F{实例创建成功?}
    F -->|否| D
    F -->|是| G[分配上下文内存]
    G --> H[初始化字段]
    H --> I[注册句柄<br/>skynet_handle_register]
    I --> J[创建消息队列]
    J --> K[调用 init 函数]
    K --> L{初始化成功?}
    L -->|是| M[加入全局队列]
    L -->|否| N[清理资源]
    M --> O[返回上下文]
    N --> D
```

### 2.3 消息分发：dispatch_message 机制

> 相关源码：`skynet-src/skynet_server.c:284`

```c
static void
dispatch_message(struct skynet_context *ctx, struct skynet_message *msg) {
    assert(ctx->init);  // 确保服务已初始化
    
    // 设置线程局部存储，存储当前服务句柄
    pthread_setspecific(G_NODE.handle_key, (void *)(uintptr_t)(ctx->handle));
    
    // 解析消息类型和大小
    int type = msg->sz >> MESSAGE_TYPE_SHIFT;      // 高位存储类型
    size_t sz = msg->sz & MESSAGE_TYPE_MASK;       // 低位存储大小
    
    // 日志记录
    FILE *f = (FILE *)ATOM_LOAD(&ctx->logfile);
    if (f) {
        skynet_log_output(f, msg->source, type, msg->session, msg->data, sz);
    }
    
    ++ctx->message_count;
    
    // 性能分析
    int reserve_msg;
    if (ctx->profile) {
        ctx->cpu_start = skynet_thread_time();
        reserve_msg = ctx->cb(ctx, ctx->cb_ud, type, msg->session, 
                             msg->source, msg->data, sz);
        uint64_t cost_time = skynet_thread_time() - ctx->cpu_start;
        ctx->cpu_cost += cost_time;
    } else {
        reserve_msg = ctx->cb(ctx, ctx->cb_ud, type, msg->session,
                             msg->source, msg->data, sz);
    }
    
    // 如果回调返回 0，释放消息数据
    if (!reserve_msg) {
        skynet_free(msg->data);
    }
}
```

**消息分发流程**：

1. **类型解析**：从 `msg->sz` 中提取消息类型和实际大小
2. **日志记录**：如果开启日志，记录消息详情
3. **性能统计**：如果开启性能分析，记录处理时间
4. **回调处理**：调用服务注册的回调函数处理消息
5. **内存管理**：根据回调返回值决定是否释放消息数据

> 监控点：工作线程调度消息时会在分发前/后触发 `skynet_monitor_trigger`（见 `skynet-src/skynet_server.c:358` 与 `skynet-src/skynet_server.c:366`，位于 `skynet_context_message_dispatch` 内），用于检测卡顿或长耗时处理。

### 2.4 命令系统：command_func 数组和各命令实现

> 相关源码：`skynet-src/skynet_server.c:421`、`skynet-src/skynet_server.c:680`

```c
static struct command_func cmd_funcs[] = {
    { "TIMEOUT", cmd_timeout },      // 设置定时器
    { "REG", cmd_reg },              // 注册服务名
    { "QUERY", cmd_query },          // 查询服务
    { "NAME", cmd_name },            // 命名服务
    { "EXIT", cmd_exit },            // 退出服务
    { "KILL", cmd_kill },            // 强制终止服务
    { "LAUNCH", cmd_launch },        // 启动新服务
    { "GETENV", cmd_getenv },        // 获取环境变量
    { "SETENV", cmd_setenv },        // 设置环境变量
    { "STARTTIME", cmd_starttime },  // 获取启动时间
    { "ABORT", cmd_abort },          // 终止所有服务
    { "MONITOR", cmd_monitor },      // 设置监控服务
    { "STAT", cmd_stat },            // 获取统计信息
    { "LOGON", cmd_logon },          // 开启日志
    { "LOGOFF", cmd_logoff },        // 关闭日志
    { "SIGNAL", cmd_signal },        // 发送信号
    { NULL, NULL },
};
```

**重要命令详解**：

```c
// LAUNCH 命令：创建新服务
static const char *
cmd_launch(struct skynet_context * context, const char * param) {
    // 解析参数：模块名 + 初始化参数
    char * mod = strsep(&args, " \t\r\n");
    args = strsep(&args, "\r\n");
    
    // 创建新服务
    struct skynet_context * inst = skynet_context_new(mod, args);
    if (inst == NULL) {
        return NULL;
    } else {
        // 返回新服务的句柄（十六进制格式）
        id_to_hex(context->result, inst->handle);
        return context->result;
    }
}

// REG 命令：注册服务名
static const char *
cmd_reg(struct skynet_context * context, const char * param) {
    if (param == NULL || param[0] == '\0') {
        // 返回当前服务的句柄
        sprintf(context->result, ":%x", context->handle);
        return context->result;
    } else if (param[0] == '.') {
        // 注册本地名字
        return skynet_handle_namehandle(context->handle, param + 1);
    }
    // 不支持在 C 层注册全局名字
    return NULL;
}
```

### 2.5 服务间通信：skynet_send 系列函数

> 相关源码：`skynet-src/skynet_server.c:735`

```c
int
skynet_send(struct skynet_context * context, uint32_t source, 
            uint32_t destination, int type, int session, 
            void * data, size_t sz) {
    // 第一步：检查消息大小
    if ((sz & MESSAGE_TYPE_MASK) != sz) {
        skynet_error(context, "error: The message to %x is too large", destination);
        return -2;
    }
    
    // 第二步：处理消息参数（复制、分配会话等）
    _filter_args(context, type, &session, (void **)&data, &sz);
    
    // 第三步：设置源地址
    if (source == 0) {
        source = context->handle;
    }
    
    // 第四步：检查目标地址
    if (destination == 0) {
        return -1;
    }
    
    // 第五步：判断本地或远程
    if (skynet_harbor_message_isremote(destination)) {
        // 远程消息，通过 harbor 发送
        struct remote_message * rmsg = skynet_malloc(sizeof(*rmsg));
        rmsg->destination.handle = destination;
        rmsg->message = data;
        rmsg->sz = sz & MESSAGE_TYPE_MASK;
        rmsg->type = sz >> MESSAGE_TYPE_SHIFT;
        skynet_harbor_send(rmsg, source, session);
    } else {
        // 本地消息，直接入队
        struct skynet_message smsg;
        smsg.source = source;
        smsg.session = session;
        smsg.data = data;
        smsg.sz = sz;
        
        if (skynet_context_push(destination, &smsg)) {
            skynet_free(data);
            return -1;
        }
    }
    return session;
}
```

**消息发送特性**：

| 特性 | 说明 |
|------|------|
| **消息大小限制** | 使用 24 位存储大小，最大 16MB |
| **消息类型编码** | 高 8 位存储类型，低 24 位存储大小 |
| **会话管理** | 支持自动分配会话 ID |
| **内存管理** | 支持零拷贝（PTYPE_TAG_DONTCOPY）|
| **分布式支持** | 自动识别远程句柄，透明转发 |

### 2.6 消息生命周期时序示例

> 相关源码：`skynet-src/skynet_server.c:735`、`skynet-src/skynet_server.c:253`、`skynet-src/skynet_server.c:284`、`skynet-src/skynet_mq.c:194`

```mermaid
sequenceDiagram
    participant A as 服务A(ctx_A)
    participant MQ as 全局/服务队列
    participant B as 服务B(ctx_B)

    A->>A: skynet_send(..., destination=B)
    A->>A: _filter_args / session 分配
    A->>MQ: skynet_context_push(B, msg)
    MQ-->>B: skynet_mq_push / pop
    B->>B: dispatch_message(ctx_B, msg)
    B->>B: cb(ctx_B, ...)
    B->>MQ: (reserve?释放消息数据)
```

**消息流转步骤**：
1. **发起发送**：A 服务通过 `skynet_send` 完成参数校验与会话号准备（`skynet-src/skynet_server.c:735`）。
2. **入队路由**：调用 `skynet_context_push`，将消息塞入目标服务的私有队列，如果目标队列当前空闲会立刻挂到全局队列（`skynet-src/skynet_server.c:253`、`skynet-src/skynet_mq.c:194`）。
3. **调度消费**：工作线程从全局队列取出 B 服务的队列，调用 `dispatch_message` 进入服务回调（`skynet-src/skynet_server.c:284`）。
4. **回调处理**：若回调返回 0，框架负责释放消息数据；返回非 0 时由业务侧保存数据并负责后续释放，确保无双重释放风险。

该路径贯穿发送、排队、调度到消费的完整链路，定位消息延迟或丢失时可按此顺序逐点排查。

### 2.7 调度、权重与过载监控

> 相关源码：`skynet-src/skynet_server.c:326`（`skynet_context_message_dispatch`）

```c
struct message_queue * 
skynet_context_message_dispatch(struct skynet_monitor *sm, struct message_queue *q, int weight) {
    if (q == NULL) q = skynet_globalmq_pop();
    if (q == NULL) return NULL;

    uint32_t handle = skynet_mq_handle(q);
    struct skynet_context * ctx = skynet_handle_grab(handle);
    if (ctx == NULL) { skynet_mq_release(q, drop_message, &d); return skynet_globalmq_pop(); }

    int i, n = 1;
    for (i=0; i<n; i++) {
        if (skynet_mq_pop(q,&msg)) { skynet_context_release(ctx); return skynet_globalmq_pop(); }
        else if (i==0 && weight >= 0) { n = skynet_mq_length(q); n >>= weight; }

        int overload = skynet_mq_overload(q);
        if (overload) { skynet_error(ctx, "error: May overload, message queue length = %d", overload); }

        skynet_monitor_trigger(sm, msg.source , handle);
        (ctx->cb ? dispatch_message(ctx, &msg) : skynet_free(msg.data));
        skynet_monitor_trigger(sm, 0, 0);
    }
    ...
}
```

要点：
- **权重调度**：`n = len >> weight`，在队列较长时批量处理，减小全局队列切换开销；`weight=-1` 表示始终处理 1 条。
- **过载告警**：当 `skynet_mq_overload(q)` 返回非零，输出一次警告日志，提示队列积压。
- **监控埋点**：分发前/后调用 `skynet_monitor_trigger`，支持定位卡线程和超时。

### 2.8 名字解析与 sendname

> 相关源码：`skynet-src/skynet_server.c:788`（`skynet_sendname`）、`skynet-src/skynet_server.c:380`（`skynet_queryname`）、`skynet-src/skynet_server.c:465`（`cmd_name`）、`skynet-src/skynet_handle.c:153`（名字表）

规则与路径：
- **地址格式**：`":<hex>"` 直指句柄；`".<local>"` 查本地名字表；其他字符串视为远程名，仅用于分布式转发。
- **本地查询**：`.name` 通过 `skynet_handle_findname` 返回本地句柄；查不到返回 0。
- **注册名字**：`REG .name` 或 `NAME .name :<hex>` 注册本地名字；C 层不支持注册全局名字（跨节点）。
- **sendname 行为**：
  - `:<hex>` → 等价于 `skynet_send` 本地/远程判定。
  - `.<name>` → 解析为本地句柄，不存在则（在 `sendname` 中）释放数据并返回 `-1`。
  - 其他字符串 → 构造 `remote_message`，拷贝 name 到 `rmsg->destination.name`，交由 harbor 层转发。

### 2.9 消息类型标志与 destination=0 语义

> 相关源码：`skynet-src/skynet_server.c:724`（`_filter_args`）、`skynet-src/skynet_server.c:736`（`skynet_send`）

- **编码布局**：`msg->sz` 低 24 位为长度，高 8 位为类型；`PTYPE_TAG_DONTCOPY`/`PTYPE_TAG_ALLOCSESSION` 作为高位标志参与 `_filter_args` 处理。
- **DONTCOPY 语义**：当标志存在且数据过大/目的无效，Skynet 会负责释放数据，避免泄漏。
- **ALLOCSESSION 语义**：若 `session==0`，自动分配新会话号，常用于请求-响应模式。
- **目的地为 0**：
  - 若 `destination==0 && data!=NULL`，打印错误并释放数据，返回 `-1`。
  - 若 `destination==0 && data==NULL`，不会报错，直接返回 `session`（适用于仅申请会话号等场景）。

### 2.10 endless 状态与 STAT 统计

> 相关源码：`skynet-src/skynet_server.c:266`（`skynet_context_endless`）、`skynet-src/skynet_server.c:558`（`cmd_stat`）

- **endless 标志**：通过 `skynet_context_endless(handle)` 将 `context->endless=true`，用于标记可能的“消息取不完”状态，以便在下一次 `STAT endless` 查询时返回 `1` 并清零标记。
- **STAT 查询**：
  - `STAT mqlen`：当前队列长度
  - `STAT endless`：是否曾触发 endless（返回后清零）
  - `STAT cpu`/`STAT time`：累计 CPU 时间/当前消息处理耗时（需开启 `profile`）

### 2.11 引用计数和内存管理

```c
// 增加引用计数
void 
skynet_context_grab(struct skynet_context *ctx) {
    ATOM_FINC(&ctx->ref);
}

// 减少引用计数，为 0 时删除
struct skynet_context * 
skynet_context_release(struct skynet_context *ctx) {
    if (ATOM_FDEC(&ctx->ref) == 1) {
        delete_context(ctx);
        return NULL;
    }
    return ctx;
}

// 删除上下文
static void 
delete_context(struct skynet_context *ctx) {
    // 关闭日志文件
    FILE *f = (FILE *)ATOM_LOAD(&ctx->logfile);
    if (f) {
        fclose(f);
    }
    
    // 释放服务实例
    skynet_module_instance_release(ctx->mod, ctx->instance);
    
    // 标记消息队列待释放
    skynet_mq_mark_release(ctx->queue);
    
    // 释放上下文内存
    skynet_free(ctx);
    
    // 减少全局服务计数
    context_dec();
}
```

**引用计数策略**：
- 初始引用计数为 2（创建时的引用 + 句柄表的引用）
- 每次 `grab` 操作增加引用
- 每次 `release` 操作减少引用
- 引用计数归零时自动释放所有资源

### 2.12 服务退出与监控协作

> 相关源码：`skynet-src/skynet_server.c:404`、`skynet-src/skynet_server.c:486`、`skynet-src/skynet_handle.c:79`

服务的退出流程在命令层通过 `cmd_exit` / `cmd_kill` 调用 `handle_exit` 实现：

1. **日志记录**：框架打印退出来源，便于排查误杀（`skynet-src/skynet_server.c:404`）。
2. **监控上报**：若配置了 `G_NODE.monitor_exit`，会向监控服务发送一条客户端消息，便于统计或触发自愈策略。
3. **句柄回收**：调用 `skynet_handle_retire` 清理句柄表并解绑名字，实现原子退出（`skynet-src/skynet_handle.c:79`）。
4. **安全释放**：引用计数归零后，`delete_context` 负责关闭日志、回收队列并释放实例资源，确保无悬挂句柄。

当需要整体停服时，`skynet_handle_retireall` 会遍历所有活跃句柄逐一退休，监控逻辑同样会收到逐服务的退出通知，方便实现灰度下线与错峰重启。

### 2.13 线程本地状态与日志开关

> 相关源码：`skynet-src/skynet_server.c:63`（`skynet_current_handle`）、`skynet-src/skynet_server.c:640`（`cmd_logon`）、`skynet-src/skynet_server.c:660`（`cmd_logoff`）

- **TLS 句柄**：通过 `pthread_setspecific`/`pthread_getspecific` 维护当前工作线程正在处理的服务句柄，`skynet_current_handle()` 在主线程返回特殊负值（用于区分线程角色）。
- **日志开关并发安全**：`LOGON`/`LOGOFF` 使用 `ATOM_CAS_POINTER` 对 `context->logfile` 原子切换，避免多线程重复打开/关闭同一日志文件。

## 3. skynet_handle.c 深度分析

### 3.1 handle 编码方案

```c
// handle 的位域布局
// |<- 8 bits ->|<--- 24 bits --->|
// |  harbor_id |   local_handle  |

#define HANDLE_MASK 0xffffff          // 低 24 位掩码
#define HANDLE_REMOTE_SHIFT 24         // harbor 位移

struct handle_storage {
    struct rwlock lock;                // 读写锁
    uint32_t harbor;                   // harbor id（高 8 位）
    uint32_t handle_index;             // 下一个分配的句柄序号
    int slot_size;                     // 哈希表大小（2 的幂）
    struct skynet_context ** slot;     // 哈希表数组
    int name_cap;                      // 名字数组容量
    int name_count;                    // 已注册名字数量
    struct handle_name *name;          // 名字数组（有序）
};
```

**Handle 编码特点**：
- **本地句柄**：24 位，支持 16M 个本地服务
- **Harbor ID**：8 位，支持 256 个分布式节点
- **零值保留**：handle 0 被系统保留，表示无效句柄

### 3.2 struct handle_storage 哈希表设计

```mermaid
graph TD
    subgraph "Handle Storage 结构"
        HS[handle_storage]
        HS --> LOCK[rwlock<br/>读写锁]
        HS --> HT[slot<br/>哈希表]
        HS --> NA[name<br/>名字数组]
    end
    
    subgraph "哈希表"
        HT --> S0[slot_0]
        HT --> S1[slot_1]
        HT --> S2[slot_2]
        HT --> SN[slot_n]
        
        S0 --> C1[context_1]
        S1 --> C2[context_2]
        S2 --> C3[context_3]
    end
    
    subgraph "名字服务"
        NA --> N1[name_1 → handle_1]
        NA --> N2[name_2 → handle_2]
        NA --> N3[name_3 → handle_3]
    end
```

**哈希表特性**：
- **开放定址法**：使用线性探测解决哈希冲突
- **动态扩容**：当槽位用满时，容量翻倍
- **快速定位**：`hash = handle & (slot_size - 1)`
- **缓存友好**：连续内存布局，提高缓存命中率

### 3.3 句柄分配算法和扩容机制

```c
uint32_t
skynet_handle_register(struct skynet_context *ctx) {
    struct handle_storage *s = H;
    rwlock_wlock(&s->lock);

    for (;;) {
        int i;
        uint32_t handle = s->handle_index;
        
        // 线性探测，寻找空槽
        for (i=0; i<s->slot_size; i++, handle++) {
            if (handle > HANDLE_MASK) {
                handle = 1;  // 回绕，跳过 0
            }
            
            int hash = handle & (s->slot_size-1);
            if (s->slot[hash] == NULL) {
                // 找到空槽，分配
                s->slot[hash] = ctx;
                s->handle_index = handle + 1;
                rwlock_wunlock(&s->lock);
                
                // 加上 harbor id
                handle |= s->harbor;
                return handle;
            }
        }
        
        // 所有槽位已满，需要扩容
        assert((s->slot_size*2 - 1) <= HANDLE_MASK);
        
        // 分配新的哈希表（容量翻倍）
        struct skynet_context ** new_slot = 
            skynet_malloc(s->slot_size * 2 * sizeof(struct skynet_context *));
        memset(new_slot, 0, s->slot_size * 2 * sizeof(struct skynet_context *));
        
        // 重新哈希所有元素
        for (i=0; i<s->slot_size; i++) {
            if (s->slot[i]) {
                int hash = skynet_context_handle(s->slot[i]) & (s->slot_size * 2 - 1);
                assert(new_slot[hash] == NULL);
                new_slot[hash] = s->slot[i];
            }
        }
        
        // 替换旧表
        skynet_free(s->slot);
        s->slot = new_slot;
        s->slot_size *= 2;
    }
}
```

**分配算法流程**：

```mermaid
flowchart TD
    A[开始分配] --> B[获取写锁]
    B --> C[从 handle_index 开始]
    C --> D{遍历槽位}
    D --> E{找到空槽?}
    E -->|是| F[分配句柄]
    E -->|否| G{遍历完成?}
    G -->|否| D
    G -->|是| H[扩容哈希表]
    H --> I[重新哈希]
    I --> C
    F --> J[更新 handle_index]
    J --> K[释放锁]
    K --> L[返回句柄]
```

### 3.4 名字服务实现

```c
// 查找名字（二分查找）
uint32_t
skynet_handle_findname(const char * name) {
    struct handle_storage *s = H;
    rwlock_rlock(&s->lock);
    
    uint32_t handle = 0;
    int begin = 0;
    int end = s->name_count - 1;
    
    // 二分查找（名字数组有序）
    while (begin <= end) {
        int mid = (begin + end) / 2;
        struct handle_name *n = &s->name[mid];
        int c = strcmp(n->name, name);
        if (c == 0) {
            handle = n->handle;
            break;
        }
        if (c < 0) {
            begin = mid + 1;
        } else {
            end = mid - 1;
        }
    }
    
    rwlock_runlock(&s->lock);
    return handle;
}

// 插入名字（保持有序）
static const char *
_insert_name(struct handle_storage *s, const char * name, uint32_t handle) {
    // 二分查找插入位置
    int begin = 0;
    int end = s->name_count - 1;
    while (begin <= end) {
        int mid = (begin + end) / 2;
        struct handle_name *n = &s->name[mid];
        int c = strcmp(n->name, name);
        if (c == 0) {
            return NULL;  // 名字已存在
        }
        if (c < 0) {
            begin = mid + 1;
        } else {
            end = mid - 1;
        }
    }
    
    // 复制名字
    char * result = skynet_strdup(name);
    
    // 在 begin 位置插入
    _insert_name_before(s, result, handle, begin);
    
    return result;
}
```

**名字服务特性**：
- **有序存储**：名字按字典序排列
- **二分查找**：O(log n) 时间复杂度
- **动态扩容**：名字数组容量不足时自动翻倍
- **原子操作**：通过读写锁保证线程安全

### 3.5 线程安全保证（rwlock）

```c
struct rwlock {
    int write;
    int read;
};

// 使用模式
// 1. 写操作（独占）
rwlock_wlock(&s->lock);
// ... 修改操作 ...
rwlock_wunlock(&s->lock);

// 2. 读操作（共享）
rwlock_rlock(&s->lock);
// ... 只读操作 ...
rwlock_runlock(&s->lock);
```

**并发控制策略**：
- **读写分离**：多个读操作可并发，写操作独占
- **写优先**：有写请求时，新的读请求会等待
- **最小化锁粒度**：操作完成立即释放锁
- **避免死锁**：释放上下文时先解锁再调用可能加锁的函数

## 4. skynet_module.c 深度分析

### 4.1 模块接口规范

```c
// 模块必须实现的四个接口
typedef void * (*skynet_dl_create)(void);
typedef int (*skynet_dl_init)(void * inst, struct skynet_context *, const char * parm);
typedef void (*skynet_dl_release)(void * inst);
typedef void (*skynet_dl_signal)(void * inst, int signal);

struct skynet_module {
    const char * name;          // 模块名（通常是文件名）
    void * module;              // dlopen 返回的句柄
    skynet_dl_create create;    // 创建实例
    skynet_dl_init init;        // 初始化实例
    skynet_dl_release release;  // 释放实例
    skynet_dl_signal signal;    // 处理信号
};
```

**接口命名规范**：
```c
// 假设模块名为 "logger"
// 则对应的函数名必须为：
logger_create    // 创建函数
logger_init      // 初始化函数  
logger_release   // 释放函数
logger_signal    // 信号函数
```

### 4.2 dlopen 动态加载实现

```c
static void *
_try_open(struct modules *m, const char * name) {
    const char *l;
    const char * path = m->path;  // 例如: "./cservice/?.so"
    size_t path_size = strlen(path);
    size_t name_size = strlen(name);
    
    void * dl = NULL;
    char tmp[path_size + name_size];
    
    // 遍历路径列表（分号分隔）
    do {
        memset(tmp, 0, sizeof(tmp));
        while (*path == ';') path++;
        if (*path == '\0') break;
        
        // 查找下一个分号
        l = strchr(path, ';');
        if (l == NULL) l = path + strlen(path);
        
        // 构建实际路径，将 ? 替换为模块名
        int len = l - path;
        int i;
        for (i=0; path[i]!='?' && i < len; i++) {
            tmp[i] = path[i];
        }
        memcpy(tmp+i, name, name_size);
        if (path[i] == '?') {
            strncpy(tmp+i+name_size, path+i+1, len - i - 1);
        }
        
        // 尝试加载动态库
        dl = dlopen(tmp, RTLD_NOW | RTLD_GLOBAL);
        path = l;
    } while(dl == NULL);
    
    return dl;
}
```

**加载过程**：
1. **路径解析**：将配置的路径模板中的 `?` 替换为模块名
2. **动态链接**：使用 `dlopen` 加载 .so 文件
3. **符号可见性**：`RTLD_GLOBAL` 使符号全局可见
4. **即时绑定**：`RTLD_NOW` 立即解析所有符号

### 4.3 模块查询和缓存

> 相关源码：`skynet-src/skynet_module.c:16`、`skynet-src/skynet_module.c:104`

```c
struct modules {
    int count;                              // 已加载模块数量
    struct spinlock lock;                   // 自旋锁
    const char * path;                      // 模块搜索路径
    struct skynet_module m[MAX_MODULE_TYPE]; // 模块缓存（最多 32 个）
};

struct skynet_module *
skynet_module_query(const char * name) {
    // 第一次查询（无锁）
    struct skynet_module * result = _query(name);
    if (result)
        return result;
    
    SPIN_LOCK(M)
    
    // 双重检查（加锁后再查一次）
    result = _query(name);
    
    if (result == NULL && M->count < MAX_MODULE_TYPE) {
        // 尝试加载新模块
        int index = M->count;
        void * dl = _try_open(M, name);
        if (dl) {
            M->m[index].name = name;
            M->m[index].module = dl;
            
            // 绑定函数符号
            if (open_sym(&M->m[index]) == 0) {
                M->m[index].name = skynet_strdup(name);
                M->count++;
                result = &M->m[index];
            }
        }
    }
    
    SPIN_UNLOCK(M)
    
    return result;
}
```

**缓存机制**：
- **一次加载**：模块只在首次使用时加载
- **永久缓存**：`struct modules` 作为进程级静态单例，不暴露卸载路径，模块常驻进程生命周期，避免符号被其他服务引用后失效
- **双重检查**：避免并发加载同一模块
- **容量限制**：最多缓存 32 种不同的模块类型

### 4.4 模块路径解析

```c
// 路径配置示例
// cpath = "./cservice/?.so;./luaclib/?.so"

// 解析过程：
// 1. 分割路径（按分号）
// 2. 替换占位符（? → 模块名）
// 3. 尝试加载每个路径
// 4. 返回第一个成功加载的模块
```

**路径解析流程图**：

```mermaid
graph LR
    A[模块名: logger] --> B[路径模板: ./cservice/?.so]
    B --> C[替换: ./cservice/logger.so]
    C --> D{dlopen}
    D -->|成功| E[返回句柄]
    D -->|失败| F[尝试下一路径]
    F --> G[./luaclib/?.so]
    G --> H[替换: ./luaclib/logger.so]
    H --> D
```

## 5. 设计要点

### 5.1 并发控制

**多层次的并发控制机制**：

| 层次 | 机制 | 应用场景 | 特点 |
|------|------|----------|------|
| **原子操作** | `ATOM_INT`, `ATOM_POINTER` | 引用计数、简单标志 | 无锁、高性能 |
| **自旋锁** | `spinlock` | 模块加载、短临界区 | 忙等待、适合短时操作 |
| **读写锁** | `rwlock` | 句柄表访问 | 读写分离、提高并发度 |
| **消息队列** | 无锁队列 | 服务间通信 | 异步、解耦 |

```c
// 原子操作示例
ATOM_FINC(&ctx->ref);  // 原子增加
ATOM_FDEC(&ctx->ref);  // 原子减少
ATOM_LOAD(&ctx->logfile);  // 原子读取
ATOM_CAS_POINTER(&ctx->logfile, old, new);  // CAS 操作

// 自旋锁使用模式
SPIN_LOCK(M)
// 临界区代码
SPIN_UNLOCK(M)

// 读写锁使用
rwlock_rlock(&lock);  // 读锁（共享）
rwlock_wlock(&lock);  // 写锁（独占）
```

### 5.2 内存管理策略

**层次化的内存管理**：

```mermaid
graph TD
    subgraph "内存分配策略"
        A[skynet_malloc] --> B[jemalloc]
        C[skynet_free] --> B
        D[skynet_strdup] --> B
    end
    
    subgraph "生命周期管理"
        E[引用计数] --> F[自动释放]
        G[消息内存] --> H[零拷贝/复制]
        I[模块缓存] --> J[永不释放]
    end
    
    subgraph "内存池"
        K[消息队列池]
        L[上下文池]
        M[句柄表]
    end
```

**关键策略**：
1. **引用计数**：自动管理服务生命周期
2. **延迟释放**：避免使用中的内存被释放
3. **内存池**：减少频繁分配/释放开销
4. **零拷贝**：大消息传递时避免复制

> 注意：C 模块通过 `modules.m[]` 永久缓存，必要的热更需配合进程重启或自定义卸载流程（`skynet-src/skynet_module.c:16`）。

### 5.3 性能优化技巧

**1. 缓存优化**
```c
// 使用 2 的幂作为哈希表大小，用位运算代替取模
int hash = handle & (s->slot_size - 1);  // 而不是 handle % s->slot_size
```

**2. 减少锁竞争**
```c
// 双重检查锁定
result = _query(name);  // 第一次检查（无锁）
if (result) return result;
SPIN_LOCK(M)
result = _query(name);  // 第二次检查（有锁）
```

**3. 批量操作**
```c
// 消息批量处理
for (i=0; i<n; i++) {
    if (skynet_mq_pop(q, &msg)) break;
    // 处理多条消息，减少调度开销
}
```

**4. 内存局部性**
```c
// 连续内存布局，提高缓存命中率
struct skynet_context ** slot;  // 数组形式
struct handle_name *name;       // 有序数组
```

### 5.4 最佳实践

#### 服务设计原则

1. **无状态共享**：服务间不共享内存，只通过消息通信
2. **异步处理**：避免阻塞操作，使用回调或协程
3. **错误隔离**：单个服务崩溃不影响其他服务
4. **资源管理**：正确处理引用计数，避免内存泄漏

#### 消息处理模式

```c
// 推荐的消息处理模式
int message_handler(struct skynet_context * ctx, void *ud, 
                    int type, int session, uint32_t source,
                    const void * msg, size_t sz) {
    switch(type) {
    case PTYPE_CLIENT:
        // 处理客户端消息
        handle_client_message(ctx, msg, sz);
        break;
    case PTYPE_RESPONSE:
        // 处理响应消息
        handle_response(ctx, session, msg, sz);
        break;
    default:
        // 未知消息类型
        skynet_error(ctx, "Unknown message type %d", type);
    }
    return 0;  // 返回 0 表示消息内存由框架释放
}
```

#### 性能监控

```c
// 开启性能分析
skynet_profile_enable(1);

// 获取统计信息
skynet_command(ctx, "STAT", "cpu");      // CPU 使用时间
skynet_command(ctx, "STAT", "mqlen");    // 消息队列长度
skynet_command(ctx, "STAT", "message");  // 处理消息数量
```

## 总结

Skynet 的服务管理模块通过精心设计的三层架构实现了高效的 Actor 模型：

1. **skynet_module.c** 提供动态模块加载能力，支持热插拔
2. **skynet_server.c** 实现服务生命周期管理和消息分发
3. **skynet_handle.c** 提供高效的服务定位和名字服务

整个系统通过以下特性保证了高性能和高可靠性：

- **无锁设计**：大量使用原子操作和无锁数据结构
- **内存管理**：引用计数自动管理生命周期
- **并发控制**：多层次的锁机制，最小化竞争
- **缓存友好**：数据结构设计考虑 CPU 缓存
- **错误隔离**：服务间相互独立，故障不扩散

这种设计使得 Skynet 能够在单机支撑数千个服务同时运行，成为游戏服务器开发的优秀框架。

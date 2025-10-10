# Skynet Harbor 跨节点通信系统详细技术文档

## 目录

1. [Harbor系统概述](#harbor系统概述)
2. [设计架构](#设计架构)
3. [核心数据结构](#核心数据结构)
4. [关键函数分析](#关键函数分析)
5. [分布式特性](#分布式特性)
6. [与其他模块的协作](#与其他模块的协作)
7. [配置和部署](#配置和部署)
8. [性能优化](#性能优化)
9. [使用示例和最佳实践](#使用示例和最佳实践)

## Harbor系统概述

### 1.1 Harbor在Skynet分布式架构中的作用

Harbor是Skynet框架中实现分布式支持的核心组件，负责处理跨节点的消息路由和服务定位。它的主要职责包括：

- **跨节点消息透明传输**：使不同物理节点上的服务能够像本地服务一样相互通信
- **全局名字服务管理**：维护全局唯一的服务名字空间，支持跨节点的服务发现
- **节点间连接管理**：处理节点间的TCP连接建立、维护和故障恢复
- **消息序列化与反序列化**：处理跨网络传输的消息打包和解包

### 1.2 节点间通信模型

Harbor采用了基于TCP的可靠连接模型：

```
┌──────────────┐                  ┌──────────────┐
│   Node 1     │                  │   Node 2     │
│              │                  │              │
│  Services    │                  │  Services    │
│     ↓        │                  │     ↓        │
│  Harbor      │<---TCP Conn----->│  Harbor      │
│              │                  │              │
└──────────────┘                  └──────────────┘
```

每个节点运行一个Harbor服务，负责：
- 监听来自其他节点的连接
- 主动连接到其他节点
- 转发本地服务的远程消息
- 接收并分发远程消息到本地服务

### 1.3 与单节点模式的区别

| 特性 | 单节点模式 | Harbor分布式模式 |
|-----|-----------|-----------------|
| Harbor ID | 0（不启用） | 1-255（每个节点唯一） |
| 服务句柄 | 24位本地ID | 8位Harbor ID + 24位本地ID |
| 消息传递 | 内存拷贝 | 网络传输 + 序列化 |
| 服务发现 | 本地查找 | 全局名字服务 |
| 性能开销 | 极低 | 网络延迟 + 序列化开销 |
| 可扩展性 | 单机限制 | 最多255个节点 |

### 1.4 Harbor ID设计（句柄高8位）

Skynet使用32位整数作为服务句柄（handle），Harbor巧妙地利用高8位存储节点ID：

```c
// 句柄结构：[8位Harbor ID][24位本地服务ID]
#define HANDLE_MASK 0xffffff          // 低24位掩码（本地服务ID）
#define HANDLE_REMOTE_SHIFT 24         // Harbor ID位移

// 判断是否为远程服务
int skynet_harbor_message_isremote(uint32_t handle) {
    int h = (handle & ~HANDLE_MASK);  // 提取高8位
    return h != HARBOR && h != 0;     // 非本地且非单节点模式
}
```

这种设计的优势：
- **透明性**：应用层代码无需区分本地/远程服务
- **高效性**：通过简单的位运算即可判断消息目标
- **兼容性**：单节点模式（harbor=0）自然兼容

## 设计架构

### 2.1 主从架构（Master/Slave）

Harbor采用主从架构管理节点间的连接和名字服务：

```
           ┌─────────────┐
           │   Master    │
           │  (Node 0)   │
           └──────┬──────┘
                  │
      ┌───────────┼───────────┐
      ↓           ↓           ↓
┌──────────┐ ┌──────────┐ ┌──────────┐
│  Slave 1 │ │  Slave 2 │ │  Slave 3 │
│ (Node 1) │ │ (Node 2) │ │ (Node 3) │
└──────────┘ └──────────┘ └──────────┘
```

**Master节点职责**：
- 维护全局名字注册表
- 广播节点连接信息
- 协调节点间的连接建立

**Slave节点职责**：
- 向Master注册全局名字
- 接收其他节点的连接信息
- 建立与其他Slave的P2P连接

### 2.2 节点发现和注册机制

本仓库实际实现由 `service/cslave.lua` 完成。与 Master 的交互使用“单字节长度 + packstring”的自定义包，握手、广播等协议标志均为单字符：

```lua
-- 打包/解包（service/cslave.lua:1,15）
local function read_package(fd)
    local sz = socket.read(fd, 1)
    assert(sz, "closed")
    sz = string.byte(sz)
    local content = assert(socket.read(fd, sz), "closed")
    return skynet.unpack(content)
end

local function pack_package(...)
    local message = skynet.packstring(...)
    local size = #message
    assert(size <= 255 , "too long")
    return string.char(size) .. message
end

-- Slave 连接 Master 并握手（service/cslave.lua:197）
local master_fd = assert(socket.open(master_addr), "Can't connect to master")
local hs_message = pack_package("H", harbor_id, slave_address)
socket.write(master_fd, hs_message)
local t, n = read_package(master_fd)
assert(t == "W" and type(n) == "number", "slave shakehand failed")

-- 接受其他 Slave 入站连接（service/cslave.lua:40,84）
local function accept_slave(fd)
    socket.start(fd)
    local id = socket.read(fd, 1)
    if not id then socket.close(fd); return end
    id = string.byte(id)
    assert(slaves[id] == nil, string.format("Slave %d exist (fd=%d)", id, fd))
    slaves[id] = fd
    socket.abandon(fd)
    -- 将 fd/id 通知 C 层 Harbor 服务，进入握手/队列分发
    skynet.send(harbor_service, "harbor", string.format("A %d %d", fd, id))
end
```

### 2.3 全局名字服务

Lua 层对外提供了简洁 API（`lualib/skynet/harbor.lua`），由 `service/cslave.lua` 驱动与 Master 的同步：

```lua
-- lualib/skynet/harbor.lua:1
function harbor.globalname(name, handle)
    handle = handle or skynet.self()
    skynet.send(".cslave", "lua", "REGISTER", name, handle)
end

function harbor.queryname(name)
    return skynet.call(".cslave", "lua", "QUERYNAME", name)
end
```

当收到 Master 的 `'N'`（名字更新）广播后，`cslave` 会缓存并转发给 C 层 Harbor：

```lua
-- service/cslave.lua:38,57
globalname[id_name] = address
skynet.redirect(harbor_service, address, "harbor", 0, "N " .. id_name)
```

名字解析流程：
1. 本地查询缓存
2. 若未找到，向Master查询
3. Master返回服务句柄
4. 缓存结果供后续使用

### 2.4 消息路由策略

跨节点消息路由核心在 C 层 `service-src/service_harbor.c`：

```c
// 句柄路由（service-src/service_harbor.c:527）
static int
remote_send_handle(struct harbor *h, uint32_t source, uint32_t destination,
                   int type, int session, const char * msg, size_t sz) {
    int harbor_id = destination >> HANDLE_REMOTE_SHIFT;
    struct skynet_context * context = h->ctx;
    if (harbor_id == h->id) {
        // 本地消息：直接投递，且使用 PTYPE_TAG_DONTCOPY 避免多余拷贝
        skynet_send(context, source, destination,
                    type | PTYPE_TAG_DONTCOPY, session, (void *)msg, sz);
        return 1;
    }

    struct slave * s = &h->s[harbor_id];
    if (s->fd == 0 || s->status == STATUS_HANDSHAKE) {
        if (s->status == STATUS_DOWN) {
            // 目标不可达：回报 PTYPE_ERROR 并记录
            skynet_send(context, destination, source, PTYPE_ERROR, session, NULL, 0);
            skynet_error(context, "Drop message to harbor %d from %x to %x (session = %d, msgsz = %d)",
                         harbor_id, source, destination, session, (int)sz);
        } else {
            // 连接未就绪：入队待发
            if (s->queue == NULL) s->queue = new_queue();
            struct remote_message_header header;
            header.source = source;
            header.destination = (type << HANDLE_REMOTE_SHIFT) | (destination & HANDLE_MASK);
            header.session = (uint32_t)session;
            push_queue(s->queue, (void *)msg, sz, &header);
            return 1;
        }
    } else {
        // 连接就绪：立即发送
        struct remote_message_header cookie;
        cookie.source = source;
        cookie.destination = (destination & HANDLE_MASK) | ((uint32_t)type << HANDLE_REMOTE_SHIFT);
        cookie.session = (uint32_t)session;
        send_remote(context, s->fd, msg, sz, &cookie);
    }
    return 0;
}
```

路由优化策略：
- **本地优先**：本地消息避免网络传输
- **消息缓存**：连接未就绪时缓存消息
- **批量发送**：积累多个消息后批量传输

## 核心数据结构

### 3.1 Harbor ID编码

```c
// Harbor ID编码规则
// 32位句柄 = [8位Harbor ID][24位本地ID]
//
// 示例：
// 0x01000001 = Harbor 1, Service 1
// 0x02000100 = Harbor 2, Service 256
// 0x00000001 = 单节点模式, Service 1

// 提取Harbor ID
#define HARBOR_ID(handle) ((handle) >> HANDLE_REMOTE_SHIFT)

// 提取本地服务ID
#define LOCAL_ID(handle) ((handle) & HANDLE_MASK)

// 构造远程句柄
#define MAKE_REMOTE_HANDLE(harbor, local) \
    (((harbor) << HANDLE_REMOTE_SHIFT) | (local))
```

### 3.2 远程消息格式

```c
// 远程消息头（12字节）
struct remote_message_header {
    uint32_t source;       // 源服务句柄
    uint32_t destination;  // 目标服务句柄（高8位含消息类型）
    uint32_t session;      // 会话ID
};

// 完整的Harbor消息
struct harbor_msg {
    struct remote_message_header header;
    void * buffer;         // 消息内容
    size_t size;          // 消息大小
};

// 网络传输格式（发送：service-src/service_harbor.c:333；接收：service-src/service_harbor.c:466）
// [4字节长度(大端)][消息体(原始payload)][12字节远程头]
// 其中长度=payload+12；接收侧要求长度首字节为 0（24bit 长度，单条消息 < 16MB），否则判为过大并关闭连接
```

消息类型编码在destination的高8位：
```c
// 发送时：type存储在destination高8位
header.destination = (type << HANDLE_REMOTE_SHIFT) | (destination & HANDLE_MASK);

// 接收时：解析type和真实destination
int type = header.destination >> HANDLE_REMOTE_SHIFT;
uint32_t destination = header.destination & HANDLE_MASK;
```

### 3.3 名字注册表

```c
// 全局名字节点
struct keyvalue {
    struct keyvalue * next;
    char key[GLOBALNAME_LENGTH];      // 16字节名字
    uint32_t hash;                     // 名字哈希值
    uint32_t value;                    // 服务句柄
    struct harbor_msg_queue * queue;  // 待处理消息队列
};

// 哈希表
#define HASH_SIZE 4096
struct hashmap {
    struct keyvalue *node[HASH_SIZE];
};

// 哈希计算（简单但高效）
uint32_t hash_name(const char name[GLOBALNAME_LENGTH]) {
    uint32_t *ptr = (uint32_t*) name;
    return ptr[0] ^ ptr[1] ^ ptr[2] ^ ptr[3];
}
```

### 3.4 节点连接管理

```c
// Slave节点状态
#define STATUS_WAIT      0  // 等待连接
#define STATUS_HANDSHAKE 1  // 握手中
#define STATUS_HEADER    2  // 读取消息头
#define STATUS_CONTENT   3  // 读取消息体
#define STATUS_DOWN      4  // 连接断开

// Slave连接信息
struct slave {
    int fd;                           // Socket文件描述符
    struct harbor_msg_queue *queue;   // 消息队列
    int status;                        // 连接状态
    int length;                        // 当前消息长度
    int read;                          // 已读取字节数
    uint8_t size[4];                   // 消息长度缓冲
    char * recv_buffer;                // 接收缓冲区
};

// Harbor主结构
struct harbor {
    struct skynet_context *ctx;       // 关联的Skynet上下文
    int id;                           // 本节点Harbor ID
    uint32_t slave;                   // Slave服务句柄
    struct hashmap * map;             // 全局名字表
    struct slave s[REMOTE_MAX];       // 所有远程节点连接（最多256个）
};
```

## 关键函数分析

### 4.1 skynet_harbor_init：初始化

```c
void skynet_harbor_init(int harbor) {
    // 设置本地Harbor ID（左移24位存储在高8位）
    HARBOR = (unsigned int)harbor << HANDLE_REMOTE_SHIFT;
}
```

初始化过程：
1. 保存Harbor ID到全局变量
2. ID为0表示单节点模式
3. ID范围1-255表示分布式节点

### 4.2 skynet_harbor_start：启动Harbor服务

```c
void skynet_harbor_start(void *ctx) {
    // 保留Harbor服务的引用，确保不被释放
    skynet_context_reserve(ctx);
    REMOTE = ctx;  // 保存Harbor服务上下文
}
```

启动流程：
1. 创建Harbor C服务
2. 保存服务上下文供消息转发使用
3. 启动网络监听和连接

### 4.3 注册全局名字（Lua 层）

全局名字注册由 `service/cslave.lua` 的 `harbor.REGISTER` 处理：

```lua
-- service/cslave.lua:160
function harbor.REGISTER(fd, name, handle)
    assert(globalname[name] == nil)
    globalname[name] = handle
    response_name(name)
    socket.write(fd, pack_package("R", name, handle))
    skynet.redirect(harbor_service, handle, "harbor", 0, "N " .. name)
end
```

注册流程：
1. 本地保存名字-句柄映射
2. 通知Master节点更新全局注册表
3. Master广播给所有Slave节点
4. 各节点更新本地缓存

### 4.4 skynet_harbor_send：跨节点消息发送

```c
void skynet_harbor_send(struct remote_message *rmsg, uint32_t source, int session) {
    assert(invalid_type(rmsg->type) && REMOTE);
    // 将消息发送给Harbor服务处理
    skynet_context_send(REMOTE, rmsg, sizeof(*rmsg), source, PTYPE_SYSTEM, session);
}
```

发送流程：
1. 检查消息类型合法性
2. 将消息传递给Harbor服务
3. Harbor服务根据目标ID选择路由
4. 本地消息直接投递，远程消息通过网络发送

### 4.5 消息打包和解包

与网络交互采用“长度(4B大端) + payload + 远程头(12B)”布局，分别对应 `send_remote` 与 `forward_local_messsage`：

```c
// 发送远程消息（service-src/service_harbor.c:333）
static void
send_remote(struct skynet_context * ctx, int fd, const char * buffer, size_t sz,
            struct remote_message_header * cookie) {
    size_t sz_header = sz + sizeof(*cookie);
    if (sz_header > UINT32_MAX) {
        skynet_error(ctx, "remote message from :%08x to :%08x is too large.",
                     cookie->source, cookie->destination);
        return;
    }
    uint8_t sendbuf[sz_header+4];
    to_bigendian(sendbuf, (uint32_t)sz_header);
    memcpy(sendbuf+4, buffer, sz);
    header_to_message(cookie, sendbuf+4+sz);

    struct socket_sendbuffer tmp;
    tmp.id = fd;
    tmp.type = SOCKET_BUFFER_RAWPOINTER;
    tmp.buffer = sendbuf;
    tmp.sz = sz_header+4;
    skynet_socket_sendbuffer(ctx, &tmp);
}

// 将远程消息转发为本地消息（service-src/service_harbor.c:316）
static void
forward_local_messsage(struct harbor *h, void *msg, int sz) {
    const char * cookie = msg;
    cookie += sz - HEADER_COOKIE_LENGTH; // HEADER_COOKIE_LENGTH = 12
    struct remote_message_header header;
    message_to_header((const uint32_t *)cookie, &header);

    uint32_t destination = header.destination;
    int type = destination >> HANDLE_REMOTE_SHIFT;
    destination = (destination & HANDLE_MASK) | ((uint32_t)h->id << HANDLE_REMOTE_SHIFT);

    // 直接将 payload 作为消息体（不复制），交给本地服务
    if (skynet_send(h->ctx, header.source, destination,
                    type | PTYPE_TAG_DONTCOPY , (int)header.session,
                    (void *)msg, sz-HEADER_COOKIE_LENGTH) < 0) {
        if (type != PTYPE_ERROR)
            skynet_send(h->ctx, destination, header.source , PTYPE_ERROR,
                        (int)header.session, NULL, 0);
        skynet_error(h->ctx, "Unknown destination :%x from :%x type(%d)",
                     destination, header.source, type);
    }
}
```

## 分布式特性

### 5.1 节点间连接建立

实际握手流程由 `cslave` 与 C 层 Harbor 协作完成：

- `cslave` 连接 Master，完成 `'H'`/`'W'` 握手后，开始监听其他 Slave，并在接入时读取其 id（单字节），随后向 C 层 Harbor 发送命令 `'A fd id'` 绑定该连接（service/cslave.lua:197,133）。
- C 层 Harbor 在收到 `'S fd id'`（主动连接）或 `'A fd id'`（被动接入）后，由 `harbor_command` 调用 `handshake` 发送本端 id，并根据分支进入 `STATUS_HANDSHAKE` 或直接投递缓存队列（service-src/service_harbor.c:603,639）。

```c
// 发送单字节握手 id（service-src/service_harbor.c:591）
static void
handshake(struct harbor *h, int id) {
    struct slave *s = &h->s[id];
    uint8_t handshake[1] = { (uint8_t)h->id };
    struct socket_sendbuffer tmp;
    tmp.id = s->fd;
    tmp.type = SOCKET_BUFFER_RAWPOINTER;
    tmp.buffer = handshake;
    tmp.sz = 1;
    skynet_socket_sendbuffer(h->ctx, &tmp);
}
```

<!-- ### 5.2 故障检测和恢复

Harbor通过多种机制保证系统可靠性：

**连接监控**：
```c
// 监控远程连接状态
static void monitor_harbor(int harbor_id) {
    struct slave *s = &slaves[harbor_id];
    if (s->status == STATUS_DOWN) {
        // 通知所有等待该节点的服务
        report_harbor_down(harbor_id);
        // 尝试重连
        attempt_reconnect(harbor_id);
    }
}
```

**消息缓存机制**：
```c
// 连接断开时缓存消息
if (s->status == STATUS_DOWN || s->status == STATUS_HANDSHAKE) {
    if (s->queue == NULL) {
        s->queue = new_queue();
    }
    push_queue(s->queue, message, size, header);
    return;
}
```

**故障通知**：
```lua
-- 节点断开时通知相关服务
local function report_harbor_down(harbor_id)
    -- 发送错误消息给所有等待响应的服务
    for _, callback in pairs(waiting_response[harbor_id]) do
        callback(false, "harbor down")
    end
    -- 清理相关数据
    slaves[harbor_id] = nil
    globalname_cache[harbor_id] = {}
end
```

### 5.3 消息可靠性保证

Harbor提供多层次的可靠性保证：

1. **TCP传输保证**：底层使用TCP确保传输可靠性
2. **消息完整性**：通过长度头确保消息边界
3. **连接状态机**：严格的状态转换保证协议正确性
4. **错误处理**：失败消息返回错误给发送方

```c
// 错误处理示例
if (s->fd == 0 || s->status == STATUS_DOWN) {
    // 目标节点不可达，返回错误
    skynet_send(context, destination, source, PTYPE_ERROR, 
                session, NULL, 0);
    skynet_error(context, "Drop message to harbor %d", harbor_id);
}
```

### 5.4 负载均衡

Harbor本身不直接提供负载均衡，但支持以下模式：

**服务分组**：
```lua
-- 同一服务在多个节点部署
local services = {
    {harbor = 1, handle = 0x01000001},
    {harbor = 2, handle = 0x02000001},
    {harbor = 3, handle = 0x03000001},
}

-- 轮询或随机选择
local function select_service()
    local idx = math.random(#services)
    return services[idx].handle
end
```

**消息批处理**：Harbor 不内置批量写出；若需批处理，应在业务层合并多条小消息（如组装为一条 `PTYPE_LUA`），在接收方再拆分处理。 -->

## 与其他模块的协作

### 6.1 与消息队列系统的集成

Harbor 接收远程包后调用 `forward_local_messsage` 将其转为本地消息，内部通过 `skynet_send` 投递给目标服务（使用 `PTYPE_TAG_DONTCOPY` 避免额外拷贝），而非直接操作 `skynet_context_push`（service-src/service_harbor.c:316,345）。

### 6.2 与服务管理的配合

Harbor 与服务管理器的协作体现在启动流程及 `.cslave` 的存在：

- `service/bootstrap.lua` 根据 `harbor`/`standalone` 环境变量选择启动 `cdummy`/`cslave`/`cmaster` 并命名 `.cslave`（用于名字注册/查询）。
- 32 位句柄的 Harbor 高位由 C 层在注册 handle 时注入（`skynet-src/skynet_handle.c:61`），无需在 Lua 层手动位运算修改。
- 服务退出的清理流程不由 Harbor 主动干预；全局名字清理需由业务自身在合适时机处理。

### 6.3 与网络层的交互

Harbor 的 Socket 事件在服务回调 `mainloop` 的 `PTYPE_SOCKET` 分支处理：

```c
// Socket 事件处理（service-src/service_harbor.c:703）
static int
mainloop(struct skynet_context * context, void * ud, int type, int session,
         uint32_t source, const void * msg, size_t sz) {
    struct harbor * h = ud;
    switch (type) {
    case PTYPE_SOCKET: {
        const struct skynet_socket_message * message = msg;
        switch(message->type) {
        case SKYNET_SOCKET_TYPE_DATA:
            push_socket_data(h, message);
            skynet_free(message->buffer);
            break;
        case SKYNET_SOCKET_TYPE_ERROR:
        case SKYNET_SOCKET_TYPE_CLOSE: {
            int id = harbor_id(h, message->id);
            if (id) report_harbor_down(h,id);
            else skynet_error(context, "Unknown fd (%d) closed", message->id);
            break;
        }
        case SKYNET_SOCKET_TYPE_CONNECT:
            break;
        case SKYNET_SOCKET_TYPE_WARNING: {
            int id = harbor_id(h, message->id);
            if (id) skynet_error(context, "message havn't send to Harbor (%d) reach %d K", id, message->ud);
            break;
        }
        default:
            skynet_error(context, "recv invalid socket message type %d", type);
            break;
        }
        return 0;
    }
    // ... 其他类型处理
}
```

## 配置和部署

### 7.1 Harbor配置项

启动流程由 `service/bootstrap.lua` 协调：

```lua
-- 单节点（harbor=0）：启动 cdummy 并命名 .cslave（service/bootstrap.lua:9,16）
local ok, slave = pcall(skynet.newservice, "cdummy")
skynet.name(".cslave", slave)

-- 分布式（harbor>0）：按需启动 cmaster（standalone=true 时），启动 cslave 并命名 .cslave
if standalone then pcall(skynet.newservice,"cmaster") end
local ok, slave = pcall(skynet.newservice, "cslave")
skynet.name(".cslave", slave)
```

`harbor` C 服务由 `cslave`/`cdummy` 内部启动：

```lua
-- 内部启动 harbor（service/cslave.lua:242, service/cdummy.lua:37）
harbor_service = assert(skynet.launch("harbor", harbor_id, skynet.self()))
```

### 7.2 多节点部署方案

典型的3节点部署：

**Master节点（Node 0）配置**：
```lua
-- config.master
harbor = 0  -- Master通常设为0或使用独立Harbor ID
standalone = "0.0.0.0:2013"
-- 其他配置...
```

**Slave节点1配置**：
```lua
-- config.slave1
harbor = 1
address = "192.168.1.11:2526"
master = "192.168.1.10:2013"
-- 其他配置...
```

**Slave节点2配置**：
```lua
-- config.slave2  
harbor = 2
address = "192.168.1.12:2526"
master = "192.168.1.10:2013"
-- 其他配置...
```

启动顺序：
1. 启动Master节点
2. 启动各Slave节点（顺序无关）
3. 节点自动发现并建立连接

### 7.3 网络拓扑设计

**星型拓扑**（推荐）：
```
        Master
       /   |   \
      /    |    \
  Slave1 Slave2 Slave3
```

优点：
- 管理简单
- 名字服务集中
- 易于监控

**全连接拓扑**（Harbor实际使用）：
```
    Node1 ─── Node2
      │ \   / │
      │   X   │
      │ /   \ │
    Node3 ─── Node4
```

特点：
- 每个节点都与其他节点建立连接
- 消息直接路由，延迟低
- 容错性好

## 性能优化

### 8.1 跨节点通信优化

Harbor 层未实现批量写出/压缩等复杂优化，实际优化策略建议：

- 应用层合并：在 Lua 层将多条小消息封包为一次 `PTYPE_LUA` 发送，由接收方解包处理。
- 队列削峰：利用 Harbor 的待发队列与 `SKYNET_SOCKET_TYPE_WARNING` 告警配合限流（见 8.2）。
- 大消息规避：对超大包（>16MB）拆分为多条业务消息，避免触发 Harbor 的长度检查与断连（接收侧高字节必须为 0）。

### 8.2 队列发送与流控

Harbor 通过队列缓存与逐条发送实现简单有效的流控；当连接拥塞时，Socket 层会回送 `SKYNET_SOCKET_TYPE_WARNING` 告警：

```c
// 发送待发队列（service-src/service_harbor.c:400）
static void
dispatch_queue(struct harbor *h, int id) {
    struct slave *s = &h->s[id];
    int fd = s->fd;
    assert(fd != 0);
    struct harbor_msg_queue *queue = s->queue;
    if (queue == NULL) return;
    struct harbor_msg * m;
    while ((m = pop_queue(queue)) != NULL) {
        send_remote(h->ctx, fd, m->buffer, m->size, &m->header);
        skynet_free(m->buffer);
    }
    release_queue(queue);
    s->queue = NULL;
}

// 拥塞告警（service-src/service_harbor.c:720）
case SKYNET_SOCKET_TYPE_WARNING: {
    int id = harbor_id(h, message->id);
    if (id) skynet_error(context,
        "message havn't send to Harbor (%d) reach %d K", id, message->ud);
    break;
}
```

## 使用示例和最佳实践

### 9.1 配置示例

**简单双节点配置**：

Master节点：
```lua
-- config.master
harbor = 0
thread = 8
start = "main"
bootstrap = "snlua bootstrap"
standalone = "0.0.0.0:2013"
luaservice = "./service/?.lua;./examples/?.lua"
cpath = "./cservice/?.so"
```

Slave节点：
```lua
-- config.slave
harbor = 1
thread = 8
start = "main"
bootstrap = "snlua bootstrap"  
address = "127.0.0.1:2526"
master = "127.0.0.1:2013"
luaservice = "./service/?.lua;./examples/?.lua"
cpath = "./cservice/?.so"
```

### 9.2 跨节点服务调用

```lua
-- 注册全局服务
local skynet = require "skynet"
local harbor = require "skynet.harbor"

skynet.start(function()
    -- 注册全局名字
    harbor.globalname("gameserver", skynet.self())
    
    -- 处理远程请求
    skynet.dispatch("lua", function(session, source, cmd, ...)
        if cmd == "hello" then
            skynet.ret(skynet.pack("world"))
        end
    end)
end)

-- 调用远程服务
skynet.start(function()
    -- 查询全局服务
    local gameserver = harbor.queryname("gameserver")
    if gameserver then
        local result = skynet.call(gameserver, "lua", "hello")
        print("Got response:", result)
    end
end)
```

### 9.3 全局名字使用

最佳实践：

```lua
-- 1. 服务注册全局名字
local function register_global_service()
    local handle = skynet.self()
    local name = "lobby_" .. harbor_id
    harbor.globalname(name, handle)
    skynet.error("Service registered as:", name)
end

-- 2. 带重试的名字查询
local function query_with_retry(name, retry_count)
    retry_count = retry_count or 3
    for i = 1, retry_count do
        local handle = harbor.queryname(name)
        if handle then
            return handle
        end
        skynet.sleep(100)  -- 等待100cs后重试
    end
    error("Failed to find service: " .. name)
end

-- 3. 缓存远程服务句柄
local remote_services = {}
local function get_remote_service(name)
    if not remote_services[name] then
        remote_services[name] = query_with_retry(name)
    end
    return remote_services[name]
end
```

### 9.4 常见问题

**问题1：Harbor ID冲突**
```lua
-- 错误：多个节点使用相同的Harbor ID
-- 解决：确保每个节点的Harbor ID唯一（1-255）

-- 检查Harbor ID
local function check_harbor_id()
    local id = skynet.harbor()
    assert(id > 0 and id < 256, "Invalid harbor ID: " .. id)
    skynet.error("Current harbor ID:", id)
end
```

**问题2：跨节点调用超时**
```lua
-- 使用超时保护
local function safe_remote_call(handle, ...)
    local ok, result = pcall(skynet.call, handle, ...)
    if not ok then
        skynet.error("Remote call failed:", result)
        -- 处理错误，如重试或降级
        return handle_remote_error(result)
    end
    return result
end
```

**问题3：网络分区**
```lua
-- 监控节点状态
local function monitor_harbors()
    skynet.fork(function()
        while true do
            for id = 1, 255 do
                if harbors[id] then
                    local ok = check_harbor_alive(id)
                    if not ok then
                        handle_harbor_down(id)
                    end
                end
            end
            skynet.sleep(500)  -- 5秒检查一次
        end
    end)
end
```

**问题4：消息顺序保证**
```lua
-- Harbor不保证跨节点消息的顺序
-- 需要顺序保证时，使用session机制

local session_manager = {}
local next_session = 1

function send_ordered(target, ...)
    local session = next_session
    next_session = next_session + 1
    
    session_manager[session] = {
        time = skynet.time(),
        data = {...}
    }
    
    skynet.send(target, "lua", "ordered_msg", session, ...)
end

function handle_ordered_msg(session, ...)
    -- 根据session处理消息顺序
    process_in_order(session, ...)
end
```

**性能调优建议**：

1. **合理设置消息队列大小**：
```lua
-- 根据业务量调整队列大小
#define DEFAULT_QUEUE_SIZE 1024  // 默认值
#define MAX_QUEUE_SIZE 65536      // 最大值
```

2. **减少跨节点调用**：
```lua
-- 批量操作减少调用次数
function batch_remote_operation(target, operations)
    return skynet.call(target, "lua", "batch", operations)
end
```

3. **本地缓存远程数据**：
```lua
local cache = {}
local cache_expire = 60 * 100  -- 60秒过期

function get_remote_data(key)
    local now = skynet.time()
    if cache[key] and cache[key].expire > now then
        return cache[key].data
    end
    
    local data = skynet.call(remote_service, "lua", "get", key)
    cache[key] = {
        data = data,
        expire = now + cache_expire
    }
    return data
end
```

## 总结

Harbor系统是Skynet实现分布式架构的核心组件，通过巧妙的设计实现了：

1. **透明的跨节点通信**：应用层无需关心服务位置
2. **高效的消息路由**：直接P2P通信，避免中转
3. **灵活的部署模式**：支持多种网络拓扑
4. **可靠的故障处理**：自动重连和错误通知

Harbor的设计体现了Skynet"简单高效"的理念，用最小的代价实现了分布式支持，为游戏服务器的横向扩展提供了坚实基础。在实际使用中，需要注意Harbor ID的规划、网络配置的正确性以及跨节点调用的性能影响，合理使用缓存和批量操作可以显著提升系统性能。

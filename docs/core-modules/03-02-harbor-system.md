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

节点启动和注册流程：

```lua
-- 1. Slave节点启动后连接到Master
function connect_master()
    local fd = socket.open(master_addr)
    socket.write(fd, string.char(harbor_id))  -- 发送自己的Harbor ID
    monitor_master(fd)  -- 监听Master的指令
end

-- 2. Master接收Slave连接
function accept_slave(fd)
    local id = socket.read(fd, 1)  -- 读取Harbor ID
    slaves[id] = fd
    -- 广播新节点信息给其他Slave
    broadcast_slave_info(id, address)
end

-- 3. Slave间建立P2P连接
function connect_slave(slave_id, address)
    local fd = socket.open(address)
    slaves[slave_id] = fd
    -- 发送握手消息
    socket.write(fd, string.char(my_harbor_id))
end
```

### 2.3 全局名字服务

全局名字服务允许跨节点的服务发现：

```c
// 名字注册结构
struct remote_name {
    char name[GLOBALNAME_LENGTH];  // 16字节的全局名字
    uint32_t handle;                // 服务句柄（含Harbor ID）
};

// 注册全局名字（Lua层）
function harbor.globalname(name, handle)
    skynet.send(".cslave", "lua", "REGISTER", name, handle)
end

// 查询全局名字
function harbor.queryname(name)
    return skynet.call(".cslave", "lua", "QUERYNAME", name)
end
```

名字解析流程：
1. 本地查询缓存
2. 若未找到，向Master查询
3. Master返回服务句柄
4. 缓存结果供后续使用

### 2.4 消息路由策略

Harbor的消息路由采用智能路由策略：

```c
// 远程消息发送决策
int remote_send_handle(struct harbor *h, uint32_t source, 
                      uint32_t destination, int type, int session, 
                      const char * msg, size_t sz) {
    int harbor_id = destination >> HANDLE_REMOTE_SHIFT;
    
    if (harbor_id == h->id) {
        // 本地消息，直接投递
        skynet_send(context, source, destination, type, session, msg, sz);
        return 1;
    }
    
    struct slave * s = &h->s[harbor_id];
    if (s->fd == 0 || s->status == STATUS_HANDSHAKE) {
        // 连接未就绪，缓存消息
        push_queue(s->queue, msg, sz, &header);
    } else {
        // 直接发送
        send_remote(h->ctx, s->fd, msg, sz, &header);
    }
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

// 网络传输格式
// [4字节长度][12字节消息头][消息内容]
// 长度采用大端序，第一字节必须为0（限制单个消息最大16MB）
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

### 4.3 skynet_harbor_register：注册全局名字

实际的注册在Lua层的cslave服务中实现：

```lua
-- cslave.lua中的注册逻辑
local function register_name(name, handle)
    globalname[name] = handle
    -- 通知Master节点
    socket.write(master_fd, pack_package("N", name, handle))
    -- 通知Harbor服务
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

```c
// 消息打包（发送前）
static void send_remote(struct skynet_context * ctx, int fd, 
                       void * buffer, size_t sz, 
                       struct remote_message_header * cookie) {
    // 1. 计算总长度
    size_t sz_header = sz + sizeof(*cookie);
    
    // 2. 构造长度头（大端序）
    uint8_t size_buf[4];
    size_buf[0] = (sz_header >> 24) & 0xff;
    size_buf[1] = (sz_header >> 16) & 0xff;
    size_buf[2] = (sz_header >> 8) & 0xff;
    size_buf[3] = sz_header & 0xff;
    
    // 3. 发送：长度 + 消息头 + 消息体
    struct iovec vec[3] = {
        { size_buf, 4 },
        { cookie, sizeof(*cookie) },
        { buffer, sz }
    };
    socket_writev(fd, vec, 3);
}

// 消息解包（接收后）
static void forward_local_messsage(struct harbor *h, void *msg, int sz) {
    struct remote_message_header *header = (struct remote_message_header *)msg;
    
    // 1. 解析目标和类型
    uint32_t destination = header->destination;
    int type = destination >> HANDLE_REMOTE_SHIFT;
    destination = (destination & HANDLE_MASK) | (h->id << HANDLE_REMOTE_SHIFT);
    
    // 2. 提取消息内容
    void * message = (char *)msg + sizeof(*header);
    int size = sz - sizeof(*header);
    
    // 3. 投递到本地服务
    skynet_send(h->ctx, header->source, destination, type, 
                header->session, message, size);
}
```

## 分布式特性

### 5.1 节点间连接建立

连接建立采用两种模式：

**主动连接（Connect）**：
```c
// Slave主动连接到其他节点
static void connect_to_harbor(int harbor_id, const char *address) {
    int fd = socket_connect(address);
    // 发送自己的Harbor ID作为握手
    uint8_t handshake = my_harbor_id;
    socket_write(fd, &handshake, 1);
    // 等待对方确认
    uint8_t remote_id;
    socket_read(fd, &remote_id, 1);
    assert(remote_id == harbor_id);
}
```

**被动接受（Accept）**：
```c
// 接受其他节点的连接
static void accept_harbor(int listen_fd) {
    int fd = socket_accept(listen_fd);
    // 读取对方的Harbor ID
    uint8_t remote_id;
    socket_read(fd, &remote_id, 1);
    // 发送自己的ID确认
    uint8_t handshake = my_harbor_id;
    socket_write(fd, &handshake, 1);
    // 保存连接
    slaves[remote_id] = fd;
}
```

### 5.2 故障检测和恢复

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

**消息批处理**：
```c
// 批量发送消息减少网络开销
static void flush_message_queue(struct harbor *h, int harbor_id) {
    struct slave *s = &h->s[harbor_id];
    struct harbor_msg *m;
    
    // 收集多个消息
    int count = 0;
    size_t total_size = 0;
    while ((m = pop_queue(s->queue)) != NULL && count < MAX_BATCH) {
        batch[count++] = m;
        total_size += m->size;
    }
    
    // 批量发送
    if (count > 0) {
        send_batch(s->fd, batch, count, total_size);
    }
}
```

## 与其他模块的协作

### 6.1 与消息队列系统的集成

Harbor与消息队列系统紧密集成：

```c
// Harbor消息进入本地消息队列
static void forward_local_messsage(struct harbor *h, void *msg, int sz) {
    struct remote_message_header *header = (struct remote_message_header *)msg;
    
    // 解析消息
    uint32_t destination = header->destination & HANDLE_MASK;
    int type = header->destination >> HANDLE_REMOTE_SHIFT;
    
    // 构造本地消息
    struct skynet_message message;
    message.source = header->source;
    message.session = header->session;
    message.data = (char *)msg + sizeof(*header);
    message.sz = sz - sizeof(*header) | (type << MESSAGE_TYPE_SHIFT);
    
    // 投递到目标服务的消息队列
    skynet_context_push(destination, &message);
}
```

### 6.2 与服务管理的配合

Harbor与服务管理器协作处理服务生命周期：

```lua
-- 服务创建时注册Harbor信息
function launcher.launch(service_name, ...)
    local handle = c.launch(service_name, ...)
    -- 设置Harbor ID
    local harbor_id = skynet.harbor()
    handle = handle | (harbor_id << 24)
    return handle
end

-- 服务退出时清理Harbor资源
function harbor.exit(handle)
    -- 清理全局名字
    for name, h in pairs(globalname) do
        if h == handle then
            globalname[name] = nil
            -- 通知Master
            notify_master("D", name)
        end
    end
end
```

### 6.3 与网络层的交互

Harbor直接使用Socket API进行网络通信：

```c
// 初始化网络监听
static void harbor_listen(struct harbor *h, const char *host, int port) {
    int listen_fd = skynet_socket_listen(h->ctx, host, port, 32);
    skynet_socket_start(h->ctx, listen_fd);
    
    // 注册socket消息处理
    skynet_callback(h->ctx, h, harbor_socket_cb);
}

// Socket消息回调
static int harbor_socket_cb(struct skynet_context * context, 
                           void *ud, int type, int session, 
                           uint32_t source, const void * msg, size_t sz) {
    struct harbor *h = (struct harbor *)ud;
    const struct skynet_socket_message * message = msg;
    
    switch(message->type) {
    case SKYNET_SOCKET_TYPE_CONNECT:
        // 连接成功
        handle_connect(h, message->id);
        break;
    case SKYNET_SOCKET_TYPE_DATA:
        // 收到数据
        push_socket_data(h, message);
        break;
    case SKYNET_SOCKET_TYPE_ERROR:
    case SKYNET_SOCKET_TYPE_CLOSE:
        // 连接断开
        handle_disconnect(h, message->id);
        break;
    }
    return 0;
}
```

## 配置和部署

### 7.1 Harbor配置项

基本配置示例：

```lua
-- config
-- 节点配置
harbor = 1                          -- Harbor ID (1-255)，0表示单节点模式
address = "127.0.0.1:2526"         -- 本节点监听地址
master = "127.0.0.1:2013"          -- Master节点地址（仅Slave需要）
standalone = "0.0.0.0:2013"        -- Master监听地址（仅Master需要）

-- 启动Harbor服务
if harbor ~= 0 then
    if standalone then
        -- Master模式
        launcher.launch("cmaster", standalone)
    else
        -- Slave模式
        launcher.launch("cslave", harbor, master, address)
    end
    launcher.launch("harbor", harbor, address)
end
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

**消息合并**：
```c
// 小消息合并发送
struct message_batch {
    int count;
    struct harbor_msg messages[MAX_BATCH_SIZE];
    size_t total_size;
};

static void batch_send(struct harbor *h, int harbor_id) {
    struct slave *s = &h->s[harbor_id];
    struct message_batch batch = {0};
    
    // 收集小消息
    while (batch.count < MAX_BATCH_SIZE && 
           batch.total_size < MAX_BATCH_BYTES) {
        struct harbor_msg *m = peek_queue(s->queue);
        if (!m || m->size > MAX_BATCH_BYTES - batch.total_size)
            break;
            
        batch.messages[batch.count++] = *pop_queue(s->queue);
        batch.total_size += m->size;
    }
    
    // 批量发送
    if (batch.count > 0) {
        send_batch_messages(s->fd, &batch);
    }
}
```

**消息压缩**（可选）：
```c
// 对大消息进行压缩
static int send_compressed(int fd, void *data, size_t size) {
    if (size > COMPRESS_THRESHOLD) {
        size_t compressed_size;
        void *compressed = compress(data, size, &compressed_size);
        if (compressed_size < size * 0.8) {
            // 压缩有效，发送压缩数据
            send_with_flag(fd, compressed, compressed_size, FLAG_COMPRESSED);
            free(compressed);
            return 1;
        }
        free(compressed);
    }
    // 不压缩，直接发送
    send_with_flag(fd, data, size, FLAG_RAW);
    return 0;
}
```

### 8.2 批量消息传输

```c
// 批量传输实现
#define MAX_IOV 16

static void flush_send_queue(struct harbor *h, int harbor_id) {
    struct slave *s = &h->s[harbor_id];
    struct iovec iov[MAX_IOV];
    int iov_count = 0;
    size_t total_size = 0;
    
    // 准备批量数据
    struct harbor_msg *m;
    while ((m = pop_queue(s->queue)) != NULL && iov_count < MAX_IOV-2) {
        // 添加长度头
        uint32_t sz = m->size + sizeof(m->header);
        iov[iov_count].iov_base = &sz;
        iov[iov_count].iov_len = 4;
        iov_count++;
        
        // 添加消息
        iov[iov_count].iov_base = m;
        iov[iov_count].iov_len = sz;
        iov_count++;
        
        total_size += sz + 4;
        
        if (total_size > MAX_SEND_BUFFER)
            break;
    }
    
    // 批量发送
    if (iov_count > 0) {
        socket_writev(s->fd, iov, iov_count);
    }
}
```

### 8.3 连接池管理

```c
// 连接池实现
struct connection_pool {
    struct connection {
        int fd;
        int harbor_id;
        int ref_count;
        time_t last_active;
    } conns[MAX_CONNECTIONS];
    int count;
};

// 获取或创建连接
static int get_connection(struct connection_pool *pool, int harbor_id) {
    // 查找现有连接
    for (int i = 0; i < pool->count; i++) {
        if (pool->conns[i].harbor_id == harbor_id) {
            pool->conns[i].ref_count++;
            pool->conns[i].last_active = time(NULL);
            return pool->conns[i].fd;
        }
    }
    
    // 创建新连接
    if (pool->count < MAX_CONNECTIONS) {
        int fd = create_connection(harbor_id);
        pool->conns[pool->count].fd = fd;
        pool->conns[pool->count].harbor_id = harbor_id;
        pool->conns[pool->count].ref_count = 1;
        pool->conns[pool->count].last_active = time(NULL);
        pool->count++;
        return fd;
    }
    
    // 连接池满，复用最久未使用的
    return reuse_oldest_connection(pool, harbor_id);
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
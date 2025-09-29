# Skynet系统服务层 - 网络服务详解 Part 1

## 目录

### Part 1 - Gate服务核心
1. [概述](#概述)
2. [Gate服务架构](#gate服务架构)
3. [C层Gate实现](#c层gate实现)
4. [Lua层Gate封装](#lua层gate封装)
5. [GateServer框架](#gateserver框架)
6. [消息转发机制](#消息转发机制)
7. [连接管理策略](#连接管理策略)

### Part 2 - 网络协议与应用服务
8. [登录服务器框架](#登录服务器框架)
9. [WebSocket服务](#websocket服务)
10. [HTTP服务](#http服务)
11. [协议处理框架](#协议处理框架)
12. [实战案例](#实战案例)

---

## 概述

### 网络服务层架构

Skynet的网络服务层提供了从底层Socket到高层应用协议的完整解决方案。整个网络服务采用分层设计，各层职责清晰：

```
┌──────────────────────────────────────────────┐
│           Application Layer                  │
│  (Game Logic, Business Service)              │
└───────────────────┬──────────────────────────┘
                    │
┌──────────────────────────────────────────────┐
│         Protocol Service Layer               │
│  ┌──────────┬──────────┬──────────────┐     │
│  │  Login   │WebSocket │     HTTP      │     │
│  │ Server   │ Service  │   Service     │     │
│  └──────────┴──────────┴──────────────┘     │
└───────────────────┬──────────────────────────┘
                    │
┌──────────────────────────────────────────────┐
│         Gate Service Layer                   │
│  ┌──────────────────────────────────────┐   │
│  │   GateServer Framework               │   │
│  │   (Message Routing & Management)     │   │
│  └──────────────────────────────────────┘   │
│  ┌──────────────────────────────────────┐   │
│  │   Gate Service (Lua)                 │   │
│  │   (High-level Interface)             │   │
│  └──────────────────────────────────────┘   │
└───────────────────┬──────────────────────────┘
                    │
┌──────────────────────────────────────────────┐
│       C Gate Service Layer                   │
│  ┌──────────────────────────────────────┐   │
│  │   service_gate.c                     │   │
│  │   (Low-level Socket Management)      │   │
│  └──────────────────────────────────────┘   │
└───────────────────┬──────────────────────────┘
                    │
┌──────────────────────────────────────────────┐
│         Socket Layer                         │
│  (epoll/kqueue/select)                       │
└──────────────────────────────────────────────┘
```

### 核心特性

1. **高性能网关**: C语言实现的底层Gate服务，处理大量并发连接
2. **灵活路由**: 支持消息转发到指定Agent服务
3. **协议无关**: 框架层面不限制具体协议格式
4. **连接管理**: 自动处理连接生命周期
5. **流量控制**: 支持发送缓冲区监控和警告
6. **协议扩展**: 支持HTTP、WebSocket等高层协议

---

## Gate服务架构

### 整体设计

Gate服务是Skynet网络层的核心组件，负责管理客户端连接和消息路由：

```
┌────────────────────────────────────────────────┐
│              Gate Service Architecture         │
└────────────────────────────────────────────────┘

                    Internet
                       │
                       ▼
              ┌───────────────┐
              │  Listen Socket │
              │   (Port 8888)  │
              └───────┬───────┘
                      │ accept
    ┌─────────────────┼─────────────────┐
    │                 │                 │
    ▼                 ▼                 ▼
┌────────┐      ┌────────┐      ┌────────┐
│ fd:101 │      │ fd:102 │      │ fd:103 │
│ Client │      │ Client │      │ Client │
└───┬────┘      └───┬────┘      └───┬────┘
    │               │               │
    └───────────────┼───────────────┘
                    │
                    ▼
         ┌─────────────────────┐
         │    Gate Service     │
         │                     │
         │  Connection Pool:   │
         │  ┌──────────────┐  │
         │  │ fd→connection│  │
         │  │   mapping    │  │
         │  └──────────────┘  │
         │                     │
         │  Message Router:    │
         │  ┌──────────────┐  │
         │  │ fd→agent     │  │
         │  │   binding    │  │
         │  └──────────────┘  │
         └──────────┬──────────┘
                    │
         ┌──────────┼──────────┐
         │          │          │
         ▼          ▼          ▼
    ┌────────┐ ┌────────┐ ┌────────┐
    │Agent #1│ │Agent #2│ │Agent #3│
    │ fd:101 │ │ fd:102 │ │ fd:103 │
    └────────┘ └────────┘ └────────┘
```

### 工作模式

Gate服务支持两种工作模式：

#### 1. Watchdog模式

```lua
-- 消息先发送给Watchdog，由Watchdog决定如何处理
Gate ──► Watchdog ──► Agent
```

特点：
- Watchdog负责创建和管理Agent
- 灵活的连接分配策略
- 支持认证、负载均衡等高级功能

#### 2. Broker模式

```lua
-- 消息直接发送给指定的Broker服务
Gate ──► Broker
```

特点：
- 所有消息集中处理
- 适合简单的转发场景
- 减少服务间通信开销

---

## C层Gate实现

### 数据结构

**文件位置**: `service-src/service_gate.c`

#### 连接结构

```c
struct connection {
    int id;                    // skynet_socket id
    uint32_t agent;            // 处理该连接的agent服务地址
    uint32_t client;           // client服务地址（用于response）
    char remote_name[32];      // 远程地址字符串
    struct databuffer buffer;  // 数据缓冲区
};
```

#### Gate结构

```c
struct gate {
    struct skynet_context *ctx;  // skynet上下文
    int listen_id;                // 监听socket id
    uint32_t watchdog;            // watchdog服务地址
    uint32_t broker;              // broker服务地址
    int client_tag;               // 客户端消息类型标记
    int header_size;              // 消息头大小
    int max_connection;           // 最大连接数
    struct hashid hash;           // fd到索引的哈希表
    struct connection *conn;      // 连接数组
    struct messagepool mp;        // 消息池
};
```

### 核心功能实现

#### 1. 监听端口

```c
// 处理"listen"命令
static void _listen(struct gate *g, char * addr, int port, int backlog) {
    struct skynet_context * ctx = g->ctx;
    
    // 创建监听socket
    int listen_fd = skynet_socket_listen(ctx, addr, port, backlog);
    if (listen_fd < 0) {
        skynet_error(ctx, "Listen error");
        return;
    }
    
    g->listen_id = listen_fd;
    skynet_socket_start(ctx, listen_fd);
}
```

#### 2. 接受连接

```c
// Socket回调：新连接
static void _accept(struct gate *g, int listen_fd, int client_fd, 
                   char * remote_addr) {
    struct skynet_context * ctx = g->ctx;
    
    // 检查连接数限制
    if (g->client_count >= g->max_connection) {
        skynet_socket_close(ctx, client_fd);
        return;
    }
    
    // 分配连接结构
    int index = hashid_insert(&g->hash, client_fd);
    struct connection * c = &g->conn[index];
    
    c->id = client_fd;
    c->agent = 0;
    c->client = 0;
    memcpy(c->remote_name, remote_addr, 32);
    databuffer_init(&c->buffer, &g->mp);
    
    // 通知watchdog
    _report(g, "%d open %d %s", client_fd, client_fd, remote_addr);
    
    // 暂不启动socket读取，等待forward命令
}
```

#### 3. 消息转发

```c
static void _forward(struct gate *g, struct connection * c, int size) {
    struct skynet_context * ctx = g->ctx;
    int fd = c->id;
    
    if (fd <= 0) {
        return;  // socket错误
    }
    
    // Broker模式：转发给broker
    if (g->broker) {
        void * temp = skynet_malloc(size);
        databuffer_read(&c->buffer, &g->mp, (char *)temp, size);
        skynet_send(ctx, 0, g->broker, 
                   g->client_tag | PTYPE_TAG_DONTCOPY, 
                   fd, temp, size);
        return;
    }
    
    // Agent模式：转发给指定agent
    if (c->agent) {
        void * temp = skynet_malloc(size);
        databuffer_read(&c->buffer, &g->mp, (char *)temp, size);
        skynet_send(ctx, c->client, c->agent, 
                   g->client_tag | PTYPE_TAG_DONTCOPY, 
                   fd, temp, size);
    } 
    // Watchdog模式：发送给watchdog
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

#### 4. 数据包处理

```c
static void dispatch_message(struct gate *g, struct connection *c, 
                            int id, void * data, int sz) {
    // 将数据推入缓冲区
    databuffer_push(&c->buffer, &g->mp, data, sz);
    
    // 循环处理完整的数据包
    for (;;) {
        // 读取消息头，获取消息大小
        int size = databuffer_readheader(&c->buffer, &g->mp, 
                                        g->header_size);
        if (size < 0) {
            return;  // 数据不完整
        }
        
        if (size > 0) {
            // 处理边界检查
            if (c->buffer.size < size) {
                return;  // 数据体不完整
            }
            
            // 转发完整的消息
            _forward(g, c, size);
        }
    }
}
```

#### 5. 控制命令处理

```c
static void _ctrl(struct gate * g, const void * msg, int sz) {
    struct skynet_context * ctx = g->ctx;
    char tmp[sz+1];
    memcpy(tmp, msg, sz);
    tmp[sz] = '\0';
    
    char * command = tmp;
    // 解析命令
    int i;
    for (i=0; i<sz; i++) {
        if (command[i]==' ') {
            break;
        }
    }
    
    // 处理各种命令
    if (memcmp(command, "kick", i) == 0) {
        // 踢掉连接
        _parm(tmp, sz, i);
        int fd = strtol(command, NULL, 10);
        int id = hashid_lookup(&g->hash, fd);
        if (id >= 0) {
            skynet_socket_close(ctx, fd);
        }
        return;
    }
    
    if (memcmp(command, "forward", i) == 0) {
        // 设置转发目标
        _parm(tmp, sz, i);
        char * client = tmp;
        char * idstr = strsep(&client, " ");
        int fd = strtol(idstr, NULL, 10);
        char * agent = strsep(&client, " ");
        uint32_t agent_handle = strtoul(agent+1, NULL, 16);
        uint32_t client_handle = strtoul(client+1, NULL, 16);
        _forward_agent(g, fd, agent_handle, client_handle);
        
        // 启动socket读取
        skynet_socket_start(ctx, fd);
        return;
    }
    
    if (memcmp(command, "broker", i) == 0) {
        // 设置broker
        _parm(tmp, sz, i);
        g->broker = skynet_queryname(ctx, command);
        return;
    }
    
    if (memcmp(command, "start", i) == 0) {
        // 启动socket
        _parm(tmp, sz, i);
        int fd = strtol(command, NULL, 10);
        int id = hashid_lookup(&g->hash, fd);
        if (id >= 0) {
            skynet_socket_start(ctx, fd);
        }
        return;
    }
    
    if (memcmp(command, "close", i) == 0) {
        // 关闭监听
        if (g->listen_id >= 0) {
            skynet_socket_close(ctx, g->listen_id);
            g->listen_id = -1;
        }
        return;
    }
}
```

### 消息协议

#### 1. 默认协议格式

Gate服务支持两种消息头格式：

```c
// 2字节头（大端序）
uint16_t size;  // 消息体大小

// 4字节头（大端序）
uint32_t size;  // 消息体大小
```

#### 2. 自定义协议

通过header_size参数可以自定义消息头：

```lua
-- 配置2字节头
gate.open(watchdog, {
    address = "0.0.0.0",
    port = 8888,
    header = 2,  -- 2字节消息头
})

-- 配置4字节头
gate.open(watchdog, {
    address = "0.0.0.0",
    port = 8888,
    header = 4,  -- 4字节消息头
})
```

---

## Lua层Gate封装

### Gate服务实现

**文件位置**: `service/gate.lua`

```lua
local skynet = require "skynet"
local gateserver = require "snax.gateserver"

local watchdog
local connection = {}  -- fd -> connection info

-- 注册client协议
skynet.register_protocol {
    name = "client",
    id = skynet.PTYPE_CLIENT,
}

local handler = {}

-- 服务启动
function handler.open(source, conf)
    watchdog = conf.watchdog or source
    return conf.address, conf.port
end

-- 处理客户端消息
function handler.message(fd, msg, sz)
    local c = connection[fd]
    local agent = c.agent
    
    if agent then
        -- 已绑定agent，直接转发
        -- 使用redirect避免消息拷贝
        skynet.redirect(agent, c.client, "client", fd, msg, sz)
    else
        -- 未绑定，发送给watchdog
        skynet.send(watchdog, "lua", "socket", "data", fd, 
                   skynet.tostring(msg, sz))
        -- tostring会拷贝消息，需要释放原始消息
        skynet.trash(msg, sz)
    end
end

-- 新连接
function handler.connect(fd, addr)
    local c = {
        fd = fd,
        ip = addr,
    }
    connection[fd] = c
    skynet.send(watchdog, "lua", "socket", "open", fd, addr)
end

-- 断开连接
function handler.disconnect(fd)
    close_fd(fd)
    skynet.send(watchdog, "lua", "socket", "close", fd)
end

-- 连接错误
function handler.error(fd, msg)
    close_fd(fd)
    skynet.send(watchdog, "lua", "socket", "error", fd, msg)
end

-- 发送缓冲区警告
function handler.warning(fd, size)
    skynet.send(watchdog, "lua", "socket", "warning", fd, size)
end

local CMD = {}

-- 绑定agent
function CMD.forward(source, fd, client, address)
    local c = assert(connection[fd])
    unforward(c)  -- 清除旧绑定
    c.client = client or 0
    c.agent = address or source
    gateserver.openclient(fd)  -- 开始接收数据
end

-- 接受连接（不绑定agent）
function CMD.accept(source, fd)
    local c = assert(connection[fd])
    unforward(c)
    gateserver.openclient(fd)
end

-- 踢掉连接
function CMD.kick(source, fd)
    gateserver.closeclient(fd)
end

-- 处理命令
function handler.command(cmd, source, ...)
    local f = assert(CMD[cmd])
    return f(source, ...)
end

-- 启动gate服务
gateserver.start(handler)
```

### 关键机制

#### 1. 消息转发优化

```lua
-- 使用redirect避免消息拷贝
skynet.redirect(agent, c.client, "client", fd, msg, sz)

-- redirect vs send的区别：
-- send: 消息会被拷贝，原消息由发送方释放
-- redirect: 消息所有权转移，避免拷贝，提高效率
```

#### 2. 连接状态管理

```lua
local connection = {}

-- 连接信息
connection[fd] = {
    fd = fd,        -- socket fd
    ip = addr,      -- 客户端地址
    agent = handle, -- 处理agent
    client = handle -- 响应地址
}
```

#### 3. 协议注册

```lua
-- 注册client协议，用于接收客户端消息
skynet.register_protocol {
    name = "client",
    id = skynet.PTYPE_CLIENT,
}

-- Agent服务需要处理client协议
skynet.dispatch("client", function(_, _, fd, msg)
    -- 处理客户端消息
end)
```

---

## GateServer框架

### 概述

GateServer是一个通用的网关服务框架，提供了更高层的抽象。

**文件位置**: `lualib/snax/gateserver.lua`

### 核心结构

```lua
local gateserver = {}

local socket        -- 监听socket
local queue         -- 消息队列
local maxclient     -- 最大客户端数
local client_number = 0
local CMD = {}
local nodelay = false
local connection = {}  -- fd -> 连接状态
```

### Handler接口

使用GateServer需要实现以下handler：

```lua
local handler = {}

-- 必须实现的接口
function handler.message(fd, msg, sz)
    -- 处理客户端消息
end

function handler.connect(fd, addr)
    -- 处理新连接
end

-- 可选接口
function handler.open(source, conf)
    -- 服务启动
    return listen_addr, listen_port
end

function handler.disconnect(fd)
    -- 连接断开
end

function handler.error(fd, msg)
    -- 连接错误
end

function handler.warning(fd, size)
    -- 缓冲区警告
end

function handler.command(cmd, source, ...)
    -- 处理命令
end
```

### 消息队列机制

```lua
-- 消息分发
local function dispatch_msg(fd, msg, sz)
    if connection[fd] then
        handler.message(fd, msg, sz)
    else
        skynet.error(string.format(
            "Drop message from fd (%d) : %s", 
            fd, netpack.tostring(msg,sz)))
    end
end

-- 队列处理
local function dispatch_queue()
    local fd, msg, sz = netpack.pop(queue)
    if fd then
        -- Fork新协程处理队列，避免阻塞
        skynet.fork(dispatch_queue)
        dispatch_msg(fd, msg, sz)
        
        -- 继续处理队列中的消息
        for fd, msg, sz in netpack.pop, queue do
            dispatch_msg(fd, msg, sz)
        end
    end
end
```

### 连接管理

```lua
-- 打开客户端（开始接收数据）
function gateserver.openclient(fd)
    if connection[fd] then
        socketdriver.start(fd)
    end
end

-- 关闭客户端
function gateserver.closeclient(fd)
    local c = connection[fd]
    if c ~= nil then
        connection[fd] = nil
        socketdriver.close(fd)
    end
end
```

### Socket事件处理

```lua
local MSG = {}

-- 新连接
function MSG.open(fd, msg)
    client_number = client_number + 1
    if client_number >= maxclient then
        socketdriver.shutdown(fd)
        return
    end
    
    if nodelay then
        socketdriver.nodelay(fd)  -- 禁用Nagle算法
    end
    
    connection[fd] = true
    handler.connect(fd, msg)
end

-- 接收数据
MSG.data = dispatch_msg

-- 消息队列有积压
MSG.more = dispatch_queue

-- 连接关闭
function MSG.close(fd)
    if fd ~= socket then
        client_number = client_number - 1
        if connection[fd] then
            connection[fd] = false  -- 标记为关闭读
        end
        if handler.disconnect then
            handler.disconnect(fd)
        end
    else
        socket = nil  -- 监听socket关闭
    end
end

-- 连接错误
function MSG.error(fd, msg)
    if fd == socket then
        skynet.error("gateserver accept error:", msg)
    else
        socketdriver.shutdown(fd)
        if handler.error then
            handler.error(fd, msg)
        end
    end
end

-- 缓冲区警告
function MSG.warning(fd, size)
    if handler.warning then
        handler.warning(fd, size)
    end
end
```

### 启动流程

```lua
function gateserver.start(handler)
    assert(handler.message)
    assert(handler.connect)
    
    -- 注册socket协议
    skynet.register_protocol {
        name = "socket",
        id = skynet.PTYPE_SOCKET,
        unpack = function (msg, sz)
            return netpack.filter(queue, msg, sz)
        end,
        dispatch = function (_, _, q, type, ...)
            queue = q
            if type then
                MSG[type](...)
            end
        end
    }
    
    -- 注册lua协议处理命令
    skynet.dispatch("lua", function(_, source, cmd, ...)
        local f = CMD[cmd]
        if f then
            skynet.ret(skynet.pack(f(source, ...)))
        else
            -- 调用handler.command
            local ret = handler.command(cmd, source, ...)
            if ret ~= nil then
                skynet.ret(skynet.pack(ret))
            end
        end
    end)
end
```

---

## 消息转发机制

### 转发流程

```
┌────────────────────────────────────────────────┐
│          Message Forward Flow                  │
└────────────────────────────────────────────────┘

Client发送数据
    │
    ▼
Socket层接收
    │
    ▼
Gate C服务
    │
    ├─► 有Agent绑定？
    │   │
    │   ├─► Yes: 直接转发给Agent
    │   │   └─► skynet_send(agent, "client", data)
    │   │
    │   └─► No: 发送给Watchdog
    │       └─► skynet_send(watchdog, "lua", "socket", "data", data)
    │
    ▼
Agent/Watchdog处理
    │
    ▼
业务逻辑
```

### 绑定机制

#### 1. Forward命令

```lua
-- Watchdog决定将连接绑定到Agent
skynet.call(gate, "lua", "forward", fd, client, agent)

-- Gate内部处理
function CMD.forward(source, fd, client, address)
    local c = assert(connection[fd])
    c.client = client or 0
    c.agent = address or source
    gateserver.openclient(fd)  -- 开始接收数据
end
```

#### 2. 消息路由

```lua
function handler.message(fd, msg, sz)
    local c = connection[fd]
    if c.agent then
        -- 已绑定：直接转发
        skynet.redirect(c.agent, c.client, "client", fd, msg, sz)
    else
        -- 未绑定：发给Watchdog
        skynet.send(watchdog, "lua", "socket", "data", fd, data)
    end
end
```

### 性能优化

#### 1. Zero-Copy转发

```lua
-- 使用redirect实现零拷贝
skynet.redirect(agent, client, "client", fd, msg, sz)

-- redirect的优势：
-- 1. 消息指针直接传递，无需拷贝
-- 2. 消息所有权转移到目标服务
-- 3. 大幅减少内存分配和拷贝开销
```

#### 2. 批量处理

```lua
-- GateServer的队列机制
local function dispatch_queue()
    local fd, msg, sz = netpack.pop(queue)
    if fd then
        skynet.fork(dispatch_queue)  -- 并发处理
        dispatch_msg(fd, msg, sz)
        
        -- 批量处理队列中的消息
        for fd, msg, sz in netpack.pop, queue do
            dispatch_msg(fd, msg, sz)
        end
    end
end
```

#### 3. Nagle算法控制

```lua
-- 禁用Nagle算法，减少延迟
if nodelay then
    socketdriver.nodelay(fd)
end

-- 适用场景：
-- 1. 实时游戏：需要低延迟
-- 2. 小包频繁：避免等待合并
-- 3. 交互密集：即时响应
```

---

## 连接管理策略

### 连接池设计

```lua
-- 预分配连接结构
local connection_pool = {}
local pool_size = 10000

function init_pool()
    for i = 1, pool_size do
        connection_pool[i] = {
            fd = 0,
            agent = nil,
            client = nil,
            buffer = {},
        }
    end
end

-- 分配连接
function alloc_connection(fd)
    local c = table.remove(connection_pool)
    if not c then
        c = { fd = fd }
    end
    return c
end

-- 回收连接
function free_connection(c)
    c.fd = 0
    c.agent = nil
    c.client = nil
    table.insert(connection_pool, c)
end
```

### 连接限制

```lua
-- 最大连接数控制
local max_connection = 10000
local current_connection = 0

function check_connection_limit(fd)
    if current_connection >= max_connection then
        -- 拒绝新连接
        socketdriver.shutdown(fd)
        skynet.error("Connection limit reached:", current_connection)
        return false
    end
    
    current_connection = current_connection + 1
    return true
end

-- 连接断开时
function on_disconnect(fd)
    current_connection = current_connection - 1
end
```

### 连接认证

```lua
-- 连接认证状态
local auth_status = {}  -- fd -> { authed, timeout }

function handler.connect(fd, addr)
    auth_status[fd] = {
        authed = false,
        timeout = skynet.timeout(3000, function()  -- 30秒超时
            if not auth_status[fd].authed then
                skynet.error("Auth timeout:", fd)
                gateserver.closeclient(fd)
            end
        end)
    }
end

function CMD.auth_success(source, fd)
    local status = auth_status[fd]
    if status then
        status.authed = true
        -- 取消超时定时器
        skynet.unregister_timeout(status.timeout)
        
        -- 绑定到Agent
        local agent = create_agent()
        CMD.forward(source, fd, 0, agent)
    end
end
```

### 连接保活

```lua
-- 心跳检测
local heartbeat = {}  -- fd -> last_heartbeat_time

function start_heartbeat_check()
    skynet.fork(function()
        while true do
            skynet.sleep(1000)  -- 10秒检查一次
            
            local now = skynet.now()
            for fd, last_time in pairs(heartbeat) do
                if now - last_time > 3000 then  -- 30秒无心跳
                    skynet.error("Heartbeat timeout:", fd)
                    gateserver.closeclient(fd)
                    heartbeat[fd] = nil
                end
            end
        end
    end)
end

function on_heartbeat(fd)
    heartbeat[fd] = skynet.now()
end
```

### 流量控制

```lua
-- 发送缓冲区监控
function handler.warning(fd, size)
    skynet.error("Send buffer warning:", fd, size, "KB")
    
    if size > 1024 then  -- 超过1MB
        -- 标记为慢速客户端
        mark_slow_client(fd)
        
        if size > 5120 then  -- 超过5MB
            -- 强制断开
            skynet.error("Force disconnect slow client:", fd)
            gateserver.closeclient(fd)
        end
    end
end

-- 限速策略
local rate_limit = {}  -- fd -> { count, reset_time }
local max_msg_per_second = 100

function check_rate_limit(fd)
    local now = skynet.now()
    local limit = rate_limit[fd]
    
    if not limit then
        limit = { count = 0, reset_time = now + 100 }
        rate_limit[fd] = limit
    end
    
    if now >= limit.reset_time then
        limit.count = 0
        limit.reset_time = now + 100
    end
    
    limit.count = limit.count + 1
    if limit.count > max_msg_per_second then
        skynet.error("Rate limit exceeded:", fd)
        return false
    end
    
    return true
end
```

### 连接分组

```lua
-- 按类型分组管理
local connection_groups = {
    normal = {},   -- 普通玩家
    vip = {},      -- VIP玩家
    admin = {},    -- 管理员
    robot = {},    -- 机器人
}

function assign_group(fd, group_type)
    local c = connection[fd]
    if c then
        c.group = group_type
        connection_groups[group_type][fd] = c
    end
end

-- 分组广播
function broadcast_to_group(group_type, msg)
    local group = connection_groups[group_type]
    for fd, c in pairs(group) do
        if c.agent then
            skynet.send(c.agent, "lua", "broadcast", msg)
        end
    end
end

-- 分组统计
function get_group_stats()
    local stats = {}
    for group_type, conns in pairs(connection_groups) do
        local count = 0
        for _ in pairs(conns) do
            count = count + 1
        end
        stats[group_type] = count
    end
    return stats
end
```

---

## 本章小结

本章详细介绍了Skynet网络服务的核心组件Gate服务，包括：

1. **架构设计**: 分层架构，职责清晰
2. **C层实现**: 高性能的底层网关
3. **Lua层封装**: 灵活的上层接口
4. **GateServer框架**: 通用的网关框架
5. **消息转发**: 高效的零拷贝转发
6. **连接管理**: 完善的连接生命周期管理

Gate服务是构建高性能网络服务的基础，理解其工作原理对开发Skynet应用至关重要。

下一部分将介绍基于Gate构建的高层网络服务，包括登录服务器、WebSocket服务、HTTP服务等。

---

**文档版本**: 1.0  
**最后更新**: 2024-01-XX  
**适用版本**: Skynet 1.x
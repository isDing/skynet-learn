# Skynet Lua框架层 - 网络通信基础架构详解

## 目录

- [1. 网络通信架构概述](#1-网络通信架构概述)
  - [1.1 分层设计](#11-分层设计)
  - [1.2 核心组件](#12-核心组件)
  - [1.3 消息流转](#13-消息流转)
- [2. Socket API详解](#2-socket-api详解)
  - [2.1 连接管理](#21-连接管理)
  - [2.2 数据读写](#22-数据读写)
  - [2.3 缓冲区管理](#23-缓冲区管理)
  - [2.4 协程调度](#24-协程调度)
- [3. 网络消息处理机制](#3-网络消息处理机制)
  - [3.1 消息类型](#31-消息类型)
  - [3.2 消息分发](#32-消息分发)
  - [3.3 错误处理](#33-错误处理)
- [4. Gate服务架构](#4-gate服务架构)
  - [4.1 GateServer框架](#41-gateserver框架)
  - [4.2 连接管理](#42-连接管理)
  - [4.3 消息转发](#43-消息转发)
- [5. NetPack协议解析](#5-netpack协议解析)
  - [5.1 包格式设计](#51-包格式设计)
  - [5.2 粘包处理](#52-粘包处理)
  - [5.3 缓存管理](#53-缓存管理)
- [6. UDP支持](#6-udp支持)
  - [6.1 UDP API](#61-udp-api)
  - [6.2 使用场景](#62-使用场景)
- [7. 高级特性](#7-高级特性)
  - [7.1 流量控制](#71-流量控制)
  - [7.2 性能优化](#72-性能优化)
  - [7.3 最佳实践](#73-最佳实践)

## 1. 网络通信架构概述

### 1.1 分层设计

Skynet的网络通信采用多层架构设计，从底层到上层分为：

```
应用层
  ├── 业务服务 (Agent、Game Logic)
  │
网关层
  ├── Gate Service
  ├── GateServer Framework
  │
协议层
  ├── NetPack (包协议处理)
  ├── HTTP/WebSocket (应用协议)
  │
Socket层
  ├── Socket API (Lua接口)
  ├── Socket Driver (C扩展)
  │
系统层
  └── Socket Server (C核心)
```

**设计理念：**
- **层次分明**：每层职责明确，便于维护和扩展
- **协程模型**：利用Lua协程实现异步I/O的同步化编程
- **零拷贝**：减少数据复制，提高性能
- **背压控制**：自动流量控制，防止内存溢出

### 1.2 核心组件

```lua
-- lualib/skynet/socket.lua
local socket = {}
local socket_pool = setmetatable({}, {
    __gc = function(p)
        -- 自动清理socket资源
        for id, v in pairs(p) do
            driver.close(id)
            p[id] = nil
        end
    end
})
```

**核心数据结构：**
```lua
-- Socket对象
local s = {
    id = id,                  -- socket句柄
    buffer = newbuffer,       -- 接收缓冲区
    pool = {},               -- 缓冲池
    connected = false,       -- 连接状态
    connecting = true,       -- 正在连接
    read_required = false,   -- 读取需求(大小/行/全部)
    co = false,             -- 等待的协程
    callback = func,        -- 回调函数(用于accept)
    protocol = "TCP",       -- 协议类型
    pause = false,          -- 暂停状态
    closing = false,        -- 关闭中
    buffer_limit = nil,     -- 缓冲区限制
    on_warning = nil,       -- 警告回调
}
```

### 1.3 消息流转

网络消息从底层到上层的流转过程：

```
1. epoll/kqueue事件 → Socket Server
2. Socket Server → 生成socket消息
3. socket消息 → 服务的消息队列
4. 服务dispatch → socket协议处理
5. socket.lua → 唤醒等待的协程
6. 业务代码 → 处理数据
```

## 2. Socket API详解

### 2.1 连接管理

#### 2.1.1 建立连接

```lua
function socket.open(addr, port)
    local id = driver.connect(addr, port)
    return connect(id)
end

local function connect(id, func)
    local newbuffer
    if func == nil then
        newbuffer = driver.buffer()  -- 创建接收缓冲区
    end
    local s = {
        id = id,
        buffer = newbuffer,
        pool = newbuffer and {},
        connected = false,
        connecting = true,
        read_required = false,
        co = false,
        callback = func,
        protocol = "TCP",
    }
    
    socket_pool[id] = s
    suspend(s)  -- 挂起等待连接完成
    
    local err = s.connecting
    s.connecting = nil
    if s.connected then
        return id
    else
        socket_pool[id] = nil
        return nil, err
    end
end
```

**连接过程：**
1. 调用底层driver创建socket
2. 创建socket对象并加入池
3. 挂起当前协程等待连接结果
4. 连接成功返回id，失败返回错误

#### 2.1.2 监听端口

```lua
function socket.listen(host, port, backlog)
    if port == nil then
        -- 解析"host:port"格式
        host, port = string.match(host, "([^:]+):(.+)$")
        port = tonumber(port)
    end
    local id = driver.listen(host, port, backlog)
    local s = {
        id = id,
        connected = false,
        listen = true,
    }
    socket_pool[id] = s
    suspend(s)  -- 等待监听成功
    return id, s.addr, s.port
end
```

#### 2.1.3 关闭连接

```lua
function socket.close(id)
    local s = socket_pool[id]
    if s == nil then
        return
    end
    driver.close(id)
    
    if s.connected then
        s.pause = false
        if s.co then
            -- 有协程正在读取，等待其完成
            assert(not s.closing)
            s.closing = coroutine.running()
            skynet.wait(s.closing)
        else
            suspend(s)
        end
        s.connected = false
    end
    socket_pool[id] = nil
end
```

### 2.2 数据读写

#### 2.2.1 读取数据

```lua
function socket.read(id, sz)
    local s = socket_pool[id]
    assert(s)
    
    if sz == nil then
        -- 读取所有可用数据
        local ret = driver.readall(s.buffer, s.pool)
        if ret ~= "" then
            return ret
        end
        
        if not s.connected then
            return false, ret
        end
        
        assert(not s.read_required)
        s.read_required = 0  -- 标记需要读取任意数据
        suspend(s)
        ret = driver.readall(s.buffer, s.pool)
        if ret ~= "" then
            return ret
        else
            return false, ret
        end
    end
    
    -- 读取指定大小
    local ret = driver.pop(s.buffer, s.pool, sz)
    if ret then
        return ret
    end
    
    if s.closing or not s.connected then
        return false, driver.readall(s.buffer, s.pool)
    end
    
    assert(not s.read_required)
    s.read_required = sz  -- 标记需要读取的大小
    suspend(s)
    ret = driver.pop(s.buffer, s.pool, sz)
    if ret then
        return ret
    else
        return false, driver.readall(s.buffer, s.pool)
    end
end
```

#### 2.2.2 按行读取

```lua
function socket.readline(id, sep)
    sep = sep or "\n"
    local s = socket_pool[id]
    assert(s)
    
    local ret = driver.readline(s.buffer, s.pool, sep)
    if ret then
        return ret
    end
    
    if not s.connected then
        return false, driver.readall(s.buffer, s.pool)
    end
    
    assert(not s.read_required)
    s.read_required = sep  -- 标记行分隔符
    suspend(s)
    
    if s.connected then
        return driver.readline(s.buffer, s.pool, sep)
    else
        return false, driver.readall(s.buffer, s.pool)
    end
end
```

#### 2.2.3 写入数据

```lua
-- 直接使用driver的send函数
socket.write = assert(driver.send)
socket.lwrite = assert(driver.lsend)  -- 发送字符串列表

-- 使用示例
local ok = socket.write(id, data)
local ok = socket.lwrite(id, {"hello", " ", "world"})
```

### 2.3 缓冲区管理

#### 2.3.1 缓冲区控制

```lua
local BUFFER_LIMIT = 128 * 1024  -- 默认128KB限制

local function pause_socket(s, size)
    if s.pause ~= nil then
        return
    end
    if size then
        skynet.error(string.format("Pause socket (%d) size : %d", s.id, size))
    else
        skynet.error(string.format("Pause socket (%d)", s.id))
    end
    driver.pause(s.id)  -- 暂停接收
    s.pause = true
    skynet.yield()  -- 让出执行，处理已有消息
end
```

#### 2.3.2 流量控制

```lua
-- 数据到达处理
socket_message[1] = function(id, size, data)
    local s = socket_pool[id]
    if s == nil then
        skynet.error("socket: drop package from " .. id)
        driver.drop(data, size)
        return
    end
    
    local sz = driver.push(s.buffer, s.pool, data, size)
    local rr = s.read_required
    local rrt = type(rr)
    
    if rrt == "number" then
        -- 读取指定大小
        if sz >= rr then
            s.read_required = nil
            if sz > BUFFER_LIMIT then
                pause_socket(s, sz)  -- 超限暂停
            end
            wakeup(s)
        end
    else
        -- 检查缓冲区限制
        if s.buffer_limit and sz > s.buffer_limit then
            skynet.error(string.format("socket buffer overflow: fd=%d size=%d", id, sz))
            driver.close(id)
            return
        end
        
        if rrt == "string" then
            -- 读取行
            if driver.readline(s.buffer, nil, rr) then
                s.read_required = nil
                if sz > BUFFER_LIMIT then
                    pause_socket(s, sz)
                end
                wakeup(s)
            end
        elseif sz > BUFFER_LIMIT and not s.pause then
            pause_socket(s, sz)
        end
    end
end
```

### 2.4 协程调度

#### 2.4.1 挂起与唤醒

```lua
local function wakeup(s)
    local co = s.co
    if co then
        s.co = nil
        skynet.wakeup(co)
    end
end

local function suspend(s)
    assert(not s.co)
    s.co = coroutine.running()
    
    if s.pause then
        -- 恢复接收
        skynet.error(string.format("Resume socket (%d)", s.id))
        driver.start(s.id)
        skynet.wait(s.co)
        s.pause = nil
    else
        skynet.wait(s.co)
    end
    
    -- 唤醒关闭中的协程
    if s.closing then
        skynet.wakeup(s.closing)
    end
end
```

## 3. 网络消息处理机制

### 3.1 消息类型

```lua
-- Socket消息类型定义
-- SKYNET_SOCKET_TYPE_DATA = 1      数据到达
-- SKYNET_SOCKET_TYPE_CONNECT = 2   连接成功
-- SKYNET_SOCKET_TYPE_CLOSE = 3     连接关闭
-- SKYNET_SOCKET_TYPE_ACCEPT = 4    接受新连接
-- SKYNET_SOCKET_TYPE_ERROR = 5     错误发生
-- SKYNET_SOCKET_TYPE_UDP = 6       UDP数据
-- SKYNET_SOCKET_TYPE_WARNING = 7   发送警告

socket_message = {}  -- 消息处理函数表
```

### 3.2 消息分发

```lua
-- 注册socket协议处理
skynet.register_protocol {
    name = "socket",
    id = skynet.PTYPE_SOCKET,
    unpack = driver.unpack,
    dispatch = function(_, _, t, ...)
        socket_message[t](...)
    end
}
```

#### 3.2.1 连接消息处理

```lua
-- SKYNET_SOCKET_TYPE_CONNECT = 2
socket_message[2] = function(id, ud, addr)
    local s = socket_pool[id]
    if s == nil then
        return
    end
    
    if not s.connected then
        if s.listen then
            s.addr = addr
            s.port = ud
        end
        s.connected = true
        wakeup(s)  -- 唤醒等待的协程
    end
end
```

#### 3.2.2 接受连接处理

```lua
-- SKYNET_SOCKET_TYPE_ACCEPT = 4
socket_message[4] = function(id, newid, addr)
    local s = socket_pool[id]
    if s == nil then
        driver.close(newid)
        return
    end
    s.callback(newid, addr)  -- 调用accept回调
end
```

#### 3.2.3 关闭消息处理

```lua
-- SKYNET_SOCKET_TYPE_CLOSE = 3
socket_message[3] = function(id)
    local s = socket_pool[id]
    if s then
        s.connected = false
        wakeup(s)
    else
        driver.close(id)
    end
    
    local cb = socket_onclose[id]
    if cb then
        cb(id)  -- 调用关闭回调
        socket_onclose[id] = nil
    end
end
```

### 3.3 错误处理

```lua
-- SKYNET_SOCKET_TYPE_ERROR = 5
socket_message[5] = function(id, _, err)
    local s = socket_pool[id]
    if s == nil then
        driver.shutdown(id)
        skynet.error("socket: error on unknown", id, err)
        return
    end
    
    if s.callback then
        -- 监听socket错误
        skynet.error("socket: accept error:", err)
        return
    end
    
    if s.connected then
        skynet.error("socket: error on", id, err)
    elseif s.connecting then
        s.connecting = err  -- 保存错误信息
    end
    
    s.connected = false
    driver.shutdown(id)
    wakeup(s)
end
```

## 4. Gate服务架构

### 4.1 GateServer框架

GateServer是Skynet提供的网关服务框架，用于管理大量客户端连接：

```lua
-- lualib/snax/gateserver.lua
local gateserver = {}

function gateserver.start(handler)
    assert(handler.message)  -- 消息处理
    assert(handler.connect)  -- 连接处理
    
    local function init()
        skynet.dispatch("lua", function(_, address, cmd, ...)
            local f = CMD[cmd]
            if f then
                skynet.ret(skynet.pack(f(address, ...)))
            else
                skynet.ret(skynet.pack(handler.command(cmd, address, ...)))
            end
        end)
    end
    
    if handler.embed then
        init()
    else
        skynet.start(init)
    end
end
```

### 4.2 连接管理

#### 4.2.1 打开监听

```lua
function CMD.open(source, conf)
    assert(not socket)
    local address = conf.address or "0.0.0.0"
    local port = assert(conf.port)
    maxclient = conf.maxclient or 1024
    nodelay = conf.nodelay
    
    skynet.error(string.format("Listen on %s:%d", address, port))
    socket = socketdriver.listen(address, port, conf.backlog)
    
    -- 等待监听成功
    listen_context.co = coroutine.running()
    listen_context.fd = socket
    skynet.wait(listen_context.co)
    
    conf.address = listen_context.addr
    conf.port = listen_context.port
    listen_context = nil
    
    socketdriver.start(socket)
    
    if handler.open then
        return handler.open(source, conf)
    end
end
```

#### 4.2.2 客户端管理

```lua
local connection = {}  -- fd -> true/false/nil

function gateserver.openclient(fd)
    if connection[fd] then
        socketdriver.start(fd)  -- 开始接收数据
    end
end

function gateserver.closeclient(fd)
    local c = connection[fd]
    if c ~= nil then
        connection[fd] = nil
        socketdriver.close(fd)
    end
end
```

### 4.3 消息转发

#### 4.3.1 消息队列处理

```lua
-- 使用netpack处理粘包
skynet.register_protocol {
    name = "socket",
    id = skynet.PTYPE_SOCKET,
    unpack = function(msg, sz)
        return netpack.filter(queue, msg, sz)
    end,
    dispatch = function(_, _, q, type, ...)
        queue = q
        if type then
            MSG[type](...)
        end
    end
}
```

#### 4.3.2 数据分发

```lua
local function dispatch_msg(fd, msg, sz)
    if connection[fd] then
        handler.message(fd, msg, sz)
    else
        skynet.error(string.format("Drop message from fd (%d) : %s", 
            fd, netpack.tostring(msg, sz)))
    end
end

local function dispatch_queue()
    local fd, msg, sz = netpack.pop(queue)
    if fd then
        -- 可能阻塞，fork新协程继续处理
        skynet.fork(dispatch_queue)
        dispatch_msg(fd, msg, sz)
        
        -- 处理剩余消息
        for fd, msg, sz in netpack.pop, queue do
            dispatch_msg(fd, msg, sz)
        end
    end
end

MSG.data = dispatch_msg
MSG.more = dispatch_queue
```

#### 4.3.3 Gate服务实现

```lua
-- service/gate.lua
local gateserver = require "snax.gateserver"

local watchdog
local connection = {}  -- fd -> {fd, client, agent, ip, mode}

local handler = {}

function handler.open(source, conf)
    watchdog = conf.watchdog or source
    return conf.address, conf.port
end

function handler.message(fd, msg, sz)
    local c = connection[fd]
    local agent = c.agent
    if agent then
        -- 直接转发给agent，零拷贝
        skynet.redirect(agent, c.client, "client", fd, msg, sz)
    else
        -- 发送给watchdog处理
        skynet.send(watchdog, "lua", "socket", "data", fd, 
            skynet.tostring(msg, sz))
        skynet.trash(msg, sz)  -- 释放内存
    end
end

function handler.connect(fd, addr)
    local c = {
        fd = fd,
        ip = addr,
    }
    connection[fd] = c
    skynet.send(watchdog, "lua", "socket", "open", fd, addr)
end

local CMD = {}

function CMD.forward(source, fd, client, address)
    local c = assert(connection[fd])
    c.client = client or 0
    c.agent = address or source
    gateserver.openclient(fd)  -- 开始接收数据
end
```

## 5. NetPack协议解析

### 5.1 包格式设计

NetPack使用简单的长度+数据格式：

```c
// lualib-src/lua-netpack.c
/*
    Each package is uint16 + data
    uint16 (serialized in big-endian) is the number of bytes comprising the data
*/

static inline int
read_size(uint8_t * buffer) {
    int r = (int)buffer[0] << 8 | (int)buffer[1];
    return r;
}
```

**包结构：**
```
+--------+----------------+
| 2字节  |    数据内容     |
| 包长度 |    (变长)       |
+--------+----------------+
```

### 5.2 粘包处理

```c
struct uncomplete {
    struct netpack pack;
    struct uncomplete * next;
    int read;     // 已读取字节数
    int header;   // 包头（部分读取时）
};

struct queue {
    int cap;
    int head;
    int tail;
    struct uncomplete * hash[HASHSIZE];  // 未完整包的哈希表
    struct netpack queue[QUEUESIZE];     // 完整包队列
};
```

**处理流程：**
1. 数据到达时先查找未完整包
2. 尝试组装完整包
3. 完整包加入队列
4. 不完整包保存到哈希表

### 5.3 缓存管理

```c
static void
push_data(lua_State *L, int fd, void *buffer, int size, int clone) {
    if (clone) {
        void * tmp = skynet_malloc(size);
        memcpy(tmp, buffer, size);
        buffer = tmp;
    }
    struct queue *q = get_queue(L);
    struct netpack *np = &q->queue[q->tail];
    if (++q->tail >= q->cap)
        q->tail -= q->cap;
    np->id = fd;
    np->buffer = buffer;
    np->size = size;
    if (q->head == q->tail) {
        expand_queue(L, q);  // 队列满时扩展
    }
}
```

## 6. UDP支持

### 6.1 UDP API

```lua
-- 创建UDP socket
function socket.udp(callback, host, port)
    local id = driver.udp(host, port)
    create_udp_object(id, callback)
    return id
end

-- 监听UDP端口
function socket.udp_listen(addr, port, callback)
    local id = driver.udp_listen(addr, port)
    create_udp_object(id, callback)
    return id
end

-- 连接UDP地址（设置默认发送地址）
function socket.udp_connect(id, addr, port, callback)
    local obj = socket_pool[id]
    if obj then
        assert(obj.protocol == "UDP")
        if callback then
            obj.callback = callback
        end
    else
        create_udp_object(id, callback)
    end
    driver.udp_connect(id, addr, port)
end

-- 发送UDP数据
socket.sendto = assert(driver.udp_send)
-- 使用示例：socket.sendto(id, addr, data)
```

### 6.2 使用场景

```lua
-- UDP服务器示例
local socket = require "skynet.socket"

local function udp_server()
    local host = "0.0.0.0"
    local port = 8888
    
    local id = socket.udp_listen(host, port, function(str, from)
        print("Received:", str, "from:", from)
        -- 回复客户端
        socket.sendto(id, from, "Reply: " .. str)
    end)
    
    skynet.error("UDP server started on", host, port)
end

-- UDP客户端示例
local function udp_client()
    local id = socket.udp(function(str, from)
        print("Reply:", str)
    end)
    
    socket.udp_connect(id, "127.0.0.1", 8888)
    socket.write(id, "Hello UDP")
end
```

## 7. 高级特性

### 7.1 流量控制

#### 7.1.1 发送警告

```lua
-- SKYNET_SOCKET_TYPE_WARNING = 7
socket_message[7] = function(id, size)
    local s = socket_pool[id]
    if s then
        local warning = s.on_warning or default_warning
        warning(id, size)
    end
end

local function default_warning(id, size)
    local s = socket_pool[id]
    if not s then
        return
    end
    skynet.error(string.format("WARNING: %d K bytes need to send out (fd = %d)", 
        size, id))
end

-- 设置警告回调
function socket.warning(id, callback)
    local obj = socket_pool[id]
    assert(obj)
    obj.on_warning = callback
end
```

#### 7.1.2 缓冲区限制

```lua
function socket.limit(id, limit)
    local s = assert(socket_pool[id])
    s.buffer_limit = limit
end

-- 使用示例
local id = socket.open(host, port)
socket.limit(id, 1024 * 1024)  -- 限制1MB
```

### 7.2 性能优化

#### 7.2.1 零拷贝转发

```lua
-- Gate中的零拷贝转发
function handler.message(fd, msg, sz)
    local c = connection[fd]
    local agent = c.agent
    if agent then
        -- redirect不会复制消息内容
        skynet.redirect(agent, c.client, "client", fd, msg, sz)
    else
        -- tostring会复制，需要手动释放
        skynet.send(watchdog, "lua", "socket", "data", fd, 
            skynet.tostring(msg, sz))
        skynet.trash(msg, sz)
    end
end
```

#### 7.2.2 批量发送

```lua
-- 使用lwrite批量发送
local data_list = {}
for i = 1, 100 do
    table.insert(data_list, "data" .. i)
end
socket.lwrite(id, data_list)  -- 一次系统调用发送所有数据
```

#### 7.2.3 连接池复用

```lua
-- 连接池实现
local connection_pool = {}

function get_connection(host, port)
    local key = host .. ":" .. port
    local pool = connection_pool[key]
    
    if pool and #pool > 0 then
        return table.remove(pool)
    end
    
    return socket.open(host, port)
end

function release_connection(host, port, id)
    local key = host .. ":" .. port
    local pool = connection_pool[key] or {}
    table.insert(pool, id)
    connection_pool[key] = pool
end
```

### 7.3 最佳实践

#### 7.3.1 服务架构设计

```lua
-- 1. Gate负责连接管理和消息转发
-- 2. Watchdog负责连接认证和分配
-- 3. Agent负责业务逻辑处理

-- Watchdog服务
local CMD = {}
local agents = {}

function CMD.socket.open(fd, addr)
    -- 分配agent
    local agent = skynet.newservice("agent")
    agents[fd] = agent
    
    -- 通知gate转发消息给agent
    skynet.call(gate, "lua", "forward", fd, 
        skynet.self(), agent)
end

function CMD.socket.close(fd)
    local agent = agents[fd]
    if agent then
        skynet.send(agent, "lua", "disconnect")
        agents[fd] = nil
    end
end
```

#### 7.3.2 错误处理

```lua
-- 健壮的读取处理
local function safe_read(id)
    local data, err = socket.read(id)
    if not data then
        skynet.error("Socket read error:", err)
        socket.close(id)
        return nil
    end
    return data
end

-- 重连机制
local function connect_with_retry(host, port, retry_count)
    retry_count = retry_count or 3
    
    for i = 1, retry_count do
        local id = socket.open(host, port)
        if id then
            return id
        end
        skynet.sleep(100 * i)  -- 递增延迟
    end
    
    return nil
end
```

#### 7.3.3 协议设计

```lua
-- 自定义协议解析
local function custom_unpack(msg, sz)
    -- 解析自定义协议头
    local header = string.unpack(">I2I2", msg)
    local cmd = header[1]
    local len = header[2]
    
    -- 解析协议体
    local body = string.sub(msg, 5, 4 + len)
    
    return cmd, body
end

-- 注册自定义协议
skynet.register_protocol {
    name = "custom",
    id = 15,  -- 自定义协议ID
    pack = function(cmd, data)
        local header = string.pack(">I2I2", cmd, #data)
        return header .. data
    end,
    unpack = custom_unpack,
}
```

## 总结

Skynet的Lua网络通信层提供了：

1. **完整的Socket API**：支持TCP/UDP，同步化的异步编程
2. **高效的Gate框架**：处理大量连接，零拷贝转发
3. **灵活的协议支持**：内置NetPack，可扩展自定义协议
4. **自动流量控制**：背压机制，防止内存溢出
5. **协程调度机制**：简化异步编程，提高开发效率

这些特性使得Skynet能够轻松处理高并发网络通信场景，特别适合游戏服务器等实时性要求高的应用。
# Skynet系统服务层 - 分布式服务详解 Part 1

## 目录

### Part 1 - Harbor服务与架构
1. [概述](#概述)
2. [分布式架构对比](#分布式架构对比)
3. [Harbor服务架构](#harbor服务架构)
4. [Master-Slave模式](#master-slave模式)
5. [Harbor通信协议](#harbor通信协议)
6. [名字服务机制](#名字服务机制)
7. [连接管理](#连接管理)

### Part 2 - Cluster服务
8. [Cluster架构设计](#cluster架构设计)
9. [节点管理](#节点管理)
10. [远程调用机制](#远程调用机制)
11. [代理服务](#代理服务)

### Part 3 - Multicast与实战
12. [Multicast组播服务](#multicast组播服务)
13. [分布式实战案例](#分布式实战案例)

---

## 概述

### 分布式服务体系

Skynet提供了两套分布式解决方案，适用于不同的应用场景：

1. **Harbor**: 单进程内的多节点通信，适合小规模集群
2. **Cluster**: 跨进程的集群通信，适合大规模分布式系统

```
┌─────────────────────────────────────────────────┐
│           Skynet Distributed Architecture       │
└─────────────────────────────────────────────────┘

        Harbor模式                    Cluster模式
   （单进程，多节点）               （多进程，跨机器）
           │                              │
    ┌──────┴──────┐               ┌───────┴───────┐
    │             │               │               │
    ▼             ▼               ▼               ▼
┌────────┐   ┌────────┐     ┌─────────┐    ┌─────────┐
│Harbor 1│   │Harbor 2│     │Process 1│    │Process 2│
│        │◄──►│        │     │         │◄──►│         │
│Services│   │Services│     │ Cluster │    │ Cluster │
└────────┘   └────────┘     └─────────┘    └─────────┘
    ▲             ▲               ▲               ▲
    └──────┬──────┘               └───────┬───────┘
           │                              │
     同进程内通信                    跨进程RPC通信
```

### 核心特性对比

| 特性 | Harbor | Cluster |
|------|--------|---------|
| 部署模式 | 单进程多节点 | 多进程分布式 |
| 节点数限制 | 最多255个 | 无限制 |
| 通信方式 | 进程内消息传递 | TCP/Socket |
| 服务发现 | 全局名字自动同步 | 需配置节点地址 |
| 容错性 | 进程级容错 | 节点级容错 |
| 适用场景 | 小型集群、游戏服 | 大型分布式系统 |

---

## 分布式架构对比

### Harbor架构

Harbor是Skynet早期的分布式方案，特点是所有节点运行在同一进程内：

```
┌──────────────────────────────────────────────────┐
│              Single Process                      │
├──────────────────────────────────────────────────┤
│  ┌─────────┐  ┌─────────┐  ┌─────────┐         │
│  │Harbor 1 │  │Harbor 2 │  │Harbor 3 │         │
│  │  ID=1   │  │  ID=2   │  │  ID=3   │         │
│  └────┬────┘  └────┬────┘  └────┬────┘         │
│       │            │            │                │
│       └────────────┼────────────┘                │
│                    │                             │
│           ┌────────┴────────┐                    │
│           │ Harbor Service  │                    │
│           │   (C Service)   │                    │
│           └────────┬────────┘                    │
│                    │                             │
│        ┌───────────┼───────────┐                 │
│        │           │           │                 │
│        ▼           ▼           ▼                 │
│   ┌────────┐  ┌────────┐  ┌────────┐           │
│   │Service │  │Service │  │Service │           │
│   │  :01xx │  │  :02xx │  │  :03xx │           │
│   └────────┘  └────────┘  └────────┘           │
└──────────────────────────────────────────────────┘
```

**地址编码**：
```
32位地址 = [8位Harbor ID][24位服务ID]
例如：0x010000AB = Harbor 1的服务0xAB
```

### Cluster架构

Cluster是更现代的分布式方案，支持跨进程、跨机器：

```
┌──────────────────────────────────────────────────┐
│              Cluster Architecture                │
└──────────────────────────────────────────────────┘

     Machine A                    Machine B
  ┌──────────────┐            ┌──────────────┐
  │  Process 1   │            │  Process 2   │
  │              │            │              │
  │ ┌──────────┐ │            │ ┌──────────┐ │
  │ │clusterd  │ │◄──────────►│ │clusterd  │ │
  │ └─────┬────┘ │    TCP     │ └─────┬────┘ │
  │       │      │            │       │      │
  │ ┌─────┴────┐ │            │ ┌─────┴────┐ │
  │ │Services  │ │            │ │Services  │ │
  │ │          │ │            │ │          │ │
  │ └──────────┘ │            │ └──────────┘ │
  └──────────────┘            └──────────────┘
```

---

## Harbor服务架构

### 核心组件

Harbor系统由以下核心组件构成：

#### 1. Harbor C服务

**文件**: `service-src/service_harbor.c`

```c
// Harbor服务的核心数据结构
struct harbor {
    int id;                    // Harbor节点ID (1-255)
    struct skynet_context *ctx;
    struct remote_queue *queue; // 远程消息队列
    struct remote_name *name;   // 全局名字表
    struct map *remote;         // 远程节点映射
};
```

#### 2. Master服务

**文件**: `service/cmaster.lua`

Master负责管理所有Slave节点的注册和名字同步：

```lua
-- Master维护的数据
local slave_node = {}    -- id -> {fd, addr, ...}
local global_name = {}   -- name -> address

-- Master-Slave协议
-- Slave -> Master:
--   'H': HANDSHAKE 握手
--   'R': REGISTER 注册名字
--   'Q': QUERY 查询名字
-- Master -> Slave:
--   'W': WAIT 等待其他节点
--   'C': CONNECT 连接节点
--   'N': NAME 名字通知
--   'D': DISCONNECT 断开节点
```

#### 3. Slave服务

**文件**: `service/cslave.lua`

Slave节点连接Master并同步信息：

```lua
local slaves = {}          -- id -> fd (其他slave连接)
local globalname = {}      -- name -> address (全局名字)
local queryname = {}       -- name -> wait_queue (查询队列)
local monitor = {}         -- id -> response_queue (监控队列)
```

### Harbor地址系统

#### 地址编码规则

```lua
-- 32位地址编码
-- [8位 Harbor ID][24位 Local Address]
local function make_address(harbor_id, local_addr)
    return (harbor_id << 24) | (local_addr & 0xffffff)
end

local function split_address(addr)
    local harbor_id = addr >> 24
    local local_addr = addr & 0xffffff
    return harbor_id, local_addr
end
```

#### 服务地址示例

```lua
-- Harbor 1的服务
:01000001  -- Harbor 1, 服务 0x000001
:01000ABC  -- Harbor 1, 服务 0x000ABC

-- Harbor 2的服务
:02000001  -- Harbor 2, 服务 0x000001
:02000DEF  -- Harbor 2, 服务 0x000DEF

-- 判断是否远程地址
function is_remote(addr)
    local harbor = skynet.harbor(addr)
    return harbor ~= 0 and harbor ~= skynet.harbor(skynet.self())
end
```

### 消息路由机制

```lua
-- Harbor消息路由流程
function route_message(source, destination, msg)
    local dest_harbor = skynet.harbor(destination)
    local self_harbor = skynet.harbor(skynet.self())
    
    if dest_harbor == 0 or dest_harbor == self_harbor then
        -- 本地消息，直接投递
        skynet.send(destination, "lua", msg)
    else
        -- 远程消息，通过Harbor转发
        harbor_send(dest_harbor, source, destination, msg)
    end
end
```

---

## Master-Slave模式

### Master启动流程

```lua
-- cmaster.lua
skynet.start(function()
    local master_addr = skynet.getenv "standalone"
    skynet.error("master listen socket " .. tostring(master_addr))
    
    -- 监听端口
    local fd = socket.listen(master_addr)
    socket.start(fd, function(id, addr)
        skynet.error("connect from " .. addr)
        socket.start(id)
        
        -- 处理Slave握手
        local ok, slave_id, slave_addr = pcall(handshake, id)
        if ok then
            -- 监控Slave
            skynet.fork(monitor_slave, slave_id, slave_addr)
        else
            socket.close(id)
        end
    end)
end)
```

### Slave启动流程

```lua
-- cslave.lua
skynet.start(function()
    local master_addr = skynet.getenv "master"
    local harbor_id = tonumber(skynet.getenv "harbor")
    local slave_address = assert(skynet.getenv "address")
    
    -- 1. 连接Master
    local master_fd = assert(socket.open(master_addr))
    
    -- 2. 发送握手消息
    local hs_message = pack_package("H", harbor_id, slave_address)
    socket.write(master_fd, hs_message)
    
    -- 3. 等待其他Harbor节点
    local t, n = read_package(master_fd)
    assert(t == "W" and type(n) == "number")
    skynet.error(string.format("Waiting for %d harbors", n))
    
    -- 4. 监听其他Slave连接
    local slave_fd = socket.listen(slave_address)
    socket.start(slave_fd, accept_slave)
    
    -- 5. 监控Master
    skynet.fork(monitor_master, master_fd)
end)
```

### 握手协议详解

#### 1. Slave握手请求

```lua
function handshake(fd)
    -- 读取握手消息
    local t, slave_id, slave_addr = read_package(fd)
    assert(t == 'H', "Invalid handshake type")
    assert(slave_id ~= 0, "Invalid slave id")
    
    -- 检查是否重复注册
    if slave_node[slave_id] then
        error(string.format("Slave %d already register", slave_id))
    end
    
    -- 通知其他节点
    report_slave(fd, slave_id, slave_addr)
    
    -- 记录Slave信息
    slave_node[slave_id] = {
        fd = fd,
        id = slave_id,
        addr = slave_addr,
    }
    
    return slave_id, slave_addr
end
```

#### 2. 广播节点信息

```lua
function report_slave(fd, slave_id, slave_addr)
    local message = pack_package("C", slave_id, slave_addr)
    local n = 0
    
    -- 通知所有已连接的Slave
    for k, v in pairs(slave_node) do
        if v.fd ~= 0 then
            socket.write(v.fd, message)
            n = n + 1
        end
    end
    
    -- 告知新Slave需要等待的节点数
    socket.write(fd, pack_package("W", n))
end
```

---

## Harbor通信协议

### 协议格式

Harbor使用简单的二进制协议：

```
┌─────────────────────────────────────┐
│         Harbor Protocol Format       │
├─────────────────────────────────────┤
│  1 byte  │   Variable Length         │
│  Size    │   Message Body            │
└─────────────────────────────────────┘
```

### 消息类型

#### Master -> Slave消息

```lua
-- WAIT: 等待n个节点
function send_wait(fd, n)
    socket.write(fd, pack_package("W", n))
end

-- CONNECT: 通知连接节点
function send_connect(fd, slave_id, slave_addr)
    socket.write(fd, pack_package("C", slave_id, slave_addr))
end

-- NAME: 同步全局名字
function send_name(fd, name, address)
    socket.write(fd, pack_package("N", name, address))
end

-- DISCONNECT: 节点断开
function send_disconnect(fd, slave_id)
    socket.write(fd, pack_package("D", slave_id))
end
```

#### Slave -> Master消息

```lua
-- HANDSHAKE: 握手注册
function send_handshake(fd, harbor_id, address)
    socket.write(fd, pack_package("H", harbor_id, address))
end

-- REGISTER: 注册全局名字
function send_register(fd, name, handle)
    socket.write(fd, pack_package("R", name, handle))
end

-- QUERY: 查询全局名字
function send_query(fd, name)
    socket.write(fd, pack_package("Q", name))
end
```

### 跨Harbor消息转发

```c
// service-src/service_harbor.c
// Harbor消息转发流程

static void harbor_send(struct harbor *h, 
                       uint32_t source, 
                       uint32_t destination, 
                       int type, 
                       void *msg, 
                       size_t sz) {
    int harbor_id = destination >> 24;
    
    // 打包消息头
    struct remote_message_header header;
    header.source = source;
    header.destination = destination;
    header.type = type;
    header.size = sz;
    
    // 发送到目标Harbor
    struct remote_queue *queue = h->queue[harbor_id];
    if (queue) {
        push_remote_message(queue, &header, msg, sz);
    }
}
```

---

## 名字服务机制

### 全局名字注册

Harbor支持全局名字注册，使服务可以通过名字访问：

```lua
-- 注册全局名字
function harbor.REGISTER(fd, name, handle)
    assert(globalname[name] == nil)
    globalname[name] = handle
    
    -- 响应等待队列
    response_name(name)
    
    -- 同步到Master
    socket.write(fd, pack_package("R", name, handle))
    
    -- 通知Harbor服务
    skynet.redirect(harbor_service, handle, "harbor", 0, "N " .. name)
end
```

### 名字查询机制

```lua
-- 查询全局名字
function harbor.QUERYNAME(fd, name)
    -- 本地名字
    if name:byte() == 46 then  -- "."
        skynet.ret(skynet.pack(skynet.localname(name)))
        return
    end
    
    -- 检查缓存
    local result = globalname[name]
    if result then
        skynet.ret(skynet.pack(result))
        return
    end
    
    -- 查询Master
    local queue = queryname[name]
    if queue == nil then
        socket.write(fd, pack_package("Q", name))
        queue = { skynet.response() }
        queryname[name] = queue
    else
        table.insert(queue, skynet.response())
    end
end
```

### 名字同步流程

```
┌────────────────────────────────────────────────┐
│           Name Synchronization Flow            │
└────────────────────────────────────────────────┘

Harbor 1注册名字               Master              Harbor 2
    │                           │                     │
    │  REGISTER "db" :01000123  │                     │
    ├──────────────────────────►│                     │
    │                           │                     │
    │                           │  NAME "db" :01000123│
    │                           ├────────────────────►│
    │                           │                     │
    │   NAME "db" :01000123     │                     │
    │◄──────────────────────────┤                     │
    │                           │                     │
    
Harbor 2查询名字
    │                           │                     │
    │                           │  QUERY "db"         │
    │                           │◄────────────────────┤
    │                           │                     │
    │                           │  NAME "db" :01000123│
    │                           ├────────────────────►│
    │                           │                     │
```

---

## 连接管理

### 连接监控

Harbor提供连接监控机制，检测节点状态：

```lua
-- 监控Harbor连接
function harbor.LINK(fd, id)
    if slaves[id] then
        -- 节点已连接，立即返回
        if monitor[id] == nil then
            monitor[id] = {}
        end
        table.insert(monitor[id], skynet.response())
    else
        -- 节点未连接，直接返回
        skynet.ret()
    end
end

-- 监控Master连接
function harbor.LINKMASTER()
    table.insert(monitor_master_set, skynet.response())
end
```

### 断线处理

```lua
-- Master检测到Slave断开
function monitor_slave(slave_id, slave_address)
    local fd = slave_node[slave_id].fd
    
    -- 监控连接
    while pcall(dispatch_slave, fd) do end
    
    skynet.error("slave " .. slave_id .. " is down")
    
    -- 通知其他节点
    local message = pack_package("D", slave_id)
    slave_node[slave_id].fd = 0
    
    for k, v in pairs(slave_node) do
        if v.fd ~= 0 then
            socket.write(v.fd, message)
        end
    end
    
    socket.close(fd)
end

-- Slave检测到其他节点断开
function handle_disconnect(slave_id)
    local fd = slaves[slave_id]
    slaves[slave_id] = false
    
    if fd then
        -- 通知等待的协程
        monitor_clear(slave_id)
        socket.close(fd)
    end
end
```

### 重连机制

```lua
-- Slave之间的连接管理
function connect_slave(slave_id, address)
    local ok, err = pcall(function()
        if slaves[slave_id] == nil then
            -- 连接其他Slave
            local fd = assert(socket.open(address))
            socketdriver.nodelay(fd)
            
            skynet.error(string.format(
                "Connect to harbor %d (fd=%d), %s", 
                slave_id, fd, address))
            
            slaves[slave_id] = fd
            monitor_clear(slave_id)
            
            -- 交给Harbor服务处理
            socket.abandon(fd)
            skynet.send(harbor_service, "harbor", 
                       string.format("S %d %d", fd, slave_id))
        end
    end)
    
    if not ok then
        skynet.error(err)
    end
end
```

### 优雅关闭

```lua
-- 关闭Harbor节点
function shutdown_harbor()
    -- 1. 停止接受新连接
    socket.close(slave_fd)
    
    -- 2. 通知Master
    socket.write(master_fd, pack_package("D", harbor_id))
    
    -- 3. 关闭到其他Slave的连接
    for id, fd in pairs(slaves) do
        if fd then
            socket.close(fd)
        end
    end
    
    -- 4. 关闭Master连接
    socket.close(master_fd)
    
    -- 5. 退出服务
    skynet.exit()
end
```

---

## 使用示例

### 配置Harbor集群

#### Master配置

```lua
-- config.master
harbor = 1
standalone = "127.0.0.1:2013"  -- Master监听地址

start = "main"
```

#### Slave配置

```lua
-- config.slave1
harbor = 2
address = "127.0.0.1:2014"     -- Slave监听地址
master = "127.0.0.1:2013"      -- Master地址

-- config.slave2
harbor = 3
address = "127.0.0.1:2015"
master = "127.0.0.1:2013"
```

### 启动集群

```bash
# 启动Master (Harbor 1)
./skynet config.master

# 启动Slave 1 (Harbor 2)
./skynet config.slave1

# 启动Slave 2 (Harbor 3)
./skynet config.slave2
```

### 跨Harbor通信

```lua
-- 在Harbor 1注册全局服务
local skynet = require "skynet"

skynet.start(function()
    -- 注册全局名字
    skynet.register(".database")
    
    skynet.dispatch("lua", function(session, source, cmd, ...)
        skynet.error("Request from", skynet.address(source))
        skynet.ret(skynet.pack("Database response"))
    end)
end)

-- 在Harbor 2访问全局服务
skynet.start(function()
    -- 通过名字访问
    local db = skynet.queryservice(".database")
    local result = skynet.call(db, "lua", "query", "data")
    
    -- 或直接调用
    local result = skynet.call(".database", "lua", "query", "data")
end)
```

### 监控Harbor状态

```lua
-- 监控Harbor连接状态
local function monitor_harbor_status()
    local harbor_id = 2
    
    -- 等待Harbor连接
    skynet.call(".cslave", "lua", "LINK", harbor_id)
    
    skynet.error("Harbor", harbor_id, "is connected")
end

-- 监控Master状态
local function monitor_master_status()
    skynet.call(".cslave", "lua", "LINKMASTER")
    skynet.error("Master is connected")
end
```

---

## 本章小结

Harbor服务提供了Skynet的进程内分布式解决方案：

### 关键特性

1. **单进程多节点**: 所有节点运行在同一进程内
2. **自动名字同步**: 全局名字自动在所有节点间同步
3. **透明访问**: 通过地址编码实现透明的远程访问
4. **Master-Slave架构**: 中心化的管理架构
5. **连接监控**: 自动检测和处理节点断开

### 优势与限制

**优势**:
- 配置简单，易于部署
- 消息延迟低（进程内通信）
- 全局名字自动同步
- 适合小型集群

**限制**:
- 最多支持255个节点
- 单点故障（进程崩溃影响所有节点）
- 不支持跨机器部署
- 扩展性有限

### 适用场景

- 单服游戏服务器
- 小型应用集群
- 开发测试环境
- 不需要跨机器扩展的系统

Harbor虽然有一定限制，但对于小型系统来说是一个简单有效的分布式方案。对于需要更大规模扩展的系统，应该使用Cluster服务。

---

**文档版本**: 1.0  
**最后更新**: 2024-01-XX  
**适用版本**: Skynet 1.x
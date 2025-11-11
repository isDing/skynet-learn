# Skynet系统服务层 - 分布式服务详解 Part 2

## 目录

### Part 2 - Cluster服务
8. [Cluster架构设计](#cluster架构设计)
9. [节点管理](#节点管理)
10. [远程调用机制](#远程调用机制)
11. [代理服务](#代理服务)

---

## Cluster架构设计

### 概述

Cluster是Skynet的跨进程分布式解决方案，支持真正的分布式部署：

```
┌────────────────────────────────────────────────┐
│           Cluster Architecture                 │
└────────────────────────────────────────────────┘

      Node A (game1)              Node B (game2)
    ┌──────────────┐            ┌──────────────┐
    │   clusterd   │            │   clusterd   │
    │              │            │              │
    │ ┌──────────┐ │            │ ┌──────────┐ │
    │ │ Sender   │◄├────────────┤►│ Sender   │ │
    │ └──────────┘ │    TCP     │ └──────────┘ │
    │              │            │              │
    │ ┌──────────┐ │            │ ┌──────────┐ │
    │ │ Agent    │ │            │ │ Agent    │ │
    │ └──────────┘ │            │ └──────────┘ │
    │              │            │              │
    │ ┌──────────┐ │            │ ┌──────────┐ │
    │ │ Proxy    │ │            │ │ Proxy    │ │
    │ └──────────┘ │            │ └──────────┘ │
    │              │            │              │
    │  Services    │            │  Services    │
    └──────────────┘            └──────────────┘
```

### 核心组件

#### 1. Clusterd服务

**文件**: `service/clusterd.lua`

Clusterd是集群管理的核心服务，负责：
- 节点配置管理
- 连接建立与维护
- 服务注册与发现
- 代理服务创建

```lua
-- clusterd核心数据结构
local node_address = {}        -- node -> "ip:port"
local node_sender = {}         -- node -> sender_service
local node_sender_closed = {}  -- node -> bool
local node_channel = {}        -- node -> channel
local connecting = {}          -- node -> wait_queue
local proxy = {}              -- fullname -> proxy_service
local cluster_agent = {}      -- fd -> agent_service
local register_name = {}      -- name <-> address
```

#### 2. ClusterSender服务

**文件**: `service/clustersender.lua`

负责向远程节点发送请求：

```lua
local channel  -- socket channel
local session = 1

-- 发送请求
function command.req(addr, msg, sz)
    local current_session = session
    local request, new_session, padding = 
        cluster.packrequest(addr, session, msg, sz)
    session = new_session
    
    -- 发送并等待响应
    return channel:request(request, current_session, padding)
end

-- 发送推送（无需响应）
function command.push(addr, msg, sz)
    local request, new_session, padding = 
        cluster.packpush(addr, session, msg, sz)
    if padding then
        session = new_session
    end
    channel:request(request, nil, padding)
end
```

#### 3. ClusterAgent服务

**文件**: `service/clusteragent.lua`

处理远程节点的请求：

```lua
-- 处理远程请求
local function dispatch_request(_, _, addr, session, msg, sz, 
                               padding, is_push)
    if padding then
        -- 处理大消息
        local req = large_request[session] or 
                   {addr = addr, is_push = is_push}
        large_request[session] = req
        cluster.append(req, msg, sz)
        return
    end
    
    if addr == 0 then
        -- 查询服务名
        local name = skynet.unpack(msg, sz)
        local addr = register_name["@" .. name]
        response = cluster.packresponse(session, addr ~= nil, addr)
    else
        -- 调用服务
        if is_push then
            skynet.rawsend(addr, "lua", msg, sz)
        else
            local ok, msg, sz = pcall(skynet.rawcall, 
                                     addr, "lua", msg, sz)
            response = cluster.packresponse(session, ok, msg, sz)
        end
    end
    
    socket.write(fd, response)
end
```

#### 4. ClusterProxy服务

**文件**: `service/clusterproxy.lua`

远程服务的本地代理：

```lua
-- 说明：实际实现见 service/clusterproxy.lua，使用 skynet.forward_type 将 lua/snax 映射到 system 协议，
--       然后统一交给 clusterd 的 sender 转发。此处仅示意主要结构，省略细节。
local node, address = ...
skynet.forward_type(forward_map, function()
  local clusterd = skynet.uniqueservice("clusterd")
  local sender = skynet.call(clusterd, "lua", "sender", node)
  skynet.dispatch("system", function(session, source, msg, sz)
    if session == 0 then
      skynet.send(sender, "lua", "push", address, msg, sz)
    else
      skynet.ret(skynet.rawcall(sender, "lua", skynet.pack("req", address, msg, sz)))
    end
  end)
end)
```

---

## 节点管理

### 节点配置

Cluster通过配置文件管理节点信息：

```lua
-- clustername.lua 配置文件
__nowaiting = false  -- 是否等待节点上线

-- 节点地址配置
node1 = "127.0.0.1:7001"
node2 = "127.0.0.1:7002"
node3 = "192.168.1.100:7003"

-- 动态禁用节点
-- node4 = false
```

### 配置加载与热更新

```lua
-- 加载配置
local function loadconfig(tmp)
    if tmp == nil then
        tmp = {}
        if config_name then
            local f = assert(io.open(config_name))
            local source = f:read "*a"
            f:close()
            assert(load(source, "@"..config_name, "t", tmp))()
        end
    end
    
    local reload = {}
    for name, address in pairs(tmp) do
        if name:sub(1,2) == "__" then
            -- 配置项
            name = name:sub(3)
            config[name] = address
        else
            -- 节点地址
            assert(address == false or type(address) == "string")
            if node_address[name] ~= address then
                -- 地址变更
                if node_sender[name] then
                    node_channel[name] = nil
                    table.insert(reload, name)
                end
                node_address[name] = address
            end
        end
    end
    
    -- 重新连接变更的节点
    for _, name in ipairs(reload) do
        skynet.fork(open_channel, node_channel, name)
    end
end

-- 热更新配置
function command.reload(source, config)
    loadconfig(config)
    skynet.ret(skynet.pack(nil))
end
```

### 连接管理

```lua
-- 打开到节点的连接
local function open_channel(t, key)
    local ct = connecting[key]
    if ct then
        -- 已有连接进行中，等待
        local co = coroutine.running()
        while ct do
            table.insert(ct, co)
            skynet.wait(co)
            channel = ct.channel
            ct = connecting[key]
        end
        return assert(node_address[key] and channel)
    end
    
    ct = {}
    connecting[key] = ct
    
    local address = node_address[key]
    if address == nil and not config.nowaiting then
        -- 等待节点配置
        local co = coroutine.running()
        ct.namequery = co
        skynet.error("Waiting for cluster node [" .. key .. "]")
        skynet.wait(co)
        address = node_address[key]
    end
    
    if address then
        local host, port = string.match(address, "([^:]+):(.*)$")
        local c = node_sender[key]
        
        if c == nil then
            -- 创建Sender服务
            c = skynet.newservice("clustersender", 
                                key, nodename, host, port)
            node_sender[key] = c
        end
        
        -- 连接节点
        local succ = pcall(skynet.call, c, "lua", 
                         "changenode", host, port)
        
        if succ then
            t[key] = c
            ct.channel = c
            node_sender_closed[key] = nil
        end
    elseif address == false then
        -- 节点被禁用
        local c = node_sender[key]
        if c and not node_sender_closed[key] then
            pcall(skynet.call, c, "lua", "changenode", false)
            node_sender_closed[key] = true
        end
    end
    
    -- 唤醒等待的协程
    connecting[key] = nil
    for _, co in ipairs(ct) do
        skynet.wakeup(co)
    end
    
    return c
end
```

### 节点监听

```lua
-- 监听端口接受其他节点连接
function command.listen(source, addr, port, maxclient)
    local gate = skynet.newservice("gate")
    
    if port == nil then
        -- 使用配置中的地址
        local address = assert(node_address[addr])
        addr, port = string.match(address, "(.+):([^:]+)$")
        port = tonumber(port)
    end
    
    -- 启动Gate服务
    local realaddr, realport = skynet.call(gate, "lua", "open", {
        address = addr,
        port = port,
        maxclient = maxclient
    })
    
    skynet.ret(skynet.pack(realaddr, realport))
end

-- 处理连接事件
function command.socket(source, subcmd, fd, msg)
    if subcmd == "open" then
        -- 新连接，创建Agent
        cluster_agent[fd] = false
        local agent = skynet.newservice("clusteragent", 
                                       skynet.self(), source, fd)
        cluster_agent[fd] = agent
        
    elseif subcmd == "close" or subcmd == "error" then
        -- 连接关闭
        local agent = cluster_agent[fd]
        if agent then
            skynet.send(agent, "lua", "exit")
            cluster_agent[fd] = nil
        end
    end
end
```

---

## 远程调用机制

### 调用流程

```
┌────────────────────────────────────────────────┐
│           Cluster RPC Flow                      │
└────────────────────────────────────────────────┘

Local Node                                    Remote Node
    │                                              │
Service                                        Service
    │                                              ▲
    │ cluster.call("node", "service", ...)        │
    ▼                                              │
Clusterd                                      Clusterd
    │                                              ▲
    │ get sender                                  │
    ▼                                              │
ClusterSender                               ClusterAgent
    │                                              ▲
    │ pack request                                │
    │ send via TCP                                │
    └─────────────────────────────────────────────┘
                     Response
```

### 请求打包与解包（摘要）

```lua
-- 由 cluster.core 提供底层协议编解码，下面为行为摘要（非二进制细节）：

-- 打包请求：可能返回 string（单帧）或 table（多帧分片），并给出新会话号与是否存在后续分片
local req, new_session, padding = cluster.packrequest(addr, session, msg, sz)

-- 打包推送：同上，但无响应；对于大消息可能需要多次 request(..., nil, padding)
local req, new_session, padding = cluster.packpush(addr, session, msg, sz)

-- 解包响应：返回 (session, ok, data, padding)
local session, ok, data, padding = cluster.unpackresponse(resp)

-- 说明：
--  - clustersender 使用 socketchannel:request(req, session, padding) 发送，处理分片与聚合
--  - clusteragent 负责将分片请求拼接（append/concat）并调用本地服务；trace 信息通过额外指令透传
```

### 远程调用API

```lua
-- 同步调用
local cluster = require "skynet.cluster"

-- 调用远程服务
local result = cluster.call("node2", ".service", "method", ...)

-- 发送消息（无响应）
cluster.send("node2", ".service", "notify", ...)

-- 代理（本地 handle）
-- 推荐：显式传 node 与 name
local h = cluster.proxy("node2", ".service")
-- 可选：也支持 "node.name" 或 "node@.name" 的组合写法
local h2 = cluster.proxy("node2.service")

-- 获取代理对象
local proxy = cluster.proxy("node2", ".service")
local result = skynet.call(proxy, "lua", "method", ...)
```

### 大消息处理

```lua
-- 大消息接收处理
local large_request = {}

local function dispatch_request(_, _, addr, session, msg, sz, 
                               padding, is_push)
    if padding then
        -- 接收分片
        local req = large_request[session] or {
            addr = addr,
            is_push = is_push,
            tracetag = tracetag
        }
        large_request[session] = req
        cluster.append(req, msg, sz)
        return
    else
        -- 组装完整消息
        local req = large_request[session]
        if req then
            large_request[session] = nil
            cluster.append(req, msg, sz)
            msg, sz = cluster.concat(req)
            addr = req.addr
            is_push = req.is_push
        end
        
        -- 处理完整消息
        process_message(addr, msg, sz, is_push)
    end
end
```

### 调用跟踪

```lua
-- 支持调用链跟踪
local function send_request(addr, msg, sz)
    local current_session = session
    local request, new_session, padding = 
        cluster.packrequest(addr, session, msg, sz)
    session = new_session
    
    -- 添加跟踪标签
    local tracetag = skynet.tracetag()
    if tracetag then
        if tracetag:sub(1,1) ~= "(" then
            -- 添加节点名
            local newtag = string.format("(%s-%s-%d)%s", 
                                       nodename, node, 
                                       session, tracetag)
            skynet.tracelog(tracetag, 
                          string.format("session %s", newtag))
            tracetag = newtag
        end
        skynet.tracelog(tracetag, 
                       string.format("cluster %s", node))
        channel:request(cluster.packtrace(tracetag))
    end
    
    return channel:request(request, current_session, padding)
end
```

---

## 代理服务

### 代理机制

代理服务允许像调用本地服务一样调用远程服务：

```lua
-- 创建代理
function command.proxy(source, node, name)
    if name == nil then
        -- 解析 node.name 格式
        node, name = node:match "^([^@.]+)([@.].+)"
    end
    
    local fullname = node .. "." .. name
    local p = proxy[fullname]
    
    if p == nil then
        -- 创建新代理
        p = skynet.newservice("clusterproxy", node, name)
        proxy[fullname] = p
    end
    
    skynet.ret(skynet.pack(p))
end
```

### 代理转发

```lua
-- clusterproxy.lua
local node, address = ...

-- 注册system协议
skynet.register_protocol {
    name = "system",
    id = skynet.PTYPE_SYSTEM,
    unpack = function(...) return ... end,
}

-- 转发映射
local forward_map = {
    [skynet.PTYPE_SNAX] = skynet.PTYPE_SYSTEM,
    [skynet.PTYPE_LUA] = skynet.PTYPE_SYSTEM,
    [skynet.PTYPE_RESPONSE] = skynet.PTYPE_RESPONSE,
}

skynet.forward_type(forward_map, function()
    local clusterd = skynet.uniqueservice("clusterd")
    local sender = skynet.call(clusterd, "lua", "sender", node)
    
    -- 处理所有消息
    skynet.dispatch("system", function(session, source, msg, sz)
        if session == 0 then
            -- 发送消息
            skynet.send(sender, "lua", "push", address, msg, sz)
        else
            -- 调用并返回结果
            skynet.ret(skynet.rawcall(sender, "lua", 
                      skynet.pack("req", address, msg, sz)))
        end
    end)
end)
```

### 使用代理

```lua
-- 方式1: 直接调用
local cluster = require "skynet.cluster"
local result = cluster.call("node2", ".database", "query", "sql")

-- 方式2: 获取代理对象
local db_proxy = cluster.proxy("node2", ".database")

-- 像本地服务一样使用
local result = skynet.call(db_proxy, "lua", "query", "sql")
skynet.send(db_proxy, "lua", "update", "data")

-- 方式3: 注册为本地名字
local db = cluster.proxy("node2", ".database")
skynet.name(".remote_db", db)

-- 通过名字使用
local result = skynet.call(".remote_db", "lua", "query", "sql")
```

### 代理缓存

```lua
-- 代理服务会被缓存
local proxy = {}  -- fullname -> proxy_service

function get_proxy(node, name)
    local fullname = node .. "." .. name
    local p = proxy[fullname]
    
    if p == nil then
        p = skynet.newservice("clusterproxy", node, name)
        -- 双重检查
        if proxy[fullname] then
            skynet.kill(p)
            p = proxy[fullname]
        else
            proxy[fullname] = p
        end
    end
    
    return p
end
```

---

## 服务注册与发现

### 本地服务注册

```lua
-- 注册本地服务供远程访问
function command.register(source, name, addr)
    assert(register_name[name] == nil)
    addr = addr or source
    
    -- 清除旧注册
    local old_name = register_name[addr]
    if old_name then
        register_name[old_name] = nil
        clearnamecache()
    end
    
    -- 注册新名字
    register_name[addr] = name
    register_name[name] = addr
    
    skynet.ret(nil)
    skynet.error(string.format("Register [%s] :%08x", name, addr))
end

-- 注销服务
function command.unregister(_, name)
    if not register_name[name] then
        return skynet.ret(nil)
    end
    
    local addr = register_name[name]
    register_name[addr] = nil
    register_name[name] = nil
    clearnamecache()
    
    skynet.ret(nil)
    skynet.error(string.format("Unregister [%s] :%08x", name, addr))
end
```

### 远程服务查询

```lua
-- ClusterAgent中的名字查询
local register_name_mt = {
    __index = function(self, name)
        local waitco = inquery_name[name]
        if waitco then
            -- 已有查询进行中，等待
            local co = coroutine.running()
            table.insert(waitco, co)
            skynet.wait(co)
            return rawget(register_name, name)
        else
            -- 发起查询
            waitco = {}
            inquery_name[name] = waitco
            
            -- 查询clusterd
            local addr = skynet.call(clusterd, "lua", 
                                   "queryname", name:sub(2))
            if addr then
                register_name[name] = addr
            end
            
            -- 唤醒等待的协程
            inquery_name[name] = nil
            for _, co in ipairs(waitco) do
                skynet.wakeup(co)
            end
            
            return addr
        end
    end
}
```

---

## 集群配置示例

### 配置文件

```lua
-- cluster_config.lua
-- 集群配置文件

-- 配置选项
__nowaiting = false  -- false: 等待节点上线; true: 不等待

-- 游戏服节点
game1 = "192.168.1.10:7001"
game2 = "192.168.1.11:7002"

-- 战斗服节点
battle1 = "192.168.1.20:8001"
battle2 = "192.168.1.21:8002"

-- 数据库节点
db = "192.168.1.30:9001"

-- 网关节点
gate1 = "192.168.1.40:6001"
gate2 = "192.168.1.41:6002"

-- 动态禁用节点
-- maintenance = false
```

### 节点启动配置

```lua
-- node_config.lua
thread = 8
harbor = 0  -- 关闭harbor

-- 集群配置
cluster = "./cluster_config.lua"
nodename = "game1"  -- 本节点名称

-- 启动服务
start = "main"
```

### 主服务实现

```lua
-- main.lua
local skynet = require "skynet"
local cluster = require "skynet.cluster"

skynet.start(function()
    -- 重载集群配置
    cluster.reload()
    
    -- 开启监听
    cluster.open("game1")
    
    -- 注册本地服务
    local db = skynet.uniqueservice("database")
    cluster.register("database", db)
    
    -- 连接其他节点
    local battle = cluster.proxy("battle1", ".battle_mgr")
    
    -- 使用远程服务
    local result = skynet.call(battle, "lua", "create_room")
    
    skynet.error("Cluster node started")
end)
```

---

## 错误处理与重连

### 连接错误处理

```lua
-- 处理连接错误
local function handle_connection_error(node, err)
    skynet.error(string.format("Connect to %s failed: %s", node, err))
    
    -- 标记节点关闭
    node_sender_closed[node] = true
    
    -- 清理连接
    local sender = node_sender[node]
    if sender then
        pcall(skynet.call, sender, "lua", "changenode", false)
    end
    
    -- 触发重连
    skynet.timeout(500, function()  -- 5秒后重试
        if node_address[node] then
            skynet.fork(open_channel, node_channel, node)
        end
    end)
end
```

### 自动重连机制

SocketChannel 默认支持断线自动重连，无需额外回调配置。创建时指定 `host/port/response/nodelay`，`channel:connect(true)` 会触发连接；发生异常会关闭通道并唤醒所有等待者（以 `socket_error`）。上层可在 `clustersender.req` 处捕获错误并按需触发重试。

```lua
local channel = sc.channel {
  host = host,
  port = port,
  response = read_response,  -- 解析响应 (session, ok, data, padding)
  nodelay = true,
}

-- 首次连接/切换节点
channel:connect(true)

-- 发送请求（自动处理分片与聚合）
local ok, data = pcall(channel.request, channel, request, session, padding)
```

### 请求超时处理（建议模式）

Skynet 的 `cluster.call` 为阻塞调用，无内建超时参数。可使用并发协程与 `skynet.sleep` 实现超时控制：

```lua
local function call_with_timeout(node, service, ms, ...)
  local co = coroutine.running()
  local done, ret
  skynet.fork(function()
    ret = { pcall(cluster.call, node, service, ...) }
    if not done then skynet.wakeup(co) end
  end)
  skynet.sleep(math.floor(ms/10))  -- 1 tick = 10ms
  done = true
  if ret then
    local ok = table.remove(ret, 1)
    return ok and table.unpack(ret) or nil, ret[1]
  else
    return nil, "timeout"
  end
end
```

---

## 性能优化

### 连接池化

```lua
-- 复用Sender服务
local node_sender = {}  -- node -> sender_service

function get_sender(node)
    local sender = node_sender[node]
    if not sender then
        local host, port = parse_address(node_address[node])
        sender = skynet.newservice("clustersender", 
                                  node, nodename, host, port)
        node_sender[node] = sender
    end
    return sender
end
```

### 批量请求

```lua
-- 批量发送请求
local function batch_request(node, requests)
    local sender = get_sender(node)
    local results = {}
    
    for i, req in ipairs(requests) do
        -- 使用push发送所有请求
        skynet.send(sender, "lua", "push", 
                   req.addr, req.msg, req.sz)
    end
    
    -- 批量接收结果
    for i, req in ipairs(requests) do
        results[i] = skynet.call(sender, "lua", "wait_response")
    end
    
    return results
end
```

### 消息压缩

```lua
-- 启用消息压缩
local function compress_message(msg)
    if #msg > 1024 then  -- 大于1KB才压缩
        local compressed = zlib.compress(msg)
        if #compressed < #msg * 0.9 then  -- 压缩率大于10%
            return compressed, true
        end
    end
    return msg, false
end

-- 发送压缩消息
function send_compressed(node, service, msg)
    local data, compressed = compress_message(msg)
    local header = string.pack("B", compressed and 1 or 0)
    cluster.send(node, service, header .. data)
end
```

---

## 监控与调试

### 节点状态监控

```lua
-- 获取所有节点状态
function get_cluster_status()
    local status = {}
    
    for node, addr in pairs(node_address) do
        local sender = node_sender[node]
        status[node] = {
            address = addr,
            connected = sender and not node_sender_closed[node],
            sender = sender,
        }
    end
    
    return status
end

-- 监控服务
local function monitor_cluster()
    while true do
        skynet.sleep(1000)  -- 10秒检查一次
        
        local status = get_cluster_status()
        for node, info in pairs(status) do
            if not info.connected and info.address then
                skynet.error("Node disconnected:", node)
                -- 尝试重连
                skynet.fork(open_channel, node_channel, node)
            end
        end
    end
end
```

### 调试命令

```lua
-- 添加调试命令
function command.debug(source, cmd, ...)
    if cmd == "status" then
        -- 返回集群状态
        return get_cluster_status()
        
    elseif cmd == "reload" then
        -- 重载配置
        loadconfig()
        return "Config reloaded"
        
    elseif cmd == "disconnect" then
        -- 断开节点
        local node = ...
        if node_sender[node] then
            skynet.send(node_sender[node], "lua", 
                       "changenode", false)
            node_sender_closed[node] = true
        end
        return "Disconnected: " .. node
        
    elseif cmd == "connect" then
        -- 连接节点
        local node = ...
        open_channel(node_channel, node)
        return "Connected: " .. node
    end
end
```

---

## 最佳实践

### 1. 服务划分

```lua
-- 按功能划分节点
-- game节点：游戏逻辑
-- battle节点：战斗服务
-- db节点：数据持久化
-- gate节点：网关服务

-- 避免循环依赖
-- game -> battle -> db (正确)
-- game <-> battle (避免)
```

### 2. 容错设计

```lua
-- 使用pcall处理远程调用
local function safe_call(node, service, ...)
    local ok, result = pcall(cluster.call, node, service, ...)
    if not ok then
        skynet.error("Remote call failed:", result)
        -- 降级处理
        return handle_fallback(...)
    end
    return result
end
```

### 3. 负载均衡

```lua
-- 多节点负载均衡
local battle_nodes = {"battle1", "battle2", "battle3"}
local current_node = 1

function get_battle_node()
    local node = battle_nodes[current_node]
    current_node = current_node % #battle_nodes + 1
    return node
end

-- 使用
local node = get_battle_node()
local room = cluster.call(node, ".battle_mgr", "create_room")
```

### 4. 监控告警

```lua
-- 节点监控服务
local function monitor_service()
    -- 检查节点状态
    local status = get_cluster_status()
    
    for node, info in pairs(status) do
        if not info.connected and info.address then
            -- 发送告警
            send_alert("Node down: " .. node)
        end
    end
    
    -- 检查延迟
    for node in pairs(node_address) do
        local start = skynet.now()
        local ok = pcall(cluster.call, node, "@ping", "ping")
        local latency = skynet.now() - start
        
        if latency > 100 then  -- 超过1秒
            send_alert("High latency: " .. node .. " " .. latency)
        end
    end
end
```

---

## 本章小结

Cluster服务提供了Skynet的跨进程分布式解决方案：

### 关键特性

1. **跨进程通信**: 支持真正的分布式部署
2. **动态配置**: 支持热更新节点配置
3. **代理机制**: 透明的远程服务调用
4. **大消息支持**: 自动分片传输
5. **容错机制**: 自动重连和错误处理

### 与Harbor对比

| 特性 | Harbor | Cluster |
|------|--------|---------|
| 部署方式 | 多进程/跨机器 | 多进程/跨机器 |
| 扩展性 | 最多255个节点 | 理论不限制（取决于配置） |
| 容错性 | Master/节点级 | 节点级（sender 重连） |
| 配置复杂度 | 简单（Harbor env） | 中等（cluster 配置） |
| 适用场景 | 小中型系统 | 大型分布式 |

### 使用建议

1. **选择合适的方案**:
   - 小型项目使用Harbor
   - 大型项目使用Cluster

2. **合理划分节点**:
   - 按功能划分
   - 避免循环依赖
   - 考虑故障隔离

3. **做好容错处理**:
   - 处理连接错误
   - 实现降级策略
   - 监控节点状态

4. **性能优化**:
   - 复用连接
   - 批量请求
   - 消息压缩

Cluster为Skynet提供了强大的分布式能力，是构建大型分布式系统的重要基础。

---

**文档版本**: 1.0  
**最后更新**: 2024-01-XX  
**适用版本**: Skynet 1.x

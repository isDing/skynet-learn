# Skynet Lua框架层 - 分布式支持架构详解

## 目录

- [1. 分布式架构概述](#1-分布式架构概述)
  - [1.1 设计理念](#11-设计理念)
  - [1.2 架构层次](#12-架构层次)
  - [1.3 核心组件](#13-核心组件)
- [2. Harbor机制详解](#2-harbor机制详解)
  - [2.1 Harbor概念](#21-harbor概念)
  - [2.2 全局名字服务](#22-全局名字服务)
  - [2.3 节点间通信](#23-节点间通信)
- [3. Cluster集群框架](#3-cluster集群框架)
  - [3.1 Cluster架构](#31-cluster架构)
  - [3.2 节点连接管理](#32-节点连接管理)
  - [3.3 远程调用机制](#33-远程调用机制)
  - [3.4 集群代理服务](#34-集群代理服务)
- [4. Multicast多播机制](#4-multicast多播机制)
  - [4.1 多播设计](#41-多播设计)
  - [4.2 频道管理](#42-频道管理)
  - [4.3 消息发布订阅](#43-消息发布订阅)
- [5. 分布式服务管理](#5-分布式服务管理)
  - [5.1 服务发现](#51-服务发现)
  - [5.2 负载均衡](#52-负载均衡)
  - [5.3 故障恢复](#53-故障恢复)
- [6. 集群配置与部署](#6-集群配置与部署)
  - [6.1 配置格式](#61-配置格式)
  - [6.2 动态配置](#62-动态配置)
  - [6.3 部署架构](#63-部署架构)
- [7. 实战案例](#7-实战案例)
  - [7.1 分布式游戏架构](#71-分布式游戏架构)
  - [7.2 跨服务通信](#72-跨服务通信)
  - [7.3 性能优化](#73-性能优化)

## 1. 分布式架构概述

### 1.1 设计理念

Skynet提供两套分布式通信能力：
- **Harbor**：早期内置的跨节点机制（基于 socket 直连），用于节点间消息转发与全局命名
- **Cluster**：更灵活的集群框架（同样基于 socket），提供远程调用/代理/动态配置

**核心设计原则：**
1. **透明性**：远程调用像本地调用一样简单
2. **高效性**：最小化序列化和网络开销
3. **可靠性**：自动重连和故障恢复
4. **灵活性**：支持多种通信模式

### 1.2 架构层次

```
应用层
  ├── 业务服务
  │
分布式框架层（进程间）
  ├── Cluster（集群框架：clusterd/clustersender/clusterproxy）
  ├── Multicast（多播）
  ├── Harbor（Master/Slave + 全局名字服务）
  │
网络层
  └── Socket通信
```

### 1.3 核心组件

**Harbor组件：**
- **harbor master**：主节点，管理全局名字
- **harbor slave**：从节点，本地服务管理
- **cdummy/cslave**：C服务实现

**Cluster组件：**
- **clusterd**：集群管理服务
- **clusterproxy**：远程服务代理
- **clustersender**：节点间发送器
- **clusteragent**：请求处理代理

## 2. Harbor机制详解

### 2.1 Harbor概念

Harbor是Skynet内置的跨节点通信机制（最多255个）：

```lua
-- 配置harbor
harbor = 1  -- 节点ID，1-255
address = "127.0.0.1:2526"  -- 本节点监听地址（供其它 slave 连接）
master = "127.0.0.1:2525"  -- master监听地址
standalone = false  -- 是否独立模式
```

**地址格式：**
```lua
-- 32位地址：高24位是服务ID，低8位是harbor ID
-- 例如：:01000001 表示harbor 1的服务0x010000
local harbor_id = addr & 0xff
local service_id = addr >> 8
```

### 2.2 全局名字服务

```lua
-- lualib/skynet/harbor.lua
local harbor = {}

-- 注册全局名字
function harbor.globalname(name, handle)
    handle = handle or skynet.self()
    skynet.send(".cslave", "lua", "REGISTER", name, handle)
end

-- 查询全局名字
function harbor.queryname(name)
    return skynet.call(".cslave", "lua", "QUERYNAME", name)
end

-- 连接到其他harbor节点
function harbor.connect(id)
    skynet.call(".cslave", "lua", "CONNECT", id)
end

-- 连接到master
function harbor.linkmaster()
    skynet.call(".cslave", "lua", "LINKMASTER")
end
```

**使用示例：**
```lua
-- 注册全局服务
local harbor = require "skynet.harbor"
harbor.globalname("gameserver", skynet.self())

-- 查询全局服务
local addr = harbor.queryname("gameserver")
skynet.send(addr, "lua", "hello")
```

### 2.3 节点间通信

Harbor 的 master 仅用于“控制面”：握手与全局名查询；数据面为 Slave↔Slave 直连转发：

```lua
-- 跨节点发送消息
-- 如果目标地址的harbor_id不同，自动通过harbor转发
skynet.send(remote_addr, "lua", "message", data)

-- 全局广播
for i = 1, 255 do
    local addr = (service_id << 8) | i
    pcall(skynet.send, addr, "lua", "broadcast", msg)
end
```

## 3. Cluster集群框架

### 3.1 Cluster架构

Cluster提供跨进程的分布式通信：

```lua
-- lualib/skynet/cluster.lua
local cluster = {}
local sender = {}  -- 节点发送器缓存
local task_queue = {}  -- 待发送任务队列

-- 获取节点发送器
local function get_sender(node)
    local s = sender[node]
    if not s then
        local q = task_queue[node]
        local task = coroutine.running()
        table.insert(q, task)
        skynet.wait(task)
        skynet.wakeup(q.confirm)
        return q.sender
    end
    return s
end
```

### 3.2 节点连接管理

```lua
-- service/clusterd.lua
local node_address = {}  -- 节点地址配置
local node_sender = {}   -- 节点发送器
local connecting = {}    -- 正在连接的节点

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
        -- 等待节点配置（nowaiting=true 时不等待，直接返回缺席错误）
        local co = coroutine.running()
        ct.namequery = co
        skynet.error("Waiting for cluster node [".. key.."]")
        skynet.wait(co)
        address = node_address[key]
    end
    
    if address then
        local host, port = string.match(address, "([^:]+):(.*)$")
        c = node_sender[key]
        
        if c == nil then
            -- 创建发送器服务
            c = skynet.newservice("clustersender", key, nodename, host, port)
            node_sender[key] = c
        end
        
        succ = pcall(skynet.call, c, "lua", "changenode", host, port)
        if succ then
            t[key] = c
            ct.channel = c
            node_sender_closed[key] = nil
        end
    elseif address == false then
        -- 节点显式下线（address=false）：关闭 sender，等待后续 reload 切回
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

### 3.3 远程调用机制

```lua
-- 远程调用
function cluster.call(node, address, ...)
    local s = sender[node]
    if not s then
        local task = skynet.packstring(address, ...)
        return skynet.call(get_sender(node), "lua", "req", 
            repack(skynet.unpack(task)))
    end
    return skynet.call(s, "lua", "req", address, skynet.pack(...))
end

-- 远程发送（无返回）
function cluster.send(node, address, ...)
    local s = sender[node]
    if not s then
        -- 加入发送队列
        table.insert(task_queue[node], skynet.packstring(address, ...))
    else
        skynet.send(sender[node], "lua", "push", address, skynet.pack(...))
    end
end

-- 使用示例
local cluster = require "skynet.cluster"

-- 配置集群节点
cluster.reload({
    node1 = "127.0.0.1:7001",
    node2 = "127.0.0.1:7002",
})

-- 远程调用
local result = cluster.call("node2", ".service", "echo", "hello")

-- 远程发送
cluster.send("node2", ".logger", "log", "message")
```

### 3.4 集群代理服务

```lua
-- service/clusterproxy.lua
-- 代理远程服务，使其像本地服务一样使用

local node, address = ...

skynet.register_protocol {
    name = "system",
    id = skynet.PTYPE_SYSTEM,
    unpack = function(...) return ... end,
}

local forward_map = {
    [skynet.PTYPE_SNAX] = skynet.PTYPE_SYSTEM,
    [skynet.PTYPE_LUA] = skynet.PTYPE_SYSTEM,
    [skynet.PTYPE_RESPONSE] = skynet.PTYPE_RESPONSE,
}

skynet.forward_type(forward_map, function()
    local clusterd = skynet.uniqueservice("clusterd")
    local sender = skynet.call(clusterd, "lua", "sender", node)
    
    skynet.dispatch("system", function(session, source, msg, sz)
        if session == 0 then
            -- 无返回消息
            skynet.send(sender, "lua", "push", address, msg, sz)
        else
            -- 需要返回的消息
            skynet.ret(skynet.rawcall(sender, "lua", 
                skynet.pack("req", address, msg, sz)))
        end
    end)
end)
```

**创建代理：**
```lua
-- 创建远程服务代理
function cluster.proxy(node, name)
    return skynet.call(clusterd, "lua", "proxy", node, name)
end

-- 使用代理
local proxy = cluster.proxy("node2", ".gameserver")
-- 现在可以像本地服务一样使用proxy
skynet.send(proxy, "lua", "hello")
local ret = skynet.call(proxy, "lua", "query")
```

## 4. Multicast多播机制

### 4.1 多播设计

Multicast提供一对多的消息广播机制：

```lua
-- lualib/skynet/multicast.lua
local multicast = {}
local dispatch = {}

local chan_meta = {
    __index = chan,
    __gc = function(self)
        self:unsubscribe()
    end,
    __tostring = function(self)
        return string.format("[Multicast:%x]", self.channel)
    end,
}
```

### 4.2 频道管理

```lua
-- 创建频道
function multicast.new(conf)
    assert(multicastd, "Init first")
    local self = {}
    conf = conf or self
    self.channel = conf.channel
    
    if self.channel == nil then
        -- 自动分配频道ID
        self.channel = skynet.call(multicastd, "lua", "NEW")
    end
    
    self.__pack = conf.pack or skynet.pack
    self.__unpack = conf.unpack or skynet.unpack
    self.__dispatch = conf.dispatch
    
    return setmetatable(self, chan_meta)
end

-- 删除频道
function chan:delete()
    local c = assert(self.channel)
    skynet.send(multicastd, "lua", "DEL", c)
    self.channel = nil
    self.__subscribe = nil
end
```

### 4.3 消息发布订阅

```lua
-- 发布消息
function chan:publish(...)
    local c = assert(self.channel)
    skynet.call(multicastd, "lua", "PUB", c, mc.pack(self.__pack(...)))
end

-- 订阅频道
function chan:subscribe()
    local c = assert(self.channel)
    if self.__subscribe then
        return  -- 已订阅
    end
    skynet.call(multicastd, "lua", "SUB", c)
    self.__subscribe = true
    dispatch[c] = self
end

-- 取消订阅
function chan:unsubscribe()
    if not self.__subscribe then
        return  -- 已取消
    end
    local c = assert(self.channel)
    skynet.send(multicastd, "lua", "USUB", c)
    self.__subscribe = nil
    dispatch[c] = nil
end

-- 使用示例
local mc = require "skynet.multicast"

-- 创建频道
local channel = mc.new({
    dispatch = function(channel, source, ...)
        print("Received:", ...)
    end
})

-- 订阅频道
channel:subscribe()

-- 发布消息
channel:publish("Hello", "World")

-- 取消订阅
channel:unsubscribe()
```

## 5. 分布式服务管理

### 5.1 服务发现

```lua
-- 服务注册
function cluster.register(name, addr)
    assert(type(name) == "string")
    assert(addr == nil or type(addr) == "number")
    return skynet.call(clusterd, "lua", "register", name, addr)
end

-- 服务注销
function cluster.unregister(name)
    assert(type(name) == "string")
    return skynet.call(clusterd, "lua", "unregister", name)
end

-- 服务查询
function cluster.query(node, name)
    return skynet.call(get_sender(node), "lua", "req", 0, skynet.pack(name))
end

-- 使用示例
-- 在node1注册服务
cluster.register("gameserver", skynet.self())

-- 在node2查询服务
local addr = cluster.query("node1", "gameserver")
```

### 5.2 负载均衡

```lua
-- 简单的轮询负载均衡
local balance = {}
local services = {}
local current = 1

function balance.add(addr)
    table.insert(services, addr)
end

function balance.remove(addr)
    for i, v in ipairs(services) do
        if v == addr then
            table.remove(services, i)
            break
        end
    end
end

function balance.get()
    if #services == 0 then
        return nil
    end
    local addr = services[current]
    current = current % #services + 1
    return addr
end

-- 一致性哈希负载均衡
local consistent_hash = {}
local nodes = {}
local virtual_nodes = 150  -- 每个节点的虚拟节点数

local function hash(key)
    -- 简单的哈希函数
    local h = 0
    for i = 1, #key do
        h = (h * 31 + string.byte(key, i)) & 0x7fffffff
    end
    return h
end

function consistent_hash.add_node(node)
    for i = 1, virtual_nodes do
        local vkey = node .. "#" .. i
        local h = hash(vkey)
        nodes[h] = node
    end
end

function consistent_hash.remove_node(node)
    for i = 1, virtual_nodes do
        local vkey = node .. "#" .. i
        local h = hash(vkey)
        nodes[h] = nil
    end
end

function consistent_hash.get_node(key)
    local h = hash(key)
    local keys = {}
    for k in pairs(nodes) do
        table.insert(keys, k)
    end
    table.sort(keys)
    
    for _, k in ipairs(keys) do
        if k >= h then
            return nodes[k]
        end
    end
    
    return nodes[keys[1]]  -- 环形结构，返回第一个
end
```

### 5.3 故障恢复

```lua
-- 健康检查
local health_check = {}
local check_interval = 100  -- 1秒
local timeout = 500  -- 5秒超时

function health_check.start(nodes)
    skynet.fork(function()
        while true do
            for node, addr in pairs(nodes) do
                skynet.fork(function()
                    local ok = pcall(skynet.call, addr, "lua", "ping")
                    if not ok then
                        -- 节点故障
                        handle_node_failure(node)
                    end
                end)
            end
            skynet.sleep(check_interval)
        end
    end)
end

-- 自动重连
local reconnect = {}
local max_retry = 5
local retry_interval = 100

function reconnect.connect(node, address)
    local retry = 0
    while retry < max_retry do
        local ok = pcall(cluster.call, node, address, "ping")
        if ok then
            return true
        end
        retry = retry + 1
        skynet.sleep(retry_interval * retry)
    end
    return false
end

-- 故障转移
local failover = {}
local backup_nodes = {}

function failover.register_backup(primary, backup)
    backup_nodes[primary] = backup
end

function failover.handle_failure(node)
    local backup = backup_nodes[node]
    if backup then
        -- 切换到备份节点
        cluster.reload({[node] = backup})
        skynet.error("Failover from", node, "to", backup)
        return true
    end
    return false
end
```

## 6. 集群配置与部署

### 6.1 配置格式

```lua
-- cluster配置文件
-- config/clustername.lua

-- 节点地址配置
node1 = "127.0.0.1:7001"
node2 = "127.0.0.1:7002"
node3 = "127.0.0.1:7003"

-- 特殊配置（以__开头）
__nowaiting = false  -- 是否等待未配置节点（false 表示等待，true 表示不等待）

-- 动态节点（设置为false表示节点下线）
-- node4 = false

-- 使用域名
game1 = "game1.example.com:7001"
game2 = "game2.example.com:7002"
```

### 6.2 动态配置

```lua
-- 动态重载配置
function cluster.reload(config)
    skynet.call(clusterd, "lua", "reload", config)
end

-- 监控配置文件变化
local function watch_config(filename)
    local last_time = 0
    skynet.fork(function()
        while true do
            local info = skynet.call(".filesystem", "lua", "stat", filename)
            if info and info.mtime > last_time then
                last_time = info.mtime
                local config = dofile(filename)
                cluster.reload(config)
                skynet.error("Cluster config reloaded")
            end
            skynet.sleep(500)  -- 5秒检查一次
        end
    end)
end

-- 通过服务发现更新配置
local function update_from_discovery(service_name)
    local discovery = require "service_discovery"
    
    discovery.watch(service_name, function(nodes)
        local config = {}
        for _, node in ipairs(nodes) do
            config[node.name] = node.address
        end
        cluster.reload(config)
    end)
end
```

### 6.3 部署架构

```lua
-- 典型的分布式游戏架构
--[[
    登录集群 (login_cluster)
      ├── login1: "10.0.0.1:7001"
      └── login2: "10.0.0.2:7001"
    
    游戏集群 (game_cluster)
      ├── game1: "10.0.1.1:7002"
      ├── game2: "10.0.1.2:7002"
      └── game3: "10.0.1.3:7002"
    
    战斗集群 (battle_cluster)
      ├── battle1: "10.0.2.1:7003"
      └── battle2: "10.0.2.2:7003"
    
    数据集群 (data_cluster)
      ├── db_master: "10.0.3.1:7004"
      └── db_slave: "10.0.3.2:7004"
]]

-- 启动脚本
-- start_node.sh
#!/bin/bash
NODE_NAME=$1
NODE_TYPE=$2

case $NODE_TYPE in
    login)
        ./skynet config/config.login
        ;;
    game)
        ./skynet config/config.game
        ;;
    battle)
        ./skynet config/config.battle
        ;;
    data)
        ./skynet config/config.data
        ;;
esac
```

## 7. 实战案例

### 7.1 分布式游戏架构

```lua
-- 登录服务器
local function login_server()
    local cluster = require "skynet.cluster"
    
    -- 开启对外端口
    cluster.open(8001)
    
    -- 处理登录请求
    local CMD = {}
    
    function CMD.login(account, password)
        -- 验证账号
        local ok, uid = verify_account(account, password)
        if not ok then
            return {ok = false, error = "Invalid account"}
        end
        
        -- 分配游戏服务器（负载均衡）
        local game_node = select_game_node(uid)
        
        -- 在游戏服务器创建玩家
        local player = cluster.call(game_node, ".playermgr", 
            "create_player", uid)
        
        return {
            ok = true,
            uid = uid,
            game_node = game_node,
            token = generate_token(uid)
        }
    end
    
    skynet.start(function()
        skynet.dispatch("lua", function(_, _, cmd, ...)
            local f = CMD[cmd]
            if f then
                skynet.ret(skynet.pack(f(...)))
            end
        end)
        
        cluster.register("loginserver", skynet.self())
    end)
end

-- 游戏服务器
local function game_server()
    local cluster = require "skynet.cluster"
    
    local players = {}
    
    local CMD = {}
    
    function CMD.create_player(uid)
        if players[uid] then
            return players[uid]
        end
        
        -- 创建玩家服务
        local player = skynet.newservice("player", uid)
        players[uid] = player
        
        -- 从数据服务器加载数据
        local data = cluster.call("db_master", ".database", 
            "load_player", uid)
        skynet.call(player, "lua", "init", data)
        
        return player
    end
    
    function CMD.enter_battle(uid, battle_id)
        local player = assert(players[uid])
        
        -- 选择战斗服务器
        local battle_node = select_battle_node(battle_id)
        
        -- 在战斗服务器创建战斗
        local battle = cluster.call(battle_node, ".battlemgr", 
            "create_battle", battle_id)
        
        -- 玩家进入战斗
        cluster.send(battle_node, battle, "add_player", uid, 
            skynet.call(player, "lua", "get_battle_data"))
        
        return {
            battle_node = battle_node,
            battle = battle
        }
    end
    
    skynet.start(function()
        skynet.dispatch("lua", function(_, _, cmd, ...)
            local f = CMD[cmd]
            if f then
                skynet.ret(skynet.pack(f(...)))
            end
        end)
        
        cluster.register("gameserver", skynet.self())
    end)
end
```

### 7.2 跨服务通信

```lua
-- 跨服聊天系统
local chat_service = {}

function chat_service:init()
    self.channels = {}  -- 频道列表
    self.users = {}     -- 用户列表
    
    -- 创建世界频道（多播）
    local mc = require "skynet.multicast"
    self.world_channel = mc.new({
        channel = 1,  -- 固定频道ID
        dispatch = function(channel, source, msg)
            self:on_world_message(source, msg)
        end
    })
    self.world_channel:subscribe()
end

function chat_service:join_world(uid, node)
    self.users[uid] = {
        node = node,
        channels = {"world"}
    }
end

function chat_service:send_world_message(uid, message)
    local user = self.users[uid]
    if not user then
        return false
    end
    
    local msg = {
        uid = uid,
        name = user.name,
        message = message,
        time = skynet.time()
    }
    
    -- 广播到所有节点
    self.world_channel:publish(msg)
    return true
end

function chat_service:on_world_message(source, msg)
    -- 转发给本节点的所有玩家
    for uid, user in pairs(self.users) do
        if user.channels["world"] then
            skynet.send(user.addr, "lua", "chat_message", "world", msg)
        end
    end
end

-- 跨服组队系统
local team_service = {}

function team_service:create_team(leader_uid, leader_node)
    local team_id = generate_team_id()
    
    local team = {
        id = team_id,
        leader = leader_uid,
        leader_node = leader_node,
        members = {
            [leader_uid] = {
                node = leader_node,
                role = "leader"
            }
        }
    }
    
    -- 注册到全局
    cluster.register("team_" .. team_id, skynet.self())
    
    return team_id
end

function team_service:join_team(team_id, uid, node, addr)
    local team = self:get_team(team_id)
    if not team then
        -- 可能在其他节点：根据创建时的 leader_node 查询并远程调用
        local leader_node = guess_leader_node(team_id)  -- 由业务自行记录/推断
        local remote_addr = cluster.query(leader_node, "team_" .. team_id)
        if remote_addr then
            return cluster.call(leader_node, remote_addr, "join_team", team_id, uid, node, addr)
        end
        return false
    end
    
    if #team.members >= MAX_TEAM_SIZE then
        return false, "Team full"
    end
    
    team.members[uid] = { node = node, addr = addr, role = "member" }
    
    -- 通知所有成员
    self:broadcast_team(team, "member_joined", uid)
    
    return true
end

function team_service:broadcast_team(team, cmd, ...)
    for uid, member in pairs(team.members) do
        cluster.send(member.node, member.addr, "team_message", cmd, ...)
    end
end
```

### 7.3 性能优化

```lua
-- 批量RPC优化
local batch_rpc = {}
local pending = {}
local BATCH_SIZE = 100
local BATCH_INTERVAL = 1  -- 10ms

function batch_rpc.init()
    skynet.fork(function()
        while true do
            skynet.sleep(BATCH_INTERVAL)
            batch_rpc.flush()
        end
    end)
end

function batch_rpc.call(node, service, ...)
    local key = node .. ":" .. service
    local batch = pending[key]
    
    if not batch then
        batch = {
            requests = {},
            callbacks = {}
        }
        pending[key] = batch
    end
    
    local co = coroutine.running()
    table.insert(batch.requests, {...})
    table.insert(batch.callbacks, co)
    
    if #batch.requests >= BATCH_SIZE then
        batch_rpc.flush_batch(key)
    end
    
    return skynet.wait(co)
end

function batch_rpc.flush()
    for key in pairs(pending) do
        batch_rpc.flush_batch(key)
    end
end

function batch_rpc.flush_batch(key)
    local batch = pending[key]
    if not batch or #batch.requests == 0 then
        return
    end
    
    pending[key] = nil
    
    local node, service = key:match("([^:]+):(.+)")
    
    -- 批量发送
    local results = cluster.call(node, service, "batch", batch.requests)
    
    -- 分发结果
    for i, co in ipairs(batch.callbacks) do
        skynet.wakeup(co, results[i])
    end
end

-- 连接池复用
local connection_pool = {}
local pool_size = 10

function connection_pool.get(node)
    local pool = connection_pool[node]
    if not pool then
        pool = {}
        connection_pool[node] = pool
    end
    
    if #pool > 0 then
        return table.remove(pool)
    end
    
    return cluster.get_sender(node)
end

function connection_pool.release(node, conn)
    local pool = connection_pool[node]
    if #pool < pool_size then
        table.insert(pool, conn)
    else
        -- 关闭多余的连接
        skynet.send(conn, "lua", "close")
    end
end

-- 消息压缩
local compress = {}

function compress.send(node, addr, ...)
    local data = skynet.packstring(...)
    
    if #data > 1024 then  -- 大于1KB才压缩
        local compressed = zlib.compress(data)
        cluster.send(node, addr, "compressed", compressed)
    else
        cluster.send(node, addr, "normal", data)
    end
end

function compress.handle(cmd, data)
    if cmd == "compressed" then
        data = zlib.decompress(data)
    end
    return skynet.unpack(data)
end
```

## 总结

Skynet的分布式支持提供了：

1. **Harbor机制**：进程内多节点通信，适合小规模分布式
2. **Cluster框架**：跨进程集群通信，适合大规模分布式
3. **Multicast多播**：高效的一对多消息广播
4. **服务发现**：动态服务注册和查询
5. **故障恢复**：自动重连和故障转移
6. **灵活配置**：支持动态配置和多种部署模式

通过这些机制，Skynet能够轻松构建高可用、高性能的分布式系统，特别适合游戏服务器、物联网平台等需要处理大量并发连接的场景。合理使用这些分布式特性，可以实现系统的水平扩展和高可用性。

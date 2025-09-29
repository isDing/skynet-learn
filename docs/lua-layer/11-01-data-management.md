# Skynet Lua框架层 - 数据管理架构详解

## 目录

- [1. 数据管理架构概述](#1-数据管理架构概述)
  - [1.1 设计理念](#11-设计理念)
  - [1.2 核心组件](#12-核心组件)
  - [1.3 数据层次](#13-数据层次)
- [2. DataCenter数据中心](#2-datacenter数据中心)
  - [2.1 数据中心概念](#21-数据中心概念)
  - [2.2 数据操作](#22-数据操作)
  - [2.3 等待机制](#23-等待机制)
  - [2.4 应用场景](#24-应用场景)
- [3. ShareData共享数据](#3-sharedata共享数据)
  - [3.1 共享数据设计](#31-共享数据设计)
  - [3.2 内存共享机制](#32-内存共享机制)
  - [3.3 版本管理](#33-版本管理)
  - [3.4 性能优化](#34-性能优化)
- [4. 数据库支持](#4-数据库支持)
  - [4.1 MySQL支持](#41-mysql支持)
  - [4.2 Redis支持](#42-redis支持)
  - [4.3 MongoDB支持](#43-mongodb支持)
  - [4.4 连接池管理](#44-连接池管理)
- [5. 数据持久化](#5-数据持久化)
  - [5.1 持久化策略](#51-持久化策略)
  - [5.2 数据序列化](#52-数据序列化)
  - [5.3 备份与恢复](#53-备份与恢复)
- [6. 缓存管理](#6-缓存管理)
  - [6.1 缓存策略](#61-缓存策略)
  - [6.2 缓存更新](#62-缓存更新)
  - [6.3 缓存失效](#63-缓存失效)
- [7. 实战案例](#7-实战案例)
  - [7.1 玩家数据管理](#71-玩家数据管理)
  - [7.2 配置数据管理](#72-配置数据管理)
  - [7.3 排行榜系统](#73-排行榜系统)

## 1. 数据管理架构概述

### 1.1 设计理念

Skynet的数据管理采用多层架构设计：

**核心原则：**
1. **分层管理**：内存→缓存→数据库三层架构
2. **读写分离**：高频读、低频写
3. **共享优化**：只读数据零拷贝共享
4. **异步持久化**：不阻塞业务逻辑

### 1.2 核心组件

```
数据管理层
  ├── DataCenter (全局配置中心)
  ├── ShareData (共享只读数据)
  ├── Database Drivers (数据库驱动)
  │   ├── MySQL
  │   ├── Redis
  │   └── MongoDB
  └── Cache Layer (缓存层)
```

### 1.3 数据层次

```lua
-- 数据访问层次
-- L1: 本地内存（服务私有数据）
local player_data = {}

-- L2: 共享内存（ShareData，只读配置）
local config = sharedata.query("gameconfig")

-- L3: 全局数据中心（DataCenter，跨服务配置）
local server_config = datacenter.get("server", "config")

-- L4: 缓存层（Redis，热数据）
local cached = redis:get("player:" .. uid)

-- L5: 持久层（MySQL，全量数据）
local persistent = mysql:query("SELECT * FROM players WHERE uid = ?", uid)
```

## 2. DataCenter数据中心

### 2.1 数据中心概念

DataCenter是Skynet的全局配置中心，用于存储跨服务共享的配置数据：

```lua
-- lualib/skynet/datacenter.lua
local datacenter = {}

-- 查询数据
function datacenter.get(...)
    return skynet.call("DATACENTER", "lua", "QUERY", ...)
end

-- 设置数据
function datacenter.set(...)
    return skynet.call("DATACENTER", "lua", "UPDATE", ...)
end

-- 等待数据
function datacenter.wait(...)
    return skynet.call("DATACENTER", "lua", "WAIT", ...)
end
```

### 2.2 数据操作

```lua
-- service/datacenterd.lua
local database = {}

-- 递归查询
local function query(db, key, ...)
    if db == nil or key == nil then
        return db
    else
        return query(db[key], ...)
    end
end

function command.QUERY(key, ...)
    local d = database[key]
    if d ~= nil then
        return query(d, ...)
    end
end

-- 递归更新
local function update(db, key, value, ...)
    if select("#", ...) == 0 then
        local ret = db[key]
        db[key] = value
        return ret, value
    else
        if db[key] == nil then
            db[key] = {}
        end
        return update(db[key], value, ...)
    end
end

function command.UPDATE(...)
    local ret, value = update(database, ...)
    if ret ~= nil or value == nil then
        return ret
    end
    -- 唤醒等待的服务
    local q = wakeup(wait_queue, ...)
    if q then
        for _, response in ipairs(q) do
            response(true, value)
        end
    end
end
```

**使用示例：**
```lua
local datacenter = require "skynet.datacenter"

-- 设置配置
datacenter.set("server", "id", 1)
datacenter.set("server", "name", "game1")
datacenter.set("server", "ip", "192.168.1.1")

-- 查询配置
local server_id = datacenter.get("server", "id")  -- 1
local server_name = datacenter.get("server", "name")  -- "game1"

-- 获取整个配置表
local server = datacenter.get("server")
-- {id = 1, name = "game1", ip = "192.168.1.1"}

-- 嵌套配置
datacenter.set("game", "dungeon", "level1", {
    monsters = 10,
    boss = "dragon"
})

local dungeon = datacenter.get("game", "dungeon", "level1")
-- {monsters = 10, boss = "dragon"}
```

### 2.3 等待机制

DataCenter支持等待数据就绪：

```lua
-- 等待队列管理
local wait_queue = {}

local function waitfor(db, key1, key2, ...)
    if key2 == nil then
        -- 创建等待队列
        local q = db[key1]
        if q == nil then
            q = {[mode] = "queue"}
            db[key1] = q
        else
            assert(q[mode] == "queue")
        end
        table.insert(q, skynet.response())
    else
        -- 递归等待
        local q = db[key1]
        if q == nil then
            q = {[mode] = "branch"}
            db[key1] = q
        else
            assert(q[mode] == "branch")
        end
        return waitfor(q, key2, ...)
    end
end

-- 使用等待
function command.WAIT(...)
    local ret = command.QUERY(...)
    if ret ~= nil then
        skynet.ret(skynet.pack(ret))
    else
        waitfor(wait_queue, ...)  -- 挂起等待
    end
end
```

**应用场景：**
```lua
-- 服务A等待配置
skynet.fork(function()
    local config = datacenter.wait("game", "config")
    print("Config loaded:", config)
end)

-- 服务B加载配置
skynet.sleep(100)  -- 模拟延迟加载
datacenter.set("game", "config", {
    version = "1.0",
    max_players = 1000
})
-- 服务A被唤醒
```

### 2.4 应用场景

```lua
-- 1. 服务器配置管理
datacenter.set("servers", "login", {
    ip = "127.0.0.1",
    port = 8001,
    capacity = 10000
})

datacenter.set("servers", "game1", {
    ip = "127.0.0.1",
    port = 8002,
    capacity = 5000
})

-- 2. 全局计数器
local function incr_counter(name)
    local count = datacenter.get("counters", name) or 0
    datacenter.set("counters", name, count + 1)
    return count + 1
end

-- 3. 功能开关
datacenter.set("features", "pvp", true)
datacenter.set("features", "trading", false)

local function is_feature_enabled(name)
    return datacenter.get("features", name) == true
end

-- 4. 动态配置
datacenter.set("game", "drop_rate", 0.5)

-- 运营活动时调整掉落率
datacenter.set("game", "drop_rate", 2.0)
```

## 3. ShareData共享数据

### 3.1 共享数据设计

ShareData用于多个服务共享只读配置数据，采用零拷贝技术：

```lua
-- lualib/skynet/sharedata.lua
local sharedata = {}
local cache = setmetatable({}, {__mode = "kv"})

function sharedata.query(name)
    if cache[name] then
        return cache[name]
    end
    
    -- 从sharedatad获取数据对象
    local obj = skynet.call(service, "lua", "query", name)
    if cache[name] and cache[name].__obj == obj then
        skynet.send(service, "lua", "confirm", obj)
        return cache[name]
    end
    
    -- 包装为代理对象
    local r = sd.box(obj)
    skynet.send(service, "lua", "confirm", obj)
    
    -- 启动监控协程
    skynet.fork(monitor, name, r, obj)
    cache[name] = r
    return r
end
```

### 3.2 内存共享机制

**核心思想：**
- 数据存储在sharedatad服务的C内存中
- 各服务通过Lua userdata引用访问
- 写时复制（Copy-on-Write）

```lua
-- service/sharedatad.lua
local pool = {}  -- 数据池
local objmap = {}  -- 对象映射

function CMD.new(name, t, ...)
    local dt = type(t)
    local value
    
    if dt == "table" then
        value = t
    elseif dt == "string" then
        -- 从文件加载
        if t:sub(1, 1) == "@" then
            local f = assert(loadfile(t:sub(2), "bt", value))
        else
            local f = assert(load(t, "=" .. name, "bt", value))
        end
        local _, ret = assert(skynet.pcall(f, ...))
        if type(ret) == "table" then
            value = ret
        end
    end
    
    -- 创建C对象
    local cobj = sharedata.host.new(value)
    sharedata.host.incref(cobj)
    
    local v = {obj = cobj, watch = {}}
    objmap[cobj] = v
    pool[name] = v
end
```

**访问方式：**
```lua
-- 创建共享数据
local sharedata = require "skynet.sharedata"

sharedata.new("config", {
    items = {
        sword = {damage = 10, price = 100},
        shield = {defense = 5, price = 50}
    },
    npcs = {
        {name = "merchant", level = 1},
        {name = "guard", level = 10}
    }
})

-- 服务中查询（零拷贝）
local config = sharedata.query("config")

-- 像普通表一样访问
local sword = config.items.sword
print(sword.damage)  -- 10

-- 遍历
for i, npc in ipairs(config.npcs) do
    print(npc.name, npc.level)
end
```

### 3.3 版本管理

ShareData支持数据更新和版本监控：

```lua
-- 更新数据
function sharedata.update(name, v, ...)
    skynet.call(service, "lua", "update", name, v, ...)
end

-- 监控更新
local function monitor(name, obj, cobj)
    local newobj = cobj
    while true do
        -- 等待新版本
        newobj = skynet.call(service, "lua", "monitor", name, newobj)
        if newobj == nil then
            break  -- 数据被删除
        end
        
        -- 更新本地引用
        sd.update(obj, newobj)
        skynet.send(service, "lua", "confirm", newobj)
    end
    
    if cache[name] == obj then
        cache[name] = nil
    end
end

-- sharedatad中的更新处理
function CMD.update(name, t, ...)
    local v = pool[name]
    local watch, oldcobj
    
    if v then
        watch = v.watch
        oldcobj = v.obj
        objmap[oldcobj] = true
        sharedata.host.decref(oldcobj)
        pool[name] = nil
    end
    
    CMD.new(name, t, ...)
    local newobj = pool[name].obj
    
    if watch then
        sharedata.host.markdirty(oldcobj)
        -- 通知所有监控者
        for _, response in pairs(watch) do
            sharedata.host.incref(newobj)
            response(true, newobj)
        end
    end
end
```

### 3.4 性能优化

```lua
-- 深拷贝（需要修改数据时）
function sharedata.deepcopy(name, ...)
    if cache[name] then
        local cobj = cache[name].__obj
        return sd.copy(cobj, ...)
    end
    
    local cobj = skynet.call(service, "lua", "query", name)
    local ret = sd.copy(cobj, ...)
    skynet.send(service, "lua", "confirm", cobj)
    return ret
end

-- 使用示例
local config = sharedata.query("config")
-- 只读访问，零拷贝

local my_config = sharedata.deepcopy("config")
-- 可修改副本
my_config.items.sword.damage = 20

-- 内存管理
function sharedata.flush()
    for name, obj in pairs(cache) do
        sd.flush(obj)
    end
    collectgarbage()
end
```

## 4. 数据库支持

### 4.1 MySQL支持

Skynet提供完整的MySQL驱动：

```lua
-- lualib/skynet/db/mysql.lua
local mysql = require "skynet.db.mysql"

-- 创建连接
local db = mysql.connect({
    host = "127.0.0.1",
    port = 3306,
    database = "gamedb",
    user = "root",
    password = "password",
    max_packet_size = 1024 * 1024,
    on_connect = function(db)
        db:query("set charset utf8mb4")
    end
})

-- 查询
local res = db:query("SELECT * FROM players WHERE level > ?", 10)
for i, row in ipairs(res) do
    print(row.name, row.level, row.exp)
end

-- 插入
local ok, err = db:query("INSERT INTO players (name, level) VALUES (?, ?)", 
    "Alice", 1)

-- 更新
local ok = db:query("UPDATE players SET level = ? WHERE name = ?", 10, "Alice")

-- 删除
local ok = db:query("DELETE FROM players WHERE level < ?", 5)

-- 事务
db:query("START TRANSACTION")
db:query("UPDATE accounts SET balance = balance - 100 WHERE id = 1")
db:query("UPDATE accounts SET balance = balance + 100 WHERE id = 2")
db:query("COMMIT")

-- 预编译语句
local stmt = db:prepare("SELECT * FROM players WHERE name = ?")
local res = stmt:execute("Alice")
stmt:close()

-- 断开连接
db:disconnect()
```

### 4.2 Redis支持

```lua
-- lualib/skynet/db/redis.lua
local redis = require "skynet.db.redis"

-- 创建连接
local db = redis.connect({
    host = "127.0.0.1",
    port = 6379,
    db = 0,
    auth = "password"
})

-- 字符串操作
db:set("key", "value")
local value = db:get("key")
db:incr("counter")
db:expire("key", 3600)

-- 哈希操作
db:hset("player:1", "name", "Alice")
db:hset("player:1", "level", 10)
local name = db:hget("player:1", "name")
local all = db:hgetall("player:1")

-- 列表操作
db:lpush("queue", "task1")
db:rpush("queue", "task2")
local task = db:lpop("queue")

-- 集合操作
db:sadd("online_users", 1, 2, 3)
local is_online = db:sismember("online_users", 1)
local users = db:smembers("online_users")

-- 有序集合
db:zadd("ranking", 100, "player1")
db:zadd("ranking", 200, "player2")
local top10 = db:zrevrange("ranking", 0, 9, "WITHSCORES")

-- 管道
db:pipeline(function(p)
    p:set("key1", "value1")
    p:set("key2", "value2")
    p:get("key1")
    p:get("key2")
end)

-- 发布订阅
db:publish("channel", "message")

-- 断开连接
db:disconnect()
```

### 4.3 MongoDB支持

```lua
-- lualib/skynet/db/mongo.lua
local mongo = require "skynet.db.mongo"

-- 创建连接
local db = mongo.client({
    host = "127.0.0.1",
    port = 27017
})

-- 选择数据库和集合
local gamedb = db:getDB("gamedb")
local players = gamedb:getCollection("players")

-- 插入
players:insert({
    name = "Alice",
    level = 1,
    items = {"sword", "shield"}
})

-- 查询
local cursor = players:find({level = {["$gt"] = 10}})
while cursor:hasNext() do
    local doc = cursor:next()
    print(doc.name, doc.level)
end

-- 更新
players:update({name = "Alice"}, {
    ["$set"] = {level = 20},
    ["$push"] = {items = "potion"}
})

-- 删除
players:delete({level = {["$lt"] = 5}})

-- 聚合
local pipeline = {
    {["$match"] = {level = {["$gte"] = 10}}},
    {["$group"] = {
        _id = "$class",
        count = {["$sum"] = 1},
        avg_level = {["$avg"] = "$level"}
    }}
}
local result = players:aggregate(pipeline)

-- 断开连接
db:disconnect()
```

### 4.4 连接池管理

```lua
-- 数据库连接池
local db_pool = {}
local pool_size = 10
local mysql = require "skynet.db.mysql"

function db_pool.init(config)
    for i = 1, pool_size do
        local db = mysql.connect(config)
        table.insert(db_pool, db)
    end
end

function db_pool.execute(func, ...)
    local db = table.remove(db_pool)
    if not db then
        error("No available database connection")
    end
    
    local ok, result = pcall(func, db, ...)
    table.insert(db_pool, db)
    
    if not ok then
        error(result)
    end
    return result
end

-- 使用连接池
db_pool.init({
    host = "127.0.0.1",
    database = "gamedb",
    user = "root",
    password = "password"
})

local players = db_pool.execute(function(db)
    return db:query("SELECT * FROM players WHERE level > 10")
end)
```

## 5. 数据持久化

### 5.1 持久化策略

```lua
-- 玩家数据持久化管理
local persistence = {}
local dirty_players = {}
local save_interval = 300  -- 5分钟

-- 标记数据为脏
function persistence.mark_dirty(uid)
    dirty_players[uid] = true
end

-- 定时保存
function persistence.auto_save()
    skynet.fork(function()
        while true do
            skynet.sleep(save_interval)
            persistence.flush()
        end
    end)
end

-- 刷新脏数据
function persistence.flush()
    local uids = {}
    for uid in pairs(dirty_players) do
        table.insert(uids, uid)
    end
    
    for _, uid in ipairs(uids) do
        local ok = pcall(persistence.save_player, uid)
        if ok then
            dirty_players[uid] = nil
        end
    end
end

-- 保存玩家数据
function persistence.save_player(uid)
    local data = get_player_data(uid)
    
    -- 序列化数据
    local json = cjson.encode(data)
    
    -- 保存到数据库
    db:query([[
        INSERT INTO players (uid, data, update_time)
        VALUES (?, ?, NOW())
        ON DUPLICATE KEY UPDATE
        data = VALUES(data),
        update_time = VALUES(update_time)
    ]], uid, json)
    
    -- 同时保存到Redis缓存
    redis:setex("player:" .. uid, 3600, json)
end
```

### 5.2 数据序列化

```lua
-- JSON序列化
local cjson = require "cjson"

local function serialize_json(data)
    return cjson.encode(data)
end

local function deserialize_json(str)
    return cjson.decode(str)
end

-- MessagePack序列化（更高效）
local msgpack = require "msgpack"

local function serialize_msgpack(data)
    return msgpack.pack(data)
end

local function deserialize_msgpack(str)
    return msgpack.unpack(str)
end

-- Sproto序列化（自定义协议）
local sproto = require "sproto"
local proto = sproto.parse [[
.player {
    uid 0 : integer
    name 1 : string
    level 2 : integer
    exp 3 : integer
}
]]

local player_proto = proto:querytypes("player")

local function serialize_sproto(data)
    return player_proto:encode(data)
end

local function deserialize_sproto(str)
    return player_proto:decode(str)
end
```

### 5.3 备份与恢复

```lua
-- 数据备份
local backup = {}

function backup.create_snapshot()
    local timestamp = os.time()
    local backup_file = string.format("backup_%d.dat", timestamp)
    
    -- 导出所有玩家数据
    local players = db:query("SELECT uid, data FROM players")
    
    local f = io.open(backup_file, "w")
    for _, player in ipairs(players) do
        f:write(player.uid, "\t", player.data, "\n")
    end
    f:close()
    
    -- 压缩
    os.execute("gzip " .. backup_file)
    
    return backup_file .. ".gz"
end

-- 数据恢复
function backup.restore(backup_file)
    -- 解压
    os.execute("gunzip " .. backup_file)
    backup_file = backup_file:sub(1, -4)  -- 移除.gz
    
    -- 清空现有数据
    db:query("TRUNCATE TABLE players")
    
    -- 导入数据
    for line in io.lines(backup_file) do
        local uid, data = line:match("(%d+)\t(.+)")
        db:query("INSERT INTO players (uid, data) VALUES (?, ?)", 
            tonumber(uid), data)
    end
end

-- 增量备份
function backup.incremental(last_backup_time)
    local players = db:query([[
        SELECT uid, data FROM players 
        WHERE update_time > FROM_UNIXTIME(?)
    ]], last_backup_time)
    
    return players
end
```

## 6. 缓存管理

### 6.1 缓存策略

```lua
-- LRU缓存实现
local cache = {}
local cache_size = 1000
local cache_list = {}  -- 访问顺序链表

function cache.get(key)
    local value = cache[key]
    if value then
        -- 更新访问时间
        update_access(key)
        return value
    end
    return nil
end

function cache.set(key, value)
    if cache[key] then
        cache[key] = value
        update_access(key)
    else
        if #cache_list >= cache_size then
            -- 淘汰最久未使用的
            local evict_key = table.remove(cache_list, 1)
            cache[evict_key] = nil
        end
        cache[key] = value
        table.insert(cache_list, key)
    end
end

local function update_access(key)
    for i, k in ipairs(cache_list) do
        if k == key then
            table.remove(cache_list, i)
            table.insert(cache_list, key)
            break
        end
    end
end
```

### 6.2 缓存更新

```lua
-- 缓存穿透保护
local loading = {}

function cache.get_with_load(key, loader)
    -- 先查缓存
    local value = cache.get(key)
    if value then
        return value
    end
    
    -- 防止并发加载
    if loading[key] then
        local co = coroutine.running()
        local queue = loading[key]
        table.insert(queue, co)
        skynet.wait(co)
        return cache.get(key)
    end
    
    -- 加载数据
    loading[key] = {}
    value = loader(key)
    cache.set(key, value)
    
    -- 唤醒等待的协程
    local queue = loading[key]
    loading[key] = nil
    for _, co in ipairs(queue) do
        skynet.wakeup(co)
    end
    
    return value
end

-- 写穿缓存
function cache.write_through(key, value)
    -- 更新缓存
    cache.set(key, value)
    
    -- 立即写入数据库
    save_to_db(key, value)
end

-- 写回缓存
function cache.write_back(key, value)
    -- 更新缓存
    cache.set(key, value)
    
    -- 标记为脏，延迟写入
    mark_dirty(key)
end
```

### 6.3 缓存失效

```lua
-- 基于时间的失效
local cache_ttl = {}

function cache.set_with_ttl(key, value, ttl)
    cache.set(key, value)
    cache_ttl[key] = skynet.time() + ttl
end

function cache.clean_expired()
    local now = skynet.time()
    for key, expire_time in pairs(cache_ttl) do
        if now >= expire_time then
            cache[key] = nil
            cache_ttl[key] = nil
        end
    end
end

-- 基于版本的失效
local cache_version = {}

function cache.set_with_version(key, value, version)
    cache.set(key, value)
    cache_version[key] = version
end

function cache.invalidate_version(key, version)
    if cache_version[key] and cache_version[key] < version then
        cache[key] = nil
        cache_version[key] = nil
    end
end

-- 主动失效
function cache.invalidate(key)
    cache[key] = nil
    cache_ttl[key] = nil
    cache_version[key] = nil
end

function cache.clear()
    cache = {}
    cache_list = {}
    cache_ttl = {}
    cache_version = {}
end
```

## 7. 实战案例

### 7.1 玩家数据管理

```lua
-- 完整的玩家数据管理系统
local player_mgr = {}
local players = {}  -- 在线玩家缓存

-- 加载玩家
function player_mgr.load(uid)
    if players[uid] then
        return players[uid]
    end
    
    -- 先从Redis加载
    local cached = redis:get("player:" .. uid)
    if cached then
        local data = cjson.decode(cached)
        players[uid] = data
        return data
    end
    
    -- 从MySQL加载
    local rows = db:query("SELECT data FROM players WHERE uid = ?", uid)
    if #rows > 0 then
        local data = cjson.decode(rows[1].data)
        players[uid] = data
        
        -- 回写Redis
        redis:setex("player:" .. uid, 3600, rows[1].data)
        return data
    end
    
    -- 创建新玩家
    local data = {
        uid = uid,
        name = "",
        level = 1,
        exp = 0,
        items = {},
        create_time = os.time()
    }
    players[uid] = data
    return data
end

-- 保存玩家
function player_mgr.save(uid)
    local data = players[uid]
    if not data then
        return
    end
    
    local json = cjson.encode(data)
    
    -- 保存到MySQL
    db:query([[
        INSERT INTO players (uid, data, update_time)
        VALUES (?, ?, NOW())
        ON DUPLICATE KEY UPDATE
        data = VALUES(data),
        update_time = VALUES(update_time)
    ]], uid, json)
    
    -- 更新Redis缓存
    redis:setex("player:" .. uid, 3600, json)
end

-- 玩家下线
function player_mgr.offline(uid)
    player_mgr.save(uid)
    players[uid] = nil
end

-- 定时自动保存
skynet.fork(function()
    while true do
        skynet.sleep(300)  -- 5分钟
        for uid in pairs(players) do
            pcall(player_mgr.save, uid)
        end
    end
end)
```

### 7.2 配置数据管理

```lua
-- 游戏配置管理
local config_mgr = {}

function config_mgr.init()
    -- 从文件加载配置
    sharedata.new("items", "@config/items.lua")
    sharedata.new("monsters", "@config/monsters.lua")
    sharedata.new("skills", "@config/skills.lua")
    
    -- 全局配置到DataCenter
    local game_config = dofile("config/game.lua")
    for k, v in pairs(game_config) do
        datacenter.set("game", k, v)
    end
end

function config_mgr.get_item(item_id)
    local items = sharedata.query("items")
    return items[item_id]
end

function config_mgr.get_monster(monster_id)
    local monsters = sharedata.query("monsters")
    return monsters[monster_id]
end

-- 热更新配置
function config_mgr.reload(config_name)
    local file = "config/" .. config_name .. ".lua"
    sharedata.update(config_name, "@" .. file)
    skynet.error("Config reloaded:", config_name)
end
```

### 7.3 排行榜系统

```lua
-- Redis排行榜实现
local ranking = {}

-- 更新排行
function ranking.update(uid, score)
    redis:zadd("ranking:global", score, uid)
    
    -- 限制排行榜大小
    local count = redis:zcard("ranking:global")
    if count > 1000 then
        redis:zremrangebyrank("ranking:global", 0, count - 1001)
    end
end

-- 获取排名
function ranking.get_rank(uid)
    return redis:zrevrank("ranking:global", uid)
end

-- 获取积分
function ranking.get_score(uid)
    return redis:zscore("ranking:global", uid)
end

-- 获取排行榜
function ranking.get_top(count)
    local list = redis:zrevrange("ranking:global", 0, count - 1, "WITHSCORES")
    local result = {}
    
    for i = 1, #list, 2 do
        local uid = tonumber(list[i])
        local score = tonumber(list[i + 1])
        table.insert(result, {uid = uid, score = score, rank = #result + 1})
    end
    
    return result
end

-- 获取附近排名
function ranking.get_around(uid, range)
    local rank = ranking.get_rank(uid)
    if not rank then
        return {}
    end
    
    local start = math.max(0, rank - range)
    local stop = rank + range
    
    return redis:zrevrange("ranking:global", start, stop, "WITHSCORES")
end
```

## 总结

Skynet的数据管理提供了：

1. **DataCenter**：全局配置中心，支持等待机制
2. **ShareData**：零拷贝共享数据，高效访问只读配置
3. **数据库支持**：完整的MySQL、Redis、MongoDB驱动
4. **持久化策略**：灵活的保存策略和序列化方案
5. **缓存管理**：多层缓存架构，支持LRU、TTL等策略
6. **实战案例**：玩家数据、配置管理、排行榜等典型应用

通过合理使用这些数据管理机制，可以构建高性能、可扩展的数据层，满足游戏服务器对数据处理的各种需求。关键是根据数据特点选择合适的存储和访问方式，平衡性能和一致性。
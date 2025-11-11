# Skynet Lua框架层 - 服务管理高级模式详解

## 目录

- [1. 唯一服务机制 (Unique Service)](#1-唯一服务机制-unique-service)
  - [1.1 唯一服务概念](#11-唯一服务概念)
  - [1.2 实现机制](#12-实现机制)
  - [1.3 使用场景](#13-使用场景)
- [2. 全局服务机制 (Global Service)](#2-全局服务机制-global-service)
  - [2.1 全局服务概念](#21-全局服务概念)
  - [2.2 跨节点服务](#22-跨节点服务)
  - [2.3 Harbor集成](#23-harbor集成)
- [3. 服务提供者框架 (Service Provider)](#3-服务提供者框架-service-provider)
  - [3.1 Service模块架构](#31-service模块架构)
  - [3.2 Service Provider实现](#32-service-provider实现)
  - [3.3 Service Cell机制](#33-service-cell机制)
- [4. Snax框架详解](#4-snax框架详解)
  - [4.1 Snax设计理念](#41-snax设计理念)
  - [4.2 消息分发机制](#42-消息分发机制)
  - [4.3 接口定义系统](#43-接口定义系统)
  - [4.4 热更新机制](#44-热更新机制)
- [5. 服务发现与查询](#5-服务发现与查询)
  - [5.1 服务查询机制](#51-服务查询机制)
  - [5.2 服务缓存策略](#52-服务缓存策略)
  - [5.3 分布式查询](#53-分布式查询)
- [6. 服务通信模式](#6-服务通信模式)
  - [6.1 Post模式](#61-post模式)
  - [6.2 Request模式](#62-request模式)
  - [6.3 系统调用](#63-系统调用)
- [7. 高级特性](#7-高级特性)
  - [7.1 性能分析](#71-性能分析)
  - [7.2 调试支持](#72-调试支持)
  - [7.3 最佳实践](#73-最佳实践)

## 1. 唯一服务机制 (Unique Service)

### 1.1 唯一服务概念

唯一服务是Skynet中确保某个服务在整个系统中只有一个实例的机制。这类似于单例模式，但在分布式Actor模型中实现。

```lua
-- lualib/skynet.lua
function skynet.uniqueservice(global, ...)
    if global == true then
        -- 全局唯一服务
        return assert(skynet.call(".service", "lua", "GLAUNCH", ...))
    else
        -- 节点唯一服务
        return assert(skynet.call(".service", "lua", "LAUNCH", global, ...))
    end
end
```

**关键特性：**
- **单例保证**：确保服务只启动一次
- **并发安全**：多个请求者同时请求时只启动一个实例
- **等待机制**：后续请求者等待服务启动完成
- **全局/局部**：支持节点级和集群级唯一

### 1.2 实现机制

Service Manager中的唯一服务实现：

```lua
-- service/service_mgr.lua
local function waitfor(name, func, ...)
    local s = service[name]
    if type(s) == "number" then
        -- 服务已存在，直接返回
        return s
    end
    
    local co = coroutine.running()
    
    if s == nil then
        -- 首次请求，创建等待队列
        s = {}
        service[name] = s
    elseif type(s) == "string" then
        -- 服务启动失败
        error(s)
    end
    
    assert(type(s) == "table")
    
    local session, source = skynet.context()
    
    if s.launch == nil and func then
        -- 第一个请求者负责启动服务
        s.launch = {
            session = session,
            source = source,
            co = co,
        }
        return request(name, func, ...)
    end
    
    -- 后续请求者加入等待队列
    table.insert(s, {
        co = co,
        session = session,
        source = source,
    })
    skynet.wait()  -- 挂起等待
    
    s = service[name]
    if type(s) == "string" then
        error(s)  -- 启动失败
    end
    assert(type(s) == "number")
    return s  -- 返回服务地址
end
```

**等待队列机制：**
1. **首次请求**：创建等待队列，发起者负责启动
2. **并发请求**：加入等待队列，挂起协程
3. **启动完成**：唤醒所有等待者
4. **错误处理**：启动失败时通知所有等待者

### 1.3 使用场景

```lua
-- 示例：数据中心服务
local datacenter = skynet.uniqueservice("datacenterd")
-- 无论调用多少次，都返回同一个服务地址

-- 示例：全局唯一服务
local global_db = skynet.uniqueservice(true, "database")
-- 整个集群只有一个database服务实例

-- 示例：查询已存在的唯一服务
local existing = skynet.queryservice("datacenterd")
-- 不会创建新服务，只查询已存在的
```

## 2. 全局服务机制 (Global Service)

### 2.1 全局服务概念

全局服务扩展了唯一服务的概念到整个Skynet集群，确保服务在所有节点中只有一个实例。

```lua
-- service/service_mgr.lua
local function register_global()
    function cmd.GLAUNCH(name, ...)
        local global_name = "@" .. name
        return cmd.LAUNCH(global_name, ...)
    end
    
    function cmd.GQUERY(name, ...)
        local global_name = "@" .. name
        return cmd.QUERY(global_name, ...)
    end
    
    -- 全局服务列表管理
    local mgr = {}
    
    function cmd.REPORT(m)
        mgr[m] = true  -- 注册远程service_mgr
    end
    
    function cmd.LIST()
        local result = {}
        -- 收集所有节点的服务信息
        for k in pairs(mgr) do
            pcall(add_list, result, k)
        end
        -- 添加本地服务信息
        local l = list_service()
        for k, v in pairs(l) do
            result[k] = v
        end
        return result
    end
end
```

### 2.2 跨节点服务

```lua
local function register_local()
    local function waitfor_remote(cmd, name, ...)
        local global_name = "@" .. name
        local local_name
        if name == "snaxd" then
            local_name = global_name .. "." .. (...)
        else
            local_name = global_name
        end
        -- 通过SERVICE（全局服务管理器）查询
        return waitfor(local_name, skynet.call, "SERVICE", "lua", cmd, global_name, ...)
    end
    
    function cmd.GLAUNCH(...)
        return waitfor_remote("LAUNCH", ...)
    end
    
    function cmd.GQUERY(...)
        return waitfor_remote("QUERY", ...)
    end
end
```

### 2.3 Harbor集成

全局服务通过Harbor机制实现跨节点通信：

```lua
-- 全局名称格式：@servicename
-- Harbor自动路由到正确的节点

-- 示例：跨节点数据同步服务
local sync = skynet.uniqueservice(true, "data_sync")
-- sync服务可能运行在集群的任意节点上

-- 示例：全局配置服务
local config = skynet.uniqueservice(true, "config_center")
-- 或仅查询（不触发创建）：
-- local config = skynet.queryservice(true, "config_center")
-- 所有节点共享同一个配置中心
```

## 3. 服务提供者框架 (Service Provider)

### 3.1 Service模块架构

Service模块提供了更灵活的服务管理方式：

```lua
-- lualib/skynet/service.lua
local service = {}
local cache = {}
local provider

local function get_provider()
    provider = provider or skynet.uniqueservice "service_provider"
    return provider
end

function service.new(name, mainfunc, ...)
    local p = get_provider()
    -- 检查服务是否已存在
    local addr, booting = skynet.call(p, "lua", "test", name)
    local address
    
    if addr then
        address = addr
    else
        if booting then
            -- 服务正在启动，等待完成
            address = skynet.call(p, "lua", "query", name)
        else
            -- 启动新服务
            check(mainfunc)  -- 验证函数
            local code = string.dump(mainfunc)  -- 序列化函数
            address = skynet.call(p, "lua", "launch", name, code, ...)
        end
    end
    
    cache[name] = address
    return address
end
```

**特点：**
- **函数即服务**：将Lua函数直接作为服务运行
- **代码传递**：通过string.dump序列化函数代码
- **延迟加载**：服务按需创建
- **缓存机制**：避免重复查询

### 3.2 Service Provider实现

```lua
-- service/service_provider.lua
local provider = {}
local svr = setmetatable({}, { __index = new_service })

function provider.launch(name, code, ...)
    local s = svr[name]
    if s.address then
        return skynet.ret(skynet.pack(s.address))
    end
    
    if s.booting then
        -- 正在启动，加入等待队列
        table.insert(s.queue, skynet.response())
    else
        s.booting = true
        local err
        local ok, addr = pcall(skynet.newservice, "service_cell", name)
        
        if ok then
            -- 初始化服务
            ok, err = xpcall(boot, debug.traceback, addr, name, code, ...)
        else
            err = addr
            addr = nil
        end
        
        s.booting = nil
        
        if ok then
            s.address = addr
            -- 唤醒所有等待者
            for _, resp in ipairs(s.queue) do
                resp(true, addr)
            end
            s.queue = nil
            skynet.ret(skynet.pack(addr))
        else
            -- 启动失败，通知等待者
            if addr then
                skynet.send(addr, "debug", "EXIT")
            end
            s.error = err
            for _, resp in ipairs(s.queue) do
                resp(false)
            end
            s.queue = nil
            error(err)
        end
    end
end
```

### 3.3 Service Cell机制

Service Cell是动态服务的容器：

```lua
-- service/service_cell.lua
local service_name = (...)
local init = {}

function init.init(code, ...)
    local start_func
    skynet.start = function(f)
        start_func = f
    end
    skynet.dispatch("lua", function() error("No dispatch function") end)
    
    -- 加载并执行服务代码
    local mainfunc = assert(load(code, service_name))
    assert(skynet.pcall(mainfunc, ...))
    
    if start_func then
        start_func()
    end
    skynet.ret()
end

skynet.start(function()
    skynet.dispatch("lua", function(_, _, cmd, ...)
        init[cmd](...)
    end)
end)
```

## 4. Snax框架详解

### 4.1 Snax设计理念

Snax（Skynet Nax）是基于Skynet的高级Actor框架，提供了更结构化的服务开发模式。

**核心概念：**
- **Accept**：无返回值的消息处理（异步）
- **Response**：有返回值的请求处理（同步）
- **System**：系统级消息（init、exit、hotfix）

### 4.2 消息分发机制

```lua
-- lualib/skynet/snax.lua
local function gen_post(type, handle)
    return setmetatable({}, {
        __index = function(t, k)
            local id = type.accept[k]
            if not id then
                error(string.format("post %s:%s no exist", type.name, k))
            end
            return function(...)
                skynet_send(handle, "snax", id, ...)
            end
        end
    })
end

local function gen_req(type, handle)
    return setmetatable({}, {
        __index = function(t, k)
            local id = type.response[k]
            if not id then
                error(string.format("request %s:%s no exist", type.name, k))
            end
            return function(...)
                return skynet_call(handle, "snax", id, ...)
            end
        end
    })
end
```

**使用示例：**
```lua
-- 创建Snax服务
local obj = snax.newservice("pingpong")

-- Post消息（无返回）
obj.post.ping("hello")

-- Request消息（等待返回）
local result = obj.req.echo("test")
```

### 4.3 接口定义系统

```lua
-- lualib/snax/interface.lua
local function func_id(id, group)
    local tmp = {}
    local function count(_, name, func)
        if type(name) ~= "string" then
            error(string.format("%s method only support string", group))
        end
        if type(func) ~= "function" then
            error(string.format("%s.%s must be function", group, name, func))
        end
        if tmp[name] then
            error(string.format("%s.%s duplicate definition", group, name))
        end
        tmp[name] = true
        table.insert(id, {#id + 1, group, name, func})
    end
    return setmetatable({}, {__newindex = count})
end

-- Snax服务定义示例
function accept.ping(msg)
    print("Received:", msg)
end

function response.echo(msg)
    return "Echo: " .. msg
end

function init(...)
    -- 服务初始化
end

function exit(...)
    -- 服务清理
end
```

### 4.4 热更新机制

Snax支持服务热更新：

```lua
-- service/snaxd.lua
local function dispatcher(session, source, id, ...)
    local method = func[id]
    
    if method[2] == "system" then
        local command = method[3]
        if command == "hotfix" then
            local hotfix = require "snax.hotfix"
            -- 执行热更新
            skynet.ret(skynet.pack(hotfix(func, ...)))
        elseif command == "profile" then
            -- 返回性能分析数据
            skynet.ret(skynet.pack(profile_table))
        elseif command == "init" then
            -- 初始化服务
            assert(not init, "Already init")
            local initfunc = method[4] or function() end
            initfunc(...)
            skynet.ret()
            init = true
        else
            -- 退出服务
            assert(command == "exit")
            local exitfunc = method[4] or function() end
            exitfunc(...)
            skynet.ret()
            init = false
            skynet.exit()
        end
    else
        assert(init, "Init first")
        timing(method, ...)  -- 性能统计
    end
end
```

**热更新流程：**
1. **代码加载**：加载新版本代码
2. **状态迁移**：保持服务状态
3. **函数替换**：替换处理函数
4. **版本管理**：跟踪更新历史

## 5. 服务发现与查询

### 5.1 服务查询机制

```lua
-- lualib/skynet.lua
function skynet.queryservice(global, ...)
    if global == true then
        -- 查询全局服务
        return assert(skynet.call(".service", "lua", "GQUERY", ...))
    else
        -- 查询本地服务
        return assert(skynet.call(".service", "lua", "QUERY", global, ...))
    end
end

-- service/service_mgr.lua
function cmd.QUERY(service_name, subname)
    local realname = read_name(service_name)
    
    if realname == "snaxd" then
        return waitfor(service_name .. "." .. subname)
    else
        return waitfor(service_name)
    end
end
```

**查询策略：**
- **本地优先**：先查询本节点服务
- **延迟创建**：查询不会创建新服务
- **等待行为**：若服务尚未创建，`queryservice` 会挂起等待，直至该服务由其他请求启动
- **错误处理**：仅当该服务曾尝试启动且记录为失败时才会抛错；无内置超时机制

### 5.2 服务缓存策略

```lua
-- lualib/skynet/service.lua
local cache = {}

function service.query(name)
    if not cache[name] then
        -- 缓存未命中，查询provider
        cache[name] = skynet.call(get_provider(), "lua", "query", name)
    end
    return cache[name]
end

function service.close(name)
    local addr = skynet.call(get_provider(), "lua", "close", name)
    if addr then
        cache[name] = nil  -- 清除缓存
        skynet.kill(addr)
        return true
    end
    return false
end
```

### 5.3 分布式查询

```lua
-- 跨节点服务查询
function cmd.LIST()
    local result = {}
    -- 查询所有已知的service_mgr
    for k in pairs(mgr) do
        pcall(add_list, result, k)
    end
    -- 添加本地服务
    local l = list_service()
    for k, v in pairs(l) do
        result[k] = v
    end
    return result
end

local function add_list(all, m)
    local harbor = "@" .. skynet.harbor(m)
    local result = skynet.call(m, "lua", "LIST")
    for k, v in pairs(result) do
        all[k .. harbor] = v
    end
end
```

## 6. 服务通信模式

### 6.1 Post模式

Post模式用于发送无需等待响应的消息：

```lua
-- Snax Post实现
local function gen_post(type, handle)
    return setmetatable({}, {
        __index = function(t, k)
            local id = type.accept[k]
            if not id then
                error(string.format("post %s:%s no exist", type.name, k))
            end
            return function(...)
                -- 异步发送，不等待返回
                skynet_send(handle, "snax", id, ...)
            end
        end
    })
end

-- 使用示例
obj.post.update({data = "new data"})
obj.post.log("operation completed")
```

**特点：**
- **非阻塞**：发送后立即返回
- **高性能**：无等待开销
- **单向通信**：适合通知类消息

### 6.2 Request模式

Request模式用于需要等待响应的请求：

```lua
-- Snax Request实现
local function gen_req(type, handle)
    return setmetatable({}, {
        __index = function(t, k)
            local id = type.response[k]
            if not id then
                error(string.format("request %s:%s no exist", type.name, k))
            end
            return function(...)
                -- 同步调用，等待返回
                return skynet_call(handle, "snax", id, ...)
            end
        end
    })
end

-- 使用示例
local result = obj.req.query("user_id")
local status = obj.req.check_status()
```

**特点：**
- **同步阻塞**：等待服务响应
- **返回值**：获取处理结果
- **双向通信**：适合查询类操作

### 6.3 系统调用

系统调用处理服务生命周期：

```lua
-- 系统消息类型
local system = {"init", "exit", "hotfix", "profile"}

-- 初始化
function init(...)
    -- 服务启动时调用
    print("Service initialized")
end

-- 退出
function exit(...)
    -- 服务关闭前调用
    print("Service exiting")
end

-- 热更新
function hotfix(...)
    -- 代码更新时调用
    print("Service hotfixed")
end
```

## 7. 高级特性

### 7.1 性能分析

Snax内置性能分析功能：

```lua
-- service/snaxd.lua
local profile_table = {}

local function update_stat(name, ti)
    local t = profile_table[name]
    if t == nil then
        t = {count = 0, time = 0}
        profile_table[name] = t
    end
    t.count = t.count + 1
    t.time = t.time + ti
end

local function timing(method, ...)
    local err, msg
    profile.start()
    if method[2] == "accept" then
        err, msg = xpcall(method[4], traceback, ...)
    else
        err, msg = xpcall(return_f, traceback, method[4], ...)
    end
    local ti = profile.stop()
    update_stat(method[3], ti)
    assert(err, msg)
end
```

**获取性能数据：**
```lua
local profile = snax.profile_info(obj)
-- 返回各方法的调用次数和耗时
```

### 7.2 调试支持

服务管理器提供了丰富的调试信息：

```lua
-- service/service_mgr.lua
local function list_service()
    local result = {}
    for k, v in pairs(service) do
        if type(v) == "string" then
            v = "Error: " .. v
        elseif type(v) == "table" then
            local querying = {}
            if v.launch then
                -- 显示启动信息
                local session = skynet.task(v.launch.co)
                local launching_address = skynet.call(".launcher", "lua", "QUERY", session)
                if launching_address then
                    table.insert(querying, "Init as " .. skynet.address(launching_address))
                    table.insert(querying, skynet.call(launching_address, "debug", "TASK", "init"))
                    table.insert(querying, "Launching from " .. skynet.address(v.launch.source))
                    table.insert(querying, skynet.call(v.launch.source, "debug", "TASK", v.launch.session))
                end
            end
            if #v > 0 then
                -- 显示等待队列
                table.insert(querying, "Querying:")
                for _, detail in ipairs(v) do
                    table.insert(querying, skynet.address(detail.source) .. " " .. 
                        tostring(skynet.call(detail.source, "debug", "TASK", detail.session)))
                end
            end
            v = table.concat(querying, "\n")
        else
            v = skynet.address(v)
        end
        result[k] = v
    end
    return result
end
```

### 7.3 最佳实践

**1. 服务粒度设计**
```lua
-- 粗粒度服务：处理复杂业务逻辑
local game_mgr = skynet.uniqueservice("game_manager")

-- 细粒度服务：单一职责
local auth = snax.newservice("authenticator")
local inventory = snax.newservice("inventory")
```

**2. 错误处理**
```lua
-- 服务启动错误处理
local ok, addr = pcall(skynet.newservice, "myservice")
if not ok then
    skynet.error("Failed to start service:", addr)
    -- 降级处理或重试
end

-- Snax服务错误处理
local ok, result = pcall(obj.req.risky_operation)
if not ok then
    -- 处理异常
end
```

**3. 资源管理**
```lua
-- 服务生命周期管理
function init(...)
    -- 初始化资源
    db = connect_database()
    cache = {}
end

function exit(...)
    -- 清理资源
    if db then
        db:close()
    end
    cache = nil
end
```

**4. 性能优化**
```lua
-- 批量操作
function response.batch_query(ids)
    local results = {}
    for _, id in ipairs(ids) do
        results[id] = cache[id] or fetch_from_db(id)
    end
    return results
end

-- 异步处理
function accept.heavy_task(data)
    -- Post不阻塞调用者
    skynet.fork(function()
        process_heavy_task(data)
    end)
end
```

## 总结

Skynet的服务管理高级模式提供了：

1. **唯一服务机制**：确保服务单例，避免重复启动
2. **全局服务支持**：跨节点的服务共享
3. **灵活的服务框架**：Service和Snax满足不同需求
4. **完善的生命周期**：初始化、运行、热更新、退出
5. **强大的调试支持**：性能分析、状态查询、错误追踪

这些机制使得Skynet能够构建复杂的分布式系统，同时保持代码的简洁性和可维护性。通过合理使用这些高级特性，开发者可以构建高性能、高可用的游戏服务器架构。

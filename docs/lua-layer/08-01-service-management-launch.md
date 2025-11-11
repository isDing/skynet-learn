# Skynet Lua框架层 - 服务管理 Part 1：启动与管理机制 (08-01)

## 模块概述

服务管理是 Skynet 框架的核心功能之一，负责服务的创建、启动、命名、查询和生命周期管理。本文档（Part 1）详细分析服务启动机制、Launcher 服务、服务管理器以及相关的管理 API。

### 核心组件
- **Bootstrap**：系统引导服务
- **Launcher**：服务启动器
- **Service Manager**：服务管理器
- **Manager API**：管理接口封装

## 系统启动流程

### 1. Bootstrap 引导过程

Bootstrap 是 Skynet 系统的第一个 Lua 服务，负责初始化核心服务和启动用户服务。

```lua
-- service/bootstrap.lua
local service = require "skynet.service"
local skynet = require "skynet.manager"

skynet.start(function()
    local standalone = skynet.getenv "standalone"
    
    -- 1. 启动 launcher 服务
    local launcher = assert(skynet.launch("snlua","launcher"))
    skynet.name(".launcher", launcher)
    
    -- 2. 处理 Harbor 配置
    local harbor_id = tonumber(skynet.getenv "harbor" or 0)
    if harbor_id == 0 then
        -- 单节点模式
        assert(standalone == nil)
        standalone = true
        skynet.setenv("standalone", "true")
        
        -- 启动 dummy slave
        local ok, slave = pcall(skynet.newservice, "cdummy")
        if not ok then
            skynet.abort()
        end
        skynet.name(".cslave", slave)
    else
        -- 多节点模式
        if standalone then
            -- 主节点启动 master
            if not pcall(skynet.newservice,"cmaster") then
                skynet.abort()
            end
        end
        
        -- 启动 slave
        local ok, slave = pcall(skynet.newservice, "cslave")
        if not ok then
            skynet.abort()
        end
        skynet.name(".cslave", slave)
    end
    
    -- 3. 启动数据中心（单节点或主节点）
    if standalone then
        local datacenter = skynet.newservice "datacenterd"
        skynet.name("DATACENTER", datacenter)
    end
    
    -- 4. 启动服务管理器
    skynet.newservice "service_mgr"
    
    -- 5. SSL 支持（可选）
    local enablessl = skynet.getenv "enablessl"
    if enablessl == "true" then
        service.new("ltls_holder", function()
            local c = require "ltls.init.c"
            c.constructor()
        end)
    end
    
    -- 6. 启动用户主服务
    pcall(skynet.newservice, skynet.getenv "start" or "main")
    
    -- 7. 退出 bootstrap
    skynet.exit()
end)
```

#### 启动顺序分析

1. **Launcher 服务**：负责后续所有服务的启动和管理
2. **Harbor 服务**：处理跨节点通信（多节点模式）
3. **数据中心**：全局数据存储服务
4. **服务管理器**：唯一服务管理
5. **用户服务**：配置文件指定的主服务

## Launcher 服务

### 1. 核心数据结构

```lua
-- service/launcher.lua
local services = {}        -- handle -> "service_name params"
local command = {}         -- 命令处理函数
local instance = {}        -- handle -> response function
local launch_session = {}  -- handle -> session

local NORET = {}          -- 不返回标记
```

### 2. 服务启动机制

```lua
-- 底层启动服务
local function launch_service(service, ...)
    local param = table.concat({...}, " ")
    local inst = skynet.launch(service, param)  -- C 层启动
    local session = skynet.context()
    local response = skynet.response()  -- 延迟响应
    
    if inst then
        -- 记录服务信息
        services[inst] = service .. " " .. param
        instance[inst] = response
        launch_session[inst] = session
    else
        response(false)  -- 启动失败
        return
    end
    
    return inst
end

-- LAUNCH 命令处理
function command.LAUNCH(_, service, ...)
    launch_service(service, ...)
    return NORET  -- 延迟响应
end

-- 带日志的启动
function command.LOGLAUNCH(_, service, ...)
    -- 需要: local core = require "skynet.core"
    local inst = launch_service(service, ...)
    if inst then
        core.command("LOGON", skynet.address(inst))
    end
    return NORET
end
```

### 3. 服务启动确认机制

Launcher 使用三阶段确认机制确保服务正确启动：

```lua
-- 1. 启动失败（服务初始化错误）
function command.ERROR(address)
    local response = instance[address]
    if response then
        response(false)  -- 通知调用者失败
        launch_session[address] = nil
        instance[address] = nil
    end
    services[address] = nil
    return NORET
end

-- 2. 启动成功
function command.LAUNCHOK(address)
    local response = instance[address]
    if response then
        response(true, address)  -- 返回服务地址
        instance[address] = nil
        launch_session[address] = nil
    end
    return NORET
end

-- 3. 查询启动会话
function command.QUERY(_, request_session)
    for address, session in pairs(launch_session) do
        if session == request_session then
            return address  -- 返回正在启动的服务地址
        end
    end
end
```

#### 启动流程图

```
调用方                Launcher              新服务
  │                      │                    │
  ├──LAUNCH──────────────>│                   │
  │                      ├──skynet.launch────>│
  │                      │<──────inst─────────│
  │                      │                    │
  │                      │     (初始化中...)   │
  │                      │                    │
  │                      │<───LAUNCHOK────────│ (成功)
  │<──────address────────│                    │
  │                      │                    │
  │                 或者  │                    │
  │                      │<─────ERROR─────────│ (失败)
  │<──────false──────────│                    │
```

### 4. 服务管理命令

```lua
-- 列出所有服务
function command.LIST()
    local list = {}
    for k,v in pairs(services) do
        list[skynet.address(k)] = v
    end
    return list
end

-- 终止服务
function command.KILL(_, handle)
    skynet.kill(handle)
    local ret = { [skynet.address(handle)] = tostring(services[handle]) }
    services[handle] = nil
    return ret
end

-- 移除服务记录（服务主动退出时调用）
function command.REMOVE(_, handle, kill)
    services[handle] = nil
    local response = instance[handle]
    if response then
        -- 服务异常退出
        response(not kill)  -- kill==false 时返回 nil
        instance[handle] = nil
        launch_session[handle] = nil
    end
    return NORET
end
```

### 5. 服务诊断命令

```lua
-- 内存统计
function command.MEM(addr, ti)
    return list_srv(ti, function(kb, addr)
        local v = services[addr]
        if type(kb) == "string" then
            return string.format("%s (%s)", kb, v)
        else
            return string.format("%.2f Kb (%s)", kb, v)
        end
    end, "MEM")
end

-- 垃圾回收
function command.GC(addr, ti)
    for k,v in pairs(services) do
        skynet.send(k, "debug", "GC")
    end
    return command.MEM(addr, ti)
end

-- 服务状态
function command.STAT(addr, ti)
    return list_srv(ti, function(v) return v end, "STAT")
end

-- 批量查询服务信息
local function list_srv(ti, fmt_func, ...)
    local list = {}
    local sessions = {}
    local req = skynet.request()
    
    -- 批量发送请求
    for addr in pairs(services) do
        local r = { addr, "debug", ... }
        req:add(r)
        sessions[r] = addr
    end
    
    -- 收集响应（带超时）
    for req, resp in req:select(ti) do
        local addr = req[1]
        if resp then
            local stat = resp[1]
            list[skynet.address(addr)] = fmt_func(stat, addr)
        else
            list[skynet.address(addr)] = fmt_func("ERROR", addr)
        end
        sessions[req] = nil
    end
    
    -- 超时的服务
    for session, addr in pairs(sessions) do
        list[skynet.address(addr)] = fmt_func("TIMEOUT", addr)
    end
    
    return list
end
```

## Manager API

### 1. 服务启动 API

```lua
-- lualib/skynet/manager.lua

-- 底层启动服务（调用内核 LAUNCH 指令）
function skynet.launch(...)
    local addr = c.command("LAUNCH", table.concat({...}, " "))
    if addr then
        return tonumber(string.sub(addr, 2), 16)
    end
end

-- lualib/skynet.lua

-- 创建新服务（通过 .launcher 转发 LAUNCH）
function skynet.newservice(name, ...)
    return skynet.call(".launcher", "lua", "LAUNCH", "snlua", name, ...)
end
```

### 2. 服务命名机制

```lua
-- 全局名称处理
local function globalname(name, handle)
    local c = string.sub(name, 1, 1)
    assert(c ~= ':')  -- 不能是地址格式
    
    if c == '.' then
        return false  -- 本地名称
    end
    
    assert(#name < 16)  -- 全局名称长度限制
    assert(tonumber(name) == nil)  -- 不能是数字
    
    local harbor = require "skynet.harbor"
    harbor.globalname(name, handle)
    
    return true
end

-- 注册服务名（当前服务）
function skynet.register(name)
    if not globalname(name) then
        c.command("REG", name)
    end
end

-- 命名其他服务
function skynet.name(name, handle)
    if not globalname(name, handle) then
        c.command("NAME", name .. " " .. skynet.address(handle))
    end
end
```

#### 命名规则

| 前缀 | 类型 | 范围 | 示例 |
|------|------|------|------|
| `.` | 本地名称 | 节点内 | `.launcher` |
| 无 | 全局名称 | 跨节点 | `DATACENTER` |
| `:` | 地址格式 | - | `:01000010` |
| `@` | 唯一服务 | - | `@console` |

### 3. 服务控制 API

```lua
-- 终止服务
function skynet.kill(name)
    local addr = number_address(name)
    if addr then
        -- 通知 launcher 清理
        skynet.send(".launcher", "lua", "REMOVE", addr, true)
        name = skynet.address(addr)
    end
    c.command("KILL", name)  -- C 层终止
end

-- 终止整个系统
function skynet.abort()
    c.command("ABORT")
end

-- 监控服务
function skynet.monitor(service, query)
    local monitor
    if query then
        monitor = skynet.queryservice(true, service)
    else
        monitor = skynet.uniqueservice(true, service)
    end
    assert(monitor, "Monitor launch failed")
    c.command("MONITOR", string.format(":%08x", monitor))
    return monitor
end
```

## Service Manager 服务

### 1. 核心功能

Service Manager 提供唯一服务管理，确保特定服务在系统中只有一个实例。

```lua
-- service/service_mgr.lua
local cmd = {}
local service = {}  -- 服务注册表

-- 等待服务启动完成
local function waitfor(name, func, ...)
    local s = service[name]
    
    if type(s) == "number" then
        return s  -- 已启动
    end
    
    local co = coroutine.running()
    
    if s == nil then
        s = {}
        service[name] = s
    elseif type(s) == "string" then
        error(s)  -- 启动失败
    end
    
    assert(type(s) == "table")
    
    local session, source = skynet.context()
    
    -- 第一个请求者负责启动
    if s.launch == nil and func then
        s.launch = {
            session = session,
            source = source,
            co = co,
        }
        return request(name, func, ...)
    end
    
    -- 其他请求者等待
    table.insert(s, {
        co = co,
        session = session,
        source = source,
    })
    
    skynet.wait()
    
    s = service[name]
    if type(s) == "string" then
        error(s)
    end
    
    assert(type(s) == "number")
    return s
end
```

### 2. 请求处理

```lua
-- 处理服务启动请求
local function request(name, func, ...)
    local ok, handle = pcall(func, ...)
    local s = service[name]
    assert(type(s) == "table")
    
    if ok then
        service[name] = handle  -- 记录服务句柄
    else
        service[name] = tostring(handle)  -- 记录错误信息
    end
    
    -- 唤醒所有等待者
    for _, v in ipairs(s) do
        skynet.wakeup(v.co)
    end
    
    if ok then
        return handle
    else
        error(tostring(handle))
    end
end
```

### 3. 服务启动与查询

```lua
-- 启动唯一服务
function cmd.LAUNCH(service_name, subname, ...)
    local realname = read_name(service_name)
    
    if realname == "snaxd" then
        -- SNAX 服务
        return waitfor(service_name.."."..subname, 
                      snax.rawnewservice, subname, ...)
    else
        -- 普通服务
        return waitfor(service_name, 
                      skynet.newservice, realname, subname, ...)
    end
end

-- 查询唯一服务
function cmd.QUERY(service_name, subname)
    local realname = read_name(service_name)
    
    if realname == "snaxd" then
        return waitfor(service_name.."."..subname)
    else
        return waitfor(service_name)
    end
end
```

### 4. 全局服务管理

```lua
-- 单节点/主节点模式
local function register_global()
    -- 全局启动
    function cmd.GLAUNCH(name, ...)
        local global_name = "@" .. name
        return cmd.LAUNCH(global_name, ...)
    end
    
    -- 全局查询
    function cmd.GQUERY(name, ...)
        local global_name = "@" .. name
        return cmd.QUERY(global_name, ...)
    end
    
    -- 管理器注册表
    local mgr = {}
    
    -- 注册其他节点的管理器
    function cmd.REPORT(m)
        mgr[m] = true
    end
    
    -- 列出所有服务（包括其他节点）
    function cmd.LIST()
        local result = {}
        
        -- 查询其他节点
        for k in pairs(mgr) do
            pcall(add_list, result, k)
        end
        
        -- 本地服务
        local l = list_service()
        for k, v in pairs(l) do
            result[k] = v
        end
        
        return result
    end
end
```

### 5. 服务诊断

```lua
-- 列出本地服务状态
local function list_service()
    local result = {}
    
    for k, v in pairs(service) do
        if type(v) == "string" then
            v = "Error: " .. v
        elseif type(v) == "table" then
            local querying = {}
            
            -- 正在启动的服务
            if v.launch then
                local session = skynet.task(v.launch.co)
                local launching_address = skynet.call(".launcher", 
                                                     "lua", "QUERY", session)
                if launching_address then
                    table.insert(querying, "Init as " .. 
                               skynet.address(launching_address))
                    table.insert(querying, skynet.call(launching_address, 
                                                      "debug", "TASK", "init"))
                    table.insert(querying, "Launching from " .. 
                               skynet.address(v.launch.source))
                    table.insert(querying, skynet.call(v.launch.source, 
                                                      "debug", "TASK", 
                                                      v.launch.session))
                end
            end
            
            -- 等待查询的协程
            if #v > 0 then
                table.insert(querying, "Querying:")
                for _, detail in ipairs(v) do
                    table.insert(querying, 
                               skynet.address(detail.source) .. " " .. 
                               tostring(skynet.call(detail.source, 
                                                  "debug", "TASK", 
                                                  detail.session)))
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

## 高级特性

### 1. 消息过滤器

```lua
-- 设置消息过滤器
function skynet.filter(f, start_func)
    c.callback(function(...)
        dispatch_message(f(...))
    end)
    skynet.timeout(0, function()
        skynet.init_service(start_func)
    end)
end
```

### 2. 类型转发

```lua
-- 消息类型映射
function skynet.forward_type(map, start_func)
    c.callback(function(ptype, msg, sz, ...)
        local prototype = map[ptype]
        if prototype then
            dispatch_message(prototype, msg, sz, ...)
        else
            local ok, err = pcall(dispatch_message, ptype, msg, sz, ...)
            c.trash(msg, sz)
            if not ok then
                error(err)
            end
        end
    end, true)
    
    skynet.timeout(0, function()
        skynet.init_service(start_func)
    end)
end
```

## 服务生命周期

### 完整生命周期流程

```
创建请求
    ↓
launcher.LAUNCH
    ├── skynet.launch (C层)
    ├── 记录 instance/session
    └── 等待确认
    ↓
服务初始化
    ├── snlua 加载 Lua 代码
    ├── 执行 skynet.start
    └── 发送 LAUNCHOK/ERROR
    ↓
服务运行
    ├── 消息处理
    ├── 定时器
    └── Fork 任务
    ↓
服务退出
    ├── skynet.exit
    ├── 通知 launcher.REMOVE
    └── 清理资源
```

## 最佳实践

### 1. 服务启动错误处理

```lua
-- 使用 pcall 捕获启动错误
local ok, addr = pcall(skynet.newservice, "myservice")
if not ok then
    skynet.error("Failed to start service: " .. addr)
    -- 处理错误...
else
    -- 使用服务地址...
end
```

### 2. 唯一服务模式

```lua
-- 确保服务唯一性
local console = skynet.uniqueservice("console")

-- 多次调用返回同一个服务
local console2 = skynet.uniqueservice("console")
assert(console == console2)
```

### 3. 服务命名规范

```lua
-- 系统服务使用 . 前缀
skynet.name(".myservice", addr)

-- 全局服务使用大写
skynet.name("GAMESERVER", addr)

-- 唯一服务使用 @ 前缀（自动）
local svc = skynet.uniqueservice(true, "myservice")
-- 内部名称为 @myservice
```

## 性能优化

### 1. 批量查询优化

Launcher 使用批量请求机制查询服务状态，减少等待时间：

```lua
local req = skynet.request()
for addr in pairs(services) do
    req:add { addr, "debug", "STAT" }
end

-- 并发收集所有响应
for req, resp in req:select(timeout) do
    -- 处理响应
end
```

### 2. 延迟响应机制

服务启动使用延迟响应，避免阻塞 Launcher：

```lua
local response = skynet.response()
instance[handle] = response
-- 稍后在 LAUNCHOK/ERROR 中响应
response(true, handle)
```

## 总结

本文档（Part 1）详细分析了 Skynet 的服务管理机制：

1. **启动流程**：从 Bootstrap 到用户服务的完整启动链
2. **Launcher 服务**：核心的服务启动和管理器
3. **Manager API**：便捷的服务管理接口
4. **Service Manager**：唯一服务管理实现
5. **生命周期**：服务从创建到销毁的完整过程

这些机制共同构成了 Skynet 灵活而强大的服务管理系统。下一部分（Part 2）将继续分析唯一服务、服务监控等高级特性。

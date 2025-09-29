# Skynet Lua框架层 - 核心框架 Part 2：服务管理与协议系统 (07-02)

## 模块概述

本文档（Part 2）继续分析 Skynet Lua 框架层的高级特性，包括协议注册、消息分发、Fork 机制、服务管理、延迟响应、追踪调试等核心功能。这些机制共同构建了 Skynet 强大而灵活的服务框架。

### 核心功能
- **协议系统**：灵活的消息协议注册和管理
- **消息分发**：高效的消息路由和处理
- **Fork 机制**：轻量级任务并发
- **服务管理**：服务创建、查询和管理
- **调试支持**：完善的追踪和诊断工具

## 协议系统

### 1. 协议注册机制

```lua
-- 协议表
local proto = {}
skynet._proto = proto

-- 注册协议
function skynet.register_protocol(class)
    local name = class.name
    local id = class.id
    
    -- 验证协议唯一性
    assert(proto[name] == nil and proto[id] == nil)
    assert(type(name) == "string" and type(id) == "number" 
           and id >= 0 and id <= 255)
    
    -- 双向索引（名称和ID）
    proto[name] = class
    proto[id] = class
end
```

### 2. 协议结构定义

```lua
-- 协议类结构
local protocol = {
    name = "lua",                    -- 协议名称
    id = skynet.PTYPE_LUA,          -- 协议 ID
    pack = skynet.pack,              -- 打包函数
    unpack = skynet.unpack,          -- 解包函数
    dispatch = function(...) end,    -- 处理函数
    trace = nil,                     -- 追踪标志
}
```

### 3. 内置协议注册

```lua
do
    local REG = skynet.register_protocol
    
    -- Lua 协议（最常用）
    REG {
        name = "lua",
        id = skynet.PTYPE_LUA,
        pack = skynet.pack,
        unpack = skynet.unpack,
    }
    
    -- 响应协议（内部使用）
    REG {
        name = "response",
        id = skynet.PTYPE_RESPONSE,
    }
    
    -- 错误协议
    REG {
        name = "error",
        id = skynet.PTYPE_ERROR,
        unpack = function(...) return ... end,
        dispatch = _error_dispatch,
    }
    
    -- 系统协议
    REG {
        name = "system",
        id = skynet.PTYPE_SYSTEM,
        unpack = function(...) return ... end,
    }
    
    -- Socket 协议
    REG {
        name = "socket",
        id = skynet.PTYPE_SOCKET,
        unpack = skynet.tostring,
    }
end
```

## 消息分发机制

### 1. 消息分发核心

```lua
local function raw_dispatch_message(prototype, msg, sz, session, source)
    -- 处理响应消息
    if prototype == 1 then  -- skynet.PTYPE_RESPONSE
        local co = session_id_coroutine[session]
        
        if co == "BREAK" then
            -- 会话已中断
            session_id_coroutine[session] = nil
        elseif co == nil then
            -- 未知会话
            unknown_response(session, source, msg, sz)
        else
            -- 恢复等待的协程
            local tag = session_coroutine_tracetag[co]
            if tag then c.trace(tag, "resume") end
            
            session_id_coroutine[session] = nil
            suspend(co, coroutine_resume(co, true, msg, sz, session))
        end
    else
        -- 处理请求消息
        local p = proto[prototype]
        
        if p == nil then
            -- 未知协议
            if prototype == skynet.PTYPE_TRACE then
                -- 追踪请求
                trace_source[source] = c.tostring(msg, sz)
            elseif session ~= 0 then
                -- 返回错误
                c.send(source, skynet.PTYPE_ERROR, session, "")
            else
                unknown_request(session, source, msg, sz, prototype)
            end
            return
        end
        
        local f = p.dispatch
        if f then
            -- 创建协程处理消息
            local co = co_create(f)
            session_coroutine_id[co] = session
            session_coroutine_address[co] = source
            
            -- 处理追踪标志
            local traceflag = p.trace
            if traceflag == false then
                -- 强制关闭追踪
                trace_source[source] = nil
                session_coroutine_tracetag[co] = false
            else
                local tag = trace_source[source]
                if tag then
                    trace_source[source] = nil
                    c.trace(tag, "request")
                    session_coroutine_tracetag[co] = tag
                elseif traceflag then
                    -- 设置追踪
                    running_thread = co
                    skynet.trace()
                end
            end
            
            -- 启动协程处理消息
            suspend(co, coroutine_resume(co, session, source, p.unpack(msg, sz)))
        else
            -- 无处理函数
            trace_source[source] = nil
            if session ~= 0 then
                c.send(source, skynet.PTYPE_ERROR, session, "")
            else
                unknown_request(session, source, msg, sz, proto[prototype].name)
            end
        end
    end
end
```

### 2. 分发入口与 Fork 处理

```lua
function skynet.dispatch_message(...)
    -- 安全调用消息分发
    local succ, err = pcall(raw_dispatch_message, ...)
    
    -- 处理 Fork 队列
    while true do
        if fork_queue.h > fork_queue.t then
            -- 队列为空
            fork_queue.h = 1
            fork_queue.t = 0
            break
        end
        
        -- 弹出队列头
        local h = fork_queue.h
        local co = fork_queue[h]
        fork_queue[h] = nil
        fork_queue.h = h + 1
        
        -- 执行 Fork 的协程
        local fork_succ, fork_err = pcall(suspend, co, coroutine_resume(co))
        
        if not fork_succ then
            if succ then
                succ = false
                err = tostring(fork_err)
            else
                -- 累加错误信息
                err = tostring(err) .. "\n" .. tostring(fork_err)
            end
        end
    end
    
    assert(succ, tostring(err))
end
```

### 3. 设置消息处理器

```lua
-- 设置协议的处理函数
function skynet.dispatch(typename, func)
    local p = proto[typename]
    if func then
        local ret = p.dispatch
        p.dispatch = func
        return ret  -- 返回旧的处理函数
    else
        return p and p.dispatch
    end
end

-- 设置未知请求处理器
function skynet.dispatch_unknown_request(unknown)
    local prev = unknown_request
    unknown_request = unknown
    return prev
end

-- 设置未知响应处理器
function skynet.dispatch_unknown_response(unknown)
    local prev = unknown_response
    unknown_response = unknown
    return prev
end
```

## Fork 机制

Fork 机制允许在当前服务内创建轻量级的并发任务，这些任务在消息处理完成后执行。

### 1. Fork 实现

```lua
-- Fork 队列
local fork_queue = { h = 1, t = 0 }  -- head 和 tail

function skynet.fork(func, ...)
    local n = select("#", ...)
    local co
    
    if n == 0 then
        -- 无参数
        co = co_create(func)
    else
        -- 有参数，需要包装
        local args = { ... }
        co = co_create(function() 
            func(table.unpack(args, 1, n)) 
        end)
    end
    
    -- 加入队列尾部
    local t = fork_queue.t + 1
    fork_queue.t = t
    fork_queue[t] = co
    
    return co  -- 返回协程供调试
end
```

### 2. Fork 执行时机

Fork 的协程在当前消息处理完成后执行：

```lua
-- 在 dispatch_message 中
function skynet.dispatch_message(...)
    -- 处理当前消息
    local succ, err = pcall(raw_dispatch_message, ...)
    
    -- 执行所有 Fork 的任务
    while fork_queue.h <= fork_queue.t do
        local h = fork_queue.h
        local co = fork_queue[h]
        fork_queue[h] = nil
        fork_queue.h = h + 1
        
        -- 执行 Fork 协程
        pcall(suspend, co, coroutine_resume(co))
    end
end
```

### 3. Fork 使用场景

```lua
-- 示例：异步处理
skynet.dispatch("lua", function(session, source, cmd, ...)
    if cmd == "process" then
        -- 立即响应
        skynet.ret(skynet.pack(true))
        
        -- Fork 异步处理
        skynet.fork(function()
            -- 耗时操作
            local result = heavy_computation(...)
            -- 通知结果
            skynet.send(source, "lua", "result", result)
        end)
    end
end)
```

## 延迟响应机制

### 1. Response 对象

```lua
function skynet.response(pack)
    pack = pack or skynet.pack
    
    local co_session = assert(session_coroutine_id[running_thread], "no session")
    session_coroutine_id[running_thread] = nil
    local co_address = session_coroutine_address[running_thread]
    
    if co_session == 0 then
        -- send 调用不需要响应
        return function() end
    end
    
    local function response(ok, ...)
        if ok == "TEST" then
            -- 测试是否已响应
            return unresponse[response] ~= nil
        end
        
        if not pack then
            error "Can't response more than once"
        end
        
        local ret
        if unresponse[response] then
            if ok then
                -- 发送成功响应
                ret = c.send(co_address, skynet.PTYPE_RESPONSE, 
                           co_session, pack(...))
                if ret == false then
                    -- 包太大，发送错误
                    c.send(co_address, skynet.PTYPE_ERROR, co_session, "")
                end
            else
                -- 发送错误响应
                ret = c.send(co_address, skynet.PTYPE_ERROR, co_session, "")
            end
            unresponse[response] = nil
            ret = ret ~= nil
        else
            ret = false
        end
        
        pack = nil  -- 防止重复响应
        return ret
    end
    
    -- 记录未响应状态
    unresponse[response] = co_address
    
    return response
end
```

### 2. 延迟响应示例

```lua
-- 创建延迟响应
local response = skynet.response()

-- 异步处理
skynet.fork(function()
    -- 执行异步操作
    local result = async_operation()
    
    -- 稍后响应
    response(true, result)
end)

-- 或者保存 response 到其他地方
pending_responses[id] = response

-- 在其他时机响应
function handle_callback(id, result)
    local resp = pending_responses[id]
    if resp then
        resp(true, result)
        pending_responses[id] = nil
    end
end
```

## 服务管理

### 1. 服务创建

```lua
-- 创建新服务
function skynet.newservice(name, ...)
    return skynet.call(".launcher", "lua", "LAUNCH", "snlua", name, ...)
end

-- 创建唯一服务
function skynet.uniqueservice(global, ...)
    if global == true then
        -- 全局唯一
        return assert(skynet.call(".service", "lua", "GLAUNCH", ...))
    else
        -- 节点唯一
        return assert(skynet.call(".service", "lua", "LAUNCH", global, ...))
    end
end

-- 查询服务
function skynet.queryservice(global, ...)
    if global == true then
        -- 查询全局服务
        return assert(skynet.call(".service", "lua", "GQUERY", ...))
    else
        -- 查询本地服务
        return assert(skynet.call(".service", "lua", "QUERY", global, ...))
    end
end
```

### 2. 服务地址管理

```lua
-- 获取自己的地址
function skynet.self()
    return c.addresscommand "REG"
end

-- 查询本地命名服务
function skynet.localname(name)
    return c.addresscommand("QUERY", name)
end

-- 格式化地址
function skynet.address(addr)
    if type(addr) == "number" then
        return string.format(":%08x", addr)
    else
        return tostring(addr)
    end
end

-- 获取 Harbor ID
function skynet.harbor(addr)
    return c.harbor(addr)
end
```

## 服务启动流程

### 1. 启动入口

```lua
function skynet.start(start_func)
    -- 设置消息回调
    c.callback(skynet.dispatch_message)
    
    -- 延迟初始化（确保消息循环已启动）
    init_thread = skynet.timeout(0, function()
        skynet.init_service(start_func)
        init_thread = nil
    end)
end
```

### 2. 服务初始化

```lua
function skynet.init_service(start)
    local function main()
        -- 初始化所有 require 的模块
        skynet_require.init_all()
        -- 执行用户启动函数
        start()
    end
    
    local ok, err = xpcall(main, traceback)
    
    if not ok then
        -- 初始化失败
        skynet.error("init service failed: " .. tostring(err))
        skynet.send(".launcher", "lua", "ERROR")
        skynet.exit()
    else
        -- 初始化成功
        skynet.send(".launcher", "lua", "LAUNCHOK")
    end
end
```

### 3. 典型服务结构

```lua
local skynet = require "skynet"
require "skynet.manager"  -- 导入命名服务支持

local CMD = {}

function CMD.hello(name)
    return "Hello, " .. name
end

function CMD.exit()
    skynet.exit()
end

skynet.start(function()
    -- 注册协议处理
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local f = CMD[cmd]
        if f then
            skynet.retpack(f(...))
        else
            error(string.format("Unknown command %s", tostring(cmd)))
        end
    end)
    
    -- 注册服务名（可选）
    skynet.register(".myservice")
    
    skynet.error("Service started")
end)
```

## 追踪与调试

### 1. 追踪机制

```lua
-- 追踪 ID 生成
local traceid = 0

function skynet.trace(info)
    skynet.error("TRACE", session_coroutine_tracetag[running_thread])
    
    if session_coroutine_tracetag[running_thread] == false then
        -- 强制关闭追踪
        return
    end
    
    traceid = traceid + 1
    
    -- 生成追踪标签
    local tag = string.format(":%08x-%d", skynet.self(), traceid)
    session_coroutine_tracetag[running_thread] = tag
    
    if info then
        c.trace(tag, "trace " .. info)
    else
        c.trace(tag, "trace")
    end
end

-- 获取当前追踪标签
function skynet.tracetag()
    return session_coroutine_tracetag[running_thread]
end

-- 设置协议追踪
function skynet.traceproto(prototype, flag)
    local p = assert(proto[prototype])
    p.trace = flag  -- true: 强制开启, false: 强制关闭, nil: 可选
end
```

### 2. 任务诊断

```lua
-- 获取任务信息
function skynet.task(ret)
    if ret == nil then
        -- 返回任务数量
        local t = 0
        for _, co in pairs(session_id_coroutine) do
            if co ~= "BREAK" then
                t = t + 1
            end
        end
        return t
    end
    
    if ret == "init" then
        -- 返回初始化线程
        if init_thread then
            return traceback(init_thread)
        else
            return
        end
    end
    
    local tt = type(ret)
    if tt == "table" then
        -- 收集所有任务
        for session, co in pairs(session_id_coroutine) do
            local key = string.format("%s session: %d", tostring(co), session)
            ret[key] = task_traceback(co)
        end
        return
    elseif tt == "number" then
        -- 查询特定会话
        local co = session_id_coroutine[ret]
        if co then
            return task_traceback(co)
        else
            return "No session"
        end
    elseif tt == "thread" then
        -- 查询协程的会话
        for session, co in pairs(session_id_coroutine) do
            if co == ret then
                return session
            end
        end
        return
    end
end
```

### 3. 任务去重统计

```lua
function skynet.uniqtask()
    local stacks = {}
    
    -- 收集所有堆栈
    for session, co in pairs(session_id_coroutine) do
        local stack = task_traceback(co)
        local info = stacks[stack] or {count = 0, sessions = {}}
        info.count = info.count + 1
        
        if info.count < 10 then
            info.sessions[#info.sessions+1] = session
        end
        
        stacks[stack] = info
    end
    
    -- 格式化输出
    local ret = {}
    for stack, info in pairs(stacks) do
        local count = info.count
        local sessions = table.concat(info.sessions, ",")
        
        if count > 10 then
            sessions = sessions .. "..."
        end
        
        local head_line = string.format("%d\tsessions:[%s]\n", count, sessions)
        ret[head_line] = stack
    end
    
    return ret
end
```

## 系统状态查询

```lua
-- 服务是否永不退出
function skynet.endless()
    return (c.intcommand("STAT", "endless") == 1)
end

-- 消息队列长度
function skynet.mqlen()
    return c.intcommand("STAT", "mqlen")
end

-- 通用状态查询
function skynet.stat(what)
    return c.intcommand("STAT", what)
end

-- 内存限制设置（只能设置一次）
function skynet.memlimit(bytes)
    debug.getregistry().memlimit = bytes
    skynet.memlimit = nil
end
```

## 环境变量管理

```lua
-- 获取环境变量
function skynet.getenv(key)
    return (c.command("GETENV", key))
end

-- 设置环境变量
function skynet.setenv(key, value)
    assert(c.command("GETENV", key) == nil, 
           "Can't setenv exist key : " .. key)
    c.command("SETENV", key .. " " .. value)
end
```

## 时间管理

```lua
-- 获取启动时间
local starttime

function skynet.starttime()
    if not starttime then
        starttime = c.intcommand("STARTTIME")
    end
    return starttime
end

-- 获取当前时间（秒）
function skynet.time()
    return skynet.now()/100 + (starttime or skynet.starttime())
end

-- 高精度计时器
skynet.now = c.now    -- 百分之一秒精度
skynet.hpc = c.hpc    -- 高精度计数器
```

## 调试框架注入

```lua
-- 注入内部调试框架
local debug = require "skynet.debug"
debug.init(skynet, {
    dispatch = skynet.dispatch_message,
    suspend = suspend,
    resume = coroutine_resume,
})
```

## 性能优化策略

### 1. 协议缓存
- 双向索引（名称和 ID）
- 直接函数引用避免查找

### 2. Fork 队列优化
- 环形缓冲区设计
- 批量执行减少开销

### 3. 追踪控制
- 三态控制（强制开/关/可选）
- 按需开启减少性能影响

## 架构图

### 协议系统架构

```
┌─────────────────────────────────────────────┐
│             用户层                           │
│    skynet.dispatch("lua", handler)          │
└─────────────┬───────────────────────────────┘
              ↓
┌─────────────────────────────────────────────┐
│           协议注册表 (proto)                  │
│  ┌──────────┬──────────┬──────────┐        │
│  │   lua    │ response │  error   │        │
│  ├──────────┼──────────┼──────────┤        │
│  │  system  │  socket  │  debug   │        │
│  └──────────┴──────────┴──────────┘        │
└─────────────┬───────────────────────────────┘
              ↓
┌─────────────────────────────────────────────┐
│         消息分发 (dispatch_message)          │
│                                              │
│  prototype → proto[type] → dispatch → co    │
└─────────────────────────────────────────────┘
```

### 服务生命周期

```
skynet.start()
    ↓
设置回调 (c.callback)
    ↓
超时触发 (timeout 0)
    ↓
init_service()
    ├── require.init_all()
    ├── start_func()
    └── LAUNCHOK/ERROR
    ↓
消息循环
    ├── 接收消息
    ├── dispatch_message()
    ├── 协程处理
    └── Fork 执行
    ↓
skynet.exit()
    ├── 通知 launcher
    ├── 清理协程
    └── EXIT
```

## 最佳实践

### 1. 协议设计
```lua
-- 自定义协议
skynet.register_protocol {
    name = "myproto",
    id = 200,
    pack = function(...) 
        return msgpack.pack(...) 
    end,
    unpack = function(msg, sz) 
        return msgpack.unpack(msg, sz) 
    end,
}
```

### 2. 延迟响应模式
```lua
local response_map = {}

skynet.dispatch("lua", function(session, source, cmd, ...)
    if cmd == "async_task" then
        local resp = skynet.response()
        local task_id = start_async_task(...)
        response_map[task_id] = resp
    end
end)

function on_task_complete(task_id, result)
    local resp = response_map[task_id]
    if resp then
        resp(true, result)
        response_map[task_id] = nil
    end
end
```

### 3. Fork 并发控制
```lua
local running_tasks = 0
local MAX_TASKS = 10

function process_with_limit(data)
    if running_tasks >= MAX_TASKS then
        skynet.sleep(10)  -- 等待
        return process_with_limit(data)
    end
    
    running_tasks = running_tasks + 1
    skynet.fork(function()
        process_data(data)
        running_tasks = running_tasks - 1
    end)
end
```

## 总结

本文档（Part 2）详细分析了 Skynet Lua 框架层的高级特性：

1. **协议系统**：灵活的消息协议注册和管理机制
2. **消息分发**：高效的消息路由和协程调度
3. **Fork 机制**：轻量级的任务并发模型
4. **服务管理**：完整的服务生命周期管理
5. **延迟响应**：支持异步处理的响应机制
6. **调试支持**：强大的追踪和诊断工具

这些特性使 Skynet 成为一个功能完备、性能优异的服务框架，为构建高并发分布式系统提供了坚实基础。通过精心设计的 API 和优化策略，开发者可以轻松构建可靠、高效的服务应用。
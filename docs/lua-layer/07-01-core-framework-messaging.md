# Skynet Lua框架层 - 核心框架 Part 1：消息机制与协程管理 (07-01)

## 模块概述

Skynet 的 Lua 框架层是整个系统的高层抽象，提供了易用的 API 和强大的并发模型。核心框架（skynet.lua）是所有 Lua 服务的基础，实现了消息调度、协程管理、服务通信等关键功能。本文档（Part 1）详细分析消息机制和协程管理部分。

### 框架定位
- **层次**：Lua 框架层最底层
- **作用**：提供核心 API 和运行时支持
- **特点**：协程池、会话管理、错误处理

## 核心数据结构

### 1. 协程会话映射

```lua
-- 会话到协程的映射
local session_id_coroutine = {}        -- session -> coroutine
local session_coroutine_id = {}        -- coroutine -> session  
local session_coroutine_address = {}   -- coroutine -> source address
local session_coroutine_tracetag = {}  -- coroutine -> trace tag

-- 未响应的请求（response 函数 -> 对端地址）
local unresponse = {}

-- 唤醒队列与睡眠映射
local wakeup_queue = {}
local sleep_session = {}               -- token -> session

-- 监控会话
local watching_session = {}            -- session -> watching service
local error_queue = {}                 -- 错误队列

-- Fork 队列
local fork_queue = { h = 1, t = 0 }    -- head 和 tail 指针
```

### 2. 消息类型定义

```lua
local skynet = {
    -- 消息类型常量（对应 C 层定义）
    PTYPE_TEXT = 0,        -- 文本消息
    PTYPE_RESPONSE = 1,    -- 响应消息
    PTYPE_MULTICAST = 2,   -- 多播消息
    PTYPE_CLIENT = 3,      -- 客户端消息
    PTYPE_SYSTEM = 4,      -- 系统消息
    PTYPE_HARBOR = 5,      -- Harbor 消息
    PTYPE_SOCKET = 6,      -- Socket 消息
    PTYPE_ERROR = 7,       -- 错误消息
    PTYPE_QUEUE = 8,       -- 队列消息（对应早期 mqueue，已废弃；使用 skynet.queue 替代）
    PTYPE_DEBUG = 9,       -- 调试消息
    PTYPE_LUA = 10,        -- Lua 消息
    PTYPE_SNAX = 11,       -- SNAX 消息
    PTYPE_TRACE = 12,      -- 追踪消息
}
```

## 协程管理机制

### 1. 协程池设计

Skynet 实现了高效的协程池，避免频繁创建和销毁协程带来的开销。

```lua
-- 协程池（弱引用表，允许 GC）
local coroutine_pool = setmetatable({}, { __mode = "kv" })

local function co_create(f)
    local co = tremove(coroutine_pool)
    if co == nil then
        -- 创建新协程
        co = coroutine_create(function(...)
            f(...)
            while true do
                -- 协程执行完毕后的清理工作
                local session = session_coroutine_id[co]
                if session and session ~= 0 then
                    -- 检查是否忘记响应
                    local source = debug.getinfo(f,"S")
                    skynet.error(string.format(
                        "Maybe forgot response session %s from %s : %s:%d",
                        session,
                        skynet.address(session_coroutine_address[co]),
                        source.source, source.linedefined))
                end
                
                -- 清理追踪标签
                local tag = session_coroutine_tracetag[co]
                if tag ~= nil then
                    if tag then c.trace(tag, "end") end
                    session_coroutine_tracetag[co] = nil
                end
                
                -- 清理地址信息
                local address = session_coroutine_address[co]
                if address then
                    session_coroutine_id[co] = nil
                    session_coroutine_address[co] = nil
                end
                
                -- 回收协程到池中
                f = nil
                coroutine_pool[#coroutine_pool+1] = co
                
                -- 等待新任务
                f = coroutine_yield "SUSPEND"
                f(coroutine_yield())
            end
        end)
    else
        -- 复用已有协程
        local running = running_thread
        coroutine_resume(co, f)
        running_thread = running
    end
    return co
end
```

#### 协程池优势：
1. **减少内存分配**：复用协程避免频繁创建
2. **自动清理**：执行完毕后自动清理状态
3. **错误检测**：检查未响应的会话
4. **追踪支持**：集成追踪标签管理

### 2. 协程调度

```lua
-- 当前运行的协程
local running_thread = nil
local init_thread = nil

-- 封装的协程恢复函数
local function coroutine_resume(co, ...)
    running_thread = co
    return cresume(co, ...)
end

-- 协程挂起处理
local function suspend(co, result, command)
    if not result then
        -- 协程执行出错
        local session = session_coroutine_id[co]
        if session then
            local addr = session_coroutine_address[co]
            if session ~= 0 then
                -- 发送错误响应
                local tag = session_coroutine_tracetag[co]
                if tag then c.trace(tag, "error") end
                c.send(addr, skynet.PTYPE_ERROR, session, "")
            end
            session_coroutine_id[co] = nil
        end
        
        -- 清理状态
        session_coroutine_address[co] = nil
        session_coroutine_tracetag[co] = nil
        
        -- 触发错误处理
        skynet.fork(function() end)  -- 触发 "SUSPEND" 命令
        local tb = traceback(co, tostring(command))
        coroutine.close(co)
        error(tb)
    end
    
    -- 根据命令处理
    if command == "SUSPEND" then
        return dispatch_wakeup()        -- 唤醒等待的协程
    elseif command == "QUIT" then
        coroutine.close(co)
        return                          -- 服务退出
    elseif command == "USER" then
        error("Call skynet.coroutine.yield out of skynet.coroutine.resume\n" 
              .. traceback(co))
    elseif command == nil then
        return                          -- debug trace
    else
        error("Unknown command : " .. command .. "\n" .. traceback(co))
    end
end
```

### 3. 协程唤醒机制

```lua
-- 唤醒队列中的协程
local function dispatch_wakeup()
    while true do
        local token = tremove(wakeup_queue, 1)
        if token then
            local session = sleep_session[token]
            if session then
                local co = session_id_coroutine[session]
                local tag = session_coroutine_tracetag[co]
                if tag then c.trace(tag, "resume") end
                
                session_id_coroutine[session] = "BREAK"
                return suspend(co, coroutine_resume(co, false, "BREAK", nil, session))
            end
        else
            break
        end
    end
    return dispatch_error_queue()
end

-- 唤醒指定协程
function skynet.wakeup(token)
    if sleep_session[token] then
        tinsert(wakeup_queue, token)
        return true
    end
end
```

## 会话管理机制

### 1. 会话 ID 冲突避免

Skynet 实现了精巧的会话 ID 冲突避免机制，防止会话 ID 重复使用导致的问题。

```lua
do ---- 避免会话回绕冲突
    local csend = c.send
    local cintcommand = c.intcommand
    local dangerzone            -- 危险区域的会话集合
    local dangerzone_size = 0x1000
    local dangerzone_low = 0x70000000
    local dangerzone_up = dangerzone_low + dangerzone_size
    
    -- 重置危险区域
    local function reset_dangerzone(session)
        dangerzone_up = session
        dangerzone_low = session
        dangerzone = { [session] = true }
        
        -- 扫描所有活跃会话
        for s in pairs(session_id_coroutine) do
            if s < dangerzone_low then
                dangerzone_low = s
            elseif s > dangerzone_up then
                dangerzone_up = s
            end
            dangerzone[s] = true
        end
        dangerzone_low = dangerzone_low - dangerzone_size
    end
    
    -- 在危险区域检查冲突
    local function checkconflict(session)
        if session == nil then
            return
        end
        local next_session = session + 1
        
        if next_session > dangerzone_up then
            -- 离开危险区域
            reset_dangerzone(session)
            assert(next_session > dangerzone_up)
            set_checkrewind()
        else
            -- 检查下一个会话是否已存在
            while true do
                if not dangerzone[next_session] then
                    break
                end
                if not session_id_coroutine[next_session] then
                    reset_dangerzone(session)
                    break
                end
                -- 跳过已存在的会话
                next_session = c.genid() + 1
            end
        end
        
        -- 处理会话回绕（0x7fffffff 后回到 1）
        if next_session == 0x80000000 and dangerzone[1] then
            assert(c.genid() == 1)
            return checkconflict(1)
        end
    end
end
```

#### 会话管理策略：
1. **安全区**：正常分配会话 ID
2. **危险区**：接近回绕点，需要检查冲突
3. **动态切换**：根据当前会话 ID 自动切换策略
4. **冲突跳过**：遇到已使用的 ID 自动跳过

### 2. 会话生命周期

```lua
-- 创建会话（用于 call）
local function yield_call(service, session)
    watching_session[session] = service     -- 记录监控
    session_id_coroutine[session] = running_thread
    
    -- 挂起等待响应
    local succ, msg, sz = coroutine_yield "SUSPEND"
    
    watching_session[session] = nil         -- 清除监控
    if not succ then
        error "call failed"
    end
    return msg, sz
end

-- 响应会话
function skynet.ret(msg, sz)
    msg = msg or ""
    local tag = session_coroutine_tracetag[running_thread]
    if tag then c.trace(tag, "response") end
    
    local co_session = session_coroutine_id[running_thread]
    if co_session == nil then
        error "No session"
    end
    
    session_coroutine_id[running_thread] = nil
    
    if co_session == 0 then
        -- send 不需要响应
        if sz ~= nil then
            c.trash(msg, sz)
        end
        return false
    end
    
    local co_address = session_coroutine_address[running_thread]
    local ret = c.send(co_address, skynet.PTYPE_RESPONSE, co_session, msg, sz)
    
    if ret then
        return true
    elseif ret == false then
        -- 包太大，返回错误
        c.send(co_address, skynet.PTYPE_ERROR, co_session, "")
    end
    return false
end
```

## 消息发送机制

### 1. 基础发送接口

```lua
-- 发送消息（不等待响应）
function skynet.send(addr, typename, ...)
    local p = proto[typename]
    return c.send(addr, p.id, 0, p.pack(...))
end

-- 原始发送（已打包的消息）
function skynet.rawsend(addr, typename, msg, sz)
    local p = proto[typename]
    return c.send(addr, p.id, 0, msg, sz)
end

-- 调用服务（等待响应）
function skynet.call(addr, typename, ...)
    local tag = session_coroutine_tracetag[running_thread]
    if tag then
        c.trace(tag, "call", 2)
        c.send(addr, skynet.PTYPE_TRACE, 0, tag)
    end
    
    local p = proto[typename]
    local session = auxsend(addr, p.id, p.pack(...))
    
    if session == nil then
        error("call to invalid address " .. skynet.address(addr))
    end
    
    return p.unpack(yield_call(addr, session))
end
```

### 2. 批量请求机制

Skynet 提供了强大的批量请求机制，支持同时向多个服务发送请求并收集响应。

```lua
do ---- request/select 实现
    -- 发送所有请求
    local function send_requests(self)
        local sessions = {}
        self._sessions = sessions
        local request_n = 0
        local err
        
        for i = 1, #self do
            local req = self[i]
            local addr = req[1]
            local p = proto[req[2]]
            
            -- 发送追踪信息
            local tag = session_coroutine_tracetag[running_thread]
            if tag then
                c.trace(tag, "call", 4)
                c.send(addr, skynet.PTYPE_TRACE, 0, tag)
            end
            
            -- 发送请求
            local session = auxsend(addr, p.id, p.pack(tunpack(req, 3, req.n)))
            
            if session == nil then
                -- 记录错误
                err = err or {}
                err[#err+1] = req
            else
                -- 记录会话信息
                sessions[session] = req
                watching_session[session] = addr
                session_id_coroutine[session] = self._thread
                request_n = request_n + 1
            end
        end
        
        self._request = request_n
        return err
    end
    
    -- 请求处理协程
    local function request_thread(self)
        while true do
            local succ, msg, sz, session = coroutine_yield "SUSPEND"
            
            if session == self._timeout then
                -- 超时
                self._timeout = nil
                self.timeout = true
            else
                -- 收到响应
                watching_session[session] = nil
                local req = self._sessions[session]
                local p = proto[req[2]]
                
                if succ then
                    self._resp[session] = tpack(p.unpack(msg, sz))
                else
                    self._resp[session] = false
                end
            end
            
            skynet.wakeup(self)
        end
    end
    
    -- 迭代器
    local function request_iter(self)
        return function()
            -- 处理错误的请求
            if self._error then
                local e = tremove(self._error)
                if e then
                    return e
                end
                self._error = nil
            end
            
            -- 获取下一个响应
            local session, resp = next(self._resp)
            if session == nil then
                if self._request == 0 then
                    return  -- 所有请求已处理
                end
                if self.timeout then
                    return  -- 超时
                end
                
                -- 等待更多响应
                skynet.wait(self)
                
                if self.timeout then
                    return
                end
                session, resp = next(self._resp)
            end
            
            self._request = self._request - 1
            local req = self._sessions[session]
            self._resp[session] = nil
            self._sessions[session] = nil
            
            return req, resp
        end
    end
    
    -- 请求对象元表
    local request_meta = {}
    request_meta.__index = request_meta
    
    -- 添加请求
    function request_meta:add(obj)
        assert(type(obj) == "table" and not self._thread)
        self[#self+1] = obj
        return self
    end
    
    request_meta.__call = request_meta.add
    
    -- 关闭请求
    function request_meta:close()
        if self._request > 0 then
            local resp = self._resp
            for session, req in pairs(self._sessions) do
                if not resp[session] then
                    session_id_coroutine[session] = "BREAK"
                    watching_session[session] = nil
                end
            end
            self._request = 0
        end
        
        if self._timeout then
            session_id_coroutine[self._timeout] = "BREAK"
            self._timeout = nil
        end
    end
    
    request_meta.__close = request_meta.close
    
    -- 执行批量请求
    function request_meta:select(timeout)
        assert(self._thread == nil)
        
        -- 创建处理协程
        self._thread = coroutine_create(request_thread)
        
        -- 发送所有请求
        self._error = send_requests(self)
        self._resp = {}
        
        -- 设置超时
        if timeout then
            self._timeout = auxtimeout(timeout)
            session_id_coroutine[self._timeout] = self._thread
        end
        
        -- 启动处理协程
        local running = running_thread
        coroutine_resume(self._thread, self)
        running_thread = running
        
        return request_iter(self), nil, nil, self
    end
    
    -- 创建请求对象
    function skynet.request(obj)
        local ret = setmetatable({}, request_meta)
        if obj then
            return ret(obj)
        end
        return ret
    end
end
```

#### 批量请求示例：

```lua
-- 创建批量请求
local req = skynet.request()
req:add { addr1, "lua", "cmd1", arg1 }
req:add { addr2, "lua", "cmd2", arg2 }
req:add { addr3, "lua", "cmd3", arg3 }

-- 执行并收集响应（带超时）
for req, resp in req:select(500) do  -- 500cs = 5秒
    if resp then
        -- 处理响应
        local result = resp[1]
    else
        -- 请求失败
    end
end
```

## 定时器与睡眠机制

### 1. 超时处理

```lua
-- 超时追踪
local co_create_for_timeout
local timeout_traceback

function skynet.trace_timeout(on)
    local function trace_coroutine(func, ti)
        local co
        co = co_create(function()
            timeout_traceback[co] = nil
            func()
        end)
        
        -- 记录超时信息
        local info = string.format("TIMER %d+%d : ", skynet.now(), ti)
        timeout_traceback[co] = traceback(info, 3)
        return co
    end
    
    if on then
        timeout_traceback = timeout_traceback or {}
        co_create_for_timeout = trace_coroutine
    else
        timeout_traceback = nil
        co_create_for_timeout = co_create
    end
end

-- 设置超时
function skynet.timeout(ti, func)
    local session = auxtimeout(ti)
    assert(session)
    
    local co = co_create_for_timeout(func, ti)
    assert(session_id_coroutine[session] == nil)
    session_id_coroutine[session] = co
    
    return co  -- 返回协程供调试
end
```

### 2. 睡眠机制

```lua
-- 内部睡眠实现
local function suspend_sleep(session, token)
    local tag = session_coroutine_tracetag[running_thread]
    if tag then c.trace(tag, "sleep", 2) end
    
    session_id_coroutine[session] = running_thread
    assert(sleep_session[token] == nil, "token duplicative")
    sleep_session[token] = session
    
    return coroutine_yield "SUSPEND"
end

-- 睡眠指定时间
function skynet.sleep(ti, token)
    local session = auxtimeout(ti)
    assert(session)
    
    token = token or coroutine.running()
    local succ, ret = suspend_sleep(session, token)
    sleep_session[token] = nil
    
    if succ then
        return
    end
    if ret == "BREAK" then
        return "BREAK"
    else
        error(ret)
    end
end

-- 让出 CPU（睡眠 0）
function skynet.yield()
    return skynet.sleep(0)
end

-- 无限等待（直到被唤醒）
function skynet.wait(token)
    local session = auxwait()
    token = token or coroutine.running()
    
    suspend_sleep(session, token)
    sleep_session[token] = nil
    session_id_coroutine[session] = nil
end
```

## 错误处理机制

### 1. 错误分发

```lua
-- 错误队列处理
local function dispatch_error_queue()
    local session = tremove(error_queue, 1)
    if session then
        local co = session_id_coroutine[session]
        session_id_coroutine[session] = nil
        return suspend(co, coroutine_resume(co, false, nil, nil, session))
    end
end

-- 错误消息处理
local function _error_dispatch(error_session, error_source)
    skynet.ignoreret()  -- 错误不需要响应
    
    if error_session == 0 then
        -- 服务宕机，清理未响应集合
        for resp, address in pairs(unresponse) do
            if error_source == address then
                unresponse[resp] = nil
            end
        end
        
        -- 通知所有监控该服务的会话
        for session, srv in pairs(watching_session) do
            if srv == error_source then
                tinsert(error_queue, session)
            end
        end
    else
        -- 捕获特定会话的错误
        if watching_session[error_session] then
            tinsert(error_queue, error_session)
        end
    end
end
```

### 2. 协程终止

```lua
function skynet.killthread(thread)
    local session
    
    -- 查找会话
    if type(thread) == "string" then
        -- 通过字符串匹配查找
        for k, v in pairs(session_id_coroutine) do
            local thread_string = tostring(v)
            if thread_string:find(thread) then
                session = k
                break
            end
        end
    else
        -- 检查 fork 队列
        local t = fork_queue.t
        for i = fork_queue.h, t do
            if fork_queue[i] == thread then
                table.move(fork_queue, i+1, t, i)
                fork_queue[t] = nil
                fork_queue.t = t - 1
                return thread
            end
        end
        
        -- 查找会话映射
        for k, v in pairs(session_id_coroutine) do
            if v == thread then
                session = k
                break
            end
        end
    end
    
    local co = session_id_coroutine[session]
    if co == nil then
        return
    end
    
    -- 清理协程状态
    local addr = session_coroutine_address[co]
    if addr then
        session_coroutine_address[co] = nil
        session_coroutine_tracetag[co] = nil
        
        local session = session_coroutine_id[co]
        if session > 0 then
            c.send(addr, skynet.PTYPE_ERROR, session, "")
        end
        session_coroutine_id[co] = nil
    end
    
    -- 清理监控和睡眠状态
    if watching_session[session] then
        session_id_coroutine[session] = "BREAK"
        watching_session[session] = nil
    else
        session_id_coroutine[session] = nil
    end
    
    for k, v in pairs(sleep_session) do
        if v == session then
            sleep_session[k] = nil
            break
        end
    end
    
    coroutine.close(co)
    return co
end
```

## 服务退出流程

```lua
function skynet.exit()
    -- 停止 fork 队列
    fork_queue = { h = 1, t = 0 }
    
    -- 通知启动器
    skynet.send(".launcher", "lua", "REMOVE", skynet.self(), false)
    
    -- 通知所有调用方
    for co, session in pairs(session_coroutine_id) do
        local address = session_coroutine_address[co]
        if session ~= 0 and address then
            c.send(address, skynet.PTYPE_ERROR, session, "")
        end
    end
    
    -- 关闭所有协程
    for session, co in pairs(session_id_coroutine) do
        if type(co) == "thread" and co ~= running_thread then
            coroutine.close(co)
        end
    end
    
    -- 通知未响应的请求
    for resp in pairs(unresponse) do
        resp(false)
    end
    
    -- 通知被监控的服务
    local tmp = {}
    for session, address in pairs(watching_session) do
        tmp[address] = true
    end
    for address in pairs(tmp) do
        c.send(address, skynet.PTYPE_ERROR, 0, "")
    end
    
    -- 设置回调处理剩余消息
    c.callback(function(prototype, msg, sz, session, source)
        if session ~= 0 and source ~= 0 then
            c.send(source, skynet.PTYPE_ERROR, session, "")
        end
    end)
    
    -- 执行退出命令
    c.command("EXIT")
    
    -- 协程退出
    coroutine_yield "QUIT"
end
```

## 性能优化策略

### 1. 协程池复用
- 避免频繁创建协程
- 自动状态清理
- 弱引用允许 GC

### 2. 会话管理优化
- 危险区域检测避免 ID 冲突
- 批量请求减少上下文切换
- 会话映射使用哈希表

### 3. 内存优化
- 消息打包避免临时对象
- 错误队列批量处理
- 追踪标签按需开启

## 架构图

### 协程生命周期

```
创建/复用
    ↓
┌─────────────────┐
│   co_create     │ ←── 从协程池获取
└────────┬────────┘
         ↓
┌─────────────────┐
│   执行函数      │
└────────┬────────┘
         ↓
    ┌────┴────┐
    │ SUSPEND │ ←── yield "SUSPEND"
    └────┬────┘
         ↓
┌─────────────────┐
│   等待消息      │
└────────┬────────┘
         ↓
┌─────────────────┐
│   resume        │ ←── 收到消息/超时
└────────┬────────┘
         ↓
┌─────────────────┐
│   继续执行      │
└────────┬────────┘
         ↓
┌─────────────────┐
│   清理状态      │
└────────┬────────┘
         ↓
┌─────────────────┐
│   回收到池      │ ──→ 协程池
└─────────────────┘
```

### 消息流转

```
skynet.send                   skynet.call
     ↓                             ↓
打包消息 (proto.pack)         打包消息 (proto.pack)
     ↓                             ↓
session=0 直接发送             分配会话ID (auxsend)
     ↓                             ↓
   c.send                     记录映射：
                               - session_id_coroutine
                               - watching_session
                                  ↓
                               c.send
                 ──────────────────┼──────────────────
                                   ↓
                                 目标服务
                                   ↓
                                消息处理
                                   ↓
                                skynet.ret/response
                                   ↓
                                响应消息
                                   ↓
                            原服务收到响应
                                   ↓
                             coroutine_resume
                                   ↓
                          解包返回 (proto.unpack)
```

## 小结

本文档（Part 1）详细分析了 Skynet Lua 框架层的核心机制：

1. **协程管理**：高效的协程池和调度机制
2. **会话管理**：精巧的 ID 冲突避免策略
3. **消息机制**：同步/异步调用和批量请求
4. **错误处理**：完善的错误传播和恢复

这些机制共同构成了 Skynet 强大的并发模型基础。下一部分（Part 2）将继续分析服务管理、协议注册等高级特性。

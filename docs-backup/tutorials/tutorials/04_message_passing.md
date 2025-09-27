# 消息传递与通信

## 你将学到的内容
- Skynet 中的高级消息传递模式
- 不同类型的服务间通信方式
- 请求-响应协议
- 事件驱动型通信
- 性能优化技术

## 前置要求
- 已完成教程 3：创建你的第一个服务（Tutorial 3: Creating Your First Service）
- 理解 Skynet 基础消息传递机制
- 熟悉 Lua 协程（Lua coroutines）

## 预计耗时
50 分钟

## 最终成果
能够设计服务间的高效通信模式，并实现复杂的消息流转

---

## 1. 消息传递基础

### 1.1 消息类型与协议
Skynet 支持多种消息类型，每种类型都有特定的使用场景：

```lua
-- 内置协议类型
skynet.PTYPE_TEXT = 0        -- 简单文本消息
skynet.PTYPE_RESPONSE = 1    -- 响应消息
skynet.PTYPE_CLIENT = 3      -- 客户端 socket 消息
skynet.PTYPE_LUA = 10        -- Lua 远程过程调用（RPC）消息
skynet.PTYPE_SOCKET = 6      -- Socket 事件消息
skynet.PTYPE_ERROR = 7       -- 错误通知消息
skynet.PTYPE_QUEUE = 8       -- 队列消息
skynet.PTYPE_DEBUG = 9       -- 调试消息
skynet.PTYPE_TRACE = 12      -- 追踪消息
```

### 1.2 注册自定义协议
```lua
-- 注册自定义协议
skynet.register_protocol {
    name = "myproto",  -- 协议名称
    id = 20,           -- 协议 ID（范围：0-255）
    pack = function(...) 
        return string.pack("z", ...)  -- 序列化（将数据打包）
    end,
    unpack = function(msg, sz)
        return string.unpack("z", msg, sz)  -- 反序列化（将数据解包）
    end
}

-- 分发自定义协议消息
skynet.dispatch("myproto", function(session, source, ...)
    -- 处理自定义协议的业务逻辑
end)
```

## 2. 通信模式

### 2.1 请求-响应模式
这是同步通信中最常用的模式：

```lua
-- 服务 A：发送请求
local function get_user_data(user_id)
    -- 查询 USER_SERVICE 服务的地址
    local user_service = skynet.query("USER_SERVICE")
    -- 调用 USER_SERVICE 服务的 "get_user" 接口，获取用户数据
    local ok, user_data = skynet.call(user_service, "lua", "get_user", user_id)
    if not ok then
        -- 打印错误日志
        skynet.error("Failed to get user:", user_data)
        return nil
    end
    return user_data
end

-- 服务 B：处理请求
skynet.dispatch("lua", function(session, source, cmd, ...)
    -- 根据命令（cmd）区分不同请求
    if cmd == "get_user" then
        local user_id = ...  -- 获取请求参数（用户 ID）
        -- 从数据库查询用户数据
        local user_data = database.get_user(user_id)
        -- 将结果打包并返回给请求方
        skynet.ret(skynet.pack(true, user_data))
    end
end)
```

### 2.2 异步"发送即忘"模式
适用于无需立即获取响应的操作：

```lua
-- 发送消息后无需等待响应
skynet.send(logger_service, "lua", "log", "User login", user_id)

-- 异步处理消息
skynet.dispatch("lua", function(session, source, cmd, ...)
    if cmd == "log" then
        local event, user_id = ...
        -- 处理日志（无需返回响应）
        write_to_log(event, user_id, skynet.time())
        -- 无需调用 skynet.ret()（无响应需返回）
    end
end)
```

### 2.3 发布/订阅模式（Pub/Sub Pattern）
适用于事件广播场景：

```lua
-- 发布者服务（Publisher Service）
local subscribers = {}  -- 存储订阅关系：topic -> {subscriber1: true, subscriber2: true, ...}

skynet.dispatch("lua", function(session, source, cmd, ...)
    -- 订阅逻辑：客户端订阅指定主题
    if cmd == "subscribe" then
        local topic = ...  -- 获取订阅的主题
        -- 初始化该主题的订阅者列表（若不存在）
        subscribers[topic] = subscribers[topic] or {}
        -- 将当前请求方（source）加入订阅者列表
        subscribers[topic][source] = true
        -- 返回空响应（确认订阅成功）
        skynet.ret()
    
    -- 发布逻辑：向订阅者广播主题消息
    elseif cmd == "publish" then
        local topic, message = ...  -- 获取主题和消息内容
        -- 若该主题存在订阅者，则遍历发送消息
        if subscribers[topic] then
            for subscriber, _ in pairs(subscribers[topic]) do
                -- 向每个订阅者发送 "notify" 通知
                skynet.send(subscriber, "lua", "notify", topic, message)
            end
        end
        -- 返回空响应（确认发布完成）
        skynet.ret()
    end
end)
```

## 3. 高级消息处理

### 3.1 多步骤请求
处理需要多步操作的复杂业务逻辑：

```lua
-- 复杂订单处理逻辑
skynet.dispatch("lua", function(session, source, cmd, ...)
    if cmd == "process_order" then
        local order_id, user_id, items = ...  -- 获取订单 ID、用户 ID、商品列表
        
        -- 步骤 1：验证库存
        local inventory_service = skynet.query("INVENTORY")  -- 查询库存服务
        local ok, available = skynet.call(inventory_service, "lua", 
                                          "check_inventory", items)
        -- 若库存不足，返回失败响应
        if not ok or not available then
            skynet.ret(skynet.pack(false, "Items not available"))
            return
        end
        
        -- 步骤 2：处理支付
        local payment_service = skynet.query("PAYMENT")  -- 查询支付服务
        local ok, transaction_id = skynet.call(payment_service, "lua", 
                                               "process_payment", user_id, 
                                               calculate_total(items))  -- calculate_total：计算商品总价
        -- 若支付失败，返回失败响应
        if not ok then
            skynet.ret(skynet.pack(false, "Payment failed"))
            return
        end
        
        -- 步骤 3：更新库存（扣减已售商品）
        skynet.call(inventory_service, "lua", "update_inventory", items)
        
        -- 步骤 4：创建订单记录
        local order_service = skynet.query("ORDER")  -- 查询订单服务
        skynet.call(order_service, "lua", "create_order", 
                   order_id, user_id, items, transaction_id)
        
        -- 步骤 5：返回成功响应（携带交易 ID）
        skynet.ret(skynet.pack(true, transaction_id))
    end
end)
```

### 3.2 消息转发
高效转发消息，避免序列化/反序列化开销：

```lua
-- 用于消息转发的网关服务（Gateway Service）
skynet.dispatch("lua", function(session, source, cmd, ...)
    if cmd == "forward" then
        local target_service, msg, sz = ...  -- 获取目标服务地址、原始消息及长度
        -- 直接转发消息（无需解包/重新打包）
        skynet.redirect(target_service, source, "lua", session, msg, sz)
        -- 无需调用 skynet.ret() —— redirect 会自动处理响应回传
    end
end)
```

### 3.3 消息聚合
合并多个服务的响应结果：

```lua
-- 聚合器服务（Aggregator Service）
local function aggregate_data(sources, query)
    local responses = {}  -- 存储各服务的响应结果
    local pending = #sources  -- 待响应的服务数量
    local response_session = coroutine.running()  -- 获取当前协程
    
    -- 遍历所有待查询的服务
    for _, source in ipairs(sources) do
        -- 启动新协程发送查询请求
        skynet.fork(function()
            -- 调用目标服务的 "query" 接口
            local response = skynet.call(source, "lua", "query", query)
            -- 存储响应结果（按服务地址索引）
            responses[source] = response
            -- 待响应数量减 1
            pending = pending - 1
            -- 若所有服务均已响应，唤醒主协程
            if pending == 0 then
                skynet.wakeup(response_session)
            end
        end)
    end
    
    -- 等待所有响应完成
    skynet.wait(response_session)
    -- 返回聚合后的结果
    return responses
end
```

## 4. 会话管理

### 4.1 会话追踪
```lua
-- 支持会话感知的服务
local active_sessions = {}  -- 存储活跃会话：operation_id -> 会话详情

skynet.dispatch("lua", function(session, source, cmd, ...)
    -- 启动操作：创建新会话
    if cmd == "start_operation" then
        local operation_id = generate_id()  -- 生成唯一操作 ID（需自行实现 generate_id）
        -- 记录会话初始状态
        active_sessions[operation_id] = {
            status = "running",       -- 会话状态：running/completed/failed
            start_time = skynet.time(),  -- 会话启动时间
            client = source           -- 发起请求的客户端地址
        }
        
        -- 启动后台协程执行耗时操作
        skynet.fork(function()
            local result = perform_long_operation()  -- 执行耗时业务（需自行实现）
            -- 更新会话结果和状态
            active_sessions[operation_id].result = result
            active_sessions[operation_id].status = "completed"
            
            -- 通知客户端操作完成
            skynet.send(source, "lua", "operation_complete", 
                       operation_id, result)
        end)
        
        -- 返回操作 ID（供客户端查询状态）
        skynet.ret(skynet.pack(true, operation_id))
    
    -- 查询操作状态
    elseif cmd == "get_status" then
        local operation_id = ...  -- 获取待查询的操作 ID
        local session_data = active_sessions[operation_id]
        if session_data then
            -- 返回会话状态和结果（若已完成）
            skynet.ret(skynet.pack(true, session_data.status, session_data.result))
        else
            -- 操作 ID 不存在，返回错误
            skynet.ret(skynet.pack(false, "Operation not found"))
        end
    end
end)
```

### 4.2 超时处理
```lua
-- 带超时机制的请求调用
local function call_with_timeout(service, timeout, ...)
    local co = coroutine.running()  -- 获取当前协程
    local response  -- 存储服务响应结果
    
    -- 启动超时定时器（timeout 单位：秒，skynet.timeout 单位：厘秒）
    local timeout_session = skynet.timeout(timeout * 100, function()
        -- 若超时前未收到响应，唤醒协程（触发超时逻辑）
        if not response then
            skynet.wakeup(co)
        end
    end)
    
    -- 启动新协程发送请求（避免阻塞主协程）
    skynet.fork(function()
        -- 调用目标服务并存储响应（包装为 table，支持多返回值）
        response = {skynet.call(service, ...)}
        -- 唤醒主协程（处理响应）
        skynet.wakeup(co)
    end)
    
    -- 等待响应或超时
    skynet.wait(co)
    
    if response then
        -- 若收到响应，关闭超时定时器
        skynet.kill(timeout_session)
        -- 解包并返回响应结果
        return unpack(response)
    else
        -- 超时未收到响应，返回错误
        return false, "Timeout"
    end
end
```

## 5. 性能优化

### 5.1 消息批处理
```lua
-- 批处理处理器
local batch_queue = {}  -- 存储待批处理的请求队列
local batch_size = 100  -- 批处理阈值（队列满 100 条则触发处理）
local batch_timer      -- 批处理定时器（避免队列长期不满导致延迟）

-- 处理批处理队列中的请求
local function process_batch()
    -- 若队列为空，直接返回
    if #batch_queue == 0 then return end
    
    -- 取出当前队列（避免并发修改问题）
    local current_batch = batch_queue
    batch_queue = {}
    
    -- 批量处理所有请求
    local results = {}
    for i, item in ipairs(current_batch) do
        results[i] = process_item(item.data)  -- 处理单个请求（需自行实现 process_item）
    end
    
    -- 向每个请求方返回结果
    for i, item in ipairs(current_batch) do
        skynet.redirect(item.client, item.source, "lua", 
                       item.session, skynet.pack(results[i]))
    end
end

skynet.dispatch("lua", function(session, source, cmd, ...)
    if cmd == "process" then
        -- 将请求加入批处理队列
        table.insert(batch_queue, {
            data = ...,          -- 请求数据
            client = skynet.self(),  -- 当前服务地址（响应回传的目标）
            source = source,     -- 请求发起方地址
            session = session    -- 会话 ID（匹配请求与响应）
        })
        
        -- 条件 1：队列长度达到阈值，立即处理
        if #batch_queue >= batch_size then
            process_batch()
        -- 条件 2：队列未达阈值，但无定时器，启动定时器（延迟处理）
        elseif not batch_timer then
            batch_timer = skynet.timeout(100, function()  -- 100 厘秒 = 1 秒
                process_batch()
                batch_timer = nil  -- 重置定时器
            end)
        end
        
        -- 无需调用 skynet.ret() —— 批处理完成后通过 redirect 返回响应
    end
end)
```

### 5.2 连接池
```lua
-- 服务连接池（复用连接，减少创建/销毁开销）
local connection_pool = {}  -- 存储连接：connection -> 占用状态（busy: boolean）
local max_connections = 10  -- 连接池最大容量

-- 从连接池获取空闲连接
local function get_connection()
    -- 优先复用空闲连接
    for conn, busy in pairs(connection_pool) do
        if not busy then
            connection_pool[conn] = true  -- 标记为占用
            return conn
        end
    end
    
    -- 若连接池未满，创建新连接
    if #connection_pool < max_connections then
        local new_conn = create_new_connection()  -- 创建新连接（需自行实现）
        connection_pool[new_conn] = true  -- 标记为占用
        return new_conn
    end
    
    -- 连接池已满且无空闲连接，返回 nil
    return nil
end

-- 释放连接（归还到连接池，标记为空闲）
local function release_connection(conn)
    connection_pool[conn] = false
end
```

## 6. 错误处理与恢复

### 6.1 熔断器模式（Circuit Breaker Pattern）
用于保护不可靠服务的调用，避免级联故障：

```lua
-- 针对不可靠服务的熔断器
local circuit_breakers = {}  -- 存储熔断器：service_name -> 熔断器状态

local function call_with_circuit(service_name, ...)
    -- 获取或初始化熔断器（默认状态：closed 闭合）
    local cb = circuit_breakers[service_name] or {
        state = "closed",     -- 状态：closed（闭合）/ open（断开）/ half-open（半开）
        failures = 0,         -- 连续失败次数
        last_failure = 0,     -- 上次失败时间（skynet.time() 时间戳）
        threshold = 5,        -- 失败阈值（连续失败 5 次触发熔断）
        timeout = 60          -- 熔断恢复时间（60 秒后进入半开状态）
    }
    
    -- 状态 1：熔断器断开（open）
    if cb.state == "open" then
        -- 检查是否超过恢复时间：超过则进入半开状态，允许试探调用
        if skynet.time() - cb.last_failure > cb.timeout then
            cb.state = "half-open"
        else
            -- 未超过恢复时间，直接返回熔断错误
            return false, "Circuit breaker open"
        end
    end
    
    -- 调用目标服务（使用 pcall 捕获异常）
    local service = skynet.query(service_name)  -- 查询服务地址
    local ok, result = pcall(skynet.call, service, ...)
    
    if ok then
        -- 调用成功：重置失败次数，熔断器恢复为闭合状态
        cb.failures = 0
        cb.state = "closed"
        return result
    else
        -- 调用失败：失败次数加 1，更新上次失败时间
        cb.failures = cb.failures + 1
        cb.last_failure = skynet.time()
        
        -- 若失败次数达到阈值，熔断器进入断开状态
        if cb.failures >= cb.threshold then
            cb.state = "open"
        end
        
        -- 返回失败信息
        return false, "Service call failed: " .. result
    end
end
```

### 6.2 重试机制
```lua
-- 带指数退避的重试逻辑（失败后等待时间翻倍）
local function retry_call(service, max_retries, ...)
    local delay = 100  -- 初始延迟时间（单位：厘秒，100 厘秒 = 1 秒）
    
    -- 循环重试（最多重试 max_retries 次）
    for attempt = 1, max_retries do
        -- 使用 pcall 捕获调用异常
        local ok, result = pcall(skynet.call, service, ...)
        if ok then
            -- 调用成功，直接返回结果
            return result
        end
        
        -- 若未达到最大重试次数，等待后继续重试
        if attempt < max_retries then
            skynet.sleep(delay)  -- 休眠指定时间
            delay = delay * 2    -- 指数退避：延迟时间翻倍
        end
    end
    
    -- 达到最大重试次数仍失败，返回错误
    return false, "Max retries exceeded"
end
```

## 7. 示例：聊天系统消息流转
下面实现一个完整的聊天系统，整合多种消息模式：

```lua
-- chat_message_hub.lua（聊天消息中枢服务）
local skynet = require "skynet"

local rooms = {}          -- 房间列表：room_id -> {users: {}, history: {}}
local user_sessions = {}  -- 用户会话映射：user_id -> session（用户服务地址）

-- 辅助函数：向房间内所有用户广播消息（可排除发送者）
local function broadcast_to_room(room_id, message, exclude_sender)
    local room = rooms[room_id]
    if not room then return end  -- 房间不存在则直接返回
    
    -- 遍历房间内所有用户，发送消息
    for user_id, session in pairs(room.users) do
        -- 排除指定发送者（避免自己收到自己的消息）
        if user_id ~= exclude_sender and user_sessions[user_id] then
            skynet.send(user_sessions[user_id], "chat", "message", message)
        end
    end
end

-- 注册自定义 "chat" 协议（用于聊天消息传输）
skynet.register_protocol {
    name = "chat",
    id = 25,
    pack = skynet.pack,    -- 使用 Skynet 内置打包函数
    unpack = skynet.unpack  -- 使用 Skynet 内置解包函数
}

skynet.start(function()
    -- 处理 Lua 命令（管理员功能：创建房间、加入房间等）
    skynet.dispatch("lua", function(session, source, cmd, ...)
        -- 1. 创建房间
        if cmd == "create_room" then
            local room_id = ...
            -- 检查房间是否已存在
            if not rooms[room_id] then
                -- 初始化房间：包含用户列表和消息历史
                rooms[room_id] = { users = {}, history = {} }
                skynet.ret(skynet.pack(true))  -- 返回创建成功
            else
                skynet.ret(skynet.pack(false, "Room exists"))  -- 返回错误
            end
        
        -- 2. 加入房间
        elseif cmd == "join_room" then
            local user_id, room_id, user_session = ...
            -- 检查房间是否存在
            if not rooms[room_id] then
                skynet.ret(skynet.pack(false, "Room not found"))
                return
            end
            
            -- 将用户加入房间，并记录用户会话
            rooms[room_id].users[user_id] = user_session
            user_sessions[user_id] = user_session
            
            -- 向房间内其他用户广播"用户加入"消息
            broadcast_to_room(room_id, {
                type = "join",    -- 消息类型：用户加入
                user = user_id,   -- 加入的用户 ID
                time = skynet.time()  -- 消息时间戳
            })
            
            skynet.ret(skynet.pack(true))  -- 返回加入成功
        end
    end)
    
    -- 处理 "chat" 协议消息（聊天消息传输）
    skynet.dispatch("chat", function(session, source, cmd, ...)
        if cmd == "message" then
            local user_id, room_id, text = ...  -- 获取发送者 ID、房间 ID、消息内容
            
            -- 构造聊天消息结构
            local message = {
                type = "chat",    -- 消息类型：聊天消息
                user = user_id,   -- 发送者 ID
                text = text,      -- 消息内容
                time = skynet.time()  -- 消息时间戳
            }
            
            -- 向房间广播消息（排除发送者）
            broadcast_to_room(room_id, message, user_id)
            
            -- 将消息存入房间历史（限制最多 1000 条，避免内存溢出）
            if rooms[room_id] then
                table.insert(rooms[room_id].history, message)
                -- 若历史消息超过 1000 条，删除最早的一条
                if #rooms[room_id].history > 1000 then
                    table.remove(rooms[room_id].history, 1)
                end
            end
        end
    end)
    
    -- 注册服务名称，供其他服务查询
    skynet.register("CHAT_HUB")
end)
```

## 8. 练习：请求聚合器服务
请创建一个满足以下需求的服务：
1. 接收来自多个客户端的请求
2. 对相似请求进行批处理
3. 统一处理批处理请求
4. 向每个客户端返回单独的响应

**具体要求**：
- 满足以下任一条件即触发批处理：① 累计 10 个请求；② 距离上次批处理已过去 100 毫秒
- 支持处理不同类型的请求（需区分请求类型，同类请求才会被批处理）
- 对同一客户端的请求，需保持响应顺序与请求顺序一致
- 实现超时处理（若批处理超时，向客户端返回超时错误）

## 总结
在本教程中，你学习了以下内容：
- 高级消息传递模式（请求-响应、发布/订阅、异步发送等）
- 会话管理技术（会话追踪、超时处理）
- 性能优化策略（消息批处理、连接池）
- 错误处理与恢复模式（熔断器、指数退避重试）
- 消息聚合与批处理的实现方式

## 后续步骤
请继续学习 [教程 5：Lua 服务进阶开发](./tutorial5_lua_services.md)，了解 Lua 服务的高级开发技术与最佳实践。
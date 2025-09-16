# 创建你的第一个 Skynet 服务

## 你将学到什么
- 如何创建完整的 Skynet 服务
- 服务初始化和设置模式
- 处理不同类型的消息
- 服务注册和发现机制
- 错误处理和调试技巧

## 先决条件
- 完成教程 2：理解 Skynet 架构
- 基础 Lua 编程知识
- 理解 Skynet 的 Actor 模型

## 预计时间
60-90 分钟

## 最终成果
一个功能完整的聊天服务，能够处理多个客户端和消息广播

## 学习目标
完成本教程后，你将能够：
1. 独立创建和配置 Skynet 服务
2. 实现服务的消息处理机制
3. 管理服务的内部状态
4. 构建多服务协作的应用程序
5. 掌握服务的调试和错误处理方法

---

## 1. 服务结构基础

Skynet 服务遵循一个标准结构，理解这个结构对于创建稳定的服务至关重要。

### 1.1 基本服务模板

```lua
local skynet = require "skynet"

-- 服务状态（仅在此服务内可见）
local service_state = {
    users = {},        -- 用户数据
    rooms = {},        -- 房间数据
    config = {}       -- 配置信息
}

-- 初始化函数
local function initialize_service()
    -- 初始化服务状态
    service_state.config.timeout = 300
    service_state.config.max_users = 1000
    skynet.error("Service initialized")
end

-- 注册消息处理器
local function register_handlers()
    -- 这里可以定义消息处理器的注册逻辑
end

-- 启动后台任务
local function start_tasks()
    -- 启动定时器或其他后台任务
end

skynet.start(function()
    -- 1. 初始化服务状态
    initialize_service()
    
    -- 2. 注册消息处理器
    register_handlers()
    
    -- 3. 注册服务名称（可选，但推荐）
    skynet.register("MYSERVICE")
    
    -- 4. 启动后台任务（如果需要）
    start_tasks()
    
    -- 服务现在将开始处理消息
    -- skynet.exit() 会在服务结束时自动调用
end)
```

### 1.2 关键概念解释

#### 服务生命周期
1. **创建阶段**: `skynet.start()` 启动服务
2. **初始化阶段**: 设置服务状态和配置
3. **注册阶段**: 注册消息处理器和服务名称
4. **运行阶段**: 处理接收到的消息
5. **退出阶段**: 调用 `skynet.exit()` 清理资源

#### 消息处理机制
- **skynet.dispatch()**: 注册消息处理器
- **skynet.call()**: 同步调用其他服务
- **skynet.send()**: 异步发送消息
- **skynet.ret()**: 返回消息处理结果

#### 状态管理
- 每个服务都有独立的 Lua 状态
- 服务间通过消息传递通信，不共享内存
- 使用局部变量存储服务私有状态

## 2. 创建一个简单的计数器服务

让我们创建一个实用的计数器服务，支持多种操作。这个例子将展示：
- 如何管理服务的内部状态
- 如何处理不同类型的命令
- 如何实现基本的数据持久化

### 2.1 基本实现

创建 `examples/counter_service.lua`：

```lua
local skynet = require "skynet"
require "skynet.manager"  -- 导入 skynet.register 函数

-- 服务状态：存储所有计数器
local counters = {}

-- 初始化计数器
local function init_counter(name, initial_value)
    initial_value = initial_value or 0
    counters[name] = initial_value
    skynet.error(string.format("Counter '%s' initialized with value %d", name, initial_value))
    return true
end

-- 增加计数器值
local function increment_counter(name, delta)
    delta = delta or 1
    if not counters[name] then
        return false, "Counter not found"
    end
    counters[name] = counters[name] + delta
    skynet.error(string.format("Counter '%s' incremented by %d, new value: %d", 
                               name, delta, counters[name]))
    return true, counters[name]
end

-- 获取计数器值
local function get_counter(name)
    return counters[name]
end

-- 重置计数器
local function reset_counter(name)
    if counters[name] then
        counters[name] = 0
        skynet.error(string.format("Counter '%s' reset to 0", name))
        return true
    end
    return false, "Counter not found"
end

-- 列出所有计数器
local function list_counters()
    local result = {}
    for name, value in pairs(counters) do
        table.insert(result, {name = name, value = value})
    end
    return result
end

-- 删除计数器
local function delete_counter(name)
    if counters[name] then
        counters[name] = nil
        skynet.error(string.format("Counter '%s' deleted", name))
        return true
    end
    return false, "Counter not found"
end

-- 获取统计信息
local function get_stats()
    local total = 0
    local count = 0
    for _, value in pairs(counters) do
        total = total + value
        count = count + 1
    end
    return {
        total_counters = count,
        total_value = total,
        average_value = count > 0 and total / count or 0
    }
end

skynet.start(function()
    -- 注册 Lua 消息处理器
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local ok, result
        
        -- 根据命令类型分发处理
        if cmd == "init" then
            local name, initial = ...
            ok, result = init_counter(name, initial)
        elseif cmd == "increment" then
            local name, delta = ...
            ok, result = increment_counter(name, delta)
        elseif cmd == "get" then
            local name = ...
            result = get_counter(name)
            ok = result ~= nil
        elseif cmd == "reset" then
            local name = ...
            ok, result = reset_counter(name)
        elseif cmd == "delete" then
            local name = ...
            ok, result = delete_counter(name)
        elseif cmd == "list" then
            result = list_counters()
            ok = true
        elseif cmd == "stats" then
            result = get_stats()
            ok = true
        else
            ok, result = false, "Unknown command: " .. cmd
        end
        
        -- 返回处理结果
        skynet.ret(skynet.pack(ok, result))
    end)
    
    -- 注册服务名称
    skynet.register("COUNTER_SERVICE")
    
    -- 输出启动信息
    skynet.error("Counter service started successfully")
    
    -- 服务退出
    skynet.exit()
end)
```

### 2.2 代码解释

#### 核心组件说明
1. **状态管理**: 使用 `counters` 表存储所有计数器数据
2. **消息分发**: 通过 `skynet.dispatch()` 注册消息处理器
3. **命令处理**: 使用 if-elseif 链根据命令类型调用相应函数
4. **服务注册**: 使用 `skynet.register()` 注册服务名称

#### 关键函数说明
- `init_counter()`: 创建新计数器，可设置初始值
- `increment_counter()`: 增加计数器值，支持自定义增量
- `get_counter()`: 获取计数器当前值
- `reset_counter()`: 重置计数器为 0
- `delete_counter()`: 删除计数器
- `list_counters()`: 列出所有计数器
- `get_stats()`: 获取统计信息

#### 错误处理
- 检查计数器是否存在
- 返回错误信息给调用者
- 使用日志记录操作

### 2.3 测试服务

创建测试脚本 `examples/test_counter.lua`：

```lua
local skynet = require "skynet"

-- 辅助函数：打印结果
local function print_result(operation, ok, result)
    if ok then
        print(string.format("[SUCCESS] %s: %s", operation, tostring(result)))
    else
        print(string.format("[FAILED] %s: %s", operation, tostring(result)))
    end
end

skynet.start(function()
    -- 获取计数器服务地址
    local counter_service = skynet.query("COUNTER_SERVICE")
    if not counter_service then
        print("Error: Counter service not found")
        skynet.exit()
    end
    
    print("=== 开始测试计数器服务 ===")
    
    -- 测试 1: 初始化计数器
    print("\n1. 测试初始化计数器:")
    local ok = skynet.call(counter_service, "lua", "init", "user1", 100)
    print_result("初始化 user1 为 100", ok, "user1")
    
    ok = skynet.call(counter_service, "lua", "init", "user2")
    print_result("初始化 user2 为默认值 0", ok, "user2")
    
    -- 测试 2: 增加计数器值
    print("\n2. 测试增加计数器值:")
    local ok, value = skynet.call(counter_service, "lua", "increment", "user1", 5)
    print_result("user1 增加 5", ok, value)
    
    ok, value = skynet.call(counter_service, "lua", "increment", "user2", 10)
    print_result("user2 增加 10", ok, value)
    
    -- 测试 3: 获取计数器值
    print("\n3. 测试获取计数器值:")
    value = skynet.call(counter_service, "lua", "get", "user1")
    print_result("获取 user1 的值", true, value)
    
    value = skynet.call(counter_service, "lua", "get", "user2")
    print_result("获取 user2 的值", true, value)
    
    -- 测试 4: 列出所有计数器
    print("\n4. 测试列出所有计数器:")
    local counters = skynet.call(counter_service, "lua", "list")
    print("所有计数器:")
    for _, counter in ipairs(counters) do
        print(string.format("  %s: %d", counter.name, counter.value))
    end
    
    -- 测试 5: 获取统计信息
    print("\n5. 测试获取统计信息:")
    local stats = skynet.call(counter_service, "lua", "stats")
    print("统计信息:")
    print(string.format("  计数器总数: %d", stats.total_counters))
    print(string.format("  总数值: %d", stats.total_value))
    print(string.format("  平均值: %.2f", stats.average_value))
    
    -- 测试 6: 重置计数器
    print("\n6. 测试重置计数器:")
    ok = skynet.call(counter_service, "lua", "reset", "user1")
    print_result("重置 user1", ok, "user1")
    
    value = skynet.call(counter_service, "lua", "get", "user1")
    print_result("重置后 user1 的值", true, value)
    
    -- 测试 7: 删除计数器
    print("\n7. 测试删除计数器:")
    ok = skynet.call(counter_service, "lua", "delete", "user2")
    print_result("删除 user2", ok, "user2")
    
    value = skynet.call(counter_service, "lua", "get", "user2")
    print_result("删除后获取 user2", value ~= nil, value or "nil")
    
    -- 测试 8: 错误处理
    print("\n8. 测试错误处理:")
    ok, result = skynet.call(counter_service, "lua", "get", "nonexistent")
    print_result("获取不存在的计数器", ok, result)
    
    ok, result = skynet.call(counter_service, "lua", "increment", "nonexistent", 5)
    print_result("增加不存在的计数器", ok, result)
    
    print("\n=== 测试完成 ===")
    skynet.exit()
end)
```

### 2.4 运行测试

#### 启动服务
1. 编译 Skynet：
```bash
make linux
```

2. 启动服务：
```bash
./skynet examples/config
```

3. 在另一个终端运行测试：
```bash
./3rd/lua/lua examples/test_counter.lua
```

#### 预期输出
测试脚本将显示详细的操作结果，包括成功和失败的情况。你会看到：
- 计数器的初始化、增加、获取、重置和删除操作
- 统计信息的计算
- 错误处理的情况
- 每个操作的执行结果

## 3. 创建聊天服务

现在让我们创建一个更复杂的聊天服务，支持房间和用户管理。这个例子将展示：
- 多服务协作的架构设计
- 复杂状态管理
- 实时消息广播
- 用户会话管理

### 3.1 聊天服务实现

创建 `examples/chat_service.lua`：

```lua
local skynet = require "skynet"

-- Service state
local users = {}          -- user_id -> {name, room, agent}
local rooms = {}          -- room_name -> {users, history}
local user_agents = {}    -- user_id -> agent_address

-- Helper functions
local function broadcast_to_room(room_name, message, exclude_user)
    local room = rooms[room_name]
    if not room then return end
    
    for user_id, _ in pairs(room.users) do
        if user_id ~= exclude_user and user_agents[user_id] then
            skynet.send(user_agents[user_id], "lua", "broadcast", message)
        end
    end
    
    -- Add to history
    table.insert(room.history, message)
    if #room.history > 100 then  -- Keep last 100 messages
        table.remove(room.history, 1)
    end
end

local function create_room(room_name)
    if rooms[room_name] then
        return false, "Room already exists"
    end
    rooms[room_name] = {
        users = {},
        history = {}
    }
    return true
end

local function join_room(user_id, room_name)
    local room = rooms[room_name]
    if not room then
        return false, "Room not found"
    end
    
    -- Leave current room if any
    if users[user_id] and users[user_id].room then
        leave_room(user_id)
    end
    
    -- Join new room
    room.users[user_id] = true
    if not users[user_id] then
        users[user_id] = {}
    end
    users[user_id].room = room_name
    
    -- Broadcast join message
    local message = {
        type = "join",
        user = users[user_id].name or user_id,
        room = room_name
    }
    broadcast_to_room(room_name, message)
    
    -- Send room history to user
    if user_agents[user_id] then
        for _, hist_msg in ipairs(room.history) do
            skynet.send(user_agents[user_id], "lua", "broadcast", hist_msg)
        end
    end
    
    return true
end

local function leave_room(user_id)
    if not users[user_id] or not users[user_id].room then
        return
    end
    
    local room_name = users[user_id].room
    local room = rooms[room_name]
    if room then
        room.users[user_id] = nil
        
        -- Broadcast leave message
        local message = {
            type = "leave",
            user = users[user_id].name or user_id,
            room = room_name
        }
        broadcast_to_room(room_name, message)
        
        -- Clean up empty rooms
        if next(room.users) == nil then
            rooms[room_name] = nil
        end
    end
    
    users[user_id].room = nil
end

local function send_message(user_id, text)
    if not users[user_id] or not users[user_id].room then
        return false, "User not in room"
    end
    
    local message = {
        type = "message",
        user = users[user_id].name or user_id,
        text = text,
        room = users[user_id].room,
        time = skynet.time()
    }
    
    broadcast_to_room(users[user_id].room, message, user_id)
    return true
end

skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local ok, result
        
        if cmd == "register_user" then
            local user_id, user_name, agent = ...
            users[user_id] = users[user_id] or {}
            users[user_id].name = user_name
            user_agents[user_id] = agent
            ok, result = true
            
        elseif cmd == "create_room" then
            local room_name = ...
            ok, result = create_room(room_name)
            
        elseif cmd == "join_room" then
            local user_id, room_name = ...
            ok, result = join_room(user_id, room_name)
            
        elseif cmd == "leave_room" then
            local user_id = ...
            leave_room(user_id)
            ok, result = true
            
        elseif cmd == "send_message" then
            local user_id, text = ...
            ok, result = send_message(user_id, text)
            
        elseif cmd == "list_rooms" then
            local room_list = {}
            for room_name, room in pairs(rooms) do
                table.insert(room_list, {
                    name = room_name,
                    users = room.users
                })
            end
            ok, result = true, room_list
            
        elseif cmd == "get_room_users" then
            local room_name = ...
            local room = rooms[room_name]
            if room then
                local user_list = {}
                for user_id, _ in pairs(room.users) do
                    table.insert(user_list, {
                        id = user_id,
                        name = users[user_id] and users[user_id].name or user_id
                    })
                end
                ok, result = true, user_list
            else
                ok, result = false, "Room not found"
            end
            
        else
            ok, result = false, "Unknown command"
        end
        
        skynet.ret(skynet.pack(ok, result))
    end)
    
    skynet.register("CHAT_SERVICE")
    skynet.exit()
end)
```

### 3.2 Chat Agent Service

Create `examples/chat_agent.lua`:

```lua
local skynet = require "skynet"

local function handle_client_message(agent, user_id, msg)
    local chat_service = skynet.query("CHAT_SERVICE")
    
    if msg.type == "join" then
        local ok, err = skynet.call(chat_service, "lua", "join_room", user_id, msg.room)
        if not ok then
            skynet.send(agent, "lua", "send_error", err)
        end
        
    elseif msg.type == "leave" then
        skynet.call(chat_service, "lua", "leave_room", user_id)
        
    elseif msg.type == "message" then
        local ok, err = skynet.call(chat_service, "lua", "send_message", user_id, msg.text)
        if not ok then
            skynet.send(agent, "lua", "send_error", err)
        end
        
    elseif msg.type == "create_room" then
        local ok, err = skynet.call(chat_service, "lua", "create_room", msg.room)
        if not ok then
            skynet.send(agent, "lua", "send_error", err)
        end
    end
end

skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        if cmd == "start" then
            local user_id, user_name, client_gate = ...
            
            -- Register with chat service
            local chat_service = skynet.query("CHAT_SERVICE")
            skynet.call(chat_service, "lua", "register_user", user_id, user_name, skynet.self())
            
            -- Send welcome message
            skynet.send(client_gate, "lua", "send_data", {
                type = "system",
                text = "Welcome to chat, " .. user_name .. "!"
            })
            
            skynet.ret(skynet.pack(skynet.self()))
            
        elseif cmd == "client_message" then
            local user_id, msg = ...
            handle_client_message(skynet.self(), user_id, msg)
            
        elseif cmd == "broadcast" then
            local message = ...
            -- Forward to client
            skynet.send(source, "lua", "send_data", message)
            
        elseif cmd == "send_error" then
            local error_msg = ...
            skynet.send(source, "lua", "send_data", {
                type = "error",
                text = error_msg
            })
            
        else
            skynet.ret(skynet.pack(false, "Unknown command"))
        end
    end)
    
    skynet.exit()
end)
```

## 4. Service Initialization Patterns

### 4.1 Configuration-based Initialization

```lua
local config = {
    max_users = 1000,
    max_rooms = 100,
    message_history_limit = 1000,
    timeout = 300  -- seconds
}

local function load_config()
    -- Load from environment or config file
    local config_file = skynet.getenv("SERVICE_CONFIG")
    if config_file then
        local f = io.open(config_file, "r")
        if f then
            local content = f:read("*all")
            f:close()
            local user_config = load("return " .. content)()
            for k, v in pairs(user_config) do
                config[k] = v
            end
        end
    end
end
```

### 4.2 Resource Initialization

```lua
local function initialize_resources()
    -- Initialize database connections
    local db = require "db"
    db_pool = db.create_pool(config.db_config)
    
    -- Initialize cache
    local cache = require "cache"
    cache_client = cache.connect(config.cache_config)
    
    -- Initialize timers
    skynet.timeout(1000, function()
        -- Periodic cleanup
        cleanup_inactive_users()
    end)
end
```

## 5. Error Handling Patterns

### 5.1 Command Validation

```lua
local function validate_command(cmd, args)
    local validators = {
        join_room = function(args)
            return args[1] and args[2], "Missing user_id or room_name"
        end,
        send_message = function(args)
            return args[1] and args[2] and args[2] ~= "", 
                   "Missing user_id or empty message"
        end
    }
    
    local validator = validators[cmd]
    if validator then
        return validator(args)
    end
    return true
end
```

### 5.2 Graceful Error Recovery

```lua
skynet.dispatch("lua", function(session, source, cmd, ...)
    local ok, err = pcall(function()
        local valid, validation_err = validate_command(cmd, {...})
        if not valid then
            return false, validation_err
        end
        
        return handle_command(cmd, ...)
    end)
    
    if not ok then
        skynet.error("Service error:", err)
        skynet.ret(skynet.pack(false, "Internal server error"))
    else
        skynet.ret(skynet.pack(err))
    end
end)
```

## 6. 练习：任务队列服务

在这个练习中，你将创建一个完整的任务队列服务，这是分布式系统中常用的组件。任务队列服务可以帮助你：
- 管理异步任务的执行
- 控制任务的优先级和执行顺序
- 监控任务状态和进度
- 处理任务失败和重试

### 6.1 需求分析

**核心功能**：
1. **任务提交**：接收新任务并分配优先级
2. **任务调度**：按优先级顺序执行任务
3. **任务取消**：支持取消正在等待或执行中的任务
4. **状态跟踪**：实时跟踪任务状态变化
5. **结果存储**：保存任务执行结果

**任务状态**：
- `pending`: 等待执行
- `processing`: 正在执行
- `completed`: 执行完成
- `failed`: 执行失败
- `cancelled`: 已取消

### 6.2 实现指导

#### 第一步：设计服务结构

```lua
local skynet = require "skynet"

-- 服务状态
local tasks = {}           -- 所有任务: task_id -> task_info
local pending_queue = {}   -- 待执行队列，按优先级排序
local processing = {}      -- 正在执行的任务
local workers = {}         -- 工作进程池
local task_counter = 0     -- 任务ID计数器

-- 任务优先级定义
local PRIORITY = {
    HIGH = 1,      -- 高优先级
    NORMAL = 5,    -- 普通优先级
    LOW = 10       -- 低优先级
}
```

#### 第二步：实现任务管理核心功能

**任务创建函数**：
```lua
local function create_task(task_type, data, priority, timeout)
    priority = priority or PRIORITY.NORMAL
    timeout = timeout or 300  -- 默认5分钟超时
    
    task_counter = task_counter + 1
    local task_id = "task_" .. task_counter
    
    local task = {
        id = task_id,
        type = task_type,
        data = data,
        priority = priority,
        status = "pending",
        create_time = skynet.time(),
        timeout = timeout,
        result = nil,
        error = nil,
        retry_count = 0,
        max_retries = 3
    }
    
    tasks[task_id] = task
    
    -- 添加到待执行队列
    table.insert(pending_queue, task)
    -- 按优先级排序
    table.sort(pending_queue, function(a, b) 
        return a.priority < b.priority 
    end)
    
    skynet.error(string.format("Task created: %s (priority: %d)", task_id, priority))
    return task_id
end
```

**任务调度函数**：
```lua
local function schedule_task()
    if #pending_queue == 0 then
        return false
    end
    
    -- 获取最高优先级的任务
    local task = table.remove(pending_queue, 1)
    task.status = "processing"
    task.start_time = skynet.time()
    processing[task.id] = task
    
    skynet.error(string.format("Task scheduled: %s", task.id))
    
    -- 启动任务执行协程
    skynet.fork(function()
        execute_task(task)
    end)
    
    return true
end
```

**任务执行函数**：
```lua
local function execute_task(task)
    local success, result
    
    -- 根据任务类型执行不同的处理逻辑
    if task.type == "http_request" then
        success, result = execute_http_request(task.data)
    elseif task.type == "database_operation" then
        success, result = execute_database_operation(task.data)
    elseif task.type == "file_processing" then
        success, result = execute_file_processing(task.data)
    else
        success, result = false, "Unknown task type: " .. task.type
    end
    
    -- 处理执行结果
    if success then
        task.status = "completed"
        task.result = result
        task.complete_time = skynet.time()
        skynet.error(string.format("Task completed: %s", task.id))
    else
        task.retry_count = task.retry_count + 1
        if task.retry_count < task.max_retries then
            -- 重试任务
            task.status = "pending"
            table.insert(pending_queue, task)
            skynet.error(string.format("Task failed, retrying: %s (attempt %d)", 
                                      task.id, task.retry_count))
        else
            -- 达到最大重试次数，标记为失败
            task.status = "failed"
            task.error = result
            task.complete_time = skynet.time()
            skynet.error(string.format("Task failed permanently: %s", task.id))
        end
    end
    
    -- 从执行队列中移除
    processing[task.id] = nil
    
    -- 调度下一个任务
    schedule_task()
end
```

#### 第三步：实现任务查询和管理功能

**任务状态查询**：
```lua
local function get_task_status(task_id)
    local task = tasks[task_id]
    if not task then
        return false, "Task not found"
    end
    
    return {
        id = task.id,
        type = task.type,
        status = task.status,
        priority = task.priority,
        create_time = task.create_time,
        start_time = task.start_time,
        complete_time = task.complete_time,
        retry_count = task.retry_count,
        result = task.result,
        error = task.error
    }
end
```

**任务取消**：
```lua
local function cancel_task(task_id)
    local task = tasks[task_id]
    if not task then
        return false, "Task not found"
    end
    
    if task.status == "completed" or task.status == "failed" then
        return false, "Task already finished"
    end
    
    if task.status == "processing" then
        -- 标记为取消，实际停止需要任务自身检查
        task.status = "cancelled"
        task.complete_time = skynet.time()
        processing[task_id] = nil
    else
        -- 从待执行队列中移除
        for i, t in ipairs(pending_queue) do
            if t.id == task_id then
                table.remove(pending_queue, i)
                break
            end
        end
        task.status = "cancelled"
        task.complete_time = skynet.time()
    end
    
    skynet.error(string.format("Task cancelled: %s", task_id))
    return true
end
```

#### 第四步：实现消息处理器

```lua
skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local ok, result
        
        if cmd == "create_task" then
            local task_type, data, priority, timeout = ...
            local task_id = create_task(task_type, data, priority, timeout)
            ok, result = true, task_id
            -- 如果有空闲工作进程，立即调度任务
            schedule_task()
            
        elseif cmd == "get_status" then
            local task_id = ...
            ok, result = get_task_status(task_id)
            
        elseif cmd == "cancel_task" then
            local task_id = ...
            ok, result = cancel_task(task_id)
            
        elseif cmd == "list_tasks" then
            local status_filter = ...
            local task_list = {}
            for _, task in pairs(tasks) do
                if not status_filter or task.status == status_filter then
                    table.insert(task_list, {
                        id = task.id,
                        type = task.type,
                        status = task.status,
                        priority = task.priority
                    })
                end
            end
            ok, result = true, task_list
            
        elseif cmd == "get_stats" then
            local stats = {
                total_tasks = task_counter,
                pending_count = #pending_queue,
                processing_count = 0,
                completed_count = 0,
                failed_count = 0,
                cancelled_count = 0
            }
            for _, task in pairs(tasks) do
                if task.status == "processing" then
                    stats.processing_count = stats.processing_count + 1
                elseif task.status == "completed" then
                    stats.completed_count = stats.completed_count + 1
                elseif task.status == "failed" then
                    stats.failed_count = stats.failed_count + 1
                elseif task.status == "cancelled" then
                    stats.cancelled_count = stats.cancelled_count + 1
                end
            end
            ok, result = true, stats
            
        else
            ok, result = false, "Unknown command: " .. cmd
        end
        
        skynet.ret(skynet.pack(ok, result))
    end)
    
    -- 启动定时器，检查超时任务
    skynet.timeout(1000, function()
        check_timeout_tasks()
    end)
    
    skynet.register("TASK_QUEUE_SERVICE")
    skynet.exit()
end)
```

### 6.3 测试用例

**基础功能测试**：
```lua
local skynet = require "skynet"

skynet.start(function()
    local task_service = skynet.query("TASK_QUEUE_SERVICE")
    
    -- 创建测试任务
    local task1 = skynet.call(task_service, "lua", "create_task", 
                             "http_request", 
                             {url = "http://example.com/api/data"}, 
                             1)  -- 高优先级
    
    local task2 = skynet.call(task_service, "lua", "create_task", 
                             "database_operation", 
                             {query = "SELECT * FROM users"}, 
                             5)  -- 普通优先级
    
    local task3 = skynet.call(task_service, "lua", "create_task", 
                             "file_processing", 
                             {file = "/tmp/data.txt", operation = "compress"}, 
                             10) -- 低优先级
    
    -- 查询任务状态
    local status = skynet.call(task_service, "lua", "get_status", task1)
    print("Task 1 status:", status.status)
    
    -- 列出所有任务
    local all_tasks = skynet.call(task_service, "lua", "list_tasks")
    print("Total tasks:", #all_tasks)
    
    -- 获取统计信息
    local stats = skynet.call(task_service, "lua", "get_stats")
    print("Pending tasks:", stats.pending_count)
    print("Processing tasks:", stats.processing_count)
    
    skynet.exit()
end)
```

### 6.4 扩展挑战

如果你完成了基础实现，可以尝试以下扩展功能：

1. **任务依赖**：实现任务间的依赖关系，只有前置任务完成后才能执行后续任务
2. **任务进度报告**：为长时间运行的任务添加进度报告功能
3. **任务超时处理**：实现更精确的任务超时检测和处理
4. **任务持久化**：将任务状态保存到数据库，实现服务重启后的任务恢复
5. **工作进程管理**：实现动态的工作进程池，根据任务负载自动调整工作进程数量
6. **任务分类和分组**：支持按类别分组管理任务，实现不同的处理策略

### 6.5 最佳实践建议

1. **错误处理**：始终实现完善的错误处理机制，包括任务重试和失败恢复
2. **资源管理**：监控任务执行过程中的资源使用，避免内存泄漏
3. **性能优化**：合理设置任务队列大小和工作进程数量，平衡性能和资源消耗
4. **日志记录**：记录详细的任务执行日志，便于问题排查和性能分析
5. **监控指标**：实现关键性能指标的收集和报告，如任务吞吐量、平均执行时间等

## 7. 调试技巧和最佳实践

### 7.1 服务调试命令

在开发过程中，添加调试命令可以帮助你监控服务状态和诊断问题。

```lua
-- 添加调试处理器
skynet.dispatch("debug", function(session, source, cmd, ...)
    if cmd == "status" then
        -- 获取服务状态信息
        local status = {
            service_name = "MY_SERVICE",
            uptime = skynet.time() - service_start_time,
            memory_usage = collectgarbage("count"),
            active_connections = #active_connections,
            processed_messages = message_count,
            last_error = last_error
        }
        skynet.ret(skynet.pack(status))
        
    elseif cmd == "dump" then
        -- 转储服务状态（谨慎使用，可能包含敏感信息）
        if not debug_mode then
            skynet.ret(skynet.pack(false, "Debug mode not enabled"))
            return
        end
        
        local dump_data = {
            users = users,
            rooms = rooms,
            config = config,
            metrics = metrics
        }
        skynet.ret(skynet.pack(dump_data))
        
    elseif cmd == "set_log_level" then
        -- 动态设置日志级别
        local level = ...
        if level == "debug" or level == "info" or level == "error" then
            config.log_level = level
            skynet.ret(skynet.pack(true, "Log level set to " .. level))
        else
            skynet.ret(skynet.pack(false, "Invalid log level"))
        end
        
    elseif cmd == "force_gc" then
        -- 强制垃圾回收
        local before = collectgarbage("count")
        collectgarbage("collect")
        local after = collectgarbage("count")
        skynet.ret(skynet.pack(true, 
            string.format("GC completed: %.2fMB -> %.2fMB", before, after)))
            
    else
        skynet.ret(skynet.pack(false, "Unknown debug command"))
    end
end)
```

### 7.2 日志记录系统

良好的日志记录对于调试和监控至关重要。

```lua
-- 日志级别定义
local LOG_LEVEL = {
    DEBUG = 1,
    INFO = 2,
    WARN = 3,
    ERROR = 4
}

-- 日志记录函数
local function log(level, fmt, ...)
    if level < config.log_level then
        return
    end
    
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local level_name = debug.getinfo(2, "n").name or "UNKNOWN"
    local message = string.format(fmt, ...)
    
    local log_entry = string.format("[%s] [%s] %s: %s", 
                                   timestamp, level_name, level, message)
    
    skynet.error(log_entry)
    
    -- 可选：写入日志文件
    if config.log_file then
        local file = io.open(config.log_file, "a")
        if file then
            file:write(log_entry .. "\n")
            file:close()
        end
    end
end

-- 便捷的日志函数
local function log_debug(fmt, ...)
    log(LOG_LEVEL.DEBUG, fmt, ...)
end

local function log_info(fmt, ...)
    log(LOG_LEVEL.INFO, fmt, ...)
end

local function log_warn(fmt, ...)
    log(LOG_LEVEL.WARN, fmt, ...)
end

local function log_error(fmt, ...)
    log(LOG_LEVEL.ERROR, fmt, ...)
end
```

### 7.3 性能监控

```lua
-- 性能指标收集
local metrics = {
    message_count = 0,
    error_count = 0,
    avg_response_time = 0,
    last_reset_time = skynet.time()
}

local response_times = {}

-- 记录响应时间
local function record_response_time(start_time)
    local response_time = skynet.time() - start_time
    table.insert(response_times, response_time)
    
    -- 保持最近100个响应时间
    if #response_times > 100 then
        table.remove(response_times, 1)
    end
    
    -- 计算平均响应时间
    local total = 0
    for _, time in ipairs(response_times) do
        total = total + time
    end
    metrics.avg_response_time = total / #response_times
end

-- 获取性能指标
local function get_metrics()
    return {
        message_count = metrics.message_count,
        error_count = metrics.error_count,
        error_rate = metrics.message_count > 0 and 
                    (metrics.error_count / metrics.message_count) or 0,
        avg_response_time = metrics.avg_response_time,
        uptime = skynet.time() - metrics.last_reset_time,
        memory_usage = collectgarbage("count")
    }
end
```

### 7.4 错误处理和恢复

```lua
-- 错误处理包装器
local function safe_call(func, ...)
    local ok, result = pcall(func, ...)
    if not ok then
        log_error("Function call failed: %s", tostring(result))
        metrics.error_count = metrics.error_count + 1
        return false, result
    end
    return true, result
end

-- 服务健康检查
local function health_check()
    local checks = {
        memory_ok = collectgarbage("count") < config.max_memory,
        message_queue_ok = #message_queue < config.max_queue_size,
        database_ok = check_database_connection(),
        external_services_ok = check_external_services()
    }
    
    local all_ok = true
    for check, result in pairs(checks) do
        if not result then
            log_warn("Health check failed: %s", check)
            all_ok = false
        end
    end
    
    return all_ok, checks
end
```

### 7.5 实际应用场景

#### 7.5.1 游戏服务器中的应用
在游戏服务器中，Skynet 服务可以用于：
- **玩家会话管理**：管理玩家登录、状态同步、断线重连
- **游戏逻辑处理**：处理游戏规则、战斗计算、物品系统
- **实时聊天系统**：处理玩家间的聊天消息、频道管理
- **排行榜系统**：计算和更新玩家排名、成就系统

#### 7.5.2 微服务架构中的应用
在微服务架构中，Skynet 可以用作：
- **API 网关**：请求路由、负载均衡、认证授权
- **消息队列**：异步任务处理、事件驱动架构
- **缓存服务**：数据缓存、会话管理
- **监控服务**：系统监控、日志收集、性能分析

#### 7.5.3 实时数据处理
- **数据流处理**：实时数据分析、事件处理
- **IoT 数据处理**：传感器数据处理、设备管理
- **金融数据处理**：实时行情、交易处理

### 7.6 最佳实践总结

#### 7.6.1 服务设计原则
1. **单一职责**：每个服务只负责一个明确的功能
2. **无状态设计**：尽量保持服务无状态，便于水平扩展
3. **故障隔离**：服务间通过消息通信，避免级联故障
4. **优雅降级**：在压力或故障情况下提供基本功能

#### 7.6.2 性能优化
1. **减少消息传递**：优化服务间的通信频率
2. **合理使用协程**：避免创建过多协程导致资源浪费
3. **内存管理**：及时释放不再使用的资源
4. **批量处理**：对大量小操作进行批量处理

#### 7.6.3 监控和运维
1. **全面监控**：监控服务的各项指标
2. **日志规范**：使用统一的日志格式和级别
3. **告警机制**：设置合理的告警阈值
4. **文档完善**：维护详细的服务文档和 API 说明

#### 7.6.4 开发流程
1. **单元测试**：为每个服务编写完整的测试用例
2. **集成测试**：测试服务间的协作
3. **性能测试**：验证服务的性能表现
4. **压力测试**：测试服务在高负载下的表现

## 总结

在本教程中，你深入学习了：

### 核心概念
- **服务结构**：掌握了 Skynet 服务的标准结构和生命周期
- **消息处理**：学会了如何注册消息处理器和分发消息
- **状态管理**：理解了服务内部状态的管理方法
- **服务注册**：掌握了服务命名和发现机制

### 实践技能
- **计数器服务**：构建了一个完整的状态管理服务
- **聊天服务**：实现了复杂的多服务协作架构
- **任务队列**：掌握了异步任务处理和优先级调度

### 开发工具
- **调试技巧**：学会了添加调试命令和监控服务状态
- **日志系统**：实现了完整的日志记录和级别管理
- **性能监控**：掌握了服务性能指标的收集和分析
- **错误处理**：学会了优雅的错误处理和恢复机制

### 最佳实践
- **服务设计**：理解了单一职责和故障隔离原则
- **性能优化**：掌握了资源管理和批量处理技巧
- **监控运维**：学会了全面的监控和告警机制
- **开发流程**：理解了测试驱动的开发方法

## 下一步

继续学习 [教程 4：消息传递和通信](./04_message_passing.md)，你将掌握：
- 高级消息传递模式
- 服务间通信的最佳实践
- 分布式系统设计模式
- 消息序列化和协议设计

## 附加资源

### 推荐阅读
- Skynet 官方文档：https://github.com/cloudwu/skynet/wiki
- Lua 协程编程：https://www.lua.org/manual/5.4/
- Actor 模式设计：https://www.reactivemanifesto.org/

### 示例代码
本教程的所有示例代码都可以在 `examples/` 目录中找到：
- `counter_service.lua` - 计数器服务实现
- `chat_service.lua` - 聊天服务实现
- `test_counter.lua` - 计数器服务测试

### 练习答案
任务队列服务的完整实现参考答案可以在 `examples/task_queue_service.lua` 中找到。

---

*本教程是 Skynet 学习系列的一部分，通过循序渐进的方式帮助你掌握 Skynet 框架的核心概念和实践技能。*
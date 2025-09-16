# Working with Lua Services（Lua 服务开发实践）
## What You'll Learn（你将学到的内容）
- Advanced Lua service development patterns（高级 Lua 服务开发模式）
- Service lifecycle management（服务生命周期管理）
- State management techniques（状态管理技巧）
- Hot-reloading services（服务热重载）
- Performance optimization for Lua services（Lua 服务性能优化）
## Prerequisites（前置要求）
- Completed Tutorial 4: Message Passing and Communication（已完成教程 4：消息传递与通信）
- Strong understanding of Lua programming（扎实的 Lua 编程基础）
- Familiarity with Skynet service basics（熟悉 Skynet 服务基础）
## Time Estimate（预计耗时）
55 minutes（55 分钟）
## Final Result（学习成果）
Ability to build robust, maintainable, and high-performance Lua services in Skynet（能够在 Skynet 中构建健壮、可维护且高性能的 Lua 服务）
---
## 1. Lua Service Architecture（1. Lua 服务架构）
### 1.1 Service Structure Patterns（1.1 服务结构模式）
A well-structured Lua service follows these patterns:（一个结构良好的 Lua 服务需遵循以下模式）
```lua
-- examples/structured_service.lua（示例/结构化服务.lua）
local skynet = require "skynet"  -- 引入 skynet 框架
local table = table  -- 引入 table 模块（用于表操作）
local string = string  -- 引入 string 模块（用于字符串操作）

-- Service constants（服务常量定义）
local SERVICE_NAME = "STRUCTURED_SERVICE"  -- 服务名称
local MAX_CONNECTIONS = 1000  -- 最大连接数
local TIMEOUT = 30 -- seconds（超时时间，单位：秒）

-- Service module（服务模块定义）
local M = {}

-- Private state（私有状态，存储服务内部数据）
local _state = {
    config = {},  -- 配置信息
    connections = {},  -- 连接信息
    data = {},  -- 业务数据
    timers = {}  -- 定时器列表
}

-- Initialize service（服务初始化函数）
function M.init(config)
    _state.config = config or {}  -- 初始化配置，无传入配置时使用空表
    
    -- Validate configuration（验证配置：若配置的最大连接数超过上限，则强制设为上限值）
    if _state.config.max_connections > MAX_CONNECTIONS then
        _state.config.max_connections = MAX_CONNECTIONS
    end
    
    -- Load resources（加载资源：初始化数据库、缓存等）
    M.load_resources()
    
    -- Start background tasks（启动后台任务：如定时清理、统计等）
    M.start_timers()
    
    return true  -- 初始化成功，返回 true
end

-- Load resources（加载资源函数）
function M.load_resources()
    -- Initialize database connections（初始化数据库连接池）
    _state.db_pool = require "db_pool".new(_state.config.db)
    
    -- Initialize cache（初始化缓存连接）
    _state.cache = require "cache".connect(_state.config.cache)
    
    -- Load initial data（加载初始数据：从数据库查询配置数据并存储到状态中）
    local data = _state.db_pool:query("SELECT * FROM config")
    for _, row in ipairs(data) do
        _state.data[row.key] = row.value
    end
end

-- Start background timers（启动后台定时器函数）
function M.start_timers()
    -- Cleanup timer（清理定时器：每 60 秒执行一次非活跃连接清理）
    _state.timers.cleanup = skynet.timeout(60000, function()
        M.cleanup_inactive_connections()
        _state.timers.cleanup = skynet.timeout(60000, function()
            M.start_timers()
        end)
    end)
    
    -- Stats timer（统计定时器：每 5 秒执行一次状态统计）
    _state.timers.stats = skynet.timeout(5000, function()
        M.update_stats()
        _state.timers.stats = skynet.timeout(5000, M.update_stats)
    end)
end

-- Command handlers（命令处理器：用于处理外部调用的命令）
local handlers = {}

-- 处理初始化命令
function handlers.init(config)
    return M.init(config)
end

-- 处理数据查询命令：根据键获取数据
function handlers.get_data(key)
    return _state.data[key]
end

-- 处理数据设置命令：设置键值对并持久化到数据库
function handlers.set_data(key, value)
    _state.data[key] = value
    
    -- Persist to database（持久化到数据库：使用 INSERT OR REPLACE 确保数据更新）
    _state.db_pool:execute("INSERT OR REPLACE INTO config VALUES (?, ?)", 
                          key, value)
    
    return true
end

-- 处理连接注册命令：注册新连接，若超过最大连接数则返回失败
function handlers.register_connection(conn_id, client_addr)
    if #_state.connections >= _state.config.max_connections then
        return false, "Too many connections"  -- 连接数过多，返回失败信息
    end
    
    _state.connections[conn_id] = {
        id = conn_id,  -- 连接 ID
        client = client_addr,  -- 客户端地址
        created = skynet.time(),  -- 连接创建时间
        last_active = skynet.time()  -- 最后活跃时间
    }
    
    return true  -- 注册成功，返回 true
end

-- 处理连接注销命令：移除指定连接
function handlers.unregister_connection(conn_id)
    _state.connections[conn_id] = nil
    return true
end

-- Service entry point（服务入口函数：Skynet 服务的启动入口）
skynet.start(function()
    -- Register command handlers（注册命令处理器：处理 "lua" 类型的消息）
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local handler = handlers[cmd]  -- 根据命令找到对应的处理器
        if handler then
            -- 使用 pcall 捕获处理器执行过程中的错误
            local ok, result = pcall(handler, ...)
            if ok then
                skynet.ret(skynet.pack(result))  -- 执行成功，返回结果
            else
                -- 执行失败，打印错误信息并返回内部错误提示
                skynet.error("Handler error:", cmd, result)
                skynet.ret(skynet.pack(false, "Internal error"))
            end
        else
            -- 无对应处理器，返回未知命令提示
            skynet.ret(skynet.pack(false, "Unknown command"))
        end
    end)
    
    -- Register service（注册服务：将服务以指定名称注册到 Skynet 中）
    skynet.register(SERVICE_NAME)
    
    -- Initialize with default config（使用默认配置初始化服务）
    M.init()
    
    skynet.exit()  -- 退出服务（此处为示例，实际服务通常会持续运行）
end)
```
## 2. State Management Patterns（2. 状态管理模式）
### 2.1 Immutable State Updates（2.1 不可变状态更新）
```lua
-- State management with immutable updates（基于不可变更新的状态管理：避免直接修改原状态，确保可追溯性）
local function update_state(updates)
    local new_state = {}  -- 创建新状态表，用于存储更新后的状态
    
    -- Copy existing state（复制现有状态：对表类型进行深拷贝，其他类型直接赋值）
    for k, v in pairs(_state) do
        if type(v) == "table" then
            new_state[k] = table.deepcopy(v)  -- 深拷贝表，避免引用共享
        else
            new_state[k] = v  -- 非表类型直接赋值
        end
    end
    
    -- Apply updates（应用更新：根据更新内容修改新状态）
    for k, v in pairs(updates) do
        if type(v) == "table" and type(new_state[k]) == "table" then
            -- 若新旧值均为表，则递归更新表内字段
            for kk, vv in pairs(v) do
                new_state[k][kk] = vv
            end
        else
            -- 否则直接覆盖字段值
            new_state[k] = v
        end
    end
    
    _state = new_state  -- 将新状态赋值给原状态变量，完成更新
end
```
### 2.2 State Persistence（2.2 状态持久化）
```lua
-- Periodic state persistence（周期性状态持久化：将服务状态定期保存到本地文件）
local function persist_state()
    -- 整理需要持久化的状态数据：包含业务数据、配置和时间戳
    local state_data = {
        data = _state.data,
        config = _state.config,
        timestamp = skynet.time()
    }
    
    -- 生成文件名：以当前时间戳命名，确保文件唯一性
    local filename = string.format("state_%d.dat", os.time())
    local f = io.open(filename, "w")  -- 以写入模式打开文件
    if f then
        f:write(skynet.pack(state_data))  -- 使用 skynet.pack 序列化状态数据并写入文件
        f:close()  -- 关闭文件
    end
end

-- Load state on startup（启动时加载状态：从本地文件中恢复最近的状态）
local function load_state()
    local latest_file = nil  -- 存储最新的状态文件名
    local latest_time = 0  -- 存储最新状态文件的时间戳
    
    -- Find latest state file（查找最新的状态文件：遍历当前目录下的 .dat 文件）
    for file in lfs.dir(".") do
        -- 使用正则匹配状态文件名（格式：state_时间戳.dat）
        local match = file:match("^state_(%d+)%.(dat)$")
        if match then
            local file_time = tonumber(match)  -- 将匹配到的时间戳转为数字
            if file_time > latest_time then
                latest_time = file_time
                latest_file = file
            end
        end
    end
    
    -- Load if found（若找到最新文件，则加载状态）
    if latest_file then
        local f = io.open(latest_file, "r")  -- 以读取模式打开文件
        if f then
            local data = f:read("*all")  -- 读取文件全部内容
            f:close()  -- 关闭文件
            local state = skynet.unpack(data)  -- 反序列化数据
            -- 恢复状态：若反序列化后无对应字段，则使用空表
            _state.data = state.data or {}
            _state.config = state.config or {}
        end
    end
end
```
## 3. Service Composition（3. 服务组合）
### 3.1 Service Dependencies（3.1 服务依赖）
```lua
-- Service with dependencies（带依赖的服务：明确声明服务所需的其他服务）
local dependencies = {
    config = "CONFIG_SERVICE",  -- 配置服务
    database = "DB_SERVICE",    -- 数据库服务
    cache = "CACHE_SERVICE",    -- 缓存服务
    auth = "AUTH_SERVICE"       -- 认证服务
}
local services = {}  -- 存储依赖服务的地址

-- 解析依赖：查询并获取所有依赖服务的地址
local function resolve_dependencies()
    for name, service_name in pairs(dependencies) do
        -- 使用 skynet.query 查询服务地址
        local addr = skynet.query(service_name)
        if not addr then
            -- 若依赖服务未找到，打印错误信息并返回失败
            skynet.error("Dependency not found:", service_name)
            return false
        end
        services[name] = addr  -- 存储依赖服务地址
    end
    return true  -- 所有依赖解析成功，返回 true
end

-- Initialize with dependencies（带依赖的初始化：先解析依赖，再初始化服务）
function M.init()
    if not resolve_dependencies() then
        return false  -- 依赖解析失败，初始化终止
    end
    
    -- Load configuration（加载配置：从配置服务中获取当前服务的配置）
    local ok, config = skynet.call(services.config, "lua", "get", SERVICE_NAME)
    if ok then
        _state.config = config  -- 加载成功，更新服务配置
    end
    
    -- Test database connection（测试数据库连接：确保数据库服务可用）
    local ok, result = skynet.call(services.database, "lua", "ping")
    if not ok then
        skynet.error("Database connection failed")  -- 数据库连接失败，打印错误
        return false
    end
    
    return true  -- 初始化成功，返回 true
end
```
### 3.2 Service Factories（3.2 服务工厂）
```lua
-- Service factory pattern（服务工厂模式：批量创建同类型的工作节点服务）
local function create_worker_service(worker_id, config)
    -- 定义工作节点服务的代码（通过字符串形式动态创建服务）
    local service_code = [[
        local skynet = require "skynet"
        local worker_id = ...  -- 接收外部传入的 worker_id
        local config = ...     -- 接收外部传入的配置
        
        -- 工作节点状态：存储节点 ID、配置、处理任务数和最后活跃时间
        local state = {
            id = worker_id,
            config = config,
            processed = 0,
            last_active = skynet.time()
        }
        
        -- 注册消息处理器：处理 "lua" 类型的消息
        skynet.dispatch("lua", function(session, source, cmd, ...)
            if cmd == "process" then
                -- 处理任务命令：执行任务并更新状态
                local task = ...
                local result = process_task(task)
                state.processed = state.processed + 1
                state.last_active = skynet.time()
                skynet.ret(skynet.pack(result))  -- 返回任务处理结果
            elseif cmd == "status" then
                -- 处理状态查询命令：返回当前工作节点状态
                skynet.ret(skynet.pack(state))
            end
        end)
        
        -- 工作节点入口：注册服务并启动
        skynet.start(function()
            skynet.register("WORKER_" .. worker_id)
        end)
    ]]
    
    -- 创建新的工作节点服务：使用 snlua 启动，并传入 worker_id 和配置
    return skynet.newservice("snlua", "worker", worker_id, skynet.pack(config))
end

-- Worker pool（工作节点池：管理一组工作节点，实现任务分发）
local worker_pool = {}

-- 创建工作节点池：根据指定数量和配置批量创建工作节点
function M.create_worker_pool(pool_size, worker_config)
    for i = 1, pool_size do
        local worker = create_worker_service(i, worker_config)
        table.insert(worker_pool, worker)  -- 将新节点加入节点池
    end
end

-- 获取工作节点：采用简单的轮询（round-robin）策略分发任务
function M.get_worker()
    local worker = worker_pool[1]  -- 取出第一个节点
    table.remove(worker_pool, 1)   -- 从池首移除
    table.insert(worker_pool, worker)  -- 加入池尾，实现轮询
    return worker
end
```
## 4. Error Handling and Recovery（4. 错误处理与恢复）
### 4.1 Graceful Shutdown（4.1 优雅关闭）
```lua
-- Shutdown handler（关闭处理器：实现服务的优雅关闭逻辑）
local shutting_down = false  -- 标记服务是否正在关闭，避免重复执行关闭逻辑
local function shutdown()
    if shutting_down then return end  -- 若已在关闭中，直接返回
    shutting_down = true
    
    skynet.error("Shutting down service...")  -- 打印关闭日志
    
    -- Cancel all timers（取消所有定时器：避免关闭过程中定时器触发新任务）
    for _, timer in pairs(_state.timers) do
        skynet.kill(timer)
    end
    
    -- Save state（保存状态：关闭前持久化当前状态，确保数据不丢失）
    persist_state()
    
    -- Close connections（关闭所有连接：通知客户端服务即将关闭）
    for conn_id, conn in pairs(_state.connections) do
        skynet.send(conn.client, "lua", "shutdown")
    end
    
    -- Notify dependencies（通知依赖服务：告知当前服务已下线）
    for _, service_addr in pairs(services) do
        skynet.send(service_addr, "lua", "service_down", SERVICE_NAME)
    end
    
    skynet.exit()  -- 退出服务，释放资源
end

-- Register shutdown handler（注册关闭处理器：处理系统级的 "shutdown" 命令）
skynet.dispatch("system", function(session, source, cmd, ...)
    if cmd == "shutdown" then
        shutdown()  -- 触发优雅关闭逻辑
    end
end)
```
### 4.2 Error Recovery（4.2 错误恢复）
```lua
-- Error monitoring and recovery（错误监控与恢复：监控错误率并触发恢复操作）
local error_counts = {}  -- 存储各操作的错误记录（键：操作名，值：错误时间列表）
local max_errors = 10    -- 错误窗口内的最大允许错误数
local error_window = 60 -- seconds（错误统计窗口，单位：秒）

-- 检查错误率：遍历各操作的错误记录，判断是否超过阈值
local function check_error_rate()
    local now = skynet.time()  --获取当前时间
    for operation, errors in pairs(error_counts) do
        -- Clean old errors（清理过期错误：只保留错误窗口内的错误记录）
        local recent_errors = 0
        for _, error_time in ipairs(errors) do
            if now - error_time < error_window then
                recent_errors = recent_errors + 1
            end
        end
        
        -- 若错误数超过阈值，触发错误处理
        if recent_errors > max_errors then
            skynet.error("High error rate for operation:", operation)
            -- Trigger recovery action（触发恢复操作：针对特定操作执行恢复逻辑）
            handle_operation_failure(operation)
        end
    end
end

-- 记录错误：将指定操作的错误时间加入错误记录
local function record_error(operation)
    if not error_counts[operation] then
        error_counts[operation] = {}  -- 若操作无错误记录，初始化空列表
    end
    table.insert(error_counts[operation], skynet.time())
    
    -- Keep only recent errors（保留近期错误：只保留 2 倍阈值数量的错误记录，避免内存占用过大）
    if #error_counts[operation] > max_errors * 2 then
        table.remove(error_counts[operation], 1)
    end
end

-- 处理操作失败：针对不同操作类型执行特定恢复逻辑
local function handle_operation_failure(operation)
    if operation == "database" then
        -- Reconnect database（数据库操作失败：重新解析数据库服务依赖，实现重连）
        services.database = nil
        resolve_dependencies()
    end
end
```
## 5. Hot-Reloading Services（5. 服务热重载）
### 5.1 Service Reloading Pattern（5.1 服务重载模式）
```lua
-- hot_reloadable_service.lua（热重载服务示例代码）
local skynet = require "skynet"
local service_version = 1  -- 服务版本号：用于标识当前服务版本

-- 创建处理器：加载服务实现代码并返回处理器
local function create_handler()
    -- Load the actual service code（加载实际服务实现：从外部文件加载服务逻辑）
    local service_code = loadfile("service_impl.lua")
    return service_code()
end

local current_handler = create_handler()  -- 初始化当前处理器：加载初始服务实现

skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        if cmd == "reload" then
            -- 处理重载命令：创建新处理器并切换
            local new_handler = create_handler()
            
            -- Transfer state if needed（按需转移状态：若旧处理器支持状态转移，则传递状态到新处理器）
            if current_handler.transfer_state then
                local state = current_handler.get_state()
                new_handler.set_state(state)
            end
            
            -- Switch handler（切换处理器：将当前处理器替换为新处理器）
            current_handler = new_handler
            service_version = service_version + 1  -- 更新服务版本号
            
            skynet.ret(skynet.pack(true, service_version))  -- 返回重载成功结果及新版本号
            
        elseif cmd == "get_version" then
            -- 处理版本查询命令：返回当前服务版本号
            skynet.ret(skynet.pack(service_version))
            
        else
            -- Forward to current handler（转发其他命令：将非重载/版本查询命令转发给当前处理器）
            current_handler.handle_message(session, source, cmd, ...)
        end
    end)
    
    -- 注册热重载服务：以指定名称注册到 Skynet
    skynet.register("HOT_RELOADABLE")
end)
```
### 5.2 State Transfer（5.2 状态转移）
```lua
-- service_impl.lua（服务实现文件：包含业务逻辑与状态转移接口）
return function()
    -- 服务内部状态：存储业务数据、配置和连接信息
    local state = {
        data = {},
        config = {},
        connections = {}
    }
    
    -- 消息处理函数：实现具体业务逻辑（此处为示例框架，需根据实际需求补充）
    local function handle_message(session, source, cmd, ...)
        -- Message handling logic（消息处理逻辑：根据命令类型执行对应业务操作）
    end
    
    -- 获取状态：返回需要转移的状态数据（通常排除临时连接等无需持久化的信息）
    local function get_state()
        return {
            data = state.data,
            config = state.config,
            -- Don't transfer connections（不转移连接信息：连接属于临时状态，重载后需重新建立）
        }
    end
    
    -- 设置状态：接收新处理器传递的状态数据，初始化新服务状态
    local function set_state(new_state)
        state.data = new_state.data or {}  -- 若新状态无数据，使用空表
        state.config = new_state.config or {}
    end
    
    -- 返回服务接口：包含消息处理、状态获取/设置及状态转移标识
    return {
        handle_message = handle_message,
        get_state = get_state,
        set_state = set_state,
        transfer_state = true  -- 状态转移标识：标记当前服务支持状态转移
    }
end
```
## 6. Performance Optimization（6. 性能优化）
### 6.1 Memory Management（6.1 内存管理）
```lua
-- Memory optimization（内存优化函数：释放无用内存，减少内存占用）
local function optimize_memory()
    -- Force garbage collection（强制垃圾回收：主动触发 Lua 垃圾回收，释放未使用内存）
    collectgarbage("collect")
    
    -- Clean up unused tables（清理无用表：移除超时的非活跃连接）
    for conn_id, conn in pairs(_state.connections) do
        if skynet.time() - conn.last_active > TIMEOUT then
            _state.connections[conn_id] = nil  -- 超时连接设为 nil，便于垃圾回收
        end
    end
    
    -- Compress large data structures（压缩大型数据结构：对大表进行压缩，减少内存占用）
    for key, value in pairs(_state.data) do
        if type(value) == "table" and #value > 1000 then
            _state.data[key] = compress_table(value)  -- 需实现 compress_table 函数（根据实际需求选择压缩算法）
        end
    end
end

-- Periodic memory optimization（周期性内存优化：每 30 秒执行一次内存优化）
skynet.timeout(30000, function()
    optimize_memory()
    skynet.timeout(30000, optimize_memory)  -- 递归注册定时器，实现周期性执行
end)
```
### 6.2 Caching Strategies（6.2 缓存策略）
```lua
-- Multi-level cache（多级缓存：实现 L1（内存）、L2（Redis）、L3（数据库）三级缓存）
local cache = {
    l1 = {},    -- Memory cache (fast, small)（L1 内存缓存：速度快、容量小，存储高频访问数据）
    l2 = nil,   -- Redis cache (medium)（L2 Redis 缓存：速度中等、容量较大，存储中频访问数据）
    l3 = nil    -- Database (slow, persistent)（L3 数据库：速度慢、容量大，存储所有数据，提供持久化）
}

-- 获取缓存数据：按 L1→L2→L3 顺序查询，命中后更新上级缓存
local function get_cached_data(key)
    -- Level 1: Memory cache（查询 L1 缓存：若数据存在且未过期，直接返回）
    if cache.l1[key] and cache.l1[key].expire > skynet.time() then
        return cache.l1[key].data
    end
    
    -- Level 2: Redis cache（查询 L2 缓存：若 L1 未命中，查询 Redis）
    if cache.l2 then
        local ok, data = skynet.call(cache.l2, "lua", "get", key)
        if ok then
            -- Store in L1 cache（更新 L1 缓存：将 Redis 数据存入内存，设置 1 分钟过期）
            cache.l1[key] = {
                data = data,
                expire = skynet.time() + 60 -- 1 minute
            }
            return data
        end
    end
    
    -- Level 3: Database（查询 L3 数据库：若 L2 未命中，查询数据库）
    if cache.l3 then
        local ok, data = skynet.call(cache.l3, "lua", "get", key)
        if ok then
            -- Store in L2 and L1 caches（更新 L2 和 L1 缓存：数据库数据存入 Redis 和内存）
            if cache.l2 then
                -- Redis 缓存设置 5 分钟过期
                skynet.send(cache.l2, "lua", "set", key, data, 300) -- 5 minutes
            end
            -- 内存缓存设置 1 分钟过期
            cache.l1[key] = {
                data = data,
                expire = skynet.time() + 60
            }
            return data
        end
    end
    
    return nil  -- 所有缓存均未命中，返回 nil
end
```
## 7. Example: Chat Room Service（7. 示例：聊天室服务）
```lua
-- chat_room_service.lua（聊天室服务示例代码）
local skynet = require "skynet"
local room_service = {}  -- 聊天室服务模块
local rooms = {}         -- 房间列表：存储所有房间信息（键：房间 ID，值：房间详情）
local users = {}         -- 用户列表：存储所有用户信息（键：用户 ID，值：用户详情）
local message_handlers = {}  -- 消息处理器：处理用户发送的各类消息

-- Message handlers（消息处理器：实现加入、发送消息、离开房间等逻辑）
-- 处理用户加入房间消息
function message_handlers.join(user_id, room_id, user_name)
    -- 若房间不存在，创建新房间
    if not rooms[room_id] then
        rooms[room_id] = {
            users = {},       -- 房间内用户列表
            messages = {},    -- 房间消息历史
            created = skynet.time()  -- 房间创建时间
        }
    end
    
    -- 记录用户在房间内的信息
    rooms[room_id].users[user_id] = {
        name = user_name,
        joined = skynet.time()  -- 用户加入时间
    }
    
    -- 记录用户全局信息
    users[user_id] = {
        room = room_id,  -- 用户当前所在房间
        name = user_name
    }
    
    -- Broadcast join message（广播加入消息：通知房间内所有用户有新用户加入）
    broadcast_to_room(room_id, {
        type = "join",
        user = user_name,
        time = skynet.time()
    })
    
    return true  -- 加入成功，返回 true
end

-- 处理用户发送消息
function message_handlers.message(user_id, text)
    local user = users[user_id]
    -- 若用户不存在或未加入房间，返回失败
    if not user or not user.room then
        return false, "User not in room"
    end
    
    -- 构造消息对象
    local message = {
        type = "message",
        user = user.name,  -- 发送者名称
        text = text,       -- 消息内容
        time = skynet.time()  -- 发送时间
    }
    
    -- Add to room history（添加到消息历史：将消息存入房间的消息列表）
    table.insert(rooms[user.room].messages, message)
    
    -- Keep only last 100 messages（保留最近 100 条消息：避免消息历史过大，节省内存）
    if #rooms[user.room].messages > 100 then
        table.remove(rooms[user.room].messages, 1)
    end
    
    -- Broadcast to room（广播消息：将消息发送给房间内所有用户）
    broadcast_to_room(user.room, message)
    
    return true  -- 消息发送成功，返回 true
end

-- 处理用户离开房间
function message_handlers.leave(user_id)
    local user = users[user_id]
    if not user then return true end  -- 若用户不存在，直接返回成功
    
    -- 若用户在房间内，执行离开逻辑
    if user.room and rooms[user.room] then
        rooms[user.room].users[user_id] = nil  -- 从房间用户列表中移除
        
        -- Broadcast leave message（广播离开消息：通知房间内所有用户有用户离开）
        broadcast_to_room(user.room, {
            type = "leave",
            user = user.name,
            time = skynet.time()
        })
        
        -- Clean up empty rooms（清理空房间：若房间无用户，删除房间以节省内存）
        if next(rooms[user.room].users) == nil then
            rooms[user.room] = nil
        end
    end
    
    users[user_id] = nil  -- 从全局用户列表中移除
    return true
end

-- Helper functions（辅助函数：实现消息广播等通用逻辑）
-- 向房间内所有用户广播消息
local function broadcast_to_room(room_id, message)
    local room = rooms[room_id]
    if not room then return end  -- 若房间不存在，直接返回
    
    -- 遍历房间内所有用户，发送消息
    for user_id, _ in pairs(room.users) do
        -- 查询用户对应的服务地址
        local user_service = skynet.query("USER_" .. user_id)
        if user_service then
            -- 发送消息给用户服务
            skynet.send(user_service, "lua", "deliver_message", message)
        end
    end
end

-- Service entry（服务入口：初始化聊天室服务并注册）
skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local handler = message_handlers[cmd]  -- 根据命令找到对应的处理器
        if handler then
            -- 使用 pcall 捕获处理器执行错误
            local ok, result = pcall(handler, ...)
            if ok then
                skynet.ret(skynet.pack(result))  -- 执行成功，返回结果
            else
                -- 执行失败，打印错误并返回失败信息
                skynet.error("Message handler error:", cmd, result)
                skynet.ret(skynet.pack(false, "Handler error"))
            end
        else
            -- 无对应处理器，返回未知命令错误
            skynet.ret(skynet.pack(false, "Unknown command"))
        end
    end)
    
    -- Register service（注册聊天室服务）
    skynet.register("CHAT_ROOM_SERVICE")
    
    skynet.exit()  -- 退出服务（示例用，实际服务需持续运行）
end)
```
## 8. Exercise: Task Queue Service（8. 练习：任务队列服务）
Create a robust task queue service with:（创建一个健壮的任务队列服务，需包含以下功能）
1. Priority-based task scheduling（基于优先级的任务调度）
2. Worker health monitoring（工作节点健康监控）
3. Task retry mechanism（任务重试机制）
4. Progress tracking（进度跟踪）
5. Hot-reload capability（热重载能力）

**Features to implement**:（需实现的额外特性）
- Task persistence（任务持久化：确保服务重启后任务不丢失）
- Worker auto-scaling（工作节点自动扩缩容：根据任务量动态调整节点数量）
- Dead letter queue for failed tasks（失败任务死信队列：存储无法重试的失败任务，便于后续排查）
- Web-based monitoring interface（基于 Web 的监控界面：可视化展示任务队列状态、节点健康度等）

## Summary（总结）
In this tutorial, you learned:（在本教程中，你学习了）
- Advanced Lua service structure patterns（高级 Lua 服务结构模式）
- State management techniques（状态管理技巧）
- Service composition and dependencies（服务组合与依赖管理）
- Error handling and recovery strategies（错误处理与恢复策略）
- Hot-reloading services（服务热重载方法）
- Performance optimization methods（性能优化手段）

## Next Steps（下一步）
Continue to [Tutorial 6: Network Programming with Skynet](./tutorial6_network_programming.md) to learn about building networked applications with Skynet's socket and gate services.（继续学习《教程 6：Skynet 网络编程》，了解如何使用 Skynet 的 socket 和 gate 服务构建网络应用。）
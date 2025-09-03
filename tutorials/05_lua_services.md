# Working with Lua Services

## What You'll Learn
- Advanced Lua service development patterns
- Service lifecycle management
- State management techniques
- Hot-reloading services
- Performance optimization for Lua services

## Prerequisites
- Completed Tutorial 4: Message Passing and Communication
- Strong understanding of Lua programming
- Familiarity with Skynet service basics

## Time Estimate
55 minutes

## Final Result
Ability to build robust, maintainable, and high-performance Lua services in Skynet

---

## 1. Lua Service Architecture

### 1.1 Service Structure Patterns

A well-structured Lua service follows these patterns:

```lua
-- examples/structured_service.lua
local skynet = require "skynet"
local table = table
local string = string

-- Service constants
local SERVICE_NAME = "STRUCTURED_SERVICE"
local MAX_CONNECTIONS = 1000
local TIMEOUT = 30 -- seconds

-- Service module
local M = {}

-- Private state
local _state = {
    config = {},
    connections = {},
    data = {},
    timers = {}
}

-- Initialize service
function M.init(config)
    _state.config = config or {}
    
    -- Validate configuration
    if _state.config.max_connections > MAX_CONNECTIONS then
        _state.config.max_connections = MAX_CONNECTIONS
    end
    
    -- Load resources
    M.load_resources()
    
    -- Start background tasks
    M.start_timers()
    
    return true
end

-- Load resources
function M.load_resources()
    -- Initialize database connections
    _state.db_pool = require "db_pool".new(_state.config.db)
    
    -- Initialize cache
    _state.cache = require "cache".connect(_state.config.cache)
    
    -- Load initial data
    local data = _state.db_pool:query("SELECT * FROM config")
    for _, row in ipairs(data) do
        _state.data[row.key] = row.value
    end
end

-- Start background timers
function M.start_timers()
    -- Cleanup timer
    _state.timers.cleanup = skynet.timeout(60000, function()
        M.cleanup_inactive_connections()
        _state.timers.cleanup = skynet.timeout(60000, function()
            M.start_timers()
        end)
    end)
    
    -- Stats timer
    _state.timers.stats = skynet.timeout(5000, function()
        M.update_stats()
        _state.timers.stats = skynet.timeout(5000, M.update_stats)
    end)
end

-- Command handlers
local handlers = {}

function handlers.init(config)
    return M.init(config)
end

function handlers.get_data(key)
    return _state.data[key]
end

function handlers.set_data(key, value)
    _state.data[key] = value
    
    -- Persist to database
    _state.db_pool:execute("INSERT OR REPLACE INTO config VALUES (?, ?)", 
                          key, value)
    
    return true
end

function handlers.register_connection(conn_id, client_addr)
    if #_state.connections >= _state.config.max_connections then
        return false, "Too many connections"
    end
    
    _state.connections[conn_id] = {
        id = conn_id,
        client = client_addr,
        created = skynet.time(),
        last_active = skynet.time()
    }
    
    return true
end

function handlers.unregister_connection(conn_id)
    _state.connections[conn_id] = nil
    return true
end

-- Service entry point
skynet.start(function()
    -- Register command handlers
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local handler = handlers[cmd]
        if handler then
            local ok, result = pcall(handler, ...)
            if ok then
                skynet.ret(skynet.pack(result))
            else
                skynet.error("Handler error:", cmd, result)
                skynet.ret(skynet.pack(false, "Internal error"))
            end
        else
            skynet.ret(skynet.pack(false, "Unknown command"))
        end
    end)
    
    -- Register service
    skynet.register(SERVICE_NAME)
    
    -- Initialize with default config
    M.init()
    
    skynet.exit()
end)
```

## 2. State Management Patterns

### 2.1 Immutable State Updates

```lua
-- State management with immutable updates
local function update_state(updates)
    local new_state = {}
    
    -- Copy existing state
    for k, v in pairs(_state) do
        if type(v) == "table" then
            new_state[k] = table.deepcopy(v)
        else
            new_state[k] = v
        end
    end
    
    -- Apply updates
    for k, v in pairs(updates) do
        if type(v) == "table" and type(new_state[k]) == "table" then
            for kk, vv in pairs(v) do
                new_state[k][kk] = vv
            end
        else
            new_state[k] = v
        end
    end
    
    _state = new_state
end
```

### 2.2 State Persistence

```lua
-- Periodic state persistence
local function persist_state()
    local state_data = {
        data = _state.data,
        config = _state.config,
        timestamp = skynet.time()
    }
    
    local filename = string.format("state_%d.dat", os.time())
    local f = io.open(filename, "w")
    if f then
        f:write(skynet.pack(state_data))
        f:close()
    end
end

-- Load state on startup
local function load_state()
    local latest_file = nil
    local latest_time = 0
    
    -- Find latest state file
    for file in lfs.dir(".") do
        local match = file:match("^state_(%d+)%.(dat)$")
        if match then
            local file_time = tonumber(match)
            if file_time > latest_time then
                latest_time = file_time
                latest_file = file
            end
        end
    end
    
    -- Load if found
    if latest_file then
        local f = io.open(latest_file, "r")
        if f then
            local data = f:read("*all")
            f:close()
            local state = skynet.unpack(data)
            _state.data = state.data or {}
            _state.config = state.config or {}
        end
    end
end
```

## 3. Service Composition

### 3.1 Service Dependencies

```lua
-- Service with dependencies
local dependencies = {
    config = "CONFIG_SERVICE",
    database = "DB_SERVICE",
    cache = "CACHE_SERVICE",
    auth = "AUTH_SERVICE"
}

local services = {}

local function resolve_dependencies()
    for name, service_name in pairs(dependencies) do
        local addr = skynet.query(service_name)
        if not addr then
            skynet.error("Dependency not found:", service_name)
            return false
        end
        services[name] = addr
    end
    return true
end

-- Initialize with dependencies
function M.init()
    if not resolve_dependencies() then
        return false
    end
    
    -- Load configuration
    local ok, config = skynet.call(services.config, "lua", "get", SERVICE_NAME)
    if ok then
        _state.config = config
    end
    
    -- Test database connection
    local ok, result = skynet.call(services.database, "lua", "ping")
    if not ok then
        skynet.error("Database connection failed")
        return false
    end
    
    return true
end
```

### 3.2 Service Factories

```lua
-- Service factory pattern
local function create_worker_service(worker_id, config)
    local service_code = [[
        local skynet = require "skynet"
        local worker_id = ...
        local config = ...
        
        local state = {
            id = worker_id,
            config = config,
            processed = 0,
            last_active = skynet.time()
        }
        
        skynet.dispatch("lua", function(session, source, cmd, ...)
            if cmd == "process" then
                local task = ...
                local result = process_task(task)
                state.processed = state.processed + 1
                state.last_active = skynet.time()
                skynet.ret(skynet.pack(result))
            elseif cmd == "status" then
                skynet.ret(skynet.pack(state))
            end
        end)
        
        skynet.start(function()
            skynet.register("WORKER_" .. worker_id)
        end)
    ]]
    
    return skynet.newservice("snlua", "worker", worker_id, skynet.pack(config))
end

-- Worker pool
local worker_pool = {}

function M.create_worker_pool(pool_size, worker_config)
    for i = 1, pool_size do
        local worker = create_worker_service(i, worker_config)
        table.insert(worker_pool, worker)
    end
end

function M.get_worker()
    -- Simple round-robin
    local worker = worker_pool[1]
    table.remove(worker_pool, 1)
    table.insert(worker_pool, worker)
    return worker
end
```

## 4. Error Handling and Recovery

### 4.1 Graceful Shutdown

```lua
-- Shutdown handler
local shutting_down = false

local function shutdown()
    if shutting_down then return end
    shutting_down = true
    
    skynet.error("Shutting down service...")
    
    -- Cancel all timers
    for _, timer in pairs(_state.timers) do
        skynet.kill(timer)
    end
    
    -- Save state
    persist_state()
    
    -- Close connections
    for conn_id, conn in pairs(_state.connections) do
        skynet.send(conn.client, "lua", "shutdown")
    end
    
    -- Notify dependencies
    for _, service_addr in pairs(services) do
        skynet.send(service_addr, "lua", "service_down", SERVICE_NAME)
    end
    
    skynet.exit()
end

-- Register shutdown handler
skynet.dispatch("system", function(session, source, cmd, ...)
    if cmd == "shutdown" then
        shutdown()
    end
end)
```

### 4.2 Error Recovery

```lua
-- Error monitoring and recovery
local error_counts = {}
local max_errors = 10
local error_window = 60 -- seconds

local function check_error_rate()
    local now = skynet.time()
    for operation, errors in pairs(error_counts) do
        -- Clean old errors
        local recent_errors = 0
        for _, error_time in ipairs(errors) do
            if now - error_time < error_window then
                recent_errors = recent_errors + 1
            end
        end
        
        if recent_errors > max_errors then
            skynet.error("High error rate for operation:", operation)
            -- Trigger recovery action
            handle_operation_failure(operation)
        end
    end
end

local function record_error(operation)
    if not error_counts[operation] then
        error_counts[operation] = {}
    end
    table.insert(error_counts[operation], skynet.time())
    
    -- Keep only recent errors
    if #error_counts[operation] > max_errors * 2 then
        table.remove(error_counts[operation], 1)
    end
end

local function handle_operation_failure(operation)
    if operation == "database" then
        -- Reconnect database
        services.database = nil
        resolve_dependencies()
    end
end
```

## 5. Hot-Reloading Services

### 5.1 Service Reloading Pattern

```lua
-- hot_reloadable_service.lua
local skynet = require "skynet"
local service_version = 1

local function create_handler()
    -- Load the actual service code
    local service_code = loadfile("service_impl.lua")
    return service_code()
end

local current_handler = create_handler()

skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        if cmd == "reload" then
            -- Create new handler
            local new_handler = create_handler()
            
            -- Transfer state if needed
            if current_handler.transfer_state then
                local state = current_handler.get_state()
                new_handler.set_state(state)
            end
            
            -- Switch handler
            current_handler = new_handler
            service_version = service_version + 1
            
            skynet.ret(skynet.pack(true, service_version))
            
        elseif cmd == "get_version" then
            skynet.ret(skynet.pack(service_version))
            
        else
            -- Forward to current handler
            current_handler.handle_message(session, source, cmd, ...)
        end
    end)
    
    skynet.register("HOT_RELOADABLE")
end)
```

### 5.2 State Transfer

```lua
-- service_impl.lua
return function()
    local state = {
        data = {},
        config = {},
        connections = {}
    }
    
    local function handle_message(session, source, cmd, ...)
        -- Message handling logic
    end
    
    local function get_state()
        return {
            data = state.data,
            config = state.config,
            -- Don't transfer connections
        }
    end
    
    local function set_state(new_state)
        state.data = new_state.data or {}
        state.config = new_state.config or {}
    end
    
    return {
        handle_message = handle_message,
        get_state = get_state,
        set_state = set_state,
        transfer_state = true
    }
end
```

## 6. Performance Optimization

### 6.1 Memory Management

```lua
-- Memory optimization
local function optimize_memory()
    -- Force garbage collection
    collectgarbage("collect")
    
    -- Clean up unused tables
    for conn_id, conn in pairs(_state.connections) do
        if skynet.time() - conn.last_active > TIMEOUT then
            _state.connections[conn_id] = nil
        end
    end
    
    -- Compress large data structures
    for key, value in pairs(_state.data) do
        if type(value) == "table" and #value > 1000 then
            _state.data[key] = compress_table(value)
        end
    end
end

-- Periodic memory optimization
skynet.timeout(30000, function()
    optimize_memory()
    skynet.timeout(30000, optimize_memory)
end)
```

### 6.2 Caching Strategies

```lua
-- Multi-level cache
local cache = {
    l1 = {},    -- Memory cache (fast, small)
    l2 = nil,   -- Redis cache (medium)
    l3 = nil    -- Database (slow, persistent)
}

local function get_cached_data(key)
    -- Level 1: Memory cache
    if cache.l1[key] and cache.l1[key].expire > skynet.time() then
        return cache.l1[key].data
    end
    
    -- Level 2: Redis cache
    if cache.l2 then
        local ok, data = skynet.call(cache.l2, "lua", "get", key)
        if ok then
            -- Store in L1 cache
            cache.l1[key] = {
                data = data,
                expire = skynet.time() + 60 -- 1 minute
            }
            return data
        end
    end
    
    -- Level 3: Database
    if cache.l3 then
        local ok, data = skynet.call(cache.l3, "lua", "get", key)
        if ok then
            -- Store in L2 and L1 caches
            if cache.l2 then
                skynet.send(cache.l2, "lua", "set", key, data, 300) -- 5 minutes
            end
            cache.l1[key] = {
                data = data,
                expire = skynet.time() + 60
            }
            return data
        end
    end
    
    return nil
end
```

## 7. Example: Chat Room Service

```lua
-- chat_room_service.lua
local skynet = require "skynet"

local room_service = {}

local rooms = {}
local users = {}
local message_handlers = {}

-- Message handlers
function message_handlers.join(user_id, room_id, user_name)
    if not rooms[room_id] then
        rooms[room_id] = {
            users = {},
            messages = {},
            created = skynet.time()
        }
    end
    
    rooms[room_id].users[user_id] = {
        name = user_name,
        joined = skynet.time()
    }
    
    users[user_id] = {
        room = room_id,
        name = user_name
    }
    
    -- Broadcast join message
    broadcast_to_room(room_id, {
        type = "join",
        user = user_name,
        time = skynet.time()
    })
    
    return true
end

function message_handlers.message(user_id, text)
    local user = users[user_id]
    if not user or not user.room then
        return false, "User not in room"
    end
    
    local message = {
        type = "message",
        user = user.name,
        text = text,
        time = skynet.time()
    }
    
    -- Add to room history
    table.insert(rooms[user.room].messages, message)
    
    -- Keep only last 100 messages
    if #rooms[user.room].messages > 100 then
        table.remove(rooms[user.room].messages, 1)
    end
    
    -- Broadcast to room
    broadcast_to_room(user.room, message)
    
    return true
end

function message_handlers.leave(user_id)
    local user = users[user_id]
    if not user then return true end
    
    if user.room and rooms[user.room] then
        rooms[user.room].users[user_id] = nil
        
        -- Broadcast leave message
        broadcast_to_room(user.room, {
            type = "leave",
            user = user.name,
            time = skynet.time()
        })
        
        -- Clean up empty rooms
        if next(rooms[user.room].users) == nil then
            rooms[user.room] = nil
        end
    end
    
    users[user_id] = nil
    return true
end

-- Helper functions
local function broadcast_to_room(room_id, message)
    local room = rooms[room_id]
    if not room then return end
    
    for user_id, _ in pairs(room.users) do
        local user_service = skynet.query("USER_" .. user_id)
        if user_service then
            skynet.send(user_service, "lua", "deliver_message", message)
        end
    end
end

-- Service entry
skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local handler = message_handlers[cmd]
        if handler then
            local ok, result = pcall(handler, ...)
            if ok then
                skynet.ret(skynet.pack(result))
            else
                skynet.error("Message handler error:", cmd, result)
                skynet.ret(skynet.pack(false, "Handler error"))
            end
        else
            skynet.ret(skynet.pack(false, "Unknown command"))
        end
    end)
    
    -- Register service
    skynet.register("CHAT_ROOM_SERVICE")
    
    skynet.exit()
end)
```

## 8. Exercise: Task Queue Service

Create a robust task queue service with:
1. Priority-based task scheduling
2. Worker health monitoring
3. Task retry mechanism
4. Progress tracking
5. Hot-reload capability

**Features to implement**:
- Task persistence
- Worker auto-scaling
- Dead letter queue for failed tasks
- Web-based monitoring interface

## Summary

In this tutorial, you learned:
- Advanced Lua service structure patterns
- State management techniques
- Service composition and dependencies
- Error handling and recovery strategies
- Hot-reloading services
- Performance optimization methods

## Next Steps

Continue to [Tutorial 6: Network Programming with Skynet](./tutorial6_network_programming.md) to learn about building networked applications with Skynet's socket and gate services.
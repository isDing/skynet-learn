# Advanced Topics

## What You'll Learn
- Hot-reloading services without downtime
- Advanced debugging techniques
- Performance optimization strategies
- Memory management and leak detection
- Security best practices
- Testing and monitoring

## Prerequisites
- Completed all previous tutorials
- Deep understanding of Skynet architecture
- Experience with Lua programming

## Time Estimate
80 minutes

## Final Result
Mastery of advanced Skynet features for building production-ready, high-performance applications

---

## 1. Hot-Reloading Services

### 1.1 Service Hot-Reload Architecture

```lua
-- hot_reloadable_service.lua
local skynet = require "skynet"

-- Service version tracking
local service_version = 1
local reload_in_progress = false
local pending_operations = {}

-- Service interface
local service_interface = {
    -- Define your service API here
    process_request = function(data) end,
    get_status = function() end,
    cleanup = function() end
}

-- Load service implementation
local function load_implementation()
    local impl = require "service_implementation"
    return impl.new(service_interface)
end

local current_impl = load_implementation()

-- State management for reload
local function save_state()
    return current_impl.get_state()
end

local function restore_state(state)
    if current_impl.set_state then
        current_impl.set_state(state)
    end
end

-- Reload handler
local function reload_service()
    if reload_in_progress then
        return false, "Reload already in progress"
    end
    
    reload_in_progress = true
    skynet.error("Starting service reload...")
    
    -- Save current state
    local state = save_state()
    
    -- Wait for pending operations
    local deadline = skynet.time() + 10  -- 10 second timeout
    while next(pending_operations) and skynet.time() < deadline do
        skynet.sleep(10)
    end
    
    if next(pending_operations) then
        reload_in_progress = false
        return false, "Timeout waiting for pending operations"
    end
    
    -- Load new implementation
    local ok, new_impl = pcall(load_implementation)
    if not ok then
        reload_in_progress = false
        return false, "Failed to load new implementation: " .. new_impl
    end
    
    -- Switch implementation
    local old_impl = current_impl
    current_impl = new_impl
    service_version = service_version + 1
    
    -- Restore state
    restore_state(state)
    
    -- Cleanup old implementation
    if old_impl.cleanup then
        old_impl.cleanup()
    end
    
    -- Clear package cache to allow module reload
    package.loaded["service_implementation"] = nil
    
    reload_in_progress = false
    skynet.error("Service reloaded successfully, version:", service_version)
    return true, service_version
end

skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        if cmd == "reload" then
            local ok, result = reload_service()
            skynet.ret(skynet.pack(ok, result))
            
        elseif cmd == "get_version" then
            skynet.ret(skynet.pack(service_version))
            
        elseif cmd == "process" then
            -- Track operation for reload safety
            local op_id = generate_uuid()
            pending_operations[op_id] = true
            
            -- Process request
            local result = current_impl.process_request(...)
            
            -- Clear tracking
            pending_operations[op_id] = nil
            
            skynet.ret(skynet.pack(result))
            
        else
            -- Forward to implementation
            local handler = current_impl[cmd]
            if handler then
                skynet.ret(skynet.pack(handler(...)))
            else
                skynet.ret(skynet.pack(false, "Unknown command"))
            end
        end
    end)
    
    -- Register service
    skynet.register("HOT_RELOADABLE_SERVICE")
    
    skynet.exit()
end)
```

### 1.2 Module Reload System

```lua
-- module_reloader.lua
local skynet = require "skynet"

local reloader = {}
local module_versions = {}
local reload_hooks = {}

local function reload_module(module_name)
    -- Check if module has reload hook
    local hook = reload_hooks[module_name]
    if hook and hook.before_reload then
        hook.before_reload()
    end
    
    -- Save version if exists
    local old_version = module_versions[module_name]
    
    -- Clear from package cache
    package.loaded[module_name] = nil
    package.loaded[module_name .. ".init"] = nil
    
    -- Clear submodules
    for k, _ in pairs(package.loaded) do
        if k:match("^" .. module_name .. "%.") then
            package.loaded[k] = nil
        end
    end
    
    -- Load new version
    local ok, new_module = pcall(require, module_name)
    if not ok then
        -- Restore old version if available
        if old_version then
            package.loaded[module_name] = old_version
        end
        return false, "Reload failed: " .. new_module
    end
    
    -- Store new version
    module_versions[module_name] = new_module
    
    -- Call after reload hook
    if hook and hook.after_reload then
        hook.after_reload(old_version, new_module)
    end
    
    return true
end

function reloader.register_reload_hook(module_name, hook)
    reload_hooks[module_name] = hook
end

function reloader.reload_module(module_name)
    return reload_module(module_name)
end

function reloader.reload_all()
    local results = {}
    for module_name, _ in pairs(reload_hooks) do
        results[module_name] = reload_module(module_name)
    end
    return results
end

return reloader
```

## 2. Advanced Debugging

### 2.1 Debug Console Extensions

```lua
-- enhanced_debug_console.lua
local skynet = require "skynet"

local debug_commands = {}

-- Enhanced service inspection
function debug_commands.SERVICE_INFO(service_addr)
    local info = {}
    
    -- Get basic info
    local basic_info = skynet.call(service_addr, "debug", "info")
    info.basic = basic_info
    
    -- Get memory usage
    local mem = skynet.call(service_addr, "debug", "mem")
    info.memory = mem
    
    -- Get message stats
    local stats = skynet.call(service_addr, "debug", "stats")
    info.stats = stats
    
    -- Get custom metrics if available
    local ok, metrics = pcall(skynet.call, service_addr, "debug", "metrics")
    if ok then
        info.metrics = metrics
    end
    
    return info
end

-- Service profiling
function debug_commands.PROFILE(service_addr, duration)
    duration = duration or 10  -- Default 10 seconds
    
    -- Start profiling
    skynet.send(service_addr, "debug", "start_profile")
    
    -- Wait for duration
    skynet.sleep(duration * 100)
    
    -- Get profile data
    local profile_data = skynet.call(service_addr, "debug", "get_profile")
    return profile_data
end

-- Message tracing
function debug_commands.TRACE(service_addr, enable)
    if enable then
        skynet.send(service_addr, "debug", "trace_on")
    else
        skynet.send(service_addr, "debug", "trace_off")
    end
    return true
end

-- Service dependency graph
function debug_commands.DEP_GRAPH(root_service)
    local graph = {}
    local visited = {}
    
    local function visit_service(service)
        if visited[service] then return end
        visited[service] = true
        
        local deps = skynet.call(service, "debug", "dependencies")
        graph[service] = deps
        
        for _, dep in ipairs(deps) do
            visit_service(dep)
        end
    end
    
    visit_service(root_service)
    return graph
end

-- Memory leak detection
function debug_commands.MEM_LEAK_CHECK(service_addr)
    -- Force GC
    skynet.send(service_addr, "debug", "gc")
    
    -- Get initial memory
    local initial_mem = skynet.call(service_addr, "debug", "mem")
    
    -- Wait for some activity
    skynet.sleep(500)  -- 5 seconds
    
    -- Force GC again
    skynet.send(service_addr, "debug", "gc")
    
    -- Get final memory
    local final_mem = skynet.call(service_addr, "debug", "mem")
    
    local leak_detected = final_mem > initial_mem * 1.1  -- 10% threshold
    
    return {
        initial_memory = initial_mem,
        final_memory = final_mem,
        leak_detected = leak_detected,
        increase = final_mem - initial_mem
    }
end

skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local command = debug_commands[cmd:upper()]
        if command then
            skynet.ret(skynet.pack(command(...)))
        else
            skynet.ret(skynet.pack(false, "Unknown debug command"))
        end
    end)
    
    skynet.register("ENHANCED_DEBUG_CONSOLE")
end)
```

### 2.2 Performance Profiler

```lua
-- service_profiler.lua
local skynet = require "skynet"

local profiler = {
    enabled = false,
    data = {},
    start_time = 0
}

function profiler.start()
    profiler.enabled = true
    profiler.data = {}
    profiler.start_time = skynet.now()
    
    -- Hook message dispatch
    local original_dispatch = skynet.dispatch
    skynet.dispatch = function(proto, handler)
        if proto == "lua" and profiler.enabled then
            local wrapped_handler = function(session, source, cmd, ...)
                local start_time = skynet.now()
                
                -- Call original handler
                local results = {pcall(handler, session, source, cmd, ...)}
                
                local end_time = skynet.now()
                local duration = end_time - start_time
                
                -- Record metrics
                profiler.record_metrics(cmd, duration, results[1])
                
                -- Return results
                if results[1] then
                    skynet.ret(skynet.pack(unpack(results, 2)))
                else
                    skynet.ret(skynet.pack(false, results[2]))
                end
            end
            original_dispatch(proto, wrapped_handler)
        else
            original_dispatch(proto, handler)
        end
    end
end

function profiler.record_metrics(cmd, duration, success)
    if not profiler.data[cmd] then
        profiler.data[cmd] = {
            count = 0,
            total_time = 0,
            min_time = math.huge,
            max_time = 0,
            errors = 0
        }
    end
    
    local metrics = profiler.data[cmd]
    metrics.count = metrics.count + 1
    metrics.total_time = metrics.total_time + duration
    metrics.min_time = math.min(metrics.min_time, duration)
    metrics.max_time = math.max(metrics.max_time, duration)
    
    if not success then
        metrics.errors = metrics.errors + 1
    end
end

function profiler.get_profile()
    local profile = {
        total_time = skynet.now() - profiler.start_time,
        commands = {}
    }
    
    for cmd, metrics in pairs(profiler.data) do
        profile.commands[cmd] = {
            count = metrics.count,
            total_time = metrics.total_time,
            avg_time = metrics.total_time / metrics.count,
            min_time = metrics.min_time,
            max_time = metrics.max_time,
            error_rate = metrics.errors / metrics.count,
            percentage = (metrics.total_time / profile.total_time) * 100
        }
    end
    
    return profile
end

function profiler.stop()
    profiler.enabled = false
    return profiler.get_profile()
end

return profiler
```

## 3. Performance Optimization

### 3.1 Connection Pool Optimization

```lua
-- optimized_connection_pool.lua
local skynet = require "skynet"

local connection_pool = {}
local pool_config = {
    min_connections = 5,
    max_connections = 50,
    max_idle_time = 300,  -- seconds
    health_check_interval = 60
}

local function create_connection(config)
    -- Create actual connection
    local conn = {
        created = skynet.time(),
        last_used = skynet.time(),
        busy = false,
        config = config
    }
    
    -- Initialize connection
    local ok, err = pcall(initialize_connection, conn)
    if not ok then
        return nil, err
    end
    
    return conn
end

local function get_connection(pool_name)
    local pool = connection_pool[pool_name]
    if not pool then
        return nil, "Pool not found"
    end
    
    -- Find idle connection
    for _, conn in ipairs(pool.idle) do
        if not conn.busy then
            conn.busy = true
            conn.last_used = skynet.time()
            table.remove(pool.idle, _.index)
            table.insert(pool.busy, conn)
            return conn
        end
    end
    
    -- Create new connection if under max
    if #pool.idle + #pool.busy < pool_config.max_connections then
        local conn = create_connection(pool.config)
        if conn then
            conn.busy = true
            table.insert(pool.busy, conn)
            return conn
        end
    end
    
    return nil, "No available connections"
end

local function release_connection(pool_name, conn)
    local pool = connection_pool[pool_name]
    if not pool then return end
    
    -- Remove from busy
    for i, c in ipairs(pool.busy) do
        if c == conn then
            table.remove(pool.busy, i)
            break
        end
    end
    
    -- Check if connection is still healthy
    if is_connection_healthy(conn) then
        conn.busy = false
        conn.last_used = skynet.time()
        table.insert(pool.idle, conn)
    else
        -- Close unhealthy connection
        close_connection(conn)
    end
end

local function cleanup_idle_connections()
    for pool_name, pool in pairs(connection_pool) do
        local current_time = skynet.time()
        local to_remove = {}
        
        for i, conn in ipairs(pool.idle) do
            if current_time - conn.last_used > pool_config.max_idle_time then
                table.insert(to_remove, i)
            end
        end
        
        -- Remove from end to maintain indices
        for i = #to_remove, 1, -1 do
            local conn = table.remove(pool.idle, to_remove[i])
            close_connection(conn)
        end
        
        -- Maintain minimum connections
        while #pool.idle < pool_config.min_connections and 
              #pool.idle + #pool.busy < pool_config.max_connections do
            local conn = create_connection(pool.config)
            if conn then
                table.insert(pool.idle, conn)
            else
                break
            end
        end
    end
end

-- Start cleanup timer
skynet.timeout(pool_config.health_check_interval * 100, function()
    cleanup_idle_connections()
    skynet.timeout(pool_config.health_check_interval * 100, cleanup_idle_connections)
end)
```

### 3.2 Message Queue Optimization

```lua
-- message_queue_optimizer.lua
local skynet = require "skynet"

local queue_optimizer = {
    batch_size = 10,
    batch_timeout = 50,  -- milliseconds
    priority_levels = 3
}

local priority_queues = {}
local batch_timers = {}

local function process_batch(queue_name)
    local queue = priority_queues[queue_name]
    if not queue or #queue == 0 then return end
    
    -- Get batch
    local batch = {}
    local batch_size = math.min(queue_optimizer.batch_size, #queue)
    
    for i = 1, batch_size do
        table.insert(batch, table.remove(queue, 1))
    end
    
    -- Process batch
    local results = {}
    for _, item in ipairs(batch) do
        local result = process_message(item)
        table.insert(results, result)
    end
    
    -- Send responses
    for i, item in ipairs(batch) do
        if item.callback then
            item.callback(results[i])
        end
    end
    
    -- Schedule next batch if more items
    if #queue > 0 then
        batch_timers[queue_name] = skynet.timeout(
            queue_optimizer.batch_timeout, 
            function()
                process_batch(queue_name)
            end
        )
    else
        batch_timers[queue_name] = nil
    end
end

function queue_optimizer.enqueue(queue_name, message, priority, callback)
    priority = priority or 1  -- Default priority
    
    if not priority_queues[queue_name] then
        priority_queues[queue_name] = {}
    end
    
    -- Insert based on priority
    local queue = priority_queues[queue_name]
    local inserted = false
    
    for i, item in ipairs(queue) do
        if item.priority < priority then
            table.insert(queue, i, {
                message = message,
                priority = priority,
                callback = callback,
                timestamp = skynet.time()
            })
            inserted = true
            break
        end
    end
    
    if not inserted then
        table.insert(queue, {
            message = message,
            priority = priority,
            callback = callback,
            timestamp = skynet.time()
        })
    end
    
    -- Start batch processing if not running
    if not batch_timers[queue_name] then
        batch_timers[queue_name] = skynet.timeout(
            queue_optimizer.batch_timeout, 
            function()
                process_batch(queue_name)
            end
        )
    end
end
```

## 4. Memory Management

### 4.1 Memory Leak Detector

```lua
-- memory_leak_detector.lua
local skynet = require "skynet"

local leak_detector = {
    snapshots = {},
    allocations = {},
    tracking_enabled = false
}

function leak_detector.start_tracking()
    leak_detector.tracking_enabled = true
    leak_detector.allocations = {}
    
    -- Hook table creation
    local original_table = {}
    setmetatable(table, {
        __index = function(t, k)
            if k == "new" or k == "create" then
                return function(...)
                    local tbl = original_table[k](...)
                    if leak_detector.tracking_enabled then
                        leak_detector.track_allocation(tbl, debug.traceback())
                    end
                    return tbl
                end
            end
            return original_table[k]
        end
    })
    
    original_table.new = table.new or function() return {} end
    original_table.create = table.create or function(n) return {} end
end

function leak_detector.track_allocation(obj, stacktrace)
    local id = tostring(obj)
    leak_detector.allocations[id] = {
        object = obj,
        stacktrace = stacktrace,
        timestamp = skynet.time(),
        type = type(obj)
    }
end

function leak_detector.take_snapshot(name)
    local snapshot = {
        name = name,
        timestamp = skynet.time(),
        memory = collectgarbage("count"),
        allocations = {}
    }
    
    -- Copy current allocations
    for id, alloc in pairs(leak_detector.allocations) do
        snapshot.allocations[id] = {
            type = alloc.type,
            timestamp = alloc.timestamp,
            stacktrace = alloc.stacktrace
        }
    end
    
    table.insert(leak_detector.snapshots, snapshot)
    return snapshot
end

function leak_detector.compare_snapshots(name1, name2)
    local snap1, snap2
    
    for _, snap in ipairs(leak_detector.snapshots) do
        if snap.name == name1 then snap1 = snap end
        if snap.name == name2 then snap2 = snap end
    end
    
    if not snap1 or not snap2 then
        return nil, "Snapshots not found"
    end
    
    local leaks = {}
    
    -- Find allocations in snap2 but not in snap1
    for id, alloc2 in pairs(snap2.allocations) do
        if not snap1.allocations[id] then
            table.insert(leaks, {
                id = id,
                type = alloc2.type,
                allocated = alloc2.timestamp,
                age = snap2.timestamp - alloc2.timestamp,
                stacktrace = alloc2.stacktrace
            })
        end
    end
    
    return {
        memory_increase = snap2.memory - snap1.memory,
        time_elapsed = snap2.timestamp - snap1.timestamp,
        potential_leaks = leaks
    }
end

function leak_detector.generate_report()
    local report = {
        current_memory = collectgarbage("count"),
        active_allocations = 0,
        oldest_allocation = 0,
        allocation_types = {}
    }
    
    local oldest_time = skynet.time()
    
    for _, alloc in pairs(leak_detector.allocations) do
        report.active_allocations = report.active_allocations + 1
        
        if alloc.timestamp < oldest_time then
            oldest_time = alloc.timestamp
            report.oldest_allocation = skynet.time() - alloc.timestamp
        end
        
        report.allocation_types[alloc.type] = 
            (report.allocation_types[alloc.type] or 0) + 1
    end
    
    return report
end
```

### 4.2 Object Pool

```lua
-- object_pool.lua
local skynet = require "skynet"

local object_pool = {}
local pools = {}

local function create_pool(pool_name, factory, reset_fn)
    pools[pool_name] = {
        available = {},
        in_use = {},
        factory = factory,
        reset = reset_fn or function(obj) end,
        created = 0,
        max_size = 1000
    }
end

local function get_object(pool_name)
    local pool = pools[pool_name]
    if not pool then
        return nil, "Pool not found"
    end
    
    -- Get from available pool
    if #pool.available > 0 then
        local obj = table.remove(pool.available)
        table.insert(pool.in_use, obj)
        return obj
    end
    
    -- Create new object
    if #pool.in_use < pool.max_size then
        local obj = pool.factory()
        pool.created = pool.created + 1
        table.insert(pool.in_use, obj)
        return obj
    end
    
    return nil, "Pool exhausted"
end

local function release_object(pool_name, obj)
    local pool = pools[pool_name]
    if not pool then return end
    
    -- Find in use pool
    for i, o in ipairs(pool.in_use) do
        if o == obj then
            table.remove(pool.in_use, i)
            
            -- Reset object
            pool.reset(obj)
            
            -- Return to available pool
            table.insert(pool.available, obj)
            break
        end
    end
end

local function cleanup_pool(pool_name)
    local pool = pools[pool_name]
    if not pool then return end
    
    -- Keep some objects for future use
    local keep_count = math.min(10, #pool.available)
    local to_remove = #pool.available - keep_count
    
    for i = 1, to_remove do
        local obj = table.remove(pool.available)
        -- Let GC handle it
    end
end

return {
    create = create_pool,
    get = get_object,
    release = release_object,
    cleanup = cleanup_pool
}
```

## 5. Security Best Practices

### 5.1 Service Authentication

```lua
-- service_auth.lua
local skynet = require "skynet"
local crypt = require "skynet.crypt"

local auth_system = {
    tokens = {},
    services = {},
    secret_key = "your-secret-key-here"
}

function auth_system.generate_token(service_name, ttl)
    ttl = ttl or 3600  -- 1 hour default
    
    local expires = skynet.time() + ttl
    local data = string.format("%s:%d", service_name, expires)
    local signature = crypt.hmac_sha256(auth_system.secret_key, data)
    
    local token = string.format("%s:%s", data, signature)
    auth_system.tokens[token] = true
    
    -- Set expiration
    skynet.timeout(ttl * 100, function()
        auth_system.tokens[token] = nil
    end)
    
    return token
end

function auth_system.validate_token(token)
    if not auth_system.tokens[token] then
        return false
    end
    
    -- Parse token
    local data, signature = token:match("^(.+):(.+)$")
    if not data or not signature then
        return false
    end
    
    -- Verify signature
    local expected_sig = crypt.hmac_sha256(auth_system.secret_key, data)
    if signature ~= expected_sig then
        return false
    end
    
    -- Check expiration
    local service_name, expires = data:match("^(.+):(%d+)$")
    if not service_name or not expires then
        return false
    end
    
    if tonumber(expires) < skynet.time() then
        return false
    end
    
    return service_name
end

function auth_system.wrap_service(service_name, service_addr)
    return {
        call = function(cmd, ...)
            local token = auth_system.generate_token(service_name)
            return skynet.call(service_addr, "lua", "authenticated_call", 
                               token, cmd, ...)
        end,
        send = function(cmd, ...)
            local token = auth_system.generate_token(service_name)
            skynet.send(service_addr, "lua", "authenticated_send", 
                       token, cmd, ...)
        end
    }
end

-- Authentication middleware
local function create_auth_middleware(next_handler)
    return function(session, source, cmd, ...)
        if cmd == "authenticated_call" or cmd == "authenticated_send" then
            local token, real_cmd = ...
            local service_name = auth_system.validate_token(token)
            
            if service_name then
                if cmd == "authenticated_call" then
                    local result = next_handler(session, source, real_cmd, 
                                              select(3, ...))
                    skynet.ret(skynet.pack(result))
                else
                    next_handler(session, source, real_cmd, select(3, ...))
                end
            else
                skynet.ret(skynet.pack(false, "Invalid token"))
            end
        else
            next_handler(session, source, cmd, ...)
        end
    end
end
```

### 5.2 Rate Limiting Middleware

```lua
-- rate_limiter.lua
local skynet = require "skynet"

local rate_limiter = {
    limits = {},
    counters = {}
}

function rate_limiter.set_limit(key, rate, burst)
    rate_limiter.limits[key] = {
        rate = rate,      -- requests per second
        burst = burst,    -- maximum burst size
        tokens = burst,
        last_update = skynet.time()
    }
end

local function update_tokens(key)
    local limit = rate_limiter.limits[key]
    if not limit then return false end
    
    local now = skynet.time()
    local elapsed = now - limit.last_update
    
    -- Add tokens based on elapsed time
    limit.tokens = math.min(limit.burst, 
                           limit.tokens + elapsed * limit.rate)
    limit.last_update = now
    
    return limit.tokens > 0
end

function rate_limiter.check(key, cost)
    cost = cost or 1
    
    if not rate_limiter.limits[key] then
        -- Default limit if not set
        rate_limiter.set_limit(key, 10, 20)
    end
    
    if update_tokens(key) then
        local limit = rate_limiter.limits[key]
        if limit.tokens >= cost then
            limit.tokens = limit.tokens - cost
            return true
        end
    end
    
    return false
end

-- Rate limiting middleware
function rate_limiter.middleware(next_handler, get_key_fn)
    return function(session, source, cmd, ...)
        local key = get_key_fn(source, cmd)
        
        if rate_limiter.check(key) then
            next_handler(session, source, cmd, ...)
        else
            skynet.ret(skynet.pack(false, "Rate limit exceeded"))
        end
    end
end
```

## 6. Testing Framework

### 6.1 Unit Testing Helper

```lua
-- skynet_test.lua
local skynet = require "skynet"

local test_framework = {
    tests = {},
    suites = {},
    current_suite = nil
}

function test_framework.suite(name)
    test_framework.current_suite = name
    test_framework.suites[name] = test_framework.suites[name] or {}
    return test_framework
end

function test_framework.test(name, test_fn)
    if not test_framework.current_suite then
        error("No test suite defined")
    end
    
    table.insert(test_framework.suites[test_framework.current_suite], {
        name = name,
        fn = test_fn
    })
end

function test_framework.assert(condition, message)
    if not condition then
        error(message or "Assertion failed")
    end
end

function test_framework.equal(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", 
                           message or "Values not equal", 
                           tostring(expected), tostring(actual)))
    end
end

function test_framework.run_suite(suite_name)
    local suite = test_framework.suites[suite_name]
    if not suite then
        return false, "Suite not found"
    end
    
    local results = {
        passed = 0,
        failed = 0,
        errors = {}
    }
    
    for _, test in ipairs(suite) do
        local ok, err = pcall(test.fn)
        if ok then
            results.passed = results.passed + 1
        else
            results.failed = results.failed + 1
            table.insert(results.errors, {
                test = test.name,
                error = err
            })
        end
    end
    
    return results
end

function test_framework.run_all()
    local total_results = {
        suites = {},
        total_passed = 0,
        total_failed = 0
    }
    
    for suite_name, _ in pairs(test_framework.suites) do
        local results = test_framework.run_suite(suite_name)
        total_results.suites[suite_name] = results
        total_results.total_passed = total_results.total_passed + results.passed
        total_results.total_failed = total_results.total_failed + results.failed
    end
    
    return total_results
end

-- Mock service for testing
function test_framework.create_mock_service(responses)
    local mock_service = skynet.newservice("mock_service")
    
    skynet.send(mock_service, "lua", "set_responses", responses)
    
    return {
        address = mock_service,
        expect_call = function(cmd, ...)
            local expected_responses = responses[cmd]
            if expected_responses then
                return expected_responses[1]
            end
            return nil
        end
    }
end

return test_framework
```

### 6.2 Integration Testing

```lua
-- integration_test.lua
local skynet = require "skynet"
local test_framework = require "skynet_test"

test_framework.suite("Integration Tests")

test_framework.test("Service Communication", function()
    -- Create test services
    local service1 = skynet.newservice("test_service1")
    local service2 = skynet.newservice("test_service2")
    
    -- Test communication
    local result = skynet.call(service1, "lua", "call_service2", service2)
    test_framework.equal(result, "success")
    
    -- Cleanup
    skynet.kill(service1)
    skynet.kill(service2)
end)

test_framework.test("Message Queue", function()
    local queue_service = skynet.newservice("queue_service")
    
    -- Enqueue messages
    for i = 1, 10 do
        skynet.send(queue_service, "lua", "enqueue", "message" .. i)
    end
    
    -- Dequeue and verify
    for i = 1, 10 do
        local msg = skynet.call(queue_service, "lua", "dequeue")
        test_framework.equal(msg, "message" .. i)
    end
    
    skynet.kill(queue_service)
end)

-- Test runner service
skynet.start(function()
    local results = test_framework.run_all()
    
    -- Print results
    print("\nTest Results:")
    print("============")
    
    for suite_name, suite_results in pairs(results.suites) do
        print("\nSuite:", suite_name)
        print("Passed:", suite_results.passed)
        print("Failed:", suite_results.failed)
        
        for _, error in ipairs(suite_results.errors) do
            print("FAIL:", error.test, "-", error.error)
        end
    end
    
    print("\nTotal:")
    print("Passed:", results.total_passed)
    print("Failed:", results.total_failed)
    
    skynet.exit()
end)
```

## 7. Monitoring and Metrics

### 7.1 Metrics Collector

```lua
-- metrics_collector.lua
local skynet = require "skynet"

local metrics = {
    counters = {},
    gauges = {},
    histograms = {},
    timers = {}
}

function metrics.counter(name)
    if not metrics.counters[name] then
        metrics.counters[name] = 0
    end
    return {
        inc = function(value)
            value = value or 1
            metrics.counters[name] = metrics.counters[name] + value
        end,
        get = function()
            return metrics.counters[name]
        end,
        reset = function()
            metrics.counters[name] = 0
        end
    }
end

function metrics.gauge(name)
    if not metrics.gauges[name] then
        metrics.gauges[name] = 0
    end
    return {
        set = function(value)
            metrics.gauges[name] = value
        end,
        get = function()
            return metrics.gauges[name]
        end,
        inc = function(value)
            value = value or 1
            metrics.gauges[name] = metrics.gauges[name] + value
        end,
        dec = function(value)
            value = value or 1
            metrics.gauges[name] = metrics.gauges[name] - value
        end
    }
end

function metrics.histogram(name, buckets)
    buckets = buckets or {10, 50, 100, 500, 1000}
    
    if not metrics.histograms[name] then
        metrics.histograms[name] = {
            buckets = buckets,
            counts = {},
            sum = 0,
            count = 0
        }
        
        -- Initialize bucket counts
        for _, bucket in ipairs(buckets) do
            metrics.histograms[name].counts[bucket] = 0
        end
        metrics.histograms[name].counts.inf = 0
    end
    
    return {
        observe = function(value)
            local hist = metrics.histograms[name]
            hist.sum = hist.sum + value
            hist.count = hist.count + 1
            
            -- Find appropriate bucket
            for _, bucket in ipairs(hist.buckets) do
                if value <= bucket then
                    hist.counts[bucket] = hist.counts[bucket] + 1
                    return
                end
            end
            
            -- Value larger than all buckets
            hist.counts.inf = hist.counts.inf + 1
        end,
        get = function()
            return metrics.histograms[name]
        end
    }
end

function metrics.timer(name)
    local histogram = metrics.histogram(name)
    
    return {
        time = function(fn)
            local start = skynet.now()
            fn()
            local duration = skynet.now() - start
            histogram.observe(duration)
        end,
        distribution = function()
            return histogram.get()
        end
    }
end

function metrics.export_prometheus()
    local output = {}
    
    -- Export counters
    for name, value in pairs(metrics.counters) do
        table.insert(output, string.format(
            "# TYPE %s counter\n%s %d", name, name, value))
    end
    
    -- Export gauges
    for name, value in pairs(metrics.gauges) do
        table.insert(output, string.format(
            "# TYPE %s gauge\n%s %d", name, name, value))
    end
    
    -- Export histograms
    for name, hist in pairs(metrics.histograms) do
        table.insert(output, string.format(
            "# TYPE %s histogram", name))
        
        -- Add bucket counts
        for bucket, count in pairs(hist.counts) do
            if bucket ~= "inf" then
                table.insert(output, string.format(
                    "%s_bucket{le=\"%d\"} %d", name, bucket, count))
            else
                table.insert(output, string.format(
                    "%s_bucket{le=\"+Inf\"} %d", name, count))
            end
        end
        
        -- Add sum and count
        table.insert(output, string.format(
            "%s_sum %d", name, hist.sum))
        table.insert(output, string.format(
            "%s_count %d", name, hist.count))
    end
    
    return table.concat(output, "\n") .. "\n"
end

-- Start metrics endpoint
skynet.start(function()
    local httpd = require "http.httpd"
    local sockethelper = require "http.sockethelper"
    
    local function handle_metrics(id)
        sockethelper.init(id)
        
        local code, url = httpd.read_request(sockethelper.readfunc(id))
        if code ~= 200 or url ~= "/metrics" then
            httpd.write_response(sockethelper.writefunc(id), 404, "Not Found")
            return
        end
        
        local metrics_data = metrics.export_prometheus()
        
        httpd.write_response(sockethelper.writefunc(id), 200, metrics_data, {
            ["Content-Type"] = "text/plain"
        })
    end
    
    local socket = require "skynet.socket"
    local fd = socket.listen("0.0.0.0", 9090)
    
    socket.start(fd, function(fd, addr)
        skynet.fork(handle_metrics, fd)
    end)
    
    skynet.error("Metrics server started on port 9090")
end)
```

## 8. Example: Production-Ready Service

```lua
-- production_service.lua
local skynet = require "skynet"
local metrics = require "metrics"
local profiler = require "service_profiler"
local auth = require "service_auth"
local rate_limiter = require "rate_limiter"

-- Initialize metrics
local request_count = metrics.counter("requests_total")
local request_duration = metrics.histogram("request_duration_seconds")
local active_connections = metrics.gauge("active_connections")

-- Service configuration
local config = {
    max_connections = 1000,
    request_timeout = 30,
    enable_profiling = false
}

-- Service state
local state = {
    connections = 0,
    data = {},
    last_gc = skynet.time()
}

-- Request handler with middleware
local function handle_request(session, source, cmd, ...)
    -- Rate limiting
    if not rate_limiter.check(source, 1) then
        return false, "Rate limit exceeded"
    end
    
    -- Metrics
    request_count.inc()
    local timer = request_duration.time()
    
    -- Process request
    local result = process_command(cmd, ...)
    
    -- Complete timing
    timer()
    
    return result
end

-- Middleware chain
local function middleware_chain(next_handler)
    return auth.middleware(
        rate_limiter.middleware(next_handler, function(source)
            return source
        end)
    )
end

-- Service entry point
skynet.start(function()
    -- Initialize
    initialize_service()
    
    -- Start background tasks
    start_background_tasks()
    
    -- Register wrapped handler
    local wrapped_handler = middleware_chain(handle_request)
    skynet.dispatch("lua", wrapped_handler)
    
    -- Register service
    skynet.register("PRODUCTION_SERVICE")
    
    skynet.exit()
end)

function initialize_service()
    -- Load configuration
    local config_service = skynet.query("CONFIG_SERVICE")
    if config_service then
        local remote_config = skynet.call(config_service, "lua", "get", 
                                         "PRODUCTION_SERVICE")
        if remote_config then
            for k, v in pairs(remote_config) do
                config[k] = v
            end
        end
    end
    
    -- Initialize state
    load_persistent_state()
end

function start_background_tasks()
    -- GC task
    skynet.timeout(60000, function()
        collectgarbage("collect")
        state.last_gc = skynet.time()
        skynet.timeout(60000, start_background_tasks)
    end)
    
    -- Metrics export
    skynet.newservice("metrics_exporter")
    
    -- Health check
    skynet.timeout(30000, function()
        perform_health_check()
        skynet.timeout(30000, perform_health_check)
    end)
end

function process_command(cmd, ...)
    local handlers = {
        get_data = function(key)
            return state.data[key]
        end,
        set_data = function(key, value)
            state.data[key] = value
            save_persistent_state()
            return true
        end,
        get_status = function()
            return {
                uptime = skynet.time() - state.start_time,
                connections = state.connections,
                memory = collectgarbage("count"),
                version = "1.0.0"
            }
        end
    }
    
    local handler = handlers[cmd]
    if handler then
        return handler(...)
    else
        return false, "Unknown command"
    end
end
```

## 9. Exercise: High-Performance Trading System

Create a high-performance trading system with:
1. Microsecond-level latency tracking
2. Order book management
3. Risk management checks
4. Audit trail for compliance
5. Real-time analytics dashboard

**Requirements**:
- Sub-millisecond order processing
- Persistent order storage
- Circuit breaker for market volatility
- Multi-asset support
- Real-time P&L calculation

## Summary

In this tutorial, you learned:
- Hot-reloading services without downtime
- Advanced debugging and profiling techniques
- Performance optimization strategies
- Memory management and leak detection
- Security best practices
- Testing and monitoring frameworks
- Building production-ready services

## Conclusion

You have now completed the comprehensive Skynet tutorial series. You should have a deep understanding of Skynet's architecture and be able to build complex, distributed, high-performance applications using Skynet. 

Continue exploring the Skynet ecosystem and contributing to the community!
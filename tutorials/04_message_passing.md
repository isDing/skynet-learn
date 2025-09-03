# Message Passing and Communication

## What You'll Learn
- Advanced message passing patterns in Skynet
- Different types of inter-service communication
- Request-response protocols
- Event-driven communication
- Performance optimization techniques

## Prerequisites
- Completed Tutorial 3: Creating Your First Service
- Understanding of basic Skynet message passing
- Familiarity with Lua coroutines

## Time Estimate
50 minutes

## Final Result
Ability to design efficient communication patterns between services and implement complex message flows

---

## 1. Message Passing Fundamentals

### 1.1 Message Types and Protocols

Skynet supports multiple message types, each with specific use cases:

```lua
-- Built-in protocol types
skynet.PTYPE_TEXT = 0        -- Simple text messages
skynet.PTYPE_RESPONSE = 1    -- Response messages
skynet.PTYPE_CLIENT = 3      -- Client socket messages
skynet.PTYPE_LUA = 10        -- Lua RPC calls
skynet.PTYPE_SOCKET = 6      -- Socket events
skynet.PTYPE_ERROR = 7       -- Error notifications
skynet.PTYPE_QUEUE = 8       -- Queue messages
skynet.PTYPE_DEBUG = 9       -- Debug messages
skynet.PTYPE_TRACE = 12      -- Trace messages
```

### 1.2 Registering Custom Protocols

```lua
-- Register a custom protocol
skynet.register_protocol {
    name = "myproto",
    id = 20,  -- 0-255
    pack = function(...) 
        return string.pack("z", ...)  -- Serialize
    end,
    unpack = function(msg, sz)
        return string.unpack("z", msg, sz)  -- Deserialize
    end
}

-- Dispatch custom protocol messages
skynet.dispatch("myproto", function(session, source, ...)
    -- Handle custom protocol
end)
```

## 2. Communication Patterns

### 2.1 Request-Response Pattern

The most common pattern for synchronous communication:

```lua
-- Service A: Send request
local function get_user_data(user_id)
    local user_service = skynet.query("USER_SERVICE")
    local ok, user_data = skynet.call(user_service, "lua", "get_user", user_id)
    if not ok then
        skynet.error("Failed to get user:", user_data)
        return nil
    end
    return user_data
end

-- Service B: Handle request
skynet.dispatch("lua", function(session, source, cmd, ...)
    if cmd == "get_user" then
        local user_id = ...
        local user_data = database.get_user(user_id)
        skynet.ret(skynet.pack(true, user_data))
    end
end)
```

### 2.2 Asynchronous Fire-and-Forget

For operations that don't need immediate response:

```lua
-- Send without waiting
skynet.send(logger_service, "lua", "log", "User login", user_id)

-- Handle asynchronously
skynet.dispatch("lua", function(session, source, cmd, ...)
    if cmd == "log" then
        local event, user_id = ...
        -- Process without response
        write_to_log(event, user_id, skynet.time())
        -- No skynet.ret() needed
    end
end)
```

### 2.3 Pub/Sub Pattern

For event broadcasting:

```lua
-- Publisher service
local subscribers = {}

skynet.dispatch("lua", function(session, source, cmd, ...)
    if cmd == "subscribe" then
        local topic = ...
        subscribers[topic] = subscribers[topic] or {}
        subscribers[topic][source] = true
        skynet.ret()
    elseif cmd == "publish" then
        local topic, message = ...
        if subscribers[topic] then
            for subscriber, _ in pairs(subscribers[topic]) do
                skynet.send(subscriber, "lua", "notify", topic, message)
            end
        end
        skynet.ret()
    end
end)
```

## 3. Advanced Message Handling

### 3.1 Multi-step Requests

Handling complex operations that require multiple steps:

```lua
-- Complex order processing
skynet.dispatch("lua", function(session, source, cmd, ...)
    if cmd == "process_order" then
        local order_id, user_id, items = ...
        
        -- Step 1: Validate inventory
        local inventory_service = skynet.query("INVENTORY")
        local ok, available = skynet.call(inventory_service, "lua", 
                                          "check_inventory", items)
        if not ok or not available then
            skynet.ret(skynet.pack(false, "Items not available"))
            return
        end
        
        -- Step 2: Process payment
        local payment_service = skynet.query("PAYMENT")
        local ok, transaction_id = skynet.call(payment_service, "lua", 
                                               "process_payment", user_id, 
                                               calculate_total(items))
        if not ok then
            skynet.ret(skynet.pack(false, "Payment failed"))
            return
        end
        
        -- Step 3: Update inventory
        skynet.call(inventory_service, "lua", "update_inventory", items)
        
        -- Step 4: Create order record
        local order_service = skynet.query("ORDER")
        skynet.call(order_service, "lua", "create_order", 
                   order_id, user_id, items, transaction_id)
        
        -- Return success
        skynet.ret(skynet.pack(true, transaction_id))
    end
end)
```

### 3.2 Message Forwarding

Efficiently forward messages without serialization overhead:

```lua
-- Gateway service that forwards messages
skynet.dispatch("lua", function(session, source, cmd, ...)
    if cmd == "forward" then
        local target_service, msg, sz = ...
        -- Forward without unpacking/repacking
        skynet.redirect(target_service, source, "lua", session, msg, sz)
        -- Don't call skynet.ret() - redirect handles response
    end
end)
```

### 3.3 Message Aggregation

Combine multiple responses:

```lua
-- Aggregator service
local function aggregate_data(sources, query)
    local responses = {}
    local pending = #sources
    local response_session = coroutine.running()
    
    for _, source in ipairs(sources) do
        skynet.fork(function()
            local response = skynet.call(source, "lua", "query", query)
            responses[source] = response
            pending = pending - 1
            if pending == 0 then
                skynet.wakeup(response_session)
            end
        end)
    end
    
    skynet.wait(response_session)
    return responses
end
```

## 4. Session Management

### 4.1 Session Tracking

```lua
-- Service with session-aware operations
local active_sessions = {}

skynet.dispatch("lua", function(session, source, cmd, ...)
    if cmd == "start_operation" then
        local operation_id = generate_id()
        active_sessions[operation_id] = {
            status = "running",
            start_time = skynet.time(),
            client = source
        }
        
        -- Start background operation
        skynet.fork(function()
            local result = perform_long_operation()
            active_sessions[operation_id].result = result
            active_sessions[operation_id].status = "completed"
            
            -- Notify client
            skynet.send(source, "lua", "operation_complete", 
                       operation_id, result)
        end)
        
        skynet.ret(skynet.pack(true, operation_id))
        
    elseif cmd == "get_status" then
        local operation_id = ...
        local session_data = active_sessions[operation_id]
        if session_data then
            skynet.ret(skynet.pack(true, session_data.status, session_data.result))
        else
            skynet.ret(skynet.pack(false, "Operation not found"))
        end
    end
end)
```

### 4.2 Timeout Handling

```lua
-- Request with timeout
local function call_with_timeout(service, timeout, ...)
    local co = coroutine.running()
    local response
    
    -- Start timeout timer
    local timeout_session = skynet.timeout(timeout * 100, function()
        if not response then
            skynet.wakeup(co)
        end
    end)
    
    -- Make the call
    skynet.fork(function()
        response = {skynet.call(service, ...)}
        skynet.wakeup(co)
    end)
    
    -- Wait for response or timeout
    skynet.wait(co)
    
    if response then
        skynet.kill(timeout_session)
        return unpack(response)
    else
        return false, "Timeout"
    end
end
```

## 5. Performance Optimization

### 5.1 Message Batching

```lua
-- Batch processor
local batch_queue = {}
local batch_size = 100
local batch_timer

local function process_batch()
    if #batch_queue == 0 then return end
    
    local current_batch = batch_queue
    batch_queue = {}
    
    -- Process all items in batch
    local results = {}
    for i, item in ipairs(current_batch) do
        results[i] = process_item(item)
    end
    
    -- Send responses
    for i, item in ipairs(current_batch) do
        skynet.redirect(item.client, item.source, "lua", 
                       item.session, skynet.pack(results[i]))
    end
end

skynet.dispatch("lua", function(session, source, cmd, ...)
    if cmd == "process" then
        table.insert(batch_queue, {
            data = ...,
            client = skynet.self(),
            source = source,
            session = session
        })
        
        if #batch_queue >= batch_size then
            process_batch()
        elseif not batch_timer then
            batch_timer = skynet.timeout(100, function()
                process_batch()
                batch_timer = nil
            end)
        end
        
        -- Don't call skynet.ret() - will respond when batched
    end
end)
```

### 5.2 Connection Pooling

```lua
-- Service connection pool
local connection_pool = {}
local max_connections = 10

local function get_connection()
    for conn, busy in pairs(connection_pool) do
        if not busy then
            connection_pool[conn] = true
            return conn
        end
    end
    
    if #connection_pool < max_connections then
        local new_conn = create_new_connection()
        connection_pool[new_conn] = true
        return new_conn
    end
    
    return nil
end

local function release_connection(conn)
    connection_pool[conn] = false
end
```

## 6. Error Handling and Recovery

### 6.1 Circuit Breaker Pattern

```lua
-- Circuit breaker for unreliable services
local circuit_breakers = {}

local function call_with_circuit(service_name, ...)
    local cb = circuit_breakers[service_name] or {
        state = "closed",  -- closed, open, half-open
        failures = 0,
        last_failure = 0,
        threshold = 5,
        timeout = 60  -- seconds
    }
    
    if cb.state == "open" then
        if skynet.time() - cb.last_failure > cb.timeout then
            cb.state = "half-open"
        else
            return false, "Circuit breaker open"
        end
    end
    
    local service = skynet.query(service_name)
    local ok, result = pcall(skynet.call, service, ...)
    
    if ok then
        cb.failures = 0
        cb.state = "closed"
        return result
    else
        cb.failures = cb.failures + 1
        cb.last_failure = skynet.time()
        
        if cb.failures >= cb.threshold then
            cb.state = "open"
        end
        
        return false, "Service call failed: " .. result
    end
end
```

### 6.2 Retry Mechanism

```lua
-- Retry with exponential backoff
local function retry_call(service, max_retries, ...)
    local delay = 100  -- Initial delay in centiseconds
    
    for attempt = 1, max_retries do
        local ok, result = pcall(skynet.call, service, ...)
        if ok then
            return result
        end
        
        if attempt < max_retries then
            skynet.sleep(delay)
            delay = delay * 2  -- Exponential backoff
        end
    end
    
    return false, "Max retries exceeded"
end
```

## 7. Example: Chat System Message Flow

Let's implement a complete chat system with various message patterns:

```lua
-- chat_message_hub.lua
local skynet = require "skynet"

local rooms = {}
local user_sessions = {}

-- Helper functions
local function broadcast_to_room(room_id, message, exclude_sender)
    local room = rooms[room_id]
    if not room then return end
    
    for user_id, session in pairs(room.users) do
        if user_id ~= exclude_sender and user_sessions[user_id] then
            skynet.send(user_sessions[user_id], "chat", "message", message)
        end
    end
end

skynet.register_protocol {
    name = "chat",
    id = 25,
    pack = skynet.pack,
    unpack = skynet.unpack
}

skynet.start(function()
    -- Handle Lua commands (admin functions)
    skynet.dispatch("lua", function(session, source, cmd, ...)
        if cmd == "create_room" then
            local room_id = ...
            if not rooms[room_id] then
                rooms[room_id] = { users = {}, history = {} }
                skynet.ret(skynet.pack(true))
            else
                skynet.ret(skynet.pack(false, "Room exists"))
            end
            
        elseif cmd == "join_room" then
            local user_id, room_id, user_session = ...
            if not rooms[room_id] then
                skynet.ret(skynet.pack(false, "Room not found"))
                return
            end
            
            rooms[room_id].users[user_id] = user_session
            user_sessions[user_id] = user_session
            
            -- Notify room
            broadcast_to_room(room_id, {
                type = "join",
                user = user_id,
                time = skynet.time()
            })
            
            skynet.ret(skynet.pack(true))
        end
    end)
    
    -- Handle chat messages
    skynet.dispatch("chat", function(session, source, cmd, ...)
        if cmd == "message" then
            local user_id, room_id, text = ...
            
            local message = {
                type = "chat",
                user = user_id,
                text = text,
                time = skynet.time()
            }
            
            broadcast_to_room(room_id, message, user_id)
            
            -- Store in history
            if rooms[room_id] then
                table.insert(rooms[room_id].history, message)
                if #rooms[room_id].history > 1000 then
                    table.remove(rooms[room_id].history, 1)
                end
            end
        end
    end)
    
    skynet.register("CHAT_HUB")
end)
```

## 8. Exercise: Request Aggregator Service

Create a service that:
1. Accepts requests from multiple clients
2. Batches similar requests
3. Processes them together
4. Returns individual responses

**Requirements**:
- Batch requests every 100ms or when 10 requests accumulate
- Handle different request types
- Maintain request order for same client
- Implement timeout handling

## Summary

In this tutorial, you learned:
- Advanced message passing patterns
- Session management techniques
- Performance optimization strategies
- Error handling and recovery patterns
- Circuit breaker and retry mechanisms
- Message aggregation and batching

## Next Steps

Continue to [Tutorial 5: Working with Lua Services](./tutorial5_lua_services.md) to explore advanced Lua service development techniques and best practices.
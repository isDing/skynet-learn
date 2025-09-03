# Creating Your First Service

## What You'll Learn
- How to create a complete Skynet service
- Service initialization and setup patterns
- Handling different types of messages
- Service registration and discovery
- Error handling and debugging

## Prerequisites
- Completed Tutorial 2: Understanding Skynet Architecture
- Basic Lua programming knowledge
- Understanding of Skynet's actor model

## Time Estimate
60 minutes

## Final Result
A fully functional chat service that can handle multiple clients and message broadcasting

---

## 1. Service Structure Basics

A Skynet service follows a standard structure:

```lua
local skynet = require "skynet"

-- Service state (private to this service)
local service_state = {
    users = {},
    rooms = {},
    config = {}
}

skynet.start(function()
    -- 1. Initialize service state
    initialize_service()
    
    -- 2. Register message handlers
    register_handlers()
    
    -- 3. Register service name (optional)
    skynet.register("MYSERVICE")
    
    -- 4. Start background tasks (if any)
    start_tasks()
    
    -- Service will now process messages
    -- skynet.exit() is called automatically
end)
```

## 2. Creating a Simple Counter Service

Let's create a practical counter service with multiple operations.

### 2.1 Basic Implementation

Create `examples/counter_service.lua`:

```lua
local skynet = require "skynet"

-- Service state
local counters = {}

-- Initialize a counter
local function init_counter(name, initial_value)
    initial_value = initial_value or 0
    counters[name] = initial_value
    return true
end

-- Increment counter
local function increment_counter(name, delta)
    delta = delta or 1
    if not counters[name] then
        return false, "Counter not found"
    end
    counters[name] = counters[name] + delta
    return true, counters[name]
end

-- Get counter value
local function get_counter(name)
    return counters[name]
end

-- Reset counter
local function reset_counter(name)
    if counters[name] then
        counters[name] = 0
        return true
    end
    return false, "Counter not found"
end

-- List all counters
local function list_counters()
    local result = {}
    for name, value in pairs(counters) do
        table.insert(result, {name = name, value = value})
    end
    return result
end

skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local ok, result
        
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
        elseif cmd == "list" then
            result = list_counters()
            ok = true
        else
            ok, result = false, "Unknown command: " .. cmd
        end
        
        skynet.ret(skynet.pack(ok, result))
    end)
    
    -- Register service
    skynet.register("COUNTER_SERVICE")
    
    skynet.exit()
end)
```

### 2.2 Testing the Service

Create a test script `examples/test_counter.lua`:

```lua
local skynet = require "skynet"

skynet.start(function()
    -- Get counter service address
    local counter_service = skynet.query("COUNTER_SERVICE")
    
    -- Initialize counters
    local ok = skynet.call(counter_service, "lua", "init", "user1", 100)
    print("Init user1:", ok)
    
    ok = skynet.call(counter_service, "lua", "init", "user2")
    print("Init user2:", ok)
    
    -- Increment counter
    local ok, value = skynet.call(counter_service, "lua", "increment", "user1", 5)
    print("Increment user1:", ok, value)
    
    -- Get counter
    value = skynet.call(counter_service, "lua", "get", "user1")
    print("Get user1:", value)
    
    -- List all counters
    local counters = skynet.call(counter_service, "lua", "list")
    print("All counters:")
    for _, counter in ipairs(counters) do
        print("  ", counter.name, ":", counter.value)
    end
    
    skynet.exit()
end)
```

## 3. Creating a Chat Service

Now let's create a more complex chat service with rooms and users.

### 3.1 Chat Service Implementation

Create `examples/chat_service.lua`:

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

## 6. Exercise: Task Queue Service

Create a task queue service that:
1. Accepts tasks with priorities
2. Processes tasks in order
3. Supports task cancellation
4. Provides task status updates

**Features to implement**:
- Task creation with priority (1-10)
- Worker processes that pick up tasks
- Task status tracking (pending, processing, completed, failed)
- Task result storage

## 7. Debugging Tips

### 7.1 Service Debug Commands

```lua
-- Add debug handler
skynet.dispatch("debug", function(session, source, cmd, ...)
    if cmd == "status" then
        local status = {
            users = #users,
            rooms = #rooms,
            memory = collectgarbage("count")
        }
        skynet.ret(skynet.pack(status))
    elseif cmd == "dump" then
        skynet.ret(skynet.pack({
            users = users,
            rooms = rooms
        }))
    end
end)
```

### 7.2 Logging

```lua
local function log_debug(fmt, ...)
    if config.debug then
        skynet.error(string.format("[DEBUG] " .. fmt, ...))
    end
end

local function log_info(fmt, ...)
    skynet.error(string.format("[INFO] " .. fmt, ...))
end
```

## Summary

In this tutorial, you learned:
- How to structure a Skynet service
- Service initialization patterns
- Message handling and dispatching
- State management within services
- Error handling and debugging
- Building a complex chat service

## Next Steps

Continue to [Tutorial 4: Message Passing and Communication](./tutorial4_message_passing.md) to learn advanced message passing patterns and inter-service communication techniques.
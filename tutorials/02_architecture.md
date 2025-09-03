# Understanding Skynet Architecture

## What You'll Learn
- Skynet's core architecture and design principles
- The actor model implementation in Skynet
- Service lifecycle and management
- Message passing mechanism
- Thread scheduling and concurrency model

## Prerequisites
- Completed Tutorial 1: Getting Started with Skynet
- Basic understanding of concurrent programming concepts
- Familiarity with Lua coroutines

## Time Estimate
45 minutes

## Final Result
Deep understanding of how Skynet works internally and ability to design efficient service architectures

---

## 1. Overview of Skynet Architecture

Skynet follows a lightweight actor model where each service is an independent entity with:
- Its own Lua state
- A message queue for incoming messages
- Isolated execution context

### Core Components

```
┌─────────────────────────────────────────────────────────────┐
│                     Skynet Runtime                          │
├─────────────────┬─────────────────┬─────────────────────────┤
│   C Core Layer  │   Service Layer │   Lua Service Layer     │
├─────────────────┼─────────────────┼─────────────────────────┤
│ • Scheduler     │ • snlua         │ • Application Services  │
│ • Message Queue │ • gate          │ • System Services       │
│ • Timer         │ • logger        │ • User Services         │
│ • Socket        │ • harbor        │                         │
│ • Module Loader │ • ...           │                         │
└─────────────────┴─────────────────┴─────────────────────────┘
```

## 2. The Actor Model in Skynet

### 2.1 What is an Actor?

An actor in Skynet is:
- An independent execution unit
- Has its own state and message queue
- Communicates only through asynchronous messages
- Processes messages sequentially

### 2.2 Service as Actor

Each service in Skynet is implemented as an actor:

```lua
local skynet = require "skynet"

-- This entire service is an actor
skynet.start(function()
    -- Actor state
    local state = {
        counter = 0,
        connections = {}
    }
    
    -- Message handler
    skynet.dispatch("lua", function(session, source, cmd, ...)
        -- Process message sequentially
        if cmd == "increment" then
            state.counter = state.counter + 1
            skynet.ret(skynet.pack(state.counter))
        end
    end)
    
    skynet.exit()
end)
```

## 3. Service Lifecycle

### 3.1 Service Creation

Services are created through the launcher service:

```lua
-- Create a new service
local service_addr = skynet.newservice("myservice")

-- Create with arguments
local service_addr = skynet.newservice("myservice", "arg1", "arg2")
```

The creation process:
1. Launcher receives new service request
2. Creates new Lua state
3. Loads service module
4. Starts service coroutine
5. Returns service address

### 3.2 Service Execution

A service executes in this flow:

```lua
skynet.start(function()
    -- 1. Initialization phase
    local service_data = {}
    
    -- 2. Register message handlers
    skynet.dispatch("lua", function(session, source, ...)
        -- Handle incoming messages
    end)
    
    -- 3. Start processing messages
    -- skynet.exit() is called automatically
end)
```

### 3.3 Service Termination

Services can exit in several ways:
- Normal exit: `skynet.exit()`
- Kill from another service: `skynet.kill(address)`
- Error termination: Unhandled error

## 4. Message Passing Mechanism

### 4.1 Message Types

Skynet supports several message types:

```lua
-- Protocol types defined in skynet.lua
skynet.PTYPE_TEXT = 0        -- Text messages
skynet.PTYPE_RESPONSE = 1    -- Response messages
skynet.PTYPE_CLIENT = 3      -- Client messages
skynet.PTYPE_LUA = 10        -- Lua call messages
skynet.PTYPE_SOCKET = 6      -- Socket events
skynet.PTYPE_ERROR = 7       -- Error messages
```

### 4.2 Sending Messages

#### Call (Synchronous)
```lua
-- Send message and wait for response
local response = skynet.call(target_addr, "lua", "command", arg1, arg2)
```

#### Send (Asynchronous)
```lua
-- Send message without waiting
skynet.send(target_addr, "lua", "command", arg1, arg2)
```

#### Redirect (Efficient Forwarding)
```lua
-- Forward message to another service
skynet.redirect(new_target, source, protocol, session, msg, sz)
```

### 4.3 Message Processing

```lua
skynet.dispatch("lua", function(session, source, cmd, ...)
    -- session: Used to send response
    -- source: Address of sender
    -- cmd: Command name
    -- ...: Arguments
    
    -- Process command
    local result = process_command(cmd, ...)
    
    -- Send response
    skynet.ret(skynet.pack(result))
end)
```

## 5. Thread Scheduling

### 5.1 Worker Threads

Skynet uses multiple worker threads (configured by `thread` in config):

```lua
-- config example
thread = 8  -- 8 worker threads
```

Each thread:
- Runs a scheduling loop
- Processes ready services
- Handles I/O events

### 5.2 Coroutine Scheduling

Each service runs in its own coroutine:

```lua
-- Service coroutine
local co = coroutine.create(function()
    -- Service code here
    skynet.start(function()
        -- This runs in service coroutine
    end)
end)
```

The scheduler:
- Resumes coroutines when they have messages
- Yields coroutines when waiting
- Balances load across threads

## 6. Service Address System

### 6.1 Address Format

Service addresses are 32-bit handles:
```
Harbor ID (8 bits) | Handle ID (24 bits)
```

### 6.2 Address Management

```lua
-- Get current service address
local my_address = skynet.self()

-- Get service address by name
local service_addr = skynet.query("servicename")

-- Register service name
skynet.register("myservice")
```

## 7. Core Services Architecture

### 7.1 Bootstrap Service

The first service started:
- Loads configuration
- Starts essential services
- Initializes the system

### 7.2 Launcher Service

Creates new services:
- Manages service lifecycle
- Handles service creation requests

### 7.3 Gate Service

Network gateway:
- Manages client connections
- Routes messages to agents
- Handles connection events

## 8. Example: Echo Service Architecture

Let's examine how an echo service works:

```lua
-- examples/echo_service.lua
local skynet = require "skynet"

local function echo_handler(session, source, msg)
    skynet.error("Received:", msg)
    skynet.ret(skynet.pack("ECHO: " .. msg))
end

skynet.start(function()
    -- Register the message handler
    skynet.dispatch("lua", echo_handler)
    
    -- Register service name
    skynet.register("ECHO_SERVICE")
    
    skynet.exit()
end)
```

Flow of messages:
1. Client sends message to ECHO_SERVICE
2. Scheduler places message in service queue
3. Service coroutine resumes
4. Handler processes message
5. Response sent back to client

## 9. Exercise: Service Communication Chain

Create three services that form a processing chain:
- Service A: Receives input, multiplies by 2
- Service B: Receives from A, adds 10
- Service C: Receives from B, returns final result

**Structure**:
```
Client -> Service A -> Service B -> Service C -> Client
```

## 10. Performance Considerations

### 10.1 Message Queue Optimization

- Keep message processing fast
- Avoid blocking operations
- Use appropriate message types

### 10.2 Service Granularity

- Fine-grained: Many small services
- Coarse-grained: Few large services
- Balance based on use case

### 10.3 Memory Management

- Each service has its own Lua state
- Monitor memory usage with debug console
- Use shared data for large datasets

## Summary

In this tutorial, you learned:
- Skynet's actor model implementation
- Service lifecycle and management
- Message passing mechanisms
- Thread scheduling and concurrency
- Core service architecture
- Performance considerations

## Next Steps

Continue to [Tutorial 3: Creating Your First Service](./tutorial3_first_service.md) to build practical services using the architecture concepts you've learned.
# Getting Started with Skynet

## What You'll Learn
- What is Skynet and its core concepts
- How to set up the Skynet development environment
- Running your first Skynet application
- Understanding the basic Skynet project structure

## Prerequisites
- Linux, macOS, or FreeBSD system
- Basic knowledge of Lua programming
- Git installed on your system
- Basic command-line skills

## Time Estimate
30 minutes

## Final Result
A running Skynet server with a basic service that can handle client connections

---

## 1. Introduction to Skynet

Skynet is a lightweight, concurrent-oriented programming framework written in C, with Lua as the primary scripting language. It's designed for building high-performance, scalable server applications, particularly in the gaming industry.

### Key Concepts
- **Actor Model**: Each service is an independent actor with its own state
- **Message Passing**: Services communicate through asynchronous messages
- **Lightweight**: Written in C for performance, Lua for flexibility
- **Concurrent**: Built-in support for thousands of concurrent services

## 2. Setting Up the Environment

### 2.1 Clone and Build Skynet

```bash
# Clone the Skynet repository
git clone https://github.com/cloudwu/skynet.git
cd skynet

# Build Skynet (choose your platform)
make linux    # For Linux
make macosx   # For macOS
make freebsd  # For FreeBSD
```

### 2.2 Verify the Build

After building, you should see:
- `skynet` executable file
- `cservice/` directory with C service modules
- `lualib/` directory with Lua libraries
- `service/` directory with Lua services

### 2.3 Project Structure

```
skynet/
├── skynet              # Main executable
├── 3rd/                # Third-party libraries (Lua, jemalloc)
├── skynet-src/         # Core C source code
├── service-src/        # C service implementations
├── lualib-src/         # C/Lua interface code
├── service/            # Lua services
├── lualib/             # Lua libraries
└── examples/           # Example applications
```

## 3. Running Your First Skynet Application

### 3.1 Start the Basic Example

```bash
# Navigate to the skynet directory
cd skynet

# Run the example configuration
./skynet examples/config
```

You should see output similar to:
```
[:00000001] LAUNCH logger
[:00000002] LAUNCH snlua bootstrap
[:00000003] LAUNCH snlua launcher
[:00000004] LAUNCH snlua cdummy
[:00000005] LAUNCH harbor 1 127.0.0.1:2526
[:00000006] LAUNCH snlua datacenterd
[:00000007] LAUNCH snlua service_mgr
[:00000008] LAUNCH snlua main
Server start
[:0000000a] LAUNCH snlua console
[:0000000b] LAUNCH snlua debug_console 8000
[:0000000c] LAUNCH snlua simpledb
[:0000000d] LAUNCH snlua watchdog
Watchdog listen on 127.0.0.1:8888
```

### 3.2 Connect a Client

Open a new terminal and run:

```bash
# Run the example client
./3rd/lua/lua examples/client.lua
```

You should see connection messages and can interact with the server.

## 4. Understanding the Configuration

Let's examine the configuration file at `/home/ding/code/game/skynet-learn/examples/config`:

```lua
include "config.path"        -- Include path configuration

thread = 8                   -- Number of worker threads
logger = nil                 -- Logger service (nil means use default)
logpath = "."                -- Log file directory
harbor = 1                   -- Harbor ID for clustering
address = "127.0.0.1:2526"   -- This node's address
master = "127.0.0.1:2013"    -- Master node address
start = "main"               -- Main service to start
bootstrap = "snlua bootstrap" -- Bootstrap service
standalone = "0.0.0.0:2013"  -- Standalone mode address
cpath = root.."cservice/?.so" -- C service module path
```

## 5. Creating a Simple Service

Let's create a simple "hello world" service.

### 5.1 Create the Service File

Create `examples/hello_service.lua`:

```lua
local skynet = require "skynet"

skynet.start(function()
    print("Hello Service started!")
    
    -- Register a command handler
    skynet.dispatch("lua", function(session, address, cmd, ...)
        if cmd == "hello" then
            local name = ...
            local response = "Hello, " .. (name or "World") .. "!"
            skynet.ret(skynet.pack(response))
        else
            skynet.error("Unknown command:", cmd)
        end
    end)
    
    -- Exit the service
    skynet.exit()
end)
```

### 5.2 Modify Main to Start Our Service

Edit `examples/main.lua`:

```lua
local skynet = require "skynet"

skynet.start(function()
    skynet.error("Server start")
    
    -- Start our hello service
    local hello_service = skynet.newservice("hello_service")
    
    -- Test our service
    local response = skynet.call(hello_service, "lua", "hello", "Skynet Developer")
    skynet.error("Response:", response)
    
    -- Start other services
    skynet.newservice("debug_console", 8000)
    
    skynet.exit()
end)
```

### 5.3 Run and Test

```bash
./skynet examples/config
```

You should see:
```
Hello Service started!
Response: Hello, Skynet Developer!
```

## 6. Exercise: Create a Counter Service

Create a new service that maintains a counter and supports:
- `increment`: Increase counter by 1
- `decrement`: Decrease counter by 1
- `get`: Return current counter value
- `reset`: Reset counter to 0

**Solution**:
```lua
-- examples/counter_service.lua
local skynet = require "skynet"

local counter = 0

skynet.start(function()
    skynet.dispatch("lua", function(session, address, cmd, ...)
        if cmd == "increment" then
            counter = counter + 1
            skynet.ret(skynet.pack(true))
        elseif cmd == "decrement" then
            counter = counter - 1
            skynet.ret(skynet.pack(true))
        elseif cmd == "get" then
            skynet.ret(skynet.pack(counter))
        elseif cmd == "reset" then
            counter = 0
            skynet.ret(skynet.pack(true))
        else
            skynet.error("Unknown command:", cmd)
            skynet.ret(skynet.pack(false, "Unknown command"))
        end
    end)
    
    skynet.exit()
end)
```

## 7. Troubleshooting Tips

### Common Issues

1. **Build Errors**
   - Ensure you have build tools installed (`gcc`, `make`, `autoconf`)
   - On Ubuntu: `sudo apt-get install build-essential autoconf`

2. **Port Already in Use**
   - Change ports in config file or kill existing process
   - Check: `netstat -tulpn | grep :8888`

3. **Lua Version Issues**
   - Skynet uses Lua 5.4.7 by default
   - Ensure system Lua matches or update Makefile

4. **Service Not Found**
   - Check `package.path` includes your service directory
   - Verify file permissions

### Debug Commands

Use the debug console (telnet to port 8000):
- `list`: List all services
- `stat`: Show service statistics
- `mem`: Show memory usage
- `logon`: Enable service logging

## Summary

In this tutorial, you learned:
- What Skynet is and its core concepts
- How to build and set up Skynet
- How to run a basic Skynet application
- The project structure and configuration
- How to create a simple service

## Next Steps

Continue to [Tutorial 2: Understanding Skynet Architecture](./tutorial2_architecture.md) to learn about Skynet's internal architecture and design patterns.
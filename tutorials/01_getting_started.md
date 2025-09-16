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

### 重要提醒：skynet.manager 模块

在使用 `skynet.register()` 函数之前，必须先引入 `skynet.manager` 模块：

```lua
local skynet = require "skynet"
require "skynet.manager"  -- 导入 skynet.register 函数
```

这是因为 `skynet.register()` 函数定义在 `skynet.manager` 模块中，而不是在核心的 `skynet` 模块中。

### 5.1 Create the Service File

Create `examples/hello_service.lua`:

```lua
local skynet = require "skynet"
require "skynet.manager"  -- 导入 skynet.register 函数

skynet.start(function()
    print("Hello Service started!")
    
    -- 注册命令处理器
    skynet.dispatch("lua", function(session, address, cmd, ...)
        if cmd == "hello" then
            local name = ...
            local response = "Hello, " .. (name or "World") .. "!"
            skynet.ret(skynet.pack(response))
        else
            skynet.error("Unknown command:", cmd)
        end
    end)
    
    -- 注意：不要调用 skynet.exit()，这样服务会持续运行处理消息
    -- 服务会一直运行直到被显式关闭
end)
```

### 5.2 Modify Main to Start Our Service

Edit `examples/main.lua`:

```lua
local skynet = require "skynet"
require "skynet.manager"  -- 导入 skynet.register 函数

skynet.start(function()
    skynet.error("Server start")
    
    -- 启动我们的 hello 服务
    local hello_service = skynet.newservice("hello_service")
    
    -- 测试我们的服务
    local response = skynet.call(hello_service, "lua", "hello", "Skynet Developer")
    skynet.error("Response:", response)
    
    -- 启动其他服务
    skynet.newservice("debug_console", 8000)
    
    -- 注册服务名称以便其他服务可以调用
    skynet.register("hello_service")
    
    -- 注意：主服务通常不会立即退出
    -- skynet.exit()  -- 注释掉这行
end)
```

### 5.3 Run and Test

```bash
./skynet examples/config
```

你应该看到：
```
Hello Service started!
[:00000008] Server start
[:00000008] Response: Hello, Skynet Developer!
[:0000000a] LAUNCH snlua console
[:0000000b] LAUNCH snlua debug_console 8000
```

注意：服务现在会持续运行，不会立即退出。

## 6. Exercise: Create a Counter Service

Create a new service that maintains a counter and supports:
- `increment`: Increase counter by 1
- `decrement`: Decrease counter by 1
- `get`: Return current counter value
- `reset`: Reset counter to 0

**解决方案**：
```lua
-- examples/counter_service.lua
local skynet = require "skynet"

local counter = 0

skynet.start(function()
    -- 注册命令处理器
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
    
    -- 注册服务名称
    skynet.register("COUNTER_SERVICE")
    
    -- 服务持续运行，不要退出
    print("Counter service started and registered as COUNTER_SERVICE")
end)
```

### 6.1 如何使用计数器服务

要测试计数器服务，你可以：

1. **修改 main.lua 来测试计数器服务**：

```lua
-- 在 examples/main.lua 中添加
local skynet = require "skynet"

skynet.start(function()
    skynet.error("Server start")
    
    -- 启动计数器服务
    local counter_service = skynet.newservice("counter_service")
    
    -- 测试计数器服务
    skynet.error("Testing counter service...")
    
    -- 增加计数器
    skynet.call(counter_service, "lua", "increment")
    skynet.call(counter_service, "lua", "increment")
    
    -- 获取当前值
    local value = skynet.call(counter_service, "lua", "get")
    skynet.error("Counter value after increment:", value)  -- 应该显示 2
    
    -- 减少计数器
    skynet.call(counter_service, "lua", "decrement")
    value = skynet.call(counter_service, "lua", "get")
    skynet.error("Counter value after decrement:", value)  -- 应该显示 1
    
    -- 重置计数器
    skynet.call(counter_service, "lua", "reset")
    value = skynet.call(counter_service, "lua", "get")
    skynet.error("Counter value after reset:", value)  -- 应该显示 0
    
    -- 启动调试控制台
    skynet.newservice("debug_console", 8000)
end)
```

2. **使用调试控制台测试**：

启动 Skynet 后，使用 telnet 连接到调试控制台（端口 8000）：

```bash
telnet 127.0.0.1 8000
```

然后在调试控制台中输入：
```
call :0100000a "get"
call :0100000a "increment"
call :0100000a "get"
call :0100000a "reset"
call :0100000a "get"
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

5. **attempt to call a nil value (field 'register')**
   - This error occurs when trying to use `skynet.register()` without importing the manager module
   - Fix: Add `require "skynet.manager"` at the top of your service file
   - The `skynet.register()` function is defined in the manager module, not the core skynet module

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
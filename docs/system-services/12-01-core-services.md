# Skynet系统服务层 - 核心服务详解

## 目录

1. [概述](#概述)
2. [Bootstrap启动服务](#bootstrap启动服务)
3. [Launcher服务管理器](#launcher服务管理器)
4. [Console调试控制台](#console调试控制台)
5. [Debug Console高级调试](#debug-console高级调试)
6. [Debug Agent调试代理](#debug-agent调试代理)
7. [Service Manager全局服务管理](#service-manager全局服务管理)
8. [Logger日志服务](#logger日志服务)
9. [Watchdog连接管理](#watchdog连接管理)
10. [实战案例](#实战案例)

---

## 概述

### 系统服务层架构

系统服务层位于Skynet架构的顶层，提供框架运行所需的核心系统服务。这些服务在系统启动时自动创建，为所有业务服务提供基础设施支持。

#### 服务分类

```
系统服务层
├── 启动与生命周期管理
│   ├── Bootstrap Service     (系统启动)
│   └── Launcher Service      (服务启动器)
├── 调试与监控
│   ├── Console Service       (简单控制台)
│   ├── Debug Console         (高级调试控制台)
│   └── Debug Agent           (远程调试代理)
├── 服务管理
│   └── Service Manager       (全局服务管理器)
├── 日志系统
│   └── Logger Service        (日志记录)
└── 连接管理
    └── Watchdog Service      (连接看门狗)
```

#### 核心职责

1. **系统初始化**: 启动核心服务和环境配置
2. **服务管理**: 服务创建、销毁、查询
3. **调试支持**: 运行时调试、性能分析、状态查询
4. **日志记录**: 系统日志和服务日志
5. **连接管理**: 客户端连接的生命周期管理

---

## Bootstrap启动服务

### 概述

Bootstrap是Skynet的第一个Lua服务，负责启动所有核心系统服务，是整个系统的引导程序。

### 源码分析

**文件位置**: `service/bootstrap.lua`

```lua
local service = require "skynet.service"
local skynet = require "skynet.manager"

skynet.start(function()
    local standalone = skynet.getenv "standalone"

    -- 1. 启动Launcher服务
    local launcher = assert(skynet.launch("snlua","launcher"))
    skynet.name(".launcher", launcher)

    -- 2. 根据harbor_id决定集群模式
    local harbor_id = tonumber(skynet.getenv "harbor" or 0)
    if harbor_id == 0 then
        -- 单节点模式
        assert(standalone == nil)
        standalone = true
        skynet.setenv("standalone", "true")
        
        local ok, slave = pcall(skynet.newservice, "cdummy")
        if not ok then
            skynet.abort()
        end
        skynet.name(".cslave", slave)
    else
        -- 集群模式
        if standalone then
            if not pcall(skynet.newservice,"cmaster") then
                skynet.abort()
            end
        end
        
        local ok, slave = pcall(skynet.newservice, "cslave")
        if not ok then
            skynet.abort()
        end
        skynet.name(".cslave", slave)
    end

    -- 3. 启动DataCenter (单节点模式)
    if standalone then
        local datacenter = skynet.newservice "datacenterd"
        skynet.name("DATACENTER", datacenter)
    end
    
    -- 4. 启动全局服务管理器
    skynet.newservice "service_mgr"

    -- 5. 启动SSL支持 (可选)
    local enablessl = skynet.getenv "enablessl"
    if enablessl == "true" then
        service.new("ltls_holder", function ()
            local c = require "ltls.init.c"
            c.constructor()
        end)
    end

    -- 6. 启动用户主服务
    pcall(skynet.newservice, skynet.getenv "start" or "main")
    
    -- 7. Bootstrap退出 (其他服务继续运行)
    skynet.exit()
end)
```

### 启动流程

```
┌─────────────────────────────────────────┐
│         Skynet Framework Start          │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│    1. Bootstrap Service Created         │
│       (First Lua Service)               │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│    2. Launch ".launcher"                │
│       (Service Creation Manager)        │
└──────────────┬──────────────────────────┘
               │
               ▼
       ┌───────┴────────┐
       │                │
       ▼                ▼
┌─────────────┐  ┌──────────────┐
│ harbor==0?  │  │ harbor > 0?  │
│ (Standalone)│  │ (Cluster)    │
└──────┬──────┘  └──────┬───────┘
       │                │
       ▼                ▼
┌─────────────┐  ┌──────────────┐
│  cdummy     │  │ cmaster?     │
│  (Dummy)    │  │ cslave       │
└──────┬──────┘  └──────┬───────┘
       │                │
       └────────┬───────┘
                │
                ▼
┌─────────────────────────────────────────┐
│    3. Launch "DATACENTER"               │
│       (Global Config Center)            │
└──────────────┬──────────────────────────┘
                │
                ▼
┌─────────────────────────────────────────┐
│    4. Launch "service_mgr"              │
│       (Global Service Manager)          │
└──────────────┬──────────────────────────┘
                │
                ▼
┌─────────────────────────────────────────┐
│    5. SSL Support (Optional)            │
│       ltls_holder                       │
└──────────────┬──────────────────────────┘
                │
                ▼
┌─────────────────────────────────────────┐
│    6. Launch User Main Service          │
│       (from "start" env)                │
└──────────────┬──────────────────────────┘
                │
                ▼
┌─────────────────────────────────────────┐
│    7. Bootstrap Exit                    │
│       (Services Continue Running)       │
└─────────────────────────────────────────┘
```

### 关键特性

#### 1. 条件启动策略

Bootstrap根据配置选择性启动服务:

- **Harbor模式判断**: `harbor_id == 0` 为单节点，否则为集群
- **Standalone标志**: 决定是否启动全局服务
- **SSL支持**: 根据`enablessl`环境变量决定

#### 2. 服务命名

```lua
-- 本地命名 (.)
skynet.name(".launcher", launcher)    -- 仅本节点可见
skynet.name(".cslave", slave)         -- 仅本节点可见

-- 全局命名 (无前缀)
skynet.name("DATACENTER", datacenter) -- 所有节点可见
```

#### 3. 优雅退出

Bootstrap在启动完所有服务后退出，但不影响已启动的服务继续运行。这是设计上的巧妙之处:

```lua
skynet.exit()  -- Bootstrap自身退出，已启动的服务继续运行
```

---

## Launcher服务管理器

### 概述

Launcher是Skynet的服务生命周期管理器，负责所有新服务的创建、监控和销毁。

### 核心数据结构

**文件位置**: `service/launcher.lua`

```lua
local services = {}          -- handle -> service_name_string
local instance = {}          -- handle -> response_function
local launch_session = {}    -- handle -> session_id

local NORET = {}  -- 标记不需要返回的命令
```

#### 服务状态跟踪

```
┌─────────────────────────────────────────────┐
│           Launcher Data Flow                │
└─────────────────────────────────────────────┘

服务启动请求 (LAUNCH)
       │
       ▼
┌──────────────────┐
│  launch_service  │
│                  │
│  1. skynet.launch(service, param)          │
│  2. services[inst] = "service param"       │
│  3. instance[inst] = response_function     │
│  4. launch_session[inst] = session         │
└──────┬───────────┘
       │
       ▼
   等待初始化
       │
       ├─────► 成功: LAUNCHOK ──► response(true, address)
       │                            清除 instance & launch_session
       │
       └─────► 失败: ERROR ─────► response(false)
                                   清除 services, instance, launch_session
```

### 核心命令

#### 1. LAUNCH - 启动服务

```lua
function command.LAUNCH(_, service, ...)
    launch_service(service, ...)
    return NORET  -- 异步返回，等待LAUNCHOK或ERROR
end

local function launch_service(service, ...)
    local param = table.concat({...}, " ")
    local inst = skynet.launch(service, param)
    local session = skynet.context()
    local response = skynet.response()
    
    if inst then
        services[inst] = service .. " " .. param
        instance[inst] = response     -- 保存响应函数
        launch_session[inst] = session -- 保存会话ID
    else
        response(false)
        return
    end
    return inst
end
```

#### 2. LAUNCHOK - 启动成功通知

```lua
function command.LAUNCHOK(address)
    local response = instance[address]
    if response then
        response(true, address)  -- 返回成功和地址
        instance[address] = nil
        launch_session[address] = nil
    end
    return NORET
end
```

#### 3. ERROR - 启动失败通知

```lua
function command.ERROR(address)
    local response = instance[address]
    if response then
        response(false)  -- 返回失败
        launch_session[address] = nil
        instance[address] = nil
    end
    services[address] = nil
    return NORET
end
```

#### 4. LIST - 列出所有服务

```lua
function command.LIST()
    local list = {}
    for k,v in pairs(services) do
        list[skynet.address(k)] = v
    end
    return list
end
```

#### 5. STAT - 服务统计信息

```lua
function command.STAT(addr, ti)
    return list_srv(ti, function(v) return v end, "STAT")
end

local function list_srv(ti, fmt_func, ...)
    local list = {}
    local req = skynet.request()
    
    -- 批量向所有服务发送debug请求
    for addr in pairs(services) do
        local r = { addr, "debug", ... }
        req:add(r)
    end
    
    -- 收集响应 (带超时)
    for req, resp in req:select(ti) do
        local addr = req[1]
        if resp then
            list[skynet.address(addr)] = fmt_func(resp[1], addr)
        else
            list[skynet.address(addr)] = fmt_func("TIMEOUT", addr)
        end
    end
    
    return list
end
```

#### 6. MEM - 内存统计

```lua
function command.MEM(addr, ti)
    return list_srv(ti, function(kb, addr)
        local v = services[addr]
        if type(kb) == "string" then
            return string.format("%s (%s)", kb, v)
        else
            return string.format("%.2f Kb (%s)", kb, v)
        end
    end, "MEM")
end
```

#### 7. GC - 垃圾回收

```lua
function command.GC(addr, ti)
    -- 向所有服务发送GC命令
    for k,v in pairs(services) do
        skynet.send(k, "debug", "GC")
    end
    return command.MEM(addr, ti)  -- 返回回收后的内存
end
```

#### 8. KILL - 杀死服务

```lua
function command.KILL(_, handle)
    skynet.kill(handle)
    local ret = { [skynet.address(handle)] = tostring(services[handle]) }
    services[handle] = nil
    return ret
end
```

#### 9. REMOVE - 移除服务记录

```lua
function command.REMOVE(_, handle, kill)
    services[handle] = nil
    local response = instance[handle]
    if response then
        response(not kill)  -- 返回nil给newservice调用者
        instance[handle] = nil
        launch_session[handle] = nil
    end
    return NORET
end
```

#### 10. QUERY - 查询服务地址

```lua
function command.QUERY(_, request_session)
    -- 根据session查找正在启动的服务地址
    for address, session in pairs(launch_session) do
        if session == request_session then
            return address
        end
    end
end
```

### 异步启动机制

Launcher使用响应保留机制实现异步启动:

```lua
┌────────────────────────────────────────────────┐
│        Asynchronous Launch Mechanism           │
└────────────────────────────────────────────────┘

调用方 (skynet.newservice)
   │
   │ CALL .launcher "LAUNCH" service_name
   │
   ▼
Launcher: command.LAUNCH()
   │
   │ 1. local response = skynet.response()
   │ 2. skynet.launch(service)
   │ 3. instance[handle] = response
   │ 4. return NORET  (不立即返回)
   │
   └──► 调用方被阻塞
         │
         │ ... 服务初始化中 ...
         │
         ▼
   服务初始化完成
         │
         │ 发送 TEXT "" (LAUNCHOK)
         │
         ▼
Launcher: command.LAUNCHOK()
   │
   │ 1. response(true, address)
   │ 2. instance[handle] = nil
   │
   └──► 调用方被唤醒，获得服务地址
```

### TEXT协议支持

为了支持C服务，Launcher注册了TEXT协议:

```lua
skynet.register_protocol {
    name = "text",
    id = skynet.PTYPE_TEXT,
    unpack = skynet.tostring,
    dispatch = function(session, address, cmd)
        if cmd == "" then
            command.LAUNCHOK(address)
        elseif cmd == "ERROR" then
            command.ERROR(address)
        else
            error("Invalid text command " .. cmd)
        end
    end,
}
```

**C服务如何通知启动完成**:

```c
// service-src/service_snlua.c
// 初始化成功
skynet_context_send(ctx, 0, launcher, PTYPE_TEXT, 0, "", 0);
```

---

## Console调试控制台

### 概述

Console是一个简单的标准输入控制台，允许从终端直接启动服务。

### 源码分析

**文件位置**: `service/console.lua`

```lua
local skynet = require "skynet"
local snax   = require "skynet.snax"
local socket = require "skynet.socket"

local function split_cmdline(cmdline)
    local split = {}
    for i in string.gmatch(cmdline, "%S+") do
        table.insert(split, i)
    end
    return split
end

local function console_main_loop()
    local stdin = socket.stdin()  -- 获取标准输入fd
    while true do
        local cmdline = socket.readline(stdin, "\n")
        local split = split_cmdline(cmdline)
        local command = split[1]
        
        if command == "snax" then
            -- 启动Snax服务
            pcall(snax.newservice, select(2, table.unpack(split)))
        elseif cmdline ~= "" then
            -- 启动普通服务
            pcall(skynet.newservice, cmdline)
        end
    end
end

skynet.start(function()
    skynet.fork(console_main_loop)
end)
```

### 使用场景

```bash
# 从标准输入启动服务
echo "simpledb" | ./skynet examples/config

# 启动Snax服务
echo "snax pingserver" | ./skynet examples/config
```

### 限制

- 只支持服务启动，不支持查询、调试等功能
- 从标准输入读取，不适合生产环境
- 功能简单，主要用于测试

---

## Debug Console高级调试

### 概述

Debug Console是一个功能完整的网络调试控制台，提供服务管理、性能分析、内存监控、远程调试等强大功能。

### 启动与配置

**文件位置**: `service/debug_console.lua`

```lua
local arg = table.pack(...)
local ip = (arg.n == 2 and arg[1] or "127.0.0.1")
local port = tonumber(arg[arg.n])

skynet.start(function()
    local listen_socket, ip, port = socket.listen(ip, port)
    skynet.error("Start debug console at " .. ip .. ":" .. port)
    
    socket.start(listen_socket, function(id, addr)
        local function print(...)
            local t = { ... }
            for k,v in ipairs(t) do
                t[k] = tostring(v)
            end
            socket.write(id, table.concat(t, "\t"))
            socket.write(id, "\n")
        end
        
        socket.start(id)
        skynet.fork(console_main_loop, id, print, addr)
    end)
end)
```

**配置文件启动**:

```lua
-- examples/config
start = "main"
thread = 8

-- main.lua
local skynet = require "skynet"

skynet.start(function()
    skynet.newservice("debug_console", 8000)  -- 监听8000端口
    -- ...
end)
```

### 连接方式

```bash
# telnet连接
telnet 127.0.0.1 8000

# netcat连接
nc 127.0.0.1 8000

# HTTP GET方式
curl http://127.0.0.1:8000/list

# HTTP POST方式
curl -X POST http://127.0.0.1:8000 -d "list"
```

### 核心命令详解

#### 1. help - 命令列表

```
help         This help message
list         List all the service
stat         Dump all stats
info         info address : get service infomation
exit         exit address : kill a lua service
kill         kill address : kill service
mem          mem : show memory status
gc           gc : force every lua service do garbage collect
start        lanuch a new lua service
snax         lanuch a new snax service
clearcache   clear lua code cache
service      List unique service
task         task address : show service task detail
uniqtask     task address : show service unique task detail
inject       inject address luascript.lua
logon        logon address
logoff       logoff address
log          launch a new lua service with log
debug        debug address : debug a lua service
signal       signal address sig
cmem         Show C memory info
jmem         Show jemalloc mem stats
ping         ping address
call         call address ...
trace        trace address [proto] [on|off]
netstat      netstat : show netstat
profactive   profactive [on|off] : active/deactive jemalloc heap profilling
dumpheap     dumpheap : dump heap profilling
killtask     killtask address threadname : threadname listed by task
dbgcmd       run address debug command
getenv       getenv name : skynet.getenv(name)
setenv       setenv name value: skynet.setenv(name,value)
```

#### 2. list - 列出所有服务

```lua
function COMMAND.list()
    return skynet.call(".launcher", "lua", "LIST")
end
```

**输出示例**:

```
:00000002    snlua launcher
:00000003    snlua cslave
:00000004    snlua datacenterd
:00000005    snlua service_mgr
:00000006    snlua debug_console 8000
:00000007    snlua main
```

#### 3. stat - 服务统计

```lua
function COMMAND.stat(ti)
    return skynet.call(".launcher", "lua", "STAT", timeout(ti))
end
```

**输出示例**:

```
:00000007    task:3 mqlen:0 cpu:12 message:156
:00000006    task:1 mqlen:0 cpu:5 message:45
```

**字段含义**:

- `task`: 当前运行的协程数
- `mqlen`: 消息队列长度
- `cpu`: CPU使用时间 (厘秒)
- `message`: 处理的消息总数

#### 4. mem - 内存统计

```lua
function COMMAND.mem(ti)
    return skynet.call(".launcher", "lua", "MEM", timeout(ti))
end
```

**输出示例**:

```
:00000007    152.34 Kb (snlua main)
:00000006    89.21 Kb (snlua debug_console 8000)
```

#### 5. gc - 强制垃圾回收

```lua
function COMMAND.gc(ti)
    return skynet.call(".launcher", "lua", "GC", timeout(ti))
end
```

向所有Lua服务发送GC命令，然后返回内存统计。

#### 6. start - 启动新服务

```lua
function COMMAND.start(...)
    local ok, addr = pcall(skynet.newservice, ...)
    if ok then
        if addr then
            return { [skynet.address(addr)] = ... }
        else
            return "Exit"
        end
    else
        return "Failed"
    end
end
```

**使用示例**:

```
> start simpledb
:0000000a    simpledb
<CMD OK>
```

#### 7. snax - 启动Snax服务

```lua
function COMMAND.snax(...)
    local ok, s = pcall(snax.newservice, ...)
    if ok then
        local addr = s.handle
        return { [skynet.address(addr)] = ... }
    else
        return "Failed"
    end
end
```

#### 8. kill - 杀死服务

```lua
function COMMAND.kill(address)
    return skynet.call(".launcher", "lua", "KILL", adjust_address(address))
end

local function adjust_address(address)
    local prefix = address:sub(1,1)
    if prefix == '.' then
        -- 命名服务
        return assert(skynet.localname(address), "Not a valid name")
    elseif prefix ~= ':' then
        -- 十六进制地址
        address = assert(tonumber("0x" .. address), "Need an address") 
                  | (skynet.harbor(skynet.self()) << 24)
    end
    return address
end
```

**使用示例**:

```
> kill 0000000a
:0000000a    simpledb
<CMD OK>

> kill .launcher
Error: Can't kill system service
```

#### 9. task - 查看协程任务

```lua
function COMMAND.task(address)
    return COMMAND.dbgcmd(address, "TASK")
end
```

**输出示例**:

```
> task :00000007
:00000007    
session_1234    lua:main.lua:45 skynet.call(".launcher", "lua", "LIST")
session_5678    lua:timer.lua:23 skynet.sleep(100)
session_9012    lua:agent.lua:102 socket.read(fd)
<CMD OK>
```

#### 10. inject - 代码注入

```lua
function COMMAND.inject(address, filename, ...)
    address = adjust_address(address)
    local f = io.open(filename, "rb")
    if not f then
        return "Can't open " .. filename
    end
    local source = f:read "*a"
    f:close()
    
    local ok, output = skynet.call(address, "debug", "RUN", 
                                    source, filename, ...)
    if ok == false then
        error(output)
    end
    return output
end
```

**使用示例**:

```lua
-- hotfix.lua
local skynet = require "skynet"
print("Hotfix applied!")

-- 修复某个函数
local old_func = some_module.func
some_module.func = function(...)
    print("New implementation")
    return old_func(...)
end
```

```
> inject :00000007 hotfix.lua
Hotfix applied!
<CMD OK>
```

#### 11. cmem - C内存统计

```lua
function COMMAND.cmem()
    local info = memory.info()
    local tmp = {}
    for k,v in pairs(info) do
        tmp[skynet.address(k)] = v
    end
    tmp.total = memory.total()
    tmp.block = memory.block()
    return tmp
end
```

**输出示例**:

```
> cmem
:00000007    156288
:00000006    92160
total        8388608
block        128
<CMD OK>
```

#### 12. jmem - jemalloc内存统计

```lua
function COMMAND.jmem()
    local info = memory.jestat()
    local tmp = {}
    for k,v in pairs(info) do
        tmp[k] = string.format("%11d  %8.2f Mb", v, v/1048576)
    end
    return tmp
end
```

**输出示例**:

```
> jmem
allocated       16777216     16.00 Mb
active          20971520     20.00 Mb
metadata         1048576      1.00 Mb
resident        33554432     32.00 Mb
mapped          67108864     64.00 Mb
<CMD OK>
```

#### 13. ping - 延迟测试

```lua
function COMMAND.ping(address)
    address = adjust_address(address)
    local ti = skynet.now()
    skynet.call(address, "debug", "PING")
    ti = skynet.now() - ti
    return tostring(ti)
end
```

**输出示例**:

```
> ping :00000007
2
<CMD OK>
```

表示往返延迟为2厘秒(0.02秒)。

#### 14. call - 远程调用

```lua
function COMMANDX.call(cmd)
    local address = adjust_address(cmd[2])
    local cmdline = assert(cmd[1]:match("%S+%s+%S+%s(.+)"), 
                          "need arguments")
    local args_func = assert(load("return " .. cmdline, 
                                  "debug console", "t", {}), 
                            "Invalid arguments")
    local args = table.pack(pcall(args_func))
    if not args[1] then
        error(args[2])
    end
    
    local rets = table.pack(skynet.call(address, "lua", 
                                        table.unpack(args, 2, args.n)))
    return rets
end
```

**使用示例**:

```
> call :00000007 "get", "key1"
"value1"
<CMD OK>

> call :00000007 "set", "key2", {x=1, y=2}
true
<CMD OK>
```

#### 15. trace - 消息跟踪

```lua
function COMMAND.trace(address, proto, flag)
    address = adjust_address(address)
    if flag == nil then
        if proto == "on" or proto == "off" then
            proto = toboolean(proto)
        end
    else
        flag = toboolean(flag)
    end
    skynet.call(address, "debug", "TRACELOG", proto, flag)
end
```

**使用示例**:

```
> trace :00000007 on
<CMD OK>

# 服务日志输出:
[:00000007] RECV lua :00000006 session:1234 8 bytes
[:00000007] SEND lua :00000006 session:1234 16 bytes
```

#### 16. netstat - 网络连接统计

```lua
function COMMAND.netstat()
    local stat = socket.netstat()
    for _, info in ipairs(stat) do
        convert_stat(info)
    end
    return stat
end
```

**输出示例**:

```
> netstat
fd:5     type:LISTEN  address::00000006  read:0  write:0
fd:7     type:SOCKET  address::00000008  read:1.5K  write:3.2K  rtime:12.5s  wtime:0.3s
<CMD OK>
```

#### 17. debug - 远程调试

```lua
function COMMANDX.debug(cmd)
    local address = adjust_address(cmd[2])
    local agent = skynet.newservice "debug_agent"
    -- ... 创建调试会话 ...
    local ok, err = skynet.call(agent, "lua", "start", address, cmd.fd)
    -- ...
end
```

**使用示例**:

```
> debug :00000007
Attach to :00000007
[Lua Debugger]
> break main.lua:45
Breakpoint set at main.lua:45
> cont
```

### HTTP接口支持

Debug Console支持HTTP协议:

```lua
if cmdline:sub(1,4) == "GET " then
    -- HTTP GET
    local code, url = httpd.read_request(
        sockethelper.readfunc(stdin, cmdline.. "\n"), 8192)
    local cmdline = url:sub(2):gsub("/"," ")
    docmd(cmdline, print, stdin)
    break
elseif cmdline:sub(1,5) == "POST " then
    -- HTTP POST
    local code, url, method, header, body = httpd.read_request(
        sockethelper.readfunc(stdin, cmdline.. "\n"), 8192)
    docmd(body, print, stdin)
    break
end
```

**示例**:

```bash
# GET方式
curl http://127.0.0.1:8000/list
curl http://127.0.0.1:8000/stat
curl http://127.0.0.1:8000/mem

# POST方式
curl -X POST http://127.0.0.1:8000 -d "start simpledb"
curl -X POST http://127.0.0.1:8000 -d "task :00000007"
```

---

## Debug Agent调试代理

### 概述

Debug Agent是远程调试功能的代理服务，配合Debug Console的`debug`命令使用。

### 源码分析

**文件位置**: `service/debug_agent.lua`

```lua
local skynet = require "skynet"
local debugchannel = require "skynet.debugchannel"

local CMD = {}
local channel

function CMD.start(address, fd)
    assert(channel == nil, "start more than once")
    skynet.error(string.format("Attach to :%08x", address))
    
    local handle
    channel, handle = debugchannel.create()
    
    local ok, err = pcall(skynet.call, address, "debug", 
                          "REMOTEDEBUG", fd, handle)
    if not ok then
        skynet.ret(skynet.pack(false, "Debugger attach failed"))
    else
        skynet.ret(skynet.pack(true))
    end
    
    skynet.exit()
end

function CMD.cmd(cmdline)
    channel:write(cmdline)
end

function CMD.ping()
    skynet.ret()  -- 用于检测agent存活
end

skynet.start(function()
    skynet.dispatch("lua", function(_,_,cmd,...)
        local f = CMD[cmd]
        f(...)
    end)
end)
```

### 调试流程

```
┌────────────────────────────────────────────────┐
│          Remote Debug Flow                     │
└────────────────────────────────────────────────┘

Debug Console
   │
   │ 用户输入: debug :00000007
   │
   ▼
创建 debug_agent
   │
   │ CALL debug_agent "start" :00000007 fd
   │
   ▼
Debug Agent
   │
   │ 1. debugchannel.create()
   │ 2. CALL :00000007 "debug" "REMOTEDEBUG" fd handle
   │
   ▼
目标服务 (:00000007)
   │
   │ 进入远程调试模式
   │
   └──► Debug Channel建立
         │
         │ 双向通信:
         │   Console ──► Agent ──► Target
         │   Console ◄── Agent ◄── Target
         │
         └──► 调试命令执行
```

---

## Service Manager全局服务管理

### 概述

Service Manager提供全局唯一服务的管理，确保某些服务在整个系统中只有一个实例。

### 核心机制

**文件位置**: `service/service_mgr.lua`

```lua
local service = {}  -- 服务名 -> 服务地址或等待队列

-- 等待队列结构:
-- service[name] = {
--     launch = { co, session, source },  -- 正在启动
--     [1] = { co, session, source },     -- 等待者1
--     [2] = { co, session, source },     -- 等待者2
--     ...
-- }
```

### waitfor机制

```lua
local function waitfor(name, func, ...)
    local s = service[name]
    
    -- 情况1: 服务已存在
    if type(s) == "number" then
        return s  -- 直接返回地址
    end
    
    local co = coroutine.running()
    
    -- 情况2: 首次访问
    if s == nil then
        s = {}
        service[name] = s
    -- 情况3: 启动失败
    elseif type(s) == "string" then
        error(s)  -- 抛出错误信息
    end
    
    assert(type(s) == "table")
    local session, source = skynet.context()
    
    -- 情况4: 需要启动服务
    if s.launch == nil and func then
        s.launch = {
            session = session,
            source = source,
            co = co,
        }
        return request(name, func, ...)
    end
    
    -- 情况5: 等待启动完成
    table.insert(s, {
        co = co,
        session = session,
        source = source,
    })
    skynet.wait()  -- 挂起等待
    
    -- 被唤醒后重新检查
    s = service[name]
    if type(s) == "string" then
        error(s)
    end
    assert(type(s) == "number")
    return s
end
```

### request机制

```lua
local function request(name, func, ...)
    local ok, handle = pcall(func, ...)
    local s = service[name]
    assert(type(s) == "table")
    
    if ok then
        service[name] = handle  -- 启动成功，保存地址
    else
        service[name] = tostring(handle)  -- 启动失败，保存错误
    end
    
    -- 唤醒所有等待者
    for _, v in ipairs(s) do
        skynet.wakeup(v.co)
    end
    
    if ok then
        return handle
    else
        error(tostring(handle))
    end
end
```

### 核心命令

#### 1. LAUNCH - 启动全局服务

```lua
function cmd.LAUNCH(service_name, subname, ...)
    local realname = read_name(service_name)
    
    if realname == "snaxd" then
        return waitfor(service_name.."."..subname, 
                      snax.rawnewservice, subname, ...)
    else
        return waitfor(service_name, 
                      skynet.newservice, realname, subname, ...)
    end
end
```

#### 2. QUERY - 查询全局服务

```lua
function cmd.QUERY(service_name, subname)
    local realname = read_name(service_name)
    
    if realname == "snaxd" then
        return waitfor(service_name.."."..subname)  -- 只等待，不启动
    else
        return waitfor(service_name)
    end
end
```

### 使用示例

```lua
-- 方式1: skynet.uniqueservice
local db = skynet.uniqueservice("simpledb")
-- 内部调用: skynet.call("SERVICE", "lua", "LAUNCH", "simpledb")

-- 方式2: skynet.queryservice
local db = skynet.queryservice("simpledb")
-- 内部调用: skynet.call("SERVICE", "lua", "QUERY", "simpledb")
```

### 并发启动保护

```
时刻T0: 服务A调用 uniqueservice("db")
  └─► waitfor("db", skynet.newservice, "db")
      └─► service["db"] = { launch = {...} }
      └─► skynet.newservice("db")  # 开始启动

时刻T1: 服务B调用 uniqueservice("db")
  └─► waitfor("db")
      └─► service["db"]是table，且launch已存在
      └─► 加入等待队列: service["db"][1] = {...}
      └─► skynet.wait()  # B被阻塞

时刻T2: 服务C调用 uniqueservice("db")
  └─► waitfor("db")
      └─► service["db"]是table，且launch已存在
      └─► 加入等待队列: service["db"][2] = {...}
      └─► skynet.wait()  # C被阻塞

时刻T3: db服务启动完成
  └─► request("db")完成
      └─► service["db"] = handle  # 保存地址
      └─► skynet.wakeup(B)  # 唤醒B
      └─► skynet.wakeup(C)  # 唤醒C

时刻T4: B和C被唤醒
  └─► waitfor返回 handle
  └─► A、B、C都得到相同的db地址
```

### 全局服务命名

Service Manager支持全局服务命名(`@`前缀):

```lua
function cmd.GLAUNCH(name, ...)
    local global_name = "@" .. name
    return cmd.LAUNCH(global_name, ...)
end

function cmd.GQUERY(name, ...)
    local global_name = "@" .. name
    return cmd.QUERY(global_name, ...)
end
```

**集群模式**:

- 每个节点有本地Service Manager (`.service`)
- Master节点有全局Service Manager (`SERVICE`)
- 全局服务在Master节点启动，其他节点通过RPC访问

---

## Logger日志服务

### 概述

Logger是一个C实现的日志服务，负责接收和记录所有服务的日志消息。

创建与命名
- 由C层在Skynet启动早期创建并注册，名称固定为`logger`（见`skynet-src/skynet_start.c`）。
- 配置项`logger`为可选日志文件路径；未配置时输出到标准输出（stdout）。
- 通过`skynet.error(...)`产生日志，底层将以`PTYPE_TEXT`消息投递到`logger`服务。

### C源码分析

**文件位置**: `service-src/service_logger.c`

```c
struct logger {
    FILE * handle;          // 文件句柄
    char * filename;        // 日志文件名
    uint32_t starttime;     // 启动时间戳
    int close;              // 是否需要关闭文件
};

// 创建logger实例
struct logger * logger_create(void) {
    struct logger * inst = skynet_malloc(sizeof(*inst));
    inst->handle = NULL;
    inst->close = 0;
    inst->filename = NULL;
    return inst;
}

// 释放logger实例
void logger_release(struct logger * inst) {
    if (inst->close) {
        fclose(inst->handle);
    }
    skynet_free(inst->filename);
    skynet_free(inst);
}
```

### 时间戳格式化

```c
#define SIZETIMEFMT 250

static int timestring(struct logger *inst, char tmp[SIZETIMEFMT]) {
    uint64_t now = skynet_now();  // 当前时间(厘秒)
    time_t ti = now/100 + inst->starttime;  // 转换为秒
    struct tm info;
    (void)localtime_r(&ti, &info);
    strftime(tmp, SIZETIMEFMT, "%d/%m/%y %H:%M:%S", &info);
    return now % 100;  // 返回厘秒部分
}
```

### 消息回调

```c
static int logger_cb(struct skynet_context * context, 
                    void *ud, int type, int session, 
                    uint32_t source, const void * msg, size_t sz) {
    struct logger * inst = ud;
    
    switch (type) {
    case PTYPE_SYSTEM:
        // 系统消息: 重新打开日志文件
        if (inst->filename) {
            inst->handle = freopen(inst->filename, "a", inst->handle);
        }
        break;
        
    case PTYPE_TEXT:
        // 文本消息: 写入日志
        if (inst->filename) {
            char tmp[SIZETIMEFMT];
            int csec = timestring(ud, tmp);
            fprintf(inst->handle, "%s.%02d ", tmp, csec);
        }
        fprintf(inst->handle, "[:%08x] ", source);
        fwrite(msg, sz, 1, inst->handle);
        fprintf(inst->handle, "\n");
        fflush(inst->handle);  // 立即刷新
        break;
    }
    
    return 0;
}
```

### 初始化

```c
int logger_init(struct logger * inst, 
               struct skynet_context *ctx, 
               const char * parm) {
    // 获取启动时间
    const char * r = skynet_command(ctx, "STARTTIME", NULL);
    inst->starttime = strtoul(r, NULL, 10);
    
    if (parm) {
        // 写入文件
        inst->handle = fopen(parm, "a");
        if (inst->handle == NULL) {
            return 1;
        }
        inst->filename = skynet_malloc(strlen(parm)+1);
        strcpy(inst->filename, parm);
        inst->close = 1;
    } else {
        // 写入stdout
        inst->handle = stdout;
    }
    
    if (inst->handle) {
        skynet_callback(ctx, inst, logger_cb);
        return 0;
    }
    return 1;
}
```

### 配置文件

```lua
-- examples/config
logger = "./skynet.log"  -- 日志文件路径

-- 或者
-- logger = nil  -- 输出到stdout
```

### 日志格式

```
25/06/23 14:32:15.42 [:00000007] Service start
25/06/23 14:32:15.45 [:00000007] Initialize database
25/06/23 14:32:16.12 [:0000000a] Client connected from 192.168.1.100
```

格式说明:

- `25/06/23 14:32:15.42`: 日期时间.厘秒
- `[:00000007]`: 服务地址
- 后续为日志内容

### 使用方式

```lua
local skynet = require "skynet"

-- skynet.error会发送PTYPE_TEXT消息给logger
skynet.error("This is a log message")
skynet.error("Value:", 123, "Data:", {x=1, y=2})
```

### LOGON/LOGOFF命令

```c
// skynet-src/skynet_server.c
void skynet_command_logon(struct skynet_context *ctx, uint32_t handle) {
    // 开启日志记录
    ctx->logfile = handle;
}

void skynet_command_logoff(struct skynet_context *ctx) {
    // 关闭日志记录
    ctx->logfile = 0;
}
```

**使用示例**:

```lua
-- 在debug console中
> logon :00000007
<CMD OK>

-- 现在服务:00000007的所有输出都会发送给logger

> logoff :00000007
<CMD OK>
```

---

## Watchdog连接管理

### 概述

Watchdog是一个连接管理模式，用于管理客户端连接的生命周期。虽然不是核心系统服务，但是非常重要的设计模式。

### 架构模式

```
┌────────────────────────────────────────────────┐
│          Watchdog Pattern                      │
└────────────────────────────────────────────────┘

                  Internet
                     │
                     ▼
              ┌──────────────┐
              │  Gate Server │  (C服务，处理网络I/O)
              └───────┬──────┘
                      │
          ┌───────────┼───────────┐
          │           │           │
          ▼           ▼           ▼
     ┌────────┐  ┌────────┐  ┌────────┐
     │Connection  │Connection  │Connection
     │   fd:5  │  │   fd:7  │  │   fd:9  │
     └────┬───┘  └────┬───┘  └────┬───┘
          │           │           │
          └───────────┼───────────┘
                      │ (socket消息)
                      ▼
              ┌──────────────┐
              │   Watchdog   │  (连接管理器)
              │              │  
              │ - 创建Agent  │
              │ - 分配连接  │
              │ - 监控状态  │
              └───────┬──────┘
                      │
          ┌───────────┼───────────┐
          │           │           │
          ▼           ▼           ▼
     ┌────────┐  ┌────────┐  ┌────────┐
     │Agent #1│  │Agent #2│  │Agent #3│
     │ fd:5   │  │ fd:7   │  │ fd:9   │
     └────────┘  └────────┘  └────────┘
     处理客户端   处理客户端   处理客户端
     业务逻辑     业务逻辑     业务逻辑
```

### 源码分析

**文件位置**: `examples/watchdog.lua`

```lua
local skynet = require "skynet"

local CMD = {}
local SOCKET = {}
local gate
local agent = {}

-- Socket事件处理

function SOCKET.open(fd, addr)
    skynet.error("New client from : " .. addr)
    
    -- 创建新Agent
    agent[fd] = skynet.newservice("agent")
    
    -- 启动Agent并关联连接
    skynet.call(agent[fd], "lua", "start", {
        gate = gate,
        client = fd,
        watchdog = skynet.self()
    })
end

local function close_agent(fd)
    local a = agent[fd]
    agent[fd] = nil
    
    if a then
        skynet.call(gate, "lua", "kick", fd)  -- 断开连接
        skynet.send(a, "lua", "disconnect")   -- 通知Agent
    end
end

function SOCKET.close(fd)
    print("socket close", fd)
    close_agent(fd)
end

function SOCKET.error(fd, msg)
    print("socket error", fd, msg)
    close_agent(fd)
end

function SOCKET.warning(fd, size)
    -- size K bytes 还未发送完
    print("socket warning", fd, size)
end

function SOCKET.data(fd, msg)
    -- 通常不在这里处理数据
    -- 数据已经转发给Agent
end

-- 命令处理

function CMD.start(conf)
    return skynet.call(gate, "lua", "open", conf)
end

function CMD.close(fd)
    close_agent(fd)
end

-- 启动

skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, subcmd, ...)
        if cmd == "socket" then
            -- Socket事件
            local f = SOCKET[subcmd]
            f(...)
        else
            -- 普通命令
            local f = assert(CMD[cmd])
            skynet.ret(skynet.pack(f(subcmd, ...)))
        end
    end)
    
    -- 创建Gate服务
    gate = skynet.newservice("gate")
end)
```

### Agent实现

```lua
-- examples/agent.lua
local skynet = require "skynet"
local netpack = require "skynet.netpack"

local gate
local client_fd
local watchdog

local CMD = {}

function CMD.start(conf)
    gate = conf.gate
    client_fd = conf.client
    watchdog = conf.watchdog
end

function CMD.disconnect()
    -- 客户端断开连接
    skynet.error("Client disconnect")
    skynet.exit()
end

skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local f = CMD[cmd]
        if f then
            skynet.ret(skynet.pack(f(...)))
        end
    end)
    
    skynet.dispatch("client", function(session, source, msg)
        -- 处理客户端消息
        local str = netpack.tostring(msg)
        skynet.error("Recv from client:", str)
        
        -- 回复客户端
        skynet.send(gate, "lua", "response", client_fd, 
                   netpack.pack("Echo: " .. str))
    end)
end)
```

### 工作流程

```
1. 客户端连接
   │
   ▼
Gate接收连接 (fd=5)
   │
   │ SEND watchdog "socket" "open" 5 "192.168.1.100:12345"
   │
   ▼
Watchdog.SOCKET.open()
   │
   ├─► 创建Agent (#1)
   │
   └─► CALL agent#1 "start" {gate, client=5, watchdog}

2. 客户端发送数据
   │
   ▼
Gate接收数据 (fd=5)
   │
   │ 查找fd对应的Agent
   │
   │ SEND agent#1 "client" msg
   │
   ▼
Agent处理消息
   │
   └─► 处理业务逻辑

3. 客户端断开
   │
   ▼
Gate检测断开 (fd=5)
   │
   │ SEND watchdog "socket" "close" 5
   │
   ▼
Watchdog.SOCKET.close()
   │
   ├─► CALL gate "kick" 5
   │
   └─► SEND agent#1 "disconnect"
       │
       └─► Agent退出
```

### 连接转发

当Agent启动后，Gate会将该fd的消息直接转发给Agent:

```c
// service-src/service_gate.c
// 在watchdog返回后，gate记录:
//   fd -> agent_address
// 
// 后续消息直接转发:
//   Gate收到fd的数据 -> 转发给agent (PTYPE_CLIENT消息)
```

### Watchdog职责

1. **连接分配**: 为每个连接创建Agent
2. **生命周期管理**: 监控连接的打开、关闭、错误
3. **资源回收**: 连接断开时清理Agent
4. **异常处理**: 处理连接错误和警告
5. **全局控制**: 提供管理接口（如踢人）

### 扩展模式

#### 1. 连接池模式

```lua
-- 预创建Agent池
local agent_pool = {}
local agent_count = 100

function init_agent_pool()
    for i = 1, agent_count do
        agent_pool[i] = skynet.newservice("agent")
    end
end

function SOCKET.open(fd, addr)
    -- 从池中分配Agent
    local a = table.remove(agent_pool)
    if not a then
        a = skynet.newservice("agent")
    end
    
    agent[fd] = a
    skynet.call(a, "lua", "start", {...})
end

function close_agent(fd)
    local a = agent[fd]
    agent[fd] = nil
    
    if a then
        skynet.call(gate, "lua", "kick", fd)
        skynet.send(a, "lua", "reset")
        -- 回收到池中
        table.insert(agent_pool, a)
    end
end
```

#### 2. 认证模式

```lua
local authed = {}  -- fd -> true/false

function SOCKET.open(fd, addr)
    -- 创建临时Agent进行认证
    agent[fd] = skynet.newservice("auth_agent")
    authed[fd] = false
    
    skynet.call(agent[fd], "lua", "start", {...})
    
    -- 设置认证超时
    skynet.timeout(3000, function()  -- 30秒
        if not authed[fd] then
            skynet.error("Auth timeout:", fd)
            close_agent(fd)
        end
    end)
end

function CMD.auth_success(fd, uid)
    -- 认证成功，切换到业务Agent
    authed[fd] = true
    
    local old_agent = agent[fd]
    agent[fd] = skynet.newservice("game_agent")
    skynet.call(agent[fd], "lua", "start", {..., uid = uid})
    
    -- 销毁认证Agent
    skynet.send(old_agent, "lua", "exit")
end
```

#### 3. 负载均衡模式

```lua
local agent_balance = {}
local agent_load = {}

function SOCKET.open(fd, addr)
    -- 选择负载最低的Agent
    local min_load = math.huge
    local selected_agent
    
    for a, load in pairs(agent_load) do
        if load < min_load then
            min_load = load
            selected_agent = a
        end
    end
    
    if not selected_agent or min_load > 100 then
        selected_agent = skynet.newservice("agent")
        agent_load[selected_agent] = 0
    end
    
    agent[fd] = selected_agent
    agent_load[selected_agent] = agent_load[selected_agent] + 1
    
    skynet.call(selected_agent, "lua", "add_client", fd, {...})
end
```

---

## 实战案例

### 案例1: 游戏服务器架构

#### 需求

设计一个支持10000+在线的游戏服务器:

- 登录认证
- 场景管理
- 聊天系统
- 性能监控

#### 架构设计

```lua
-- main.lua
local skynet = require "skynet"

skynet.start(function()
    -- 1. 启动调试控制台
    skynet.newservice("debug_console", 8000)
    
    -- 2. 启动数据库服务
    local db = skynet.uniqueservice("mysql_service")
    
    -- 3. 启动登录服务
    local login = skynet.uniqueservice("login_service")
    
    -- 4. 启动场景管理器
    local scenemgr = skynet.uniqueservice("scene_manager")
    
    -- 5. 启动聊天服务
    local chat = skynet.uniqueservice("chat_service")
    
    -- 6. 启动监控服务
    local monitor = skynet.uniqueservice("monitor_service")
    
    -- 7. 启动网关
    local watchdog = skynet.newservice("game_watchdog")
    skynet.call(watchdog, "lua", "start", {
        port = 8888,
        maxclient = 10000,
        nodelay = true,
    })
    
    skynet.error("Game server started!")
end)
```

#### 游戏Watchdog

```lua
-- game_watchdog.lua
local skynet = require "skynet"

local CMD = {}
local SOCKET = {}
local gate
local agent = {}
local online_count = 0
local max_client = 10000

function SOCKET.open(fd, addr)
    -- 检查在线人数
    if online_count >= max_client then
        skynet.error("Server full, reject:", addr)
        skynet.call(gate, "lua", "kick", fd)
        return
    end
    
    skynet.error("New connection from:", addr)
    
    -- 创建登录Agent
    agent[fd] = skynet.newservice("login_agent")
    skynet.call(agent[fd], "lua", "start", {
        gate = gate,
        client = fd,
        watchdog = skynet.self(),
        addr = addr,
    })
    
    online_count = online_count + 1
    
    -- 认证超时
    skynet.timeout(3000, function()
        if agent[fd] and not agent[fd].authed then
            skynet.error("Auth timeout:", fd)
            close_agent(fd)
        end
    end)
end

function SOCKET.close(fd)
    close_agent(fd)
    online_count = online_count - 1
end

function SOCKET.error(fd, msg)
    skynet.error("Socket error:", fd, msg)
    close_agent(fd)
    online_count = online_count - 1
end

function SOCKET.warning(fd, size)
    -- 发送缓冲区积压
    skynet.error("Send buffer warning:", fd, size, "KB")
    
    if size > 1024 then  -- 超过1MB
        skynet.error("Force disconnect slow client:", fd)
        close_agent(fd)
    end
end

function CMD.auth_success(fd, uid, username)
    -- 认证成功，切换到游戏Agent
    local old_agent = agent[fd]
    
    agent[fd] = {
        handle = skynet.newservice("game_agent"),
        uid = uid,
        username = username,
        authed = true,
    }
    
    skynet.call(agent[fd].handle, "lua", "start", {
        gate = gate,
        client = fd,
        watchdog = skynet.self(),
        uid = uid,
        username = username,
    })
    
    -- 销毁登录Agent
    skynet.send(old_agent, "lua", "exit")
    
    skynet.error("Player online:", uid, username)
end

function CMD.start(conf)
    skynet.call(gate, "lua", "open", conf)
    max_client = conf.maxclient or 10000
end

function CMD.stats()
    return {
        online = online_count,
        max = max_client,
    }
end

function CMD.kick(uid)
    for fd, a in pairs(agent) do
        if a.uid == uid then
            close_agent(fd)
            return true
        end
    end
    return false
end

local function close_agent(fd)
    local a = agent[fd]
    agent[fd] = nil
    
    if a then
        skynet.call(gate, "lua", "kick", fd)
        
        if type(a) == "table" and a.handle then
            skynet.send(a.handle, "lua", "disconnect")
        else
            skynet.send(a, "lua", "disconnect")
        end
    end
end

skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, subcmd, ...)
        if cmd == "socket" then
            local f = SOCKET[subcmd]
            f(...)
        else
            local f = assert(CMD[cmd])
            skynet.ret(skynet.pack(f(subcmd, ...)))
        end
    end)
    
    gate = skynet.newservice("gate")
end)
```

#### 监控服务

```lua
-- monitor_service.lua
local skynet = require "skynet"

local stats = {
    start_time = 0,
    total_connections = 0,
    total_messages = 0,
    errors = {},
}

local function collect_stats()
    while true do
        skynet.sleep(6000)  -- 每分钟
        
        -- 收集服务统计
        local services = skynet.call(".launcher", "lua", "STAT", 100)
        local mem = skynet.call(".launcher", "lua", "MEM", 100)
        
        local report = {
            timestamp = os.time(),
            services = services,
            memory = mem,
        }
        
        -- 检查异常
        for addr, stat in pairs(services) do
            if stat.mqlen > 1000 then
                skynet.error("WARNING: High message queue:", 
                           addr, stat.mqlen)
                table.insert(stats.errors, {
                    time = os.time(),
                    type = "high_mqlen",
                    addr = addr,
                    mqlen = stat.mqlen,
                })
            end
            
            if stat.cpu > 10000 then  -- 100秒
                skynet.error("WARNING: High CPU usage:", 
                           addr, stat.cpu)
                table.insert(stats.errors, {
                    time = os.time(),
                    type = "high_cpu",
                    addr = addr,
                    cpu = stat.cpu,
                })
            end
        end
        
        -- 保存报告
        -- save_report(report)
    end
end

local CMD = {}

function CMD.get_stats()
    return stats
end

function CMD.get_errors()
    return stats.errors
end

skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local f = CMD[cmd]
        skynet.ret(skynet.pack(f(...)))
    end)
    
    stats.start_time = os.time()
    skynet.fork(collect_stats)
end)
```

#### 使用Debug Console监控

```bash
# 连接到debug console
telnet 127.0.0.1 8000

# 查看所有服务
> list
:00000002    snlua launcher
:00000003    snlua cslave
:00000007    snlua debug_console 8000
:00000008    snlua mysql_service
:00000009    snlua login_service
:0000000a    snlua scene_manager
:0000000b    snlua chat_service
:0000000c    snlua monitor_service
:0000000d    snlua game_watchdog
:0000000e    snlua gate
...
:00000fff    snlua game_agent
<CMD OK>

# 查看服务统计
> stat
:00000d      task:1 mqlen:0 cpu:23 message:1234
:00000fff    task:2 mqlen:0 cpu:156 message:5678
<CMD OK>

# 查看内存
> mem
:00000d      245.67 Kb (snlua game_watchdog)
:00000fff    312.45 Kb (snlua game_agent)
<CMD OK>

# 查看网络连接
> netstat
fd:10    type:SOCKET  address::00000fff  read:15K  write:32K
fd:11    type:SOCKET  address::00001000  read:8K   write:12K
<CMD OK>

# 查看监控统计
> call :0000000c get_stats
{
    start_time = 1719325415,
    total_connections = 1234,
    total_messages = 567890,
    errors = {}
}
<CMD OK>

# 踢掉某个玩家
> call :0000000d kick 10001
true
<CMD OK>

# 强制GC
> gc
:00000d      215.32 Kb (snlua game_watchdog)
:00000fff    278.91 Kb (snlua game_agent)
<CMD OK>

# 注入热更新代码
> inject :00000fff hotfix.lua
Hotfix applied!
<CMD OK>
```

---

### 案例2: 性能压测工具

#### 需求

利用Debug Console实现性能压测和监控:

- 实时监控服务状态
- 自动检测性能瓶颈
- 生成压测报告

#### 实现

```lua
-- stress_test.lua
local skynet = require "skynet"
local socket = require "skynet.socket"

local console_addr = "127.0.0.1"
local console_port = 8000

local function send_command(fd, cmd)
    socket.write(fd, cmd .. "\n")
    local result = {}
    
    repeat
        local line = socket.readline(fd, "\n")
        if line == "<CMD OK>" then
            break
        elseif line == "<CMD Error>" then
            return nil, "Command error"
        else
            table.insert(result, line)
        end
    until false
    
    return result
end

local function stress_test()
    local fd = socket.open(console_addr, console_port)
    if not fd then
        skynet.error("Connect to console failed")
        return
    end
    
    socket.start(fd)
    
    -- 1. 获取初始状态
    skynet.error("=== Initial State ===")
    local list = send_command(fd, "list")
    local stat = send_command(fd, "stat")
    local mem = send_command(fd, "mem")
    
    -- 2. 开始压测
    skynet.error("=== Starting Stress Test ===")
    
    -- 创建1000个测试服务
    for i = 1, 1000 do
        send_command(fd, "start test_service")
    end
    
    skynet.sleep(500)  -- 等待5秒
    
    -- 3. 收集压测数据
    skynet.error("=== Stress Test Results ===")
    
    local samples = {}
    for i = 1, 60 do  -- 采样1分钟
        local stat = send_command(fd, "stat")
        local mem = send_command(fd, "mem")
        
        table.insert(samples, {
            time = os.time(),
            stat = stat,
            mem = mem,
        })
        
        skynet.sleep(100)  -- 1秒间隔
    end
    
    -- 4. 分析结果
    local max_mqlen = 0
    local max_cpu = 0
    local total_mem = 0
    
    for _, sample in ipairs(samples) do
        for _, line in ipairs(sample.stat) do
            local addr, data = line:match("(%S+)%s+(.+)")
            local mqlen = data:match("mqlen:(%d+)")
            local cpu = data:match("cpu:(%d+)")
            
            if mqlen then
                mqlen = tonumber(mqlen)
                if mqlen > max_mqlen then
                    max_mqlen = mqlen
                end
            end
            
            if cpu then
                cpu = tonumber(cpu)
                if cpu > max_cpu then
                    max_cpu = cpu
                end
            end
        end
        
        for _, line in ipairs(sample.mem) do
            local mem = line:match("(%d+%.%d+) Kb")
            if mem then
                total_mem = total_mem + tonumber(mem)
            end
        end
    end
    
    -- 5. 生成报告
    skynet.error("=== Performance Report ===")
    skynet.error("Max Message Queue Length:", max_mqlen)
    skynet.error("Max CPU Usage:", max_cpu, "cs")
    skynet.error("Average Memory:", total_mem / #samples, "Kb")
    
    -- 6. 清理
    send_command(fd, "gc")
    
    socket.close(fd)
end

skynet.start(function()
    stress_test()
    skynet.exit()
end)
```

---

## 总结

### 系统服务层职责矩阵

| 服务 | 主要职责 | 关键特性 | 使用场景 |
|------|---------|---------|---------|
| Bootstrap | 系统启动 | 条件启动、优雅退出 | 系统初始化 |
| Launcher | 服务生命周期 | 异步启动、状态跟踪 | 服务管理 |
| Console | 简单控制台 | 标准输入、快速启动 | 开发测试 |
| Debug Console | 高级调试 | 网络接口、HTTP支持 | 生产监控 |
| Debug Agent | 远程调试 | 调试通道、命令转发 | 问题排查 |
| Service Manager | 全局服务 | 唯一性保证、并发保护 | 单例服务 |
| Logger | 日志记录 | 时间戳、文件输出 | 系统日志 |
| Watchdog | 连接管理 | Agent池、生命周期 | 网络服务 |

### 最佳实践

#### 1. 启动顺序

```lua
-- 推荐启动顺序
1. Bootstrap
2. Launcher
3. Harbor (集群模式)
4. DataCenter
5. Service Manager
6. Logger
7. Debug Console (开发环境)
8. 业务服务
```

#### 2. 调试策略

- **开发环境**: 使用Console + Debug Console
- **测试环境**: 使用Debug Console + Logger
- **生产环境**: 使用Logger + 远程Debug Console (限制IP)

#### 3. 监控指标

关键监控指标:

- `mqlen`: 消息队列长度 (> 1000需要关注)
- `cpu`: CPU使用时间 (持续高CPU需要优化)
- `task`: 协程数量 (过多可能有泄漏)
- `memory`: 内存使用 (持续增长需要检查)

#### 4. 性能优化

- 使用`uniqueservice`减少服务实例
- 定期执行`gc`命令释放内存
- 监控`warning`消息，优化慢客户端
- 使用`trace`命令分析消息流

#### 5. 安全建议

- Debug Console绑定127.0.0.1或使用防火墙
- 生产环境禁用`inject`命令
- 限制Debug Console访问IP
- 定期审查日志文件

---

## 参考资料

### 源码文件

- `service/bootstrap.lua` - 启动服务
- `service/launcher.lua` - 服务管理器
- `service/console.lua` - 简单控制台
- `service/debug_console.lua` - 调试控制台
- `service/debug_agent.lua` - 调试代理
- `service/service_mgr.lua` - 全局服务管理器
- `service-src/service_logger.c` - 日志服务
- `examples/watchdog.lua` - 连接管理模式

### 调试命令速查

```
list         列出所有服务
stat         服务统计信息
mem          内存使用情况
gc           强制垃圾回收
start        启动新服务
kill         杀死服务
task         查看协程任务
inject       代码注入
cmem         C内存统计
jmem         jemalloc统计
ping         延迟测试
call         远程调用
trace        消息跟踪
netstat      网络连接统计
debug        远程调试
```

### 配置示例

```lua
-- examples/config
thread = 8
start = "main"
harbor = 0
logger = "./skynet.log"

-- main.lua
local skynet = require "skynet"

skynet.start(function()
    -- 开发环境
    if skynet.getenv("mode") == "dev" then
        skynet.newservice("debug_console", 8000)
    end
    
    -- 启动业务
    skynet.newservice("game_watchdog")
end)
```

---

**文档版本**: 1.0  
**最后更新**: 2024-01-XX  
**适用版本**: Skynet 1.x

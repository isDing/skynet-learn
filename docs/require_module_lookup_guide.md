# Lua require 模块查找指南

## 概述

本文档详细说明如何确定 Lua `require` 语句加载的实际文件位置，以及不同类型模块的查找机制和作用。

## 1. 模块类型分类

### 1.1 Lua 模块 (.lua 文件)
- **特征**：纯 Lua 代码实现
- **扩展名**：`.lua`
- **查找路径**：`package.path`
- **示例**：`require "skynet"`, `require "skynet.manager"`

### 1.2 C 扩展模块 (.so 文件)
- **特征**：C 代码编译的动态库
- **扩展名**：`.so` (Linux), `.dll` (Windows)
- **查找路径**：`package.cpath`
- **示例**：`require "skynet.core"`, `require "skynet.socket"`

### 1.3 混合模块
- **特征**：C 库中包含多个 luaopen_* 函数
- **实现**：一个 .so 文件提供多个逻辑模块
- **示例**：`skynet.so` 包含 `skynet.core`, `skynet.socketdriver` 等

## 2. 查找机制详解

### 2.1 package.path 搜索规则

**默认 package.path**：
```
/usr/local/share/lua/5.3/?.lua;
/usr/local/share/lua/5.3/?/init.lua;
/usr/local/lib/lua/5.3/?.lua;
/usr/local/lib/lua/5.3/?/init.lua;
/usr/share/lua/5.3/?.lua;
/usr/share/lua/5.3/?/init.lua;
./?.lua;
./?/init.lua
```

**搜索示例**：`require "skynet.manager"`
1. `./skynet/manager.lua` ✓ (找到)
2. `./skynet/manager/init.lua`
3. `/usr/local/share/lua/5.3/skynet/manager.lua`
4. ... (其他路径)

### 2.2 package.cpath 搜索规则

**默认 package.cpath**：
```
/usr/local/lib/lua/5.3/?.so;
/usr/lib/x86_64-linux-gnu/lua/5.3/?.so;
/usr/lib/lua/5.3/?.so;
/usr/local/lib/lua/5.3/loadall.so;
./?.so
```

**搜索示例**：`require "skynet.core"`
1. `./skynet.core.so` (不存在)
2. `./skynet/core.so` (不存在)
3. `./skynet.so` ✓ (找到，查找 luaopen_skynet_core)

## 3. 实际查找方法

### 3.1 使用 package.searchpath

```lua
-- 查找 Lua 模块
local path = package.searchpath("skynet.manager", package.path)
print("skynet.manager 位于:", path)
-- 输出: ./lualib/skynet/manager.lua

-- 查找 C 模块
local cpath = package.searchpath("skynet.core", package.cpath)
print("skynet.core 搜索:", cpath)
-- 输出: ./luaclib/skynet.so
```

### 3.2 使用命令行工具

```bash
# 查找 Lua 文件
find . -name "*.lua" -path "*/skynet/manager.lua"

# 查找 C 库文件
find . -name "*.so" | xargs nm -D 2>/dev/null | grep luaopen_skynet_core

# 检查动态库中的符号
nm -D luaclib/skynet.so | grep luaopen
```

### 3.3 运行时检查

```lua
-- 检查模块是否已加载
if package.loaded["skynet.core"] then
    print("skynet.core 已加载")
end

-- 获取当前路径配置
print("Lua Path:", package.path)
print("C Path:", package.cpath)

-- 在 Skynet 中查看自定义路径
-- 在 service-src/service_snlua.c 中设置的路径
print("LUA_PATH:", os.getenv("LUA_PATH"))
print("LUA_CPATH:", os.getenv("LUA_CPATH"))
```

## 4. Skynet 特殊情况

### 4.1 路径配置

Skynet 在 `service_snlua.c` 中设置自定义路径：

```c
const char *path = optstring(ctx, "lua_path","./lualib/?.lua;./lualib/?/init.lua");
const char *cpath = optstring(ctx, "lua_cpath","./luaclib/?.so");
const char *service = optstring(ctx, "luaservice", "./service/?.lua");
```

### 4.2 多模块单库设计

`luaclib/skynet.so` 包含多个模块：
- `luaopen_skynet_core` → `require "skynet.core"`
- `luaopen_skynet_socketdriver` → `require "skynet.socketdriver"`
- `luaopen_skynet_netpack` → `require "skynet.netpack"`
- `luaopen_skynet_memory` → `require "skynet.memory"`
- 等等...

### 4.3 自定义 require

Skynet 使用自定义的 require 实现：

```lua
-- 在 lualib/skynet/require.lua 中
_G.require = (require "skynet.require").require
```

提供了初始化队列和循环依赖检测等增强功能。

## 5. 实际案例分析

### 案例 1: require "skynet"

**查找过程**：
1. 在 `package.path` 中搜索
2. 找到 `./lualib/skynet.lua`
3. 加载纯 Lua 模块

**文件内容**：
```lua
-- lualib/skynet.lua
local c = require "skynet.core"  -- 依赖 C 模块
-- ... 1000+ 行 Lua 代码实现高级功能
return skynet
```

### 案例 2: require "skynet.core"

**查找过程**：
1. 在 `package.cpath` 中搜索
2. 找到 `./luaclib/skynet.so`
3. 在库中查找 `luaopen_skynet_core` 函数
4. 调用该函数初始化模块

**C 实现**：
```c
// lualib-src/lua-skynet.c
LUAMOD_API int luaopen_skynet_core(lua_State *L) {
    // 注册 C 函数到 Lua
    return 1;
}
```

### 案例 3: require "skynet.manager"

**查找过程**：
1. 在 `package.path` 中搜索
2. 找到 `./lualib/skynet/manager.lua`
3. 加载 Lua 模块

**模块作用**：
```lua
-- lualib/skynet/manager.lua
local skynet = require "skynet"
local c = require "skynet.core"

-- 扩展 skynet 模块，添加管理功能
function skynet.launch(...) end
function skynet.kill(name) end
function skynet.register(name) end
-- ...

return skynet  -- 返回扩展后的 skynet
```

## 6. 调试技巧

### 6.1 启用模块加载跟踪

```lua
-- 重写 require 以添加跟踪
local original_require = require
_G.require = function(name)
    print("Loading module:", name)
    local path = package.searchpath(name, package.path)
    if path then
        print("  Lua file:", path)
    else
        local cpath = package.searchpath(name, package.cpath)
        if cpath then
            print("  C library:", cpath)
        end
    end
    return original_require(name)
end
```

### 6.2 检查已加载模块

```lua
-- 打印所有已加载的模块
for name, module in pairs(package.loaded) do
    print(name, type(module))
end
```

### 6.3 模块依赖关系追踪

```lua
-- 在模块开头添加
print(debug.traceback("Loading " .. (...), 2))
```

## 7. Skynet 项目完整模块映射

### 7.1 核心模块 (Core Modules)

| require 语句 | 文件路径 | 类型 | 功能描述 |
|-------------|----------|------|----------|
| `require "skynet"` | `./lualib/skynet.lua` | Lua | 核心框架，提供服务管理、消息传递、协程调度等基础功能 |
| `require "skynet.core"` | `./luaclib/skynet.so` | C | 底层C桥接模块，提供send、call、response等核心API |
| `require "skynet.manager"` | `./lualib/skynet/manager.lua` | Lua | 服务管理模块，提供launch、kill、register等管理功能 |
| `require "skynet.service"` | `./lualib/skynet/service.lua` | Lua | 服务启动和查询，简化服务创建流程 |
| `require "skynet.require"` | `./lualib/skynet/require.lua` | Lua | 自定义require实现，支持延迟加载和初始化队列 |

### 7.2 网络模块 (Network Modules)

| require 语句 | 文件路径 | 类型 | 功能描述 |
|-------------|----------|------|----------|
| `require "skynet.socket"` | `./lualib/skynet/socket.lua` | Lua | 高层socket封装，提供TCP连接管理 |
| `require "skynet.socketdriver"` | `./luaclib/skynet.so` | C | 底层socket驱动，基于epoll/kqueue实现 |
| `require "skynet.netpack"` | `./luaclib/skynet.so` | C | 网络包处理，消息打包和解包 |
| `require "skynet.socketchannel"` | `./lualib/skynet/socketchannel.lua` | Lua | socket通道抽象，支持连接池和重连 |

### 7.3 分布式支持 (Distributed Support)

| require 语句 | 文件路径 | 类型 | 功能描述 |
|-------------|----------|------|----------|
| `require "skynet.harbor"` | `./lualib/skynet/harbor.lua` | Lua | 港口系统，多节点通信支持 |
| `require "skynet.cluster"` | `./lualib/skynet/cluster.lua` | Lua | 集群管理，跨节点服务调用 |
| `require "skynet.cluster.core"` | `./luaclib/skynet.so` | C | 集群底层实现 |

### 7.4 数据存储 (Data Storage)

| require 语句 | 文件路径 | 类型 | 功能描述 |
|-------------|----------|------|----------|
| `require "skynet.sharedata"` | `./lualib/skynet/sharedata.lua` | Lua | 共享数据访问接口 |
| `require "skynet.sharedata.core"` | `./luaclib/skynet.so` | C | 共享数据底层实现 |
| `require "skynet.sharedata.corelib"` | `./lualib/skynet/sharedata/corelib.lua` | Lua | 共享数据核心库 |
| `require "skynet.datacenter"` | `./lualib/skynet/datacenter.lua` | Lua | 数据中心服务 |
| `require "skynet.datasheet.core"` | `./luaclib/skynet.so` | C | 数据表核心实现 |
| `require "skynet.datasheet.init"` | `./lualib/skynet/datasheet/init.lua` | Lua | 数据表初始化 |
| `require "skynet.datasheet.builder"` | `./lualib/skynet/datasheet/builder.lua` | Lua | 数据表构建器 |
| `require "skynet.datasheet.dump"` | `./lualib/skynet/datasheet/dump.lua` | Lua | 数据表转储 |

### 7.5 数据库支持 (Database Support)

| require 语句 | 文件路径 | 类型 | 功能描述 |
|-------------|----------|------|----------|
| `require "skynet.db.mysql"` | `./lualib/skynet/db/mysql.lua` | Lua | MySQL数据库连接器 |
| `require "skynet.db.redis"` | `./lualib/skynet/db/redis.lua` | Lua | Redis数据库连接器 |
| `require "skynet.db.redis.cluster"` | `./lualib/skynet/db/redis/cluster.lua` | Lua | Redis集群支持 |
| `require "skynet.db.redis.crc16"` | `./lualib/skynet/db/redis/crc16.lua` | Lua | Redis CRC16算法 |
| `require "skynet.db.mongo"` | `./lualib/skynet/db/mongo.lua` | Lua | MongoDB数据库连接器 |
| `require "skynet.mongo.driver"` | `./lualib/skynet/mongo/driver.lua` | Lua | MongoDB驱动 |

### 7.6 工具和实用模块 (Utility Modules)

| require 语句 | 文件路径 | 类型 | 功能描述 |
|-------------|----------|------|----------|
| `require "skynet.crypt"` | `./luaclib/skynet.so` | C | 加密和哈希函数 |
| `require "skynet.memory"` | `./luaclib/skynet.so` | C | 内存管理和监控 |
| `require "skynet.profile"` | `./lualib/skynet/profile.lua` | Lua | 性能分析工具 |
| `require "skynet.debug"` | `./lualib/skynet/debug.lua` | Lua | 调试工具 |
| `require "skynet.codecache"` | `./lualib/skynet/codecache.lua` | Lua | 代码缓存管理 |
| `require "skynet.dns"` | `./lualib/skynet/dns.lua` | Lua | DNS解析器 |

### 7.7 并发和同步 (Concurrency & Synchronization)

| require 语句 | 文件路径 | 类型 | 功能描述 |
|-------------|----------|------|----------|
| `require "skynet.queue"` | `./lualib/skynet/queue.lua` | Lua | 任务队列，串行化执行 |
| `require "skynet.mqueue"` | `./lualib/skynet/mqueue.lua` | Lua | 消息队列 |
| `require "skynet.multicast"` | `./lualib/skynet/multicast.lua` | Lua | 多播消息 |
| `require "skynet.multicast.core"` | `./luaclib/skynet.so` | C | 多播底层实现 |
| `require "skynet.stm"` | `./luaclib/skynet.so` | C | 软件事务内存 |
| `require "skynet.sharemap"` | `./lualib/skynet/sharemap.lua` | Lua | 共享映射表 |
| `require "skynet.sharetable"` | `./lualib/skynet/sharetable.lua` | Lua | 共享表实现 |
| `require "skynet.sharetable.core"` | `./luaclib/skynet.so` | C | 共享表底层实现 |

### 7.8 调试和诊断 (Debug & Diagnostics)

| require 语句 | 文件路径 | 类型 | 功能描述 |
|-------------|----------|------|----------|
| `require "skynet.debugchannel"` | `./luaclib/skynet.so` | C | 调试通道 |
| `require "skynet.remotedebug"` | `./lualib/skynet/remotedebug.lua` | Lua | 远程调试支持 |
| `require "skynet.inject"` | `./lualib/skynet/inject.lua` | Lua | 代码注入 |
| `require "skynet.injectcode"` | `./lualib/skynet/injectcode.lua` | Lua | 代码注入实现 |

### 7.9 Snax 框架 (Snax Framework)

| require 语句 | 文件路径 | 类型 | 功能描述 |
|-------------|----------|------|----------|
| `require "snax"` | `./lualib/snax.lua` | Lua | Snax框架入口 |
| `require "skynet.snax"` | `./lualib/skynet/snax.lua` | Lua | Snax集成模块 |
| `require "snax.interface"` | `./lualib/snax/interface.lua` | Lua | Snax接口定义 |
| `require "snax.gateserver"` | `./lualib/snax/gateserver.lua` | Lua | 网关服务器框架 |
| `require "snax.msgserver"` | `./lualib/snax/msgserver.lua` | Lua | 消息服务器框架 |
| `require "snax.loginserver"` | `./lualib/snax/loginserver.lua` | Lua | 登录服务器框架 |
| `require "snax.hotfix"` | `./lualib/snax/hotfix.lua` | Lua | 热修复支持 |

### 7.10 协议和序列化 (Protocol & Serialization)

| require 语句 | 文件路径 | 类型 | 功能描述 |
|-------------|----------|------|----------|
| `require "sproto"` | `./lualib/sproto.lua` | Lua | Sproto协议库 |
| `require "sproto.core"` | `./luaclib/skynet.so` | C | Sproto底层实现 |
| `require "sprotoparser"` | `./lualib/sprotoparser.lua` | Lua | Sproto解析器 |
| `require "sprotoloader"` | `./lualib/sprotoloader.lua` | Lua | Sproto加载器 |
| `require "bson"` | `./luaclib/bson.so` | C | BSON序列化 |

### 7.11 HTTP 支持 (HTTP Support)

| require 语句 | 文件路径 | 类型 | 功能描述 |
|-------------|----------|------|----------|
| `require "http.httpd"` | `./lualib/http/httpd.lua` | Lua | HTTP服务器 |
| `require "http.httpc"` | `./lualib/http/httpc.lua` | Lua | HTTP客户端 |
| `require "http.sockethelper"` | `./lualib/http/sockethelper.lua` | Lua | HTTP socket助手 |
| `require "http.internal"` | `./lualib/http/internal.lua` | Lua | HTTP内部实现 |
| `require "http.websocket"` | `./lualib/http/websocket.lua` | Lua | WebSocket支持 |
| `require "http.url"` | `./lualib/http/url.lua` | Lua | URL解析 |
| `require "http.tlshelper"` | `./lualib/http/tlshelper.lua` | Lua | TLS支持 |

### 7.12 第三方库 (Third-party Libraries)

| require 语句 | 文件路径 | 类型 | 功能描述 |
|-------------|----------|------|----------|
| `require "lpeg"` | 系统库 | C | LPEG模式匹配 |
| `require "cjson"` | 系统库 | C | JSON编解码 |
| `require "md5"` | `./lualib/md5.lua` | Lua | MD5哈希 |
| `require "md5.core"` | `./luaclib/md5.so` | C | MD5底层实现 |
| `require "ltls.c"` | 外部库 | C | TLS支持 |
| `require "ltls.init.c"` | 外部库 | C | TLS初始化 |

### 7.13 客户端库 (Client Libraries)

| require 语句 | 文件路径 | 类型 | 功能描述 |
|-------------|----------|------|----------|
| `require "client.socket"` | `./luaclib/client.so` | C | 客户端socket |
| `require "client.crypt"` | `./luaclib/client.so` | C | 客户端加密 |

### 7.14 兼容性模块 (Compatibility Modules)

**位置**: `./lualib/compat10/` - 提供向后兼容支持

| require 语句 | 功能 |
|-------------|------|
| `require "socket"` → `skynet.socket` | 兼容旧版socket接口 |
| `require "cluster"` → `skynet.cluster` | 兼容旧版集群接口 |
| `require "sharedata"` → `skynet.sharedata` | 兼容旧版共享数据接口 |
| `require "snax"` → `skynet.snax` | 兼容旧版snax接口 |
| ... | 其他兼容性映射 |

## 8. 最佳实践

### 8.1 模块查找优先级

1. **优先使用绝对路径**：明确指定模块位置
2. **检查 package.loaded**：避免重复加载
3. **理解搜索顺序**：当前目录 → 系统目录
4. **注意命名冲突**：避免与系统模块同名

### 8.2 性能考虑

1. **模块缓存**：require 自动缓存已加载模块
2. **路径优化**：将常用路径放在搜索列表前面
3. **延迟加载**：在真正需要时才 require

### 7.3 调试建议

1. **使用 package.searchpath**：确认模块位置
2. **检查符号导出**：使用 nm 查看 C 库符号
3. **启用详细日志**：跟踪模块加载过程
4. **验证依赖关系**：确保所有依赖都能找到

## 8. 常见问题

### Q1: require "xxx" 报错 "module not found"
**解决方法**：
1. 检查 package.path 和 package.cpath
2. 确认文件存在且有读取权限
3. 验证路径中的通配符匹配

### Q2: C 模块加载报错 "undefined symbol"
**解决方法**：
1. 检查 luaopen_* 函数是否正确导出
2. 确认库文件架构匹配 (32/64位)
3. 验证 Lua 版本兼容性

### Q3: 模块加载了但功能不对
**解决方法**：
1. 检查是否加载了错误的同名文件
2. 确认模块返回值正确
3. 验证依赖模块版本

---

**总结**：理解 require 的查找机制对于 Lua 开发至关重要。通过掌握路径搜索规则、使用调试工具和遵循最佳实践，可以有效解决模块加载问题并优化项目结构。
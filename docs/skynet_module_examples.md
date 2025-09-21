# Skynet 模块查找实战示例

本文档提供了 Skynet 项目中常见 require 语句的实际查找示例和验证方法。

## 1. 实际验证脚本

### 检查模块位置脚本

```bash
#!/bin/bash
# save as: check_modules.sh

echo "=== Skynet 模块位置检查 ==="

# 检查 Lua 模块
echo -e "\n1. Lua 模块:"
for module in "skynet" "skynet.manager" "skynet.socket" "skynet.harbor"; do
    file=$(find . -name "*.lua" -path "*${module//.//}*" 2>/dev/null | head -1)
    if [ -n "$file" ]; then
        echo "  $module -> $file"
    else
        echo "  $module -> NOT FOUND"
    fi
done

# 检查 C 模块  
echo -e "\n2. C 模块:"
for module in "skynet.core" "skynet.socketdriver" "skynet.netpack"; do
    # 查找包含对应 luaopen 函数的 .so 文件
    luaopen_func="luaopen_${module//./_}"
    so_file=$(find . -name "*.so" -exec nm -D {} 2>/dev/null \; | grep -l "$luaopen_func" | head -1)
    if [ -n "$so_file" ]; then
        echo "  $module -> $so_file (function: $luaopen_func)"
    else
        echo "  $module -> NOT FOUND"
    fi
done

# 检查服务模块
echo -e "\n3. 服务模块:"
for service in "bootstrap" "launcher" "console" "gate"; do
    file=$(find ./service -name "${service}.lua" 2>/dev/null)
    if [ -n "$file" ]; then
        echo "  $service -> $file"
    else
        echo "  $service -> NOT FOUND"
    fi
done

echo -e "\n=== 完成 ==="
```

### Lua 运行时检查脚本

```lua
-- save as: check_require.lua
-- 运行: ./skynet examples/config check_require.lua

local skynet = require "skynet"

skynet.start(function()
    print("=== Skynet 模块查找验证 ===")
    
    -- 1. 检查路径配置
    print("\n1. 路径配置:")
    print("  package.path =", package.path)
    print("  package.cpath =", package.cpath)
    
    -- 2. 检查已加载模块
    print("\n2. 已加载的 Skynet 相关模块:")
    for name, mod in pairs(package.loaded) do
        if name:match("skynet") then
            print("  " .. name .. " -> " .. type(mod))
        end
    end
    
    -- 3. 测试模块查找
    print("\n3. 模块查找测试:")
    local test_modules = {
        "skynet",
        "skynet.core", 
        "skynet.manager",
        "skynet.socket",
        "skynet.socketdriver"
    }
    
    for _, mod_name in ipairs(test_modules) do
        -- 查找 Lua 模块
        local lua_path = package.searchpath(mod_name, package.path)
        if lua_path then
            print("  " .. mod_name .. " (Lua) -> " .. lua_path)
        else
            -- 查找 C 模块
            local c_path = package.searchpath(mod_name, package.cpath)
            if c_path then
                print("  " .. mod_name .. " (C) -> " .. c_path)
            else
                print("  " .. mod_name .. " -> NOT FOUND")
            end
        end
    end
    
    -- 4. 验证 C 模块符号
    print("\n4. C 模块符号验证:")
    local c = require "skynet.core"
    print("  skynet.core.send =", type(c.send))
    print("  skynet.core.command =", type(c.command))
    print("  skynet.core.pack =", type(c.pack))
    
    skynet.exit()
end)
```

## 2. 常见模块映射表

| require 语句 | 文件位置 | 类型 | 说明 |
|-------------|----------|------|------|
| `require "skynet"` | `./lualib/skynet.lua` | Lua | 核心框架模块 |
| `require "skynet.manager"` | `./lualib/skynet/manager.lua` | Lua | 管理功能扩展 |
| `require "skynet.core"` | `./luaclib/skynet.so` | C | 底层API桥接 |
| `require "skynet.socket"` | `./lualib/skynet/socket.lua` | Lua | 网络编程封装 |
| `require "skynet.socketdriver"` | `./luaclib/skynet.so` | C | 底层socket实现 |
| `require "skynet.netpack"` | `./luaclib/skynet.so` | C | 网络包处理 |
| `require "skynet.harbor"` | `./lualib/skynet/harbor.lua` | Lua | 分布式支持 |
| `require "skynet.cluster"` | `./lualib/skynet/cluster.lua` | Lua | 集群管理 |
| `require "snax"` | `./lualib/snax.lua` | Lua | Actor框架 |
| `require "sproto"` | `./lualib/sproto.lua` | Lua | 协议序列化 |

## 3. 验证命令集合

```bash
# 查看编译后的动态库
ls -la luaclib/

# 检查 skynet.so 中的导出符号
nm -D luaclib/skynet.so | grep luaopen

# 查找特定模块文件
find . -name "*.lua" -path "*skynet*" | head -10

# 检查服务模块
ls -la service/

# 验证 C 模块符号存在
objdump -T luaclib/skynet.so | grep skynet_core

# 检查依赖关系
ldd luaclib/skynet.so
```

## 4. 调试技巧实例

### 启用详细 require 日志

```lua
-- 在服务开头添加
local original_require = require
_G.require = function(name)
    local start_time = skynet.now()
    
    -- 尝试查找路径
    local lua_path = package.searchpath(name, package.path)
    local c_path = package.searchpath(name, package.cpath)
    
    print(string.format("[REQUIRE] %s", name))
    if lua_path then
        print(string.format("  -> Lua: %s", lua_path))
    elseif c_path then
        print(string.format("  -> C: %s", c_path))
    else
        print(string.format("  -> SEARCHING..."))
    end
    
    local result = original_require(name)
    local end_time = skynet.now()
    
    print(string.format("  -> LOADED in %dms", end_time - start_time))
    return result
end
```

### 检查模块加载状态

```lua
-- 检查是否已加载
local function check_module_loaded(name)
    if package.loaded[name] then
        print(name .. " 已加载，类型:", type(package.loaded[name]))
        return true
    else
        print(name .. " 未加载")
        return false
    end
end

-- 使用示例
check_module_loaded("skynet.core")
check_module_loaded("skynet.manager")
```

## 5. 问题排查流程

### 问题 1: "module 'xxx' not found"

**排查步骤**：
```bash
# 1. 检查文件是否存在
find . -name "*xxx*" -type f

# 2. 检查路径配置
lua -e "print(package.path)"
lua -e "print(package.cpath)"

# 3. 手动测试查找
lua -e "print(package.searchpath('xxx', package.path))"
lua -e "print(package.searchpath('xxx', package.cpath))"
```

### 问题 2: C 模块 "undefined symbol"

**排查步骤**：
```bash
# 1. 检查符号是否导出
nm -D luaclib/skynet.so | grep luaopen_xxx

# 2. 检查库依赖
ldd luaclib/skynet.so

# 3. 验证架构匹配
file luaclib/skynet.so
uname -m
```

### 问题 3: 加载了错误的模块

**排查步骤**：
```lua
-- 1. 检查加载路径
local path = package.searchpath("module_name", package.path)
print("实际加载路径:", path)

-- 2. 检查模块内容
local mod = require "module_name"
print("模块类型:", type(mod))
if type(mod) == "table" then
    for k, v in pairs(mod) do
        print("  " .. k .. ":", type(v))
    end
end

-- 3. 检查模块来源
local debug_info = debug.getinfo(mod.some_function, "S")
print("函数来源:", debug_info.source)
```

## 6. 性能优化建议

### 减少模块查找时间

```lua
-- 1. 预加载常用模块
local common_modules = {
    "skynet.core",
    "skynet.socket", 
    "skynet.manager"
}

for _, mod in ipairs(common_modules) do
    require(mod)
end

-- 2. 缓存模块引用
local skynet_core = require "skynet.core"
local skynet_socket = require "skynet.socket"

-- 3. 延迟加载重模块
local function get_http_module()
    if not package.loaded["http"] then
        return require "http"
    end
    return package.loaded["http"]
end
```

### 优化路径搜索

```lua
-- 将常用路径放在前面
package.path = "./lualib/?.lua;" .. package.path
package.cpath = "./luaclib/?.so;" .. package.cpath
```

## 7. 开发工具脚本

### 模块依赖分析工具

```bash
#!/bin/bash
# analyze_deps.sh - 分析模块依赖关系

echo "=== 模块依赖分析 ==="

if [ -z "$1" ]; then
    echo "用法: $0 <module_file.lua>"
    exit 1
fi

echo "分析文件: $1"
echo "依赖模块:"

grep -n "require.*[\"']" "$1" | while read line; do
    module=$(echo "$line" | sed -n 's/.*require.*[\"'\'\'\"]\([^\"'\'']*\)[\"'\'\'"].*/\1/p')
    line_num=$(echo "$line" | cut -d: -f1)
    echo "  行 $line_num: $module"
    
    # 查找模块位置
    lua_path=$(find . -name "*.lua" -path "*${module//.//}*" 2>/dev/null | head -1)
    if [ -n "$lua_path" ]; then
        echo "    -> $lua_path"
    else
        echo "    -> 可能是 C 模块或未找到"
    fi
done
```

---

通过这些实际示例和工具，你可以快速定位任何 Skynet 模块的实际位置，理解其作用，并解决相关的加载问题。
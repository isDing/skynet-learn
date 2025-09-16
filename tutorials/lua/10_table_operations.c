#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>

// ============== 1. 表的创建和基本操作 ==============
void table_basics() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("=== Table Basics ===\n");
    
    // 创建空表
    lua_newtable(L);
    
    // 设置字段 t.name = "skynet"
    lua_pushstring(L, "skynet");
    lua_setfield(L, -2, "name");
    
    // 设置字段 t.port = 8888
    lua_pushinteger(L, 8888);
    lua_setfield(L, -2, "port");
    
    // 设置数组元素 t[1] = "first"
    lua_pushstring(L, "first");
    lua_rawseti(L, -2, 1);
    
    // 设置数组元素 t[2] = "second"
    lua_pushstring(L, "second");
    lua_rawseti(L, -2, 2);
    
    // 读取字段
    lua_getfield(L, -1, "name");
    printf("name: %s\n", lua_tostring(L, -1));
    lua_pop(L, 1);
    
    lua_getfield(L, -1, "port");
    printf("port: %lld\n", lua_tointeger(L, -1));
    lua_pop(L, 1);
    
    // 读取数组元素
    lua_rawgeti(L, -1, 1);
    printf("[1]: %s\n", lua_tostring(L, -1));
    lua_pop(L, 1);
    
    lua_rawgeti(L, -1, 2);
    printf("[2]: %s\n", lua_tostring(L, -1));
    lua_pop(L, 1);
    
    lua_pop(L, 1);  // 弹出表
    lua_close(L);
}

// ============== 2. 表的遍历 ==============
void table_iteration() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("\n=== Table Iteration ===\n");
    
    // 创建一个混合表
    lua_newtable(L);
    
    // 添加一些数据
    lua_pushstring(L, "value1");
    lua_setfield(L, -2, "key1");
    
    lua_pushstring(L, "value2");
    lua_setfield(L, -2, "key2");
    
    lua_pushstring(L, "array1");
    lua_rawseti(L, -2, 1);
    
    lua_pushstring(L, "array2");
    lua_rawseti(L, -2, 2);
    
    // 遍历表
    printf("Iterating table:\n");
    lua_pushnil(L);  // 第一个键
    while (lua_next(L, -2) != 0) {
        // 栈: -1 => value; -2 => key; -3 => table
        
        // 复制键，因为 lua_tostring 可能修改栈上的值
        lua_pushvalue(L, -2);
        
        const char *key = lua_tostring(L, -1);
        const char *value = lua_tostring(L, -2);
        
        if (key && value) {
            printf("  %s = %s\n", key, value);
        }
        
        lua_pop(L, 2);  // 弹出复制的键和值
    }
    
    lua_pop(L, 1);  // 弹出表
    lua_close(L);
}

// ============== 3. 创建带元表的对象 ==============
static int vector_add(lua_State *L) {
    // 获取两个向量
    lua_getfield(L, 1, "x");
    lua_getfield(L, 1, "y");
    double x1 = lua_tonumber(L, -2);
    double y1 = lua_tonumber(L, -1);
    lua_pop(L, 2);
    
    lua_getfield(L, 2, "x");
    lua_getfield(L, 2, "y");
    double x2 = lua_tonumber(L, -2);
    double y2 = lua_tonumber(L, -1);
    lua_pop(L, 2);
    
    // 创建结果向量
    lua_newtable(L);
    lua_pushnumber(L, x1 + x2);
    lua_setfield(L, -2, "x");
    lua_pushnumber(L, y1 + y2);
    lua_setfield(L, -2, "y");
    
    // 设置元表
    luaL_getmetatable(L, "Vector");
    lua_setmetatable(L, -2);
    
    return 1;
}

static int vector_tostring(lua_State *L) {
    lua_getfield(L, 1, "x");
    lua_getfield(L, 1, "y");
    double x = lua_tonumber(L, -2);
    double y = lua_tonumber(L, -1);
    lua_pop(L, 2);
    
    lua_pushfstring(L, "Vector(%f, %f)", x, y);
    return 1;
}

void metatable_demo() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("\n=== Metatable Demo ===\n");
    
    // 创建 Vector 元表
    luaL_newmetatable(L, "Vector");
    
    // 设置 __add 元方法
    lua_pushcfunction(L, vector_add);
    lua_setfield(L, -2, "__add");
    
    // 设置 __tostring 元方法
    lua_pushcfunction(L, vector_tostring);
    lua_setfield(L, -2, "__tostring");
    
    lua_pop(L, 1);  // 弹出元表
    
    // 创建两个向量
    lua_newtable(L);
    lua_pushnumber(L, 3.0);
    lua_setfield(L, -2, "x");
    lua_pushnumber(L, 4.0);
    lua_setfield(L, -2, "y");
    luaL_getmetatable(L, "Vector");
    lua_setmetatable(L, -2);
    lua_setglobal(L, "v1");
    
    lua_newtable(L);
    lua_pushnumber(L, 1.0);
    lua_setfield(L, -2, "x");
    lua_pushnumber(L, 2.0);
    lua_setfield(L, -2, "y");
    luaL_getmetatable(L, "Vector");
    lua_setmetatable(L, -2);
    lua_setglobal(L, "v2");
    
    // 在 Lua 中测试
    luaL_dostring(L, 
        "local v3 = v1 + v2\n"
        "print('v1:', v1)\n"
        "print('v2:', v2)\n"
        "print('v1 + v2:', v3)\n"
    );
    
    lua_close(L);
}

// ============== 4. 数组操作 ==============
void array_operations() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("\n=== Array Operations ===\n");
    
    // 创建数组
    lua_newtable(L);
    
    // 填充数组
    for (int i = 1; i <= 5; i++) {
        lua_pushinteger(L, i * 10);
        lua_rawseti(L, -2, i);
    }
    
    // 获取数组长度
    size_t len = lua_rawlen(L, -1);
    printf("Array length: %zu\n", len);
    
    // 读取数组元素
    printf("Array elements: ");
    for (int i = 1; i <= (int)len; i++) {
        lua_rawgeti(L, -1, i);
        printf("%lld ", lua_tointeger(L, -1));
        lua_pop(L, 1);
    }
    printf("\n");
    
    // 修改数组元素
    lua_pushinteger(L, 999);
    lua_rawseti(L, -2, 3);  // arr[3] = 999
    
    // 验证修改
    lua_rawgeti(L, -1, 3);
    printf("Modified arr[3]: %lld\n", lua_tointeger(L, -1));
    lua_pop(L, 1);
    
    lua_pop(L, 1);  // 弹出数组
    lua_close(L);
}

// ============== 5. 表作为缓存 ==============
static int cached_compute(lua_State *L) {
    int n = luaL_checkinteger(L, 1);
    
    // 获取缓存表（在上值中）
    lua_pushvalue(L, lua_upvalueindex(1));
    
    // 检查缓存
    lua_pushinteger(L, n);
    lua_gettable(L, -2);
    
    if (!lua_isnil(L, -1)) {
        printf("Cache hit for %d\n", n);
        return 1;  // 返回缓存的值
    }
    lua_pop(L, 1);  // 弹出 nil
    
    // 计算新值（模拟耗时计算）
    printf("Computing for %d...\n", n);
    int result = n * n * n;  // 立方
    
    // 存入缓存
    lua_pushinteger(L, n);
    lua_pushinteger(L, result);
    lua_settable(L, -3);
    
    lua_pop(L, 1);  // 弹出缓存表
    lua_pushinteger(L, result);
    return 1;
}

void cache_demo() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("\n=== Cache Demo ===\n");
    
    // 创建缓存表
    lua_newtable(L);
    
    // 创建带缓存的函数
    lua_pushvalue(L, -1);  // 复制缓存表作为上值
    lua_pushcclosure(L, cached_compute, 1);
    lua_setglobal(L, "compute");
    
    lua_pop(L, 1);  // 弹出缓存表
    
    // 测试缓存
    luaL_dostring(L, 
        "print('Result:', compute(5))\n"
        "print('Result:', compute(5))\n"  // 第二次应该命中缓存
        "print('Result:', compute(3))\n"
        "print('Result:', compute(3))\n"  // 第二次应该命中缓存
    );
    
    lua_close(L);
}

// ============== 6. 弱引用表 ==============
void weak_table_demo() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("\n=== Weak Table Demo ===\n");
    
    // 创建弱引用表
    lua_newtable(L);
    
    // 设置弱引用元表
    lua_newtable(L);
    lua_pushstring(L, "v");  // 值是弱引用
    lua_setfield(L, -2, "__mode");
    lua_setmetatable(L, -2);
    
    lua_setglobal(L, "weak_cache");
    
    // 测试弱引用
    luaL_dostring(L, 
        "-- 创建一些对象并放入弱引用表\n"
        "local obj1 = {name = 'object1'}\n"
        "local obj2 = {name = 'object2'}\n"
        "weak_cache[1] = obj1\n"
        "weak_cache[2] = obj2\n"
        "weak_cache[3] = {name = 'temp'}  -- 没有强引用的对象\n"
        "\n"
        "print('Before GC:')\n"
        "for k, v in pairs(weak_cache) do\n"
        "    print('  ', k, v.name)\n"
        "end\n"
        "\n"
        "-- 垃圾回收\n"
        "collectgarbage('collect')\n"
        "\n"
        "print('After GC:')\n"
        "for k, v in pairs(weak_cache) do\n"
        "    print('  ', k, v.name)\n"
        "end\n"
        "-- obj1 和 obj2 还在（有强引用）\n"
        "-- temp 对象被回收了（没有强引用）\n"
    );
    
    lua_close(L);
}

// ============== 7. 表的序列化 ==============
void serialize_table(lua_State *L, int idx, int indent) {
    if (idx < 0) {
        idx = lua_gettop(L) + idx + 1;
    }
    
    const char *spacing = "";
    for (int i = 0; i < indent; i++) {
        printf("  ");
    }
    printf("{\n");
    
    lua_pushnil(L);
    while (lua_next(L, idx) != 0) {
        // 打印缩进
        for (int i = 0; i <= indent; i++) {
            printf("  ");
        }
        
        // 打印键
        int key_type = lua_type(L, -2);
        if (key_type == LUA_TSTRING) {
            printf("[\"%s\"] = ", lua_tostring(L, -2));
        } else if (key_type == LUA_TNUMBER) {
            printf("[%g] = ", lua_tonumber(L, -2));
        } else {
            printf("[%s] = ", lua_typename(L, key_type));
        }
        
        // 打印值
        int value_type = lua_type(L, -1);
        if (value_type == LUA_TTABLE) {
            printf("\n");
            serialize_table(L, lua_gettop(L), indent + 1);
        } else if (value_type == LUA_TSTRING) {
            printf("\"%s\"", lua_tostring(L, -1));
        } else if (value_type == LUA_TNUMBER) {
            printf("%g", lua_tonumber(L, -1));
        } else if (value_type == LUA_TBOOLEAN) {
            printf("%s", lua_toboolean(L, -1) ? "true" : "false");
        } else {
            printf("%s", lua_typename(L, value_type));
        }
        
        printf(",\n");
        lua_pop(L, 1);
    }
    
    for (int i = 0; i < indent; i++) {
        printf("  ");
    }
    printf("}");
    if (indent == 0) printf("\n");
}

void serialization_demo() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("\n=== Serialization Demo ===\n");
    
    // 创建复杂的嵌套表
    luaL_dostring(L, 
        "complex_table = {\n"
        "    name = 'skynet',\n"
        "    version = 1.0,\n"
        "    active = true,\n"
        "    services = {\n"
        "        'gate',\n"
        "        'agent',\n"
        "        'db'\n"
        "    },\n"
        "    config = {\n"
        "        host = '127.0.0.1',\n"
        "        port = 8888,\n"
        "        workers = 4\n"
        "    }\n"
        "}\n"
    );
    
    lua_getglobal(L, "complex_table");
    printf("Serialized table:\n");
    serialize_table(L, -1, 0);
    lua_pop(L, 1);
    
    lua_close(L);
}

// ============== 8. 表的性能测试 ==============
void performance_test() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("\n=== Performance Test ===\n");
    
    clock_t start, end;
    double cpu_time_used;
    const int N = 100000;
    
    // 测试1：预分配 vs 动态增长
    start = clock();
    lua_newtable(L);
    for (int i = 1; i <= N; i++) {
        lua_pushinteger(L, i);
        lua_rawseti(L, -2, i);
    }
    lua_pop(L, 1);
    end = clock();
    cpu_time_used = ((double)(end - start)) / CLOCKS_PER_SEC;
    printf("Dynamic growth (%d items): %.3f seconds\n", N, cpu_time_used);
    
    // 测试2：使用 lua_createtable 预分配
    start = clock();
    lua_createtable(L, N, 0);  // 预分配 N 个数组槽位
    for (int i = 1; i <= N; i++) {
        lua_pushinteger(L, i);
        lua_rawseti(L, -2, i);
    }
    lua_pop(L, 1);
    end = clock();
    cpu_time_used = ((double)(end - start)) / CLOCKS_PER_SEC;
    printf("Pre-allocated (%d items): %.3f seconds\n", N, cpu_time_used);
    
    // 测试3：字典操作性能
    start = clock();
    lua_newtable(L);
    char key[32];
    for (int i = 1; i <= N/10; i++) {
        snprintf(key, sizeof(key), "key_%d", i);
        lua_pushstring(L, key);
        lua_pushinteger(L, i);
        lua_settable(L, -3);
    }
    lua_pop(L, 1);
    end = clock();
    cpu_time_used = ((double)(end - start)) / CLOCKS_PER_SEC;
    printf("Dictionary operations (%d items): %.3f seconds\n", N/10, cpu_time_used);
    
    lua_close(L);
}

// ============== 9. Skynet 风格的服务表 ==============
static int dispatch_message(lua_State *L) {
    const char *cmd = luaL_checkstring(L, 1);
    
    // 获取命令处理器表（在上值中）
    lua_pushvalue(L, lua_upvalueindex(1));
    
    // 查找对应的处理函数
    lua_getfield(L, -1, cmd);
    
    if (lua_isfunction(L, -1)) {
        // 调用处理函数，传递剩余参数
        int nargs = lua_gettop(L) - 2;  // 除去 cmd 和处理器表
        for (int i = 2; i <= nargs + 1; i++) {
            lua_pushvalue(L, i);
        }
        lua_call(L, nargs, LUA_MULTRET);
        return lua_gettop(L) - 2;  // 返回所有结果
    } else {
        return luaL_error(L, "Unknown command: %s", cmd);
    }
}

void skynet_style_demo() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("\n=== Skynet Style Service Demo ===\n");
    
    // 创建命令处理器表
    lua_newtable(L);
    
    // 注册命令处理器
    luaL_dostring(L, 
        "return {\n"
        "    start = function(...)\n"
        "        print('Service started with args:', ...)\n"
        "        return 'OK'\n"
        "    end,\n"
        "    stop = function()\n"
        "        print('Service stopping...')\n"
        "        return 'STOPPED'\n"
        "    end,\n"
        "    query = function(key)\n"
        "        print('Querying:', key)\n"
        "        return 'value_of_' .. key\n"
        "    end\n"
        "}\n"
    );
    
    // 创建分发函数
    lua_pushvalue(L, -1);  // 复制处理器表作为上值
    lua_pushcclosure(L, dispatch_message, 1);
    lua_setglobal(L, "dispatch");
    
    lua_pop(L, 1);  // 弹出处理器表
    
    // 测试消息分发
    luaL_dostring(L, 
        "print('Dispatch result:', dispatch('start', 'arg1', 'arg2'))\n"
        "print('Dispatch result:', dispatch('query', 'name'))\n"
        "print('Dispatch result:', dispatch('stop'))\n"
        "-- print('Dispatch result:', dispatch('unknown'))  -- 会报错\n"
    );
    
    lua_close(L);
}

// ============== 10. 表的高级技巧 ==============
void advanced_techniques() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("\n=== Advanced Table Techniques ===\n");
    
    // 技巧1：使用表作为集合
    luaL_dostring(L, 
        "-- 集合操作\n"
        "local set = {}\n"
        "local items = {'a', 'b', 'c', 'a', 'b'}\n"
        "for _, v in ipairs(items) do\n"
        "    set[v] = true\n"
        "end\n"
        "print('Unique items:')\n"
        "for k in pairs(set) do\n"
        "    print('  ', k)\n"
        "end\n"
    );
    
    // 技巧2：表的深拷贝
    luaL_dostring(L, 
        "function deep_copy(t)\n"
        "    if type(t) ~= 'table' then return t end\n"
        "    local copy = {}\n"
        "    for k, v in pairs(t) do\n"
        "        copy[deep_copy(k)] = deep_copy(v)\n"
        "    end\n"
        "    return setmetatable(copy, getmetatable(t))\n"
        "end\n"
        "\n"
        "local original = {a = 1, b = {c = 2}}\n"
        "local copy = deep_copy(original)\n"
        "copy.b.c = 3\n"
        "print('Original:', original.b.c)  -- 还是 2\n"
        "print('Copy:', copy.b.c)          -- 变成 3\n"
    );
    
    // 技巧3：默认值表
    luaL_dostring(L, 
        "-- 带默认值的表\n"
        "local defaults = {host = '127.0.0.1', port = 8080}\n"
        "local config = setmetatable({port = 9090}, {\n"
        "    __index = defaults\n"
        "})\n"
        "print('Host:', config.host)  -- 使用默认值\n"
        "print('Port:', config.port)  -- 使用覆盖值\n"
    );
    
    lua_close(L);
}

int main() {
    table_basics();
    table_iteration();
    metatable_demo();
    array_operations();
    cache_demo();
    weak_table_demo();
    serialization_demo();
    performance_test();
    skynet_style_demo();
    advanced_techniques();
    
    return 0;
}
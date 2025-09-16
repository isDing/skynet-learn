#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// 注册表是一个特殊的全局表，用于存储 C 代码需要的 Lua 值
void registry_demo() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("=== Registry Demo ===\n");
    
    // 1. 在注册表中存储值
    lua_pushstring(L, "skynet_context_pointer");
    lua_pushlightuserdata(L, (void*)0x12345678);  // 模拟指针
    lua_settable(L, LUA_REGISTRYINDEX);
    
    // 2. 使用 setfield 简化操作
    lua_pushboolean(L, 1);
    lua_setfield(L, LUA_REGISTRYINDEX, "LUA_NOENV");
    
    // 3. 存储 Lua 函数引用 (跳过 C 函数示例)
    lua_pushnumber(L, 42);
    lua_setfield(L, LUA_REGISTRYINDEX, "c_data_ref");
    
    // 4. 从注册表读取值
    lua_getfield(L, LUA_REGISTRYINDEX, "LUA_NOENV");
    if (lua_toboolean(L, -1)) {
        printf("LUA_NOENV is set to true\n");
    }
    lua_pop(L, 1);
    
    // 5. 检查注册表中的所有键值
    printf("Registry contents:\n");
    lua_pushnil(L);
    while (lua_next(L, LUA_REGISTRYINDEX)) {
        // 栈: [key, value]
        const char* key_str = "unknown";
        if (lua_type(L, -2) == LUA_TSTRING) {
            key_str = lua_tostring(L, -2);
        }
        
        const char* value_type = lua_typename(L, lua_type(L, -1));
        printf("  %s: %s\n", key_str, value_type);
        
        lua_pop(L, 1);  // 保留 key 用于下次迭代
    }
    
    lua_close(L);
}

// Lua 引用系统用于在 C 代码中持久化保存 Lua 值
void reference_demo() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("=== Reference System Demo ===\n");
    
    // 1. 创建一个复杂的 Lua 对象
    luaL_dostring(L, 
        "local obj = {\n"
        "    name = \"test_object\",\n"
        "    data = {1, 2, 3, 4, 5},\n"
        "    func = function(self)\n" 
        "        return \"Hello from \" .. self.name\n"
        "    end\n"
        "}\n"
        "return obj\n"
    );
    
    // 2. 创建引用 (对象会从栈中弹出)
    int obj_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    printf("Created reference: %d\n", obj_ref);
    printf("Stack size after ref: %d\n", lua_gettop(L));
    
    // 3. 稍后使用引用
    printf("\n--- Using reference later ---\n");
    
    // 将引用的对象推回栈
    lua_rawgeti(L, LUA_REGISTRYINDEX, obj_ref);
    
    // 调用对象的方法
    lua_getfield(L, -1, "func");  // 获取 func 方法
    lua_pushvalue(L, -2);         // 复制 obj 作为 self 参数
    lua_call(L, 1, 1);            // 调用 func(self)
    
    printf("Method result: %s\n", lua_tostring(L, -1));
    lua_pop(L, 2);  // 弹出结果和对象
    
    // 4. 释放引用
    luaL_unref(L, LUA_REGISTRYINDEX, obj_ref);
    printf("Reference freed\n");
    
    lua_close(L);
}

// 创建弱引用表，用于缓存但不阻止垃圾回收
void weak_table_demo() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("=== Weak Table Demo ===\n");
    
    // 1. 创建弱引用表 (类似 skynet profile 模块中的做法)
    lua_newtable(L);              // 主表
    lua_newtable(L);              // 弱表元表
    lua_pushliteral(L, "kv");     // 键值都是弱引用
    lua_setfield(L, -2, "__mode");
    lua_setmetatable(L, -2);      // 设置弱引用元表
    
    int weak_table_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    
    // 2. 在弱表中存储对象
    lua_rawgeti(L, LUA_REGISTRYINDEX, weak_table_ref);
    
    // 创建一个临时对象
    lua_newtable(L);
    lua_pushstring(L, "temporary_data");
    lua_setfield(L, -2, "data");
    
    // 使用对象自身作为键
    lua_pushvalue(L, -1);  // 复制对象作为键
    lua_pushstring(L, "associated_value");
    lua_rawset(L, -3);     // weak_table[obj] = "associated_value"
    
    lua_pop(L, 2);  // 弹出对象和弱表
    
    // 3. 强制垃圾回收
    printf("Before GC:\n");
    lua_rawgeti(L, LUA_REGISTRYINDEX, weak_table_ref);
    lua_len(L, -1);
    printf("Weak table size: %lld\n", lua_tointeger(L, -1));
    lua_pop(L, 2);
    
    lua_gc(L, LUA_GCCOLLECT, 0);  // 全量垃圾回收
    
    printf("After GC:\n");
    lua_rawgeti(L, LUA_REGISTRYINDEX, weak_table_ref);
    lua_len(L, -1);
    printf("Weak table size: %lld\n", lua_tointeger(L, -1));
    lua_pop(L, 2);
    
    luaL_unref(L, LUA_REGISTRYINDEX, weak_table_ref);
    lua_close(L);
}

// 不是所有应用都需要全部标准库，可以选择性加载
void selective_library_loading() {
    lua_State *L = luaL_newstate();
    
    printf("=== Selective Library Loading ===\n");
    
    // 1. 手动加载特定库
    static const luaL_Reg libs[] = {
        {"_G", luaopen_base},           // 基础库
        {LUA_TABLIBNAME, luaopen_table}, // 表操作库
        {LUA_STRLIBNAME, luaopen_string}, // 字符串库
        {LUA_MATHLIBNAME, luaopen_math},  // 数学库
        // 注意：没有加载 io, os, debug 库 (安全考虑)
        {NULL, NULL}
    };
    
    const luaL_Reg *lib;
    for (lib = libs; lib->func; lib++) {
        luaL_requiref(L, lib->name, lib->func, 1);
        lua_pop(L, 1);  // 移除库表的引用
    }
    
    // 2. 测试可用的功能
    printf("Testing loaded libraries:\n");
    
    // 数学库
    luaL_dostring(L, "print('math.pi =', math.pi)");
    
    // 字符串库
    luaL_dostring(L, "print('string.upper =', string.upper('hello'))");
    
    // 表库
    luaL_dostring(L, 
        "local t = {3, 1, 4, 1, 5}\n"
        "table.sort(t)\n"
        "print('sorted table:', table.concat(t, ', '))\n"
    );
    
    // 3. 验证未加载的库
    printf("\nTesting unavailable libraries:\n");
    int result = luaL_dostring(L, "print(io.open)");  // 应该失败
    if (result != LUA_OK) {
        printf("io library not available (as expected)\n");
        lua_pop(L, 1);  // 弹出错误消息
    }
    
    lua_close(L);
}

// 创建自定义 C 模块 (类似 skynet.profile)
static int custom_add(lua_State *L) {
    double a = luaL_checknumber(L, 1);
    double b = luaL_checknumber(L, 2);
    lua_pushnumber(L, a + b);
    return 1;  // 返回 1 个值
}

static int custom_concat(lua_State *L) {
    const char *a = luaL_checkstring(L, 1);
    const char *b = luaL_checkstring(L, 2);
    lua_pushfstring(L, "%s%s", a, b);
    return 1;
}

static int custom_info(lua_State *L) {
    lua_newtable(L);
    
    lua_pushstring(L, "custom_module");
    lua_setfield(L, -2, "name");
    
    lua_pushstring(L, "1.0.0");
    lua_setfield(L, -2, "version");
    
    lua_pushinteger(L, time(NULL));
    lua_setfield(L, -2, "timestamp");
    
    return 1;
}

// 模块函数表
static const luaL_Reg custom_module_funcs[] = {
    {"add", custom_add},
    {"concat", custom_concat},
    {"info", custom_info},
    {NULL, NULL}
};

// 模块初始化函数
static int luaopen_custom_module(lua_State *L) {
    luaL_newlib(L, custom_module_funcs);
    return 1;
}

void custom_module_demo() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("=== Custom Module Demo ===\n");
    
    // 1. 加载自定义模块
    luaL_requiref(L, "custom", luaopen_custom_module, 1);
    lua_pop(L, 1);  // 弹出模块表
    
    // 2. 使用自定义模块
    luaL_dostring(L, 
        "local custom = require('custom')\n"
        "\n"
        "-- 使用模块函数\n"
        "print('3 + 5 =', custom.add(3, 5))\n"
        "print('concat:', custom.concat('Hello, ', 'World!'))\n"
        "\n"
        "-- 获取模块信息\n"
        "local info = custom.info()\n"
        "for k, v in pairs(info) do\n"
        "    print('info.' .. k .. ':', v)\n"
        "end\n"
    );
    
    lua_close(L);
}

// 模拟 skynet 的模块预加载机制
void preload_demo() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("=== Preload Demo ===\n");
    
    // 1. 将模块添加到 package.preload
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "preload");
    
    // 添加我们的自定义模块
    lua_pushcfunction(L, luaopen_custom_module);
    lua_setfield(L, -2, "mymodule");
    
    lua_pop(L, 2);  // 弹出 preload 和 package 表
    
    // 2. 现在可以 require 这个模块
    luaL_dostring(L, 
        "-- 模块会从 package.preload 中加载\n"
        "local mymodule = require('mymodule')\n"
        "print('Module loaded from preload')\n"
        "print('mymodule.add(10, 20) =', mymodule.add(10, 20))\n"
    );
    
    // 3. 检查 package.loaded
    luaL_dostring(L, 
        "print('\\nLoaded modules:')\n"
        "for name, module in pairs(package.loaded) do\n"
        "    if type(name) == 'string' and not name:match('^_') then\n"
        "        print('  ' .. name .. ': ' .. type(module))\n"
        "    end\n"
        "end\n"
    );
    
    lua_close(L);
}

int main() {
    registry_demo();
    printf("\n");
    reference_demo();
    printf("\n");
    weak_table_demo();
    printf("\n");
    selective_library_loading();
    printf("\n");
    custom_module_demo();
    printf("\n");
    preload_demo();
    
    return 0;
}

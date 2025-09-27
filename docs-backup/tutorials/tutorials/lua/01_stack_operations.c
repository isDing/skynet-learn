#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <stdio.h>
#include <stdlib.h>

// 简单的Lua C函数示例
static int dummy_resume(lua_State *L) {
    (void)L; // 避免未使用参数警告
    printf("Profile resume called\n");
    return 0;
}

static int dummy_wrap(lua_State *L) {
    (void)L; // 避免未使用参数警告
    printf("Profile wrap called\n");
    return 0;
}

// 基础栈操作示例
void stack_demo() {
    lua_State *L = luaL_newstate();
    
    // 1. 压入不同类型的值
    lua_pushinteger(L, 42);        // 栈位置: 1
    lua_pushstring(L, "hello");    // 栈位置: 2  
    lua_pushboolean(L, 1);         // 栈位置: 3
    lua_pushnil(L);                // 栈位置: 4
    
    printf("Stack size: %d\n", lua_gettop(L)); // 输出: 4
    
    // 2. 读取栈中的值 (负索引从栈顶开始)
    printf("Top value (nil): %s\n", lua_isnil(L, -1) ? "nil" : "not nil");
    printf("String at -3: %s\n", lua_tostring(L, -3));  // "hello"
    printf("Integer at 1: %lld\n", lua_tointeger(L, 1)); // 42
    
    // 3. 栈操作
    lua_pop(L, 2);  // 弹出 2 个元素 (nil 和 boolean)
    printf("Stack size after pop: %d\n", lua_gettop(L)); // 输出: 2
    
    // 4. 设置栈顶位置 (等价于 pop 操作)
    lua_settop(L, 1);  // 保留栈底的 1 个元素
    printf("Final stack size: %d\n", lua_gettop(L)); // 输出: 1
    
    lua_close(L);
}

// 高级栈操作技巧
void advanced_stack_ops() {
    lua_State *L = luaL_newstate();
    
    // 压入测试数据
    lua_pushstring(L, "first");
    lua_pushstring(L, "second"); 
    lua_pushstring(L, "third");
    
    // 1. 复制栈顶元素
    lua_pushvalue(L, -1);  // 复制 "third"
    // 栈: ["first", "second", "third", "third"]
    
    // 2. 旋转栈元素 
    lua_rotate(L, 1, 1);   // 将栈底元素旋转到栈顶
    // 栈: ["second", "third", "third", "first"]
    
    // 3. 插入元素到指定位置
    lua_pushstring(L, "inserted");
    lua_insert(L, 2);      // 插入到位置 2
    // 栈: ["second", "inserted", "third", "third", "first"]
    
    // 4. 移除指定位置的元素
    lua_remove(L, 3);      // 移除位置 3 的元素
    // 栈: ["second", "inserted", "third", "first"]
    
    printf("Advanced stack operations completed\n");
    printf("Final stack size: %d\n", lua_gettop(L));
    
    lua_close(L);
}

// skynet 风格的栈操作分析
void skynet_style_stack_analysis() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    // 模拟 skynet init_cb 中的栈操作
    printf("=== Skynet Style Stack Analysis ===\n");
    
    // 模拟加载 profile 模块
    lua_newtable(L);  // 创建模拟的 profile 模块
    lua_pushcfunction(L, dummy_resume);  // 使用dummy函数作为示例
    lua_setfield(L, -2, "resume");
    lua_pushcfunction(L, dummy_wrap);
    lua_setfield(L, -2, "wrap");
    
    int profile_lib = lua_gettop(L);  // 记录 profile 模块的栈位置
    printf("Profile module at stack position: %d\n", profile_lib);

    lua_pushnil(L);
    while(lua_next(L, profile_lib)) {
        const char *key = "unknow";
        if (lua_type(L, -2) == LUA_TSTRING) {
            key = lua_tostring(L, -2);
        }
        const char *valuetype = lua_typename(L, lua_type(L, -1));
        printf("key: %s, value: %s\n", key, valuetype);
        lua_pop(L, 1);
    }
    
    // 栈状态分析：
    // 栈顶 -> [skynet.profile 模块] <- profile_lib 指向这里
    
    lua_getglobal(L, "coroutine");        // 获取全局 coroutine 表
    // 栈顶 -> [coroutine 表]
    //        [skynet.profile 模块]
    
    lua_getfield(L, profile_lib, "resume"); // 从 profile 模块获取 resume 函数
    // 栈顶 -> [profile.resume 函数]
    //        [coroutine 表]  
    //        [skynet.profile 模块]
    
    lua_setfield(L, -2, "resume");        // 设置 coroutine.resume = profile.resume
    // 栈顶 -> [coroutine 表]  (resume 字段已被修改)
    //        [skynet.profile 模块]
    
    lua_getfield(L, profile_lib, "wrap");
    lua_setfield(L, -2, "wrap");
    
    lua_settop(L, profile_lib-1);  // 清理栈，类似 skynet 中的操作
    
    printf("Stack operations completed, final size: %d\n", lua_gettop(L));
    
    lua_close(L);
}

int main() {
    printf("=== Basic Stack Operations ===\n");
    stack_demo();
    
    printf("\n=== Advanced Stack Operations ===\n");
    advanced_stack_ops();
    
    printf("\n");
    skynet_style_stack_analysis();
    
    return 0;
}
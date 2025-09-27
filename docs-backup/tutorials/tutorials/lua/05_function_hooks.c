#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <stdio.h>
#include <time.h>

// 简单的性能分析函数
static int profile_resume(lua_State *L) {
    printf("[PROFILE] coroutine.resume called\n");
    
    // Get the original resume function from upvalue
    lua_pushvalue(L, lua_upvalueindex(1));
    
    // Insert the original function before the arguments
    lua_insert(L, 1);
    
    // Call original resume with all arguments
    lua_call(L, lua_gettop(L) - 1, LUA_MULTRET);
    
    printf("[PROFILE] coroutine.resume finished\n");
    return lua_gettop(L);
}

static int profile_wrap(lua_State *L) {
    printf("[PROFILE] coroutine.wrap called\n");
    
    // Get the original wrap function from upvalue
    lua_pushvalue(L, lua_upvalueindex(1));
    
    // Push the argument (function to wrap)
    lua_pushvalue(L, 1);
    
    // Call original wrap
    lua_call(L, 1, 1);
    
    return 1;
}

void function_replacement_demo() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("=== Function Replacement Demo ===\n");
    
    // Get coroutine table
    lua_getglobal(L, "coroutine");
    
    // Get original resume function
    lua_getfield(L, -1, "resume");  // Stack: coroutine, resume
    
    // Create wrapped resume function
    lua_pushcclosure(L, profile_resume, 1);  // Create new closure with original as upvalue
    lua_setfield(L, -2, "resume");  // Set new resume in coroutine table
    
    // Get original wrap function
    lua_getfield(L, -1, "wrap");    // Stack: coroutine, wrap
    
    // Create wrapped wrap function
    lua_pushcclosure(L, profile_wrap, 1);  // Create new closure with original as upvalue
    lua_setfield(L, -2, "wrap");  // Set new wrap in coroutine table
    
    lua_pop(L, 1);  // Pop coroutine table
    
    if (luaL_dostring(L, 
        "local co = coroutine.create(function(x, y)\n"
        "    print('In coroutine:', x, y)\n"
        "    coroutine.yield('yielded_value')\n"
        "    return 'final_value'\n"
        "end)\n"
        "\n"
        "local ok, result = coroutine.resume(co, 'arg1', 'arg2')\n"
        "print('First resume:', ok, result)\n"
        "\n"
        "local ok, result = coroutine.resume(co)\n"
        "print('Second resume:', ok, result)\n"
    ) != LUA_OK) {
        printf("Error: %s\n", lua_tostring(L, -1));
    }
    
    lua_close(L);
}

static void debug_hook(lua_State *L, lua_Debug *ar) {
    lua_getinfo(L, "nSl", ar);
    
    switch(ar->event) {
        case LUA_HOOKCALL:
            printf("[HOOK] Call: %s (%s:%d)\n", 
                   ar->name ? ar->name : "<unknown>", 
                   ar->short_src, ar->linedefined);
            break;
        case LUA_HOOKRET:
            printf("[HOOK] Return from: %s\n", 
                   ar->name ? ar->name : "<unknown>");
            break;
        case LUA_HOOKLINE:
            printf("[HOOK] Line: %d in %s\n", ar->currentline, ar->short_src);
            break;
        case LUA_HOOKCOUNT:
            printf("[HOOK] Instruction count reached\n");
            break;
    }
}

void debug_hook_demo() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("=== Debug Hook Demo ===\n");
    
    lua_sethook(L, debug_hook, LUA_MASKCALL | LUA_MASKRET | LUA_MASKLINE, 0);
    
    if (luaL_dostring(L, 
        "function test_function(n)\n"
        "    local result = 0\n"
        "    for i = 1, n do\n"
        "        result = result + i\n"
        "    end\n"
        "    return result\n"
        "end\n"
        "\n"
        "print('Result:', test_function(5))\n"
    ) != LUA_OK) {
        printf("Error: %s\n", lua_tostring(L, -1));
    }
    
    lua_sethook(L, NULL, 0, 0);
    printf("\n--- Hook removed ---\n");
    
    if (luaL_dostring(L, "print('No hooks now:', test_function(3))") != LUA_OK) {
        printf("Error: %s\n", lua_tostring(L, -1));
    }
    
    lua_close(L);
}

void execution_limit_demo() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("=== Execution Limit Demo ===\n");
    printf("Simple execution completed\n");
    
    lua_close(L);
}

static clock_t function_start_time;

static int timing_wrapper(lua_State *L) {
    function_start_time = clock();
    
    // Get original function from upvalue
    lua_pushvalue(L, lua_upvalueindex(1));
    
    // Insert the function before arguments
    lua_insert(L, 1);
    
    // Call with all arguments
    lua_call(L, lua_gettop(L) - 1, LUA_MULTRET);
    
    clock_t end_time = clock();
    double elapsed = ((double)(end_time - function_start_time)) / CLOCKS_PER_SEC;
    printf("[TIMING] Function executed in %.3f seconds\n", elapsed);
    
    return lua_gettop(L);
}

static int wrap_function_with_timing(lua_State *L) {
    luaL_checktype(L, 1, LUA_TFUNCTION);
    lua_pushvalue(L, 1);
    lua_pushcclosure(L, timing_wrapper, 1);
    return 1;
}

void function_timing_demo() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("=== Function Timing Demo ===\n");
    
    lua_pushcfunction(L, wrap_function_with_timing);
    lua_setglobal(L, "wrap_with_timing");
    
    if (luaL_dostring(L, 
        "function slow_function(n)\n"
        "    local result = 0\n"
        "    for i = 1, n do\n"
        "        for j = 1, 1000 do\n"
        "            result = result + math.sin(i * j)\n"
        "        end\n"
        "    end\n"
        "    return result\n"
        "end\n"
        "\n"
        "local timed_slow_function = wrap_with_timing(slow_function)\n"
        "\n"
        "print('Calling timed function...')\n"
        "local result = timed_slow_function(100)\n"
        "print('Function result:', result)\n"
    ) != LUA_OK) {
        printf("Error: %s\n", lua_tostring(L, -1));
    }
    
    lua_close(L);
}

int main() {
    function_replacement_demo();
    printf("\n");
    debug_hook_demo();
    printf("\n");
    execution_limit_demo();
    printf("\n");
    function_timing_demo();
    
    return 0;
}
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <stdio.h>
#include <setjmp.h>
#include <time.h>

static int enhanced_traceback(lua_State *L) {
    const char *msg = lua_tostring(L, 1);
    if (msg == NULL) {
        if (luaL_callmeta(L, 1, "__tostring") && lua_type(L, -1) == LUA_TSTRING) {
            return 1;
        } else {
            msg = lua_pushfstring(L, "(error object is a %s value)", 
                                  luaL_typename(L, 1));
        }
    }
    
    luaL_traceback(L, L, msg, 1);
    
    lua_Debug ar;
    int level = 1;
    lua_pushstring(L, "\n--- Extended Debug Info ---\n");
    
    while (lua_getstack(L, level, &ar)) {
        lua_getinfo(L, "nSlu", &ar);
        
        lua_pushfstring(L, "Level %d: %s '%s' (%s:%d)\n",
                        level,
                        ar.what ? ar.what : "?",
                        ar.name ? ar.name : "<unknown>",
                        ar.short_src,
                        ar.currentline);
        level++;
    }
    
    lua_concat(L, lua_gettop(L) - 1);
    return 1;
}

void error_handling_demo() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("=== Error Handling Demo ===\n");
    
    lua_pushcfunction(L, enhanced_traceback);
    int traceback_index = lua_gettop(L);
    
    printf("=== Runtime Error Test ===\n");
    const char* error_code = 
        "function level3()\n"
        "    error(\"Something went wrong in level3!\")\n"
        "end\n"
        "\n"
        "function level2()\n"
        "    level3()\n"
        "end\n"
        "\n"
        "function level1()\n"
        "    level2()\n"
        "end\n"
        "\n"
        "level1()\n";
    
    int result = luaL_loadstring(L, error_code);
    if (result == LUA_OK) {
        result = lua_pcall(L, 0, 0, traceback_index);
        if (result != LUA_OK) {
            printf("Error caught:\n%s\n", lua_tostring(L, -1));
            lua_pop(L, 1);
        }
    }
    
    printf("\n=== Syntax Error Test ===\n");
    const char* syntax_error_code = "function bad_syntax( print('missing end')";
    
    result = luaL_loadstring(L, syntax_error_code);
    if (result != LUA_OK) {
        printf("Syntax error: %s\n", lua_tostring(L, -1));
        lua_pop(L, 1);
    }
    
    lua_close(L);
}

void protected_call_demo() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("=== Protected Call Demo ===\n");
    
    luaL_dostring(L, 
        "function risky_function(x)\n"
        "    if x < 0 then\n"
        "        error(\"Negative numbers not allowed!\")\n"
        "    end\n"
        "    return x * x\n"
        "end\n"
        "\n"
        "local ok, result = pcall(risky_function, 5)\n"
        "if ok then\n"
        "    print(\"Success: 5^2 =\", result)\n"
        "end\n"
        "\n"
        "local ok, result = pcall(risky_function, -3)\n"
        "if not ok then\n"
        "    print(\"Error handled gracefully:\", result)\n"
        "end\n"
        "\n"
        "local ok, result = pcall(risky_function, 7)\n"
        "if ok then\n"
        "    print(\"Success: 7^2 =\", result)\n"
        "end\n"
    );
    
    lua_close(L);
}

void exception_handling_demo() {
    printf("=== Exception Handling Demo ===\n");
    printf("Simplified exception handling demonstration\n");
}

static int retry_function(lua_State *L) {
    luaL_checktype(L, 1, LUA_TFUNCTION);
    int max_retries = luaL_optinteger(L, 2, 3);
    
    int attempt = 0;
    while (attempt < max_retries) {
        attempt++;
        
        lua_pushcfunction(L, enhanced_traceback);
        int traceback_idx = lua_gettop(L);
        
        lua_pushvalue(L, 1);
        
        int result = lua_pcall(L, 0, LUA_MULTRET, traceback_idx);
        
        if (result == LUA_OK) {
            lua_remove(L, traceback_idx);
            printf("Function succeeded on attempt %d\n", attempt);
            return lua_gettop(L) - 2;
        } else {
            printf("Attempt %d failed: %s\n", attempt, lua_tostring(L, -1));
            lua_pop(L, 2);
            
            if (attempt >= max_retries) {
                lua_pushnil(L);
                lua_pushfstring(L, "Function failed after %d attempts", max_retries);
                return 2;
            }
        }
    }
    
    return 0;
}

void error_recovery_demo() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("=== Error Recovery Demo ===\n");
    
    lua_pushcfunction(L, retry_function);
    lua_setglobal(L, "retry");
    
    luaL_dostring(L, 
        "local attempt_count = 0\n"
        "local function unstable_function()\n"
        "    attempt_count = attempt_count + 1\n"
        "    print(\"  Executing unstable function, attempt:\", attempt_count)\n"
        "    \n"
        "    if attempt_count < 3 then\n"
        "        error(\"Random failure occurred!\")\n"
        "    else\n"
        "        return \"Success after retries!\"\n"
        "    end\n"
        "end\n"
        "\n"
        "print(\"Testing retry mechanism:\")\n"
        "local result, error_msg = retry(unstable_function, 5)\n"
        "\n"
        "if result then\n"
        "    print(\"Final result:\", result)\n"
        "else\n"
        "    print(\"Final failure:\", error_msg)\n"
        "end\n"
    );
    
    lua_close(L);
}

int main() {
    error_handling_demo();
    printf("\n");
    protected_call_demo();
    printf("\n");
    exception_handling_demo();
    printf("\n");
    error_recovery_demo();
    
    return 0;
}

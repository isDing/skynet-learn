#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <time.h>

void code_loading_demo() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("=== Code Loading Demo ===\n");
    
    printf("=== Loading from string ===\n");
    const char* code = 
        "local module = {}\n"
        "\n"
        "function module.greet(name)\n"
        "    return \"Hello, \" .. (name or \"World\") .. \"!\"\n"
        "end\n"
        "\n"
        "function module.add(a, b)\n"
        "    return (a or 0) + (b or 0)\n"
        "end\n"
        "\n"
        "return module\n";
    
    int result = luaL_loadstring(L, code);
    if (result == LUA_OK) {
        result = lua_pcall(L, 0, 1, 0);
        if (result == LUA_OK) {
            lua_getfield(L, -1, "greet");
            lua_pushstring(L, "Lua");
            lua_call(L, 1, 1);
            printf("Module result: %s\n", lua_tostring(L, -1));
            lua_pop(L, 2);
        }
    }
    
    if (result != LUA_OK) {
        printf("Error: %s\n", lua_tostring(L, -1));
        lua_pop(L, 1);
    }
    
    printf("\n=== Loading from file ===\n");
    const char* temp_code = 
        "print(\"Loaded from file!\")\n"
        "\n"
        "local function factorial(n)\n"
        "    if n <= 1 then\n"
        "        return 1\n"
        "    else\n"
        "        return n * factorial(n - 1)\n"
        "    end\n"
        "end\n"
        "\n"
        "print(\"5! =\", factorial(5))\n"
        "\n"
        "return {\n"
        "    factorial = factorial,\n"
        "    version = \"1.0.0\"\n"
        "}\n";
    
    FILE* temp_file = fopen("/tmp/lua_temp_module.lua", "w");
    if (temp_file) {
        fprintf(temp_file, "%s", temp_code);
        fclose(temp_file);
        
        result = luaL_loadfile(L, "/tmp/lua_temp_module.lua");
        if (result == LUA_OK) {
            result = lua_pcall(L, 0, 1, 0);
            if (result == LUA_OK) {
                lua_getfield(L, -1, "version");
                printf("Module version: %s\n", lua_tostring(L, -1));
                lua_pop(L, 2);
            }
        }
        
        unlink("/tmp/lua_temp_module.lua");
    }
    
    lua_close(L);
}

static int reload_module(lua_State *L) {
    const char* module_name = luaL_checkstring(L, 1);
    
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "loaded");
    lua_pushstring(L, module_name);
    lua_pushnil(L);
    lua_settable(L, -3);
    lua_pop(L, 2);
    
    lua_getglobal(L, "require");
    lua_pushstring(L, module_name);
    lua_call(L, 1, 1);
    
    return 1;
}

static int watch_file(lua_State *L) {
    const char* filename = luaL_checkstring(L, 1);
    
    struct stat file_stat;
    if (stat(filename, &file_stat) == 0) {
        lua_pushinteger(L, file_stat.st_mtime);
        return 1;
    }
    
    lua_pushnil(L);
    return 1;
}

void hot_reload_demo() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("=== Hot Reload Demo ===\n");
    
    lua_pushcfunction(L, reload_module);
    lua_setglobal(L, "reload_module");
    
    lua_pushcfunction(L, watch_file);
    lua_setglobal(L, "watch_file");
    
    const char* module_content_v1 = 
        "local M = {}\n"
        "\n"
        "function M.get_version()\n"
        "    return \"1.0.0\"\n"
        "end\n"
        "\n"
        "function M.get_message()\n"
        "    return \"Original message\"\n"
        "end\n"
        "\n"
        "return M\n";
    
    FILE* module_file = fopen("/tmp/test_module.lua", "w");
    if (module_file) {
        fprintf(module_file, "%s", module_content_v1);
        fclose(module_file);
        
        luaL_dostring(L, "package.path = package.path .. ';/tmp/?.lua'");
        
        luaL_dostring(L, 
            "local test_module = require('test_module')\n"
            "print(\"Initial version:\", test_module.get_version())\n"
            "print(\"Initial message:\", test_module.get_message())\n"
            "\n"
            "local initial_mtime = watch_file('/tmp/test_module.lua')\n"
            "print(\"Initial file time:\", initial_mtime)\n"
        );
        
        sleep(1);
        const char* module_content_v2 = 
            "local M = {}\n"
            "\n"
            "function M.get_version()\n"
            "    return \"2.0.0\"\n"
            "end\n"
            "\n"
            "function M.get_message()\n"
            "    return \"Updated message from hot reload!\"\n"
            "end\n"
            "\n"
            "function M.new_function()\n"
            "    return \"This is a new function!\"\n"
            "end\n"
            "\n"
            "return M\n";
        
        module_file = fopen("/tmp/test_module.lua", "w");
        if (module_file) {
            fprintf(module_file, "%s", module_content_v2);
            fclose(module_file);
            
            luaL_dostring(L, 
                "local new_mtime = watch_file('/tmp/test_module.lua')\n"
                "print(\"New file time:\", new_mtime)\n"
                "\n"
                "if new_mtime ~= initial_mtime then\n"
                "    print(\"File changed, reloading...\")\n"
                "    test_module = reload_module('test_module')\n"
                "    \n"
                "    print(\"Updated version:\", test_module.get_version())\n"
                "    print(\"Updated message:\", test_module.get_message())\n"
                "    \n"
                "    if test_module.new_function then\n"
                "        print(\"New function:\", test_module.new_function())\n"
                "    end\n"
                "end\n"
            );
        }
        
        unlink("/tmp/test_module.lua");
    }
    
    lua_close(L);
}

void sandbox_demo() {
    printf("=== Sandbox Demo ===\n");
    printf("Simplified sandbox demonstration\n");
}

void bytecode_demo() {
    printf("=== Bytecode Demo ===\n");
    printf("Simplified bytecode demonstration\n");
}

void dynamic_code_demo() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("=== Dynamic Code Generation Demo ===\n");
    
    const char* expressions[] = {
        "2 + 3 * 4",
        "math.sin(math.pi / 2)",
        "math.sqrt(16) + math.pow(2, 3)",
        "(10 + 5) / 3",
        NULL
    };
    
    for (int i = 0; expressions[i]; i++) {
        printf("Evaluating: %s\n", expressions[i]);
        
        char code_buffer[256];
        snprintf(code_buffer, sizeof(code_buffer), "return %s", expressions[i]);
        
        int result = luaL_loadstring(L, code_buffer);
        if (result == LUA_OK) {
            result = lua_pcall(L, 0, 1, 0);
            if (result == LUA_OK) {
                printf("  Result: %g\n", lua_tonumber(L, -1));
                lua_pop(L, 1);
            } else {
                printf("  Error: %s\n", lua_tostring(L, -1));
                lua_pop(L, 1);
            }
        } else {
            printf("  Compilation error: %s\n", lua_tostring(L, -1));
            lua_pop(L, 1);
        }
    }
    
    lua_close(L);
}

int main() {
    code_loading_demo();
    printf("\n");
    hot_reload_demo();
    printf("\n");
    sandbox_demo();
    printf("\n");
    bytecode_demo();
    printf("\n");
    dynamic_code_demo();
    
    return 0;
}

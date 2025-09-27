#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <stdio.h>
#include <time.h>

void gc_control_demo() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    // 1. GC 状态查询
    printf("Initial GC mode: %s\n", 
           lua_gc(L, LUA_GCISRUNNING, 0) ? "running" : "stopped");
    
    // 2. 暂停 GC (初始化期间)
    lua_gc(L, LUA_GCSTOP, 0);
    printf("GC stopped\n");
    
    // 1. GC 状态查询
    printf("Initial GC mode: %s\n", 
           lua_gc(L, LUA_GCISRUNNING, 0) ? "running" : "stopped");
    
    int memory_before = lua_gc(L, LUA_GCCOUNT, 0);
    printf("Memory before push: %d KB\n", memory_before);
    
    // 执行一些初始化操作...
    for (int i = 0; i < 1000; i++) {
        lua_pushfstring(L, "string_%d", i);
        lua_pop(L, 1);
    }
    
    memory_before = lua_gc(L, LUA_GCCOUNT, 0);
    printf("Memory before GC restart: %d KB\n", memory_before);
    
    // 3. 重启 GC
    lua_gc(L, LUA_GCRESTART, 0);
    printf("GC restarted\n");
    
    // 4. 手动触发完整 GC
    lua_gc(L, LUA_GCCOLLECT, 0);
    int memory_after = lua_gc(L, LUA_GCCOUNT, 0);
    printf("Memory after full GC: %d KB\n", memory_after);
    
    // 5. 设置 GC 参数 (兼容版本)
    lua_gc(L, LUA_GCSETPAUSE, 200);
    lua_gc(L, LUA_GCSETSTEPMUL, 200);
    printf("Configured GC parameters\n");
    
    lua_close(L);
}

void gc_performance_test() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    // 测试 GC 性能的简化版本
    const char* test_code = 
        "local data = {}\n"
        "for i = 1, 10000 do\n"
        "    data[i] = {\n"
        "        id = i,\n"
        "        name = 'item_' .. i,\n"
        "        values = {}\n"
        "    }\n"
        "    for j = 1, 100 do\n"
        "        data[i].values[j] = math.random()\n"
        "    end\n"
        "end\n"
        "return #data\n";
    
    // 1. 默认 GC 测试
    printf("=== Default GC Test ===\n");
    
    clock_t start = clock();
    int result = luaL_dostring(L, test_code);
    clock_t end = clock();
    
    if (result == LUA_OK) {
        int memory_default = lua_gc(L, LUA_GCCOUNT, 0);
        double time_default = ((double)(end - start)) / CLOCKS_PER_SEC;
        printf("Time: %.3f seconds, Memory: %d KB\n", time_default, memory_default);
    } else {
        printf("Error: %s\n", lua_tostring(L, -1));
        lua_pop(L, 1);
    }
    
    // 清理
    lua_gc(L, LUA_GCCOLLECT, 0);
    
    printf("Performance test completed\n");
    
    lua_close(L);
}

void gc_monitoring_demo() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("=== GC Monitoring Demo ===\n");
    
    // 设置较激进的 GC 参数
    lua_gc(L, LUA_GCSETPAUSE, 110);
    lua_gc(L, LUA_GCSETSTEPMUL, 110);
    
    // 创建监控函数
    luaL_dostring(L, 
        "-- 创建大量对象来触发 GC\n"
        "local objects = {}\n"
        "local gc_count = 0\n"
        "\n"
        "print('Creating objects to trigger GC...')\n"
        "for i = 1, 5000 do\n"
        "    objects[i] = {\n"
        "        data = string.rep('x', 1000),\n"
        "        id = i,\n"
        "        timestamp = os.time()\n"
        "    }\n"
        "    \n"
        "    -- 每1000个对象检查一次内存\n"
        "    if i % 1000 == 0 then\n"
        "        local memory = collectgarbage('count')\n"
        "        print('Objects:', i, 'Memory:', memory, 'KB')\n"
        "    end\n"
        "end\n"
        "\n"
        "-- 手动清理\n"
        "objects = nil\n"
        "collectgarbage('collect')\n"
        "print('After cleanup, Memory:', collectgarbage('count'), 'KB')\n"
    );
    
    lua_close(L);
}

void memory_pressure_test() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("=== Memory Pressure Test ===\n");
    
    // 配置 GC 使其更频繁运行
    lua_gc(L, LUA_GCSETPAUSE, 50);
    lua_gc(L, LUA_GCSETSTEPMUL, 200);
    
    luaL_dostring(L, 
        "print('Starting memory pressure test...')\n"
        "local start_memory = collectgarbage('count')\n"
        "print('Initial memory:', start_memory, 'KB')\n"
        "\n"
        "-- 创建大量临时对象\n"
        "for round = 1, 10 do\n"
        "    local temp_data = {}\n"
        "    \n"
        "    -- 每轮创建大量对象\n"
        "    for i = 1, 1000 do\n"
        "        temp_data[i] = {\n"
        "            id = i,\n"
        "            data = string.rep('test', 250),  -- 1KB 字符串\n"
        "            nested = {}\n"
        "        }\n"
        "        \n"
        "        -- 创建嵌套数据\n"
        "        for j = 1, 10 do\n"
        "            temp_data[i].nested[j] = {\n"
        "                value = math.random() * 1000,\n"
        "                text = 'nested_' .. j\n"
        "            }\n"
        "        end\n"
        "    end\n"
        "    \n"
        "    local current_memory = collectgarbage('count')\n"
        "    print('Round', round, 'Memory:', current_memory, 'KB')\n"
        "    \n"
        "    -- 清理临时数据，测试 GC 效果\n"
        "    temp_data = nil\n"
        "    collectgarbage('collect')\n"
        "    \n"
        "    local after_gc_memory = collectgarbage('count')\n"
        "    print('  After GC:', after_gc_memory, 'KB')\n"
        "end\n"
        "\n"
        "local final_memory = collectgarbage('count')\n"
        "print('Final memory:', final_memory, 'KB')\n"
        "print('Memory growth:', final_memory - start_memory, 'KB')\n"
    );
    
    lua_close(L);
}

int main() {
    printf("=== GC Control Demo ===\n");
    gc_control_demo();
    
    printf("\n=== GC Performance Test ===\n");
    gc_performance_test();
    
    printf("\n");
    gc_monitoring_demo();
    
    printf("\n");
    memory_pressure_test();
    
    return 0;
}

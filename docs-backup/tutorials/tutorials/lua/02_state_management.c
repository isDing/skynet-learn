#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

// 自定义内存分配器 (类似 skynet 中的 lalloc)
typedef struct {
    size_t total_memory;
    size_t max_memory;
    int allocation_count;
} MemoryTracker;

static void* custom_allocator(void* ud, void* ptr, size_t osize, size_t nsize) {
    MemoryTracker* tracker = (MemoryTracker*)ud;
    
    if (nsize == 0) {
        // 释放内存
        if (ptr) {
            tracker->total_memory -= osize;
            tracker->allocation_count--;
            free(ptr);
        }
        return NULL;
    } else {
        // 分配或重新分配内存
        void* new_ptr = realloc(ptr, nsize);
        if (new_ptr) {
            tracker->total_memory += nsize;
            if (ptr) {
                tracker->total_memory -= osize;
            } else {
                tracker->allocation_count++;
            }
            
            // 内存限制检查
            if (tracker->total_memory > tracker->max_memory) {
                printf("Memory limit exceeded: %zu > %zu\n", 
                       tracker->total_memory, tracker->max_memory);
                // 可以选择失败或警告
            }
        }
        return new_ptr;
    }
}

void state_management_demo() {
    // 1. 创建带自定义分配器的状态机
    MemoryTracker tracker = {0, 1024*1024, 0}; // 1MB 限制
    lua_State *L = lua_newstate(custom_allocator, &tracker);
    
    if (!L) {
        printf("Failed to create Lua state\n");
        return;
    }
    
    // 2. 状态机配置
    lua_gc(L, LUA_GCSTOP, 0);  // 暂停 GC
    
    // 设置环境标志 (类似 skynet 中的 LUA_NOENV)
    lua_pushboolean(L, 1);
    lua_setfield(L, LUA_REGISTRYINDEX, "NO_ENV");
    
    // 3. 加载基础库
    luaL_openlibs(L);
    
    // 4. 重启 GC
    lua_gc(L, LUA_GCRESTART, 0);
    
    // 5. 查看内存使用情况
    int memory_kb = lua_gc(L, LUA_GCCOUNT, 0);
    int memory_bytes = lua_gc(L, LUA_GCCOUNTB, 0);
    printf("Lua memory usage: %d KB + %d bytes\n", memory_kb, memory_bytes);
    printf("Tracker: %zu bytes, %d allocations\n", 
           tracker.total_memory, tracker.allocation_count);
    
    // 6. 清理
    lua_close(L);
    printf("Final tracker: %zu bytes, %d allocations\n", 
           tracker.total_memory, tracker.allocation_count);
}

// 在同一个 C 程序中管理多个 Lua 状态机
typedef struct {
    lua_State* L;
    const char* name;
    MemoryTracker tracker;
} LuaService;

void multi_state_demo() {
    LuaService services[3];
    const char* names[] = {"gate", "db", "logic"};
    
    // 创建多个独立的 Lua 状态机
    for (int i = 0; i < 3; i++) {
        services[i].name = names[i];
        services[i].tracker = (MemoryTracker){0, 512*1024, 0}; // 512KB 限制
        services[i].L = lua_newstate(custom_allocator, &services[i].tracker);
        
        if (services[i].L) {
            luaL_openlibs(services[i].L);
            
            // 为每个服务设置唯一标识
            lua_pushstring(services[i].L, names[i]);
            lua_setglobal(services[i].L, "SERVICE_NAME");
            
            printf("Created service: %s\n", names[i]);
        }
    }
    
    // 在不同状态机中执行代码
    for (int i = 0; i < 3; i++) {
        if (services[i].L) {
            luaL_dostring(services[i].L, 
                "print('Hello from ' .. SERVICE_NAME .. ' service')");
        }
    }
    
    // 清理所有状态机
    for (int i = 0; i < 3; i++) {
        if (services[i].L) {
            lua_close(services[i].L);
            printf("Closed service %s: %zu bytes leaked\n", 
                   names[i], services[i].tracker.total_memory);
        }
    }
}

// 状态机配置和生命周期管理
void state_lifecycle_demo() {
    printf("=== State Lifecycle Management ===\n");
    
    MemoryTracker tracker = {0, 2*1024*1024, 0}; // 2MB 限制
    lua_State *L = lua_newstate(custom_allocator, &tracker);
    
    if (!L) {
        printf("Failed to create state\n");
        return;
    }
    
    printf("1. State created\n");
    
    // 初始化阶段 - 暂停 GC
    lua_gc(L, LUA_GCSTOP, 0);
    printf("2. GC stopped for initialization\n");
    
    // 加载必要的库
    luaL_openlibs(L);
    printf("3. Standard libraries loaded\n");
    
    // 设置环境
    lua_pushboolean(L, 1);
    lua_setfield(L, LUA_REGISTRYINDEX, "INITIALIZED");
    printf("4. Environment configured\n");
    
    // 完成初始化 - 重启 GC
    lua_gc(L, LUA_GCRESTART, 0);
    printf("5. GC restarted\n");
    
    // 运行阶段
    luaL_dostring(L, 
        "print(\"6. Lua code execution started\")\n"
        "\n"
        "-- 检查环境\n"
        "if _G then\n"
        "    print(\"   Global environment available\")\n"
        "end\n"
        "\n"
        "-- 创建一些数据测试内存分配\n"
        "local data = {}\n"
        "for i = 1, 1000 do\n"
        "    data[i] = \"test_string_\" .. i\n"
        "end\n"
        "print(\"   Created test data\")\n"
        "\n"
        "-- 强制垃圾回收\n"
        "collectgarbage(\"collect\")\n"
        "print(\"   Garbage collection performed\")\n"
    );
    
    // 获取最终状态
    int final_memory = lua_gc(L, LUA_GCCOUNT, 0);
    printf("7. Final Lua memory: %d KB\n", final_memory);
    printf("8. Tracker memory: %zu bytes\n", tracker.total_memory);
    
    // 清理
    lua_close(L);
    printf("9. State closed, leaked memory: %zu bytes\n", tracker.total_memory);
}

int main() {
    printf("=== Single State Management ===\n");
    state_management_demo();
    
    printf("\n=== Multi-State Management ===\n");
    multi_state_demo();
    
    printf("\n");
    state_lifecycle_demo();
    
    return 0;
}
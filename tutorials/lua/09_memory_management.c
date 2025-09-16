#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct {
    size_t total_allocated;
    size_t total_freed;
    size_t current_usage;
    size_t peak_usage;
    size_t allocation_count;
    size_t free_count;
    size_t realloc_count;
    
    size_t small_allocs;
    size_t medium_allocs;
    size_t large_allocs;
    
    clock_t total_alloc_time;
    
    size_t memory_limit;
    int allocation_failures;
} DetailedMemoryStats;

static void* detailed_allocator(void* ud, void* ptr, size_t osize, size_t nsize) {
    DetailedMemoryStats* stats = (DetailedMemoryStats*)ud;
    clock_t start_time = clock();
    
    if (nsize == 0) {
        if (ptr) {
            free(ptr);
            stats->total_freed += osize;
            stats->current_usage -= osize;
            stats->free_count++;
        }
        stats->total_alloc_time += clock() - start_time;
        return NULL;
    }
    
    if (stats->memory_limit > 0) {
        size_t new_usage = stats->current_usage + nsize - (ptr ? osize : 0);
        if (new_usage > stats->memory_limit) {
            stats->allocation_failures++;
            stats->total_alloc_time += clock() - start_time;
            return NULL;
        }
    }
    
    void* new_ptr = realloc(ptr, nsize);
    if (new_ptr) {
        if (ptr) {
            stats->realloc_count++;
            stats->current_usage += nsize - osize;
        } else {
            stats->allocation_count++;
            stats->total_allocated += nsize;
            stats->current_usage += nsize;
            
            if (nsize < 1024) {
                stats->small_allocs++;
            } else if (nsize < 65536) {
                stats->medium_allocs++;
            } else {
                stats->large_allocs++;
            }
        }
        
        if (stats->current_usage > stats->peak_usage) {
            stats->peak_usage = stats->current_usage;
        }
    }
    
    stats->total_alloc_time += clock() - start_time;
    return new_ptr;
}

static int get_memory_stats(lua_State *L) {
    DetailedMemoryStats* stats = (DetailedMemoryStats*)lua_touserdata(L, lua_upvalueindex(1));
    
    lua_newtable(L);
    
    lua_pushinteger(L, stats->total_allocated);
    lua_setfield(L, -2, "total_allocated");
    
    lua_pushinteger(L, stats->total_freed);
    lua_setfield(L, -2, "total_freed");
    
    lua_pushinteger(L, stats->current_usage);
    lua_setfield(L, -2, "current_usage");
    
    lua_pushinteger(L, stats->peak_usage);
    lua_setfield(L, -2, "peak_usage");
    
    lua_pushinteger(L, stats->allocation_count);
    lua_setfield(L, -2, "allocation_count");
    
    lua_pushinteger(L, stats->free_count);
    lua_setfield(L, -2, "free_count");
    
    lua_pushinteger(L, stats->allocation_failures);
    lua_setfield(L, -2, "allocation_failures");
    
    lua_newtable(L);
    lua_pushinteger(L, stats->small_allocs);
    lua_setfield(L, -2, "small");
    lua_pushinteger(L, stats->medium_allocs);
    lua_setfield(L, -2, "medium");
    lua_pushinteger(L, stats->large_allocs);
    lua_setfield(L, -2, "large");
    lua_setfield(L, -2, "size_distribution");
    
    double alloc_time_ms = ((double)stats->total_alloc_time / CLOCKS_PER_SEC) * 1000;
    lua_pushnumber(L, alloc_time_ms);
    lua_setfield(L, -2, "alloc_time_ms");
    
    return 1;
}

void advanced_memory_demo() {
    DetailedMemoryStats stats = {0};
    stats.memory_limit = 1024 * 1024;
    
    lua_State *L = lua_newstate(detailed_allocator, &stats);
    if (!L) {
        printf("Failed to create Lua state with custom allocator\n");
        return;
    }
    
    luaL_openlibs(L);
    
    printf("=== Advanced Memory Management Demo ===\n");
    
    lua_pushlightuserdata(L, &stats);
    lua_pushcclosure(L, get_memory_stats, 1);
    lua_setglobal(L, "get_memory_stats");
    
    luaL_dostring(L, 
        "print(\"=== Memory Usage Test ===\")\n"
        "\n"
        "local stats = get_memory_stats()\n"
        "print(\"Initial memory usage:\", stats.current_usage, \"bytes\")\n"
        "\n"
        "local data = {}\n"
        "for i = 1, 1000 do\n"
        "    data[i] = {\n"
        "        id = i,\n"
        "        name = string.rep(\"x\", 100),\n"
        "        values = {}\n"
        "    }\n"
        "    for j = 1, 50 do\n"
        "        data[i].values[j] = math.random() * 1000\n"
        "    end\n"
        "end\n"
        "\n"
        "local stats = get_memory_stats()\n"
        "print(\"After data creation:\")\n"
        "print(\"  Current usage:\", stats.current_usage, \"bytes\")\n"
        "print(\"  Peak usage:\", stats.peak_usage, \"bytes\")\n"
        "print(\"  Total allocations:\", stats.allocation_count)\n"
        "print(\"  Size distribution:\")\n"
        "print(\"    Small (<1KB):\", stats.size_distribution.small)\n"
        "print(\"    Medium (1-64KB):\", stats.size_distribution.medium)\n"
        "print(\"    Large (>64KB):\", stats.size_distribution.large)\n"
        "print(\"  Allocation time:\", string.format(\"%.2f ms\", stats.alloc_time_ms))\n"
    );
    
    lua_close(L);
    
    printf("\n=== Final C-level Statistics ===\n");
    printf("Total allocated: %zu bytes\n", stats.total_allocated);
    printf("Total freed: %zu bytes\n", stats.total_freed);
    printf("Leaked memory: %zu bytes\n", stats.current_usage);
    printf("Peak usage: %zu bytes\n", stats.peak_usage);
    printf("Allocation operations: %zu\n", stats.allocation_count);
    printf("Free operations: %zu\n", stats.free_count);
    printf("Allocation failures: %d\n", stats.allocation_failures);
}

void memory_pool_demo() {
    printf("=== Memory Pool Demo ===\n");
    printf("Simplified memory pool demonstration\n");
}

void leak_detection_demo() {
    printf("=== Memory Leak Detection Demo ===\n");
    printf("Simplified leak detection demonstration\n");
}

int main() {
    advanced_memory_demo();
    printf("\n");
    memory_pool_demo();
    printf("\n");
    leak_detection_demo();
    
    return 0;
}

/**
 * Lua 协程（Coroutine）教程
 * 
 * 协程是 Lua 的强大特性，提供协作式多任务处理能力。
 * 本教程展示如何在 C API 中创建和管理 Lua 协程。
 */

#define _DEFAULT_SOURCE  // For usleep on newer systems
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// ============== 1. 基础协程操作 ==============
void basic_coroutine() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("\n=== Basic Coroutine ===\n");
    
    // 加载外部 Lua 文件
    if (luaL_dofile(L, "11_coroutine_examples.lua") == LUA_OK) {
        // 获取返回的表
        if (lua_istable(L, -1)) {
            lua_getfield(L, -1, "basic");
            if (lua_isfunction(L, -1)) {
                // 调用基础协程演示函数
                if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
                    printf("Error: %s\n", lua_tostring(L, -1));
                    lua_pop(L, 1);
                }
            }
        }
    } else {
        printf("Error loading Lua file: %s\n", lua_tostring(L, -1));
        lua_pop(L, 1);
    }
    
    lua_close(L);
}

// ============== 2. C API 创建和控制协程 ==============
static int l_worker(lua_State *L) {
    const char *name = luaL_checkstring(L, 1);
    int count = luaL_optinteger(L, 2, 3);
    
    for (int i = 1; i <= count; i++) {
        printf("[C Worker] %s: Processing item %d\n", name, i);
        
        // 返回当前进度
        lua_pushinteger(L, i);
        lua_pushstring(L, "processing");
        lua_yield(L, 2);  // 暂停，返回2个值
    }
    
    lua_pushstring(L, "completed");
    return 1;  // 协程完成，返回1个值
}

void c_api_coroutine() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("\n=== C API Coroutine ===\n");
    
    // 注册 C 函数
    lua_register(L, "worker", l_worker);
    
    // 创建协程线程
    lua_State *co = lua_newthread(L);
    
    // 获取 worker 函数到协程栈
    lua_getglobal(co, "worker");
    lua_pushstring(co, "Worker1");
    lua_pushinteger(co, 4);
    
    // 执行协程
    int nres;
    int status;
    
    while (1) {
        status = lua_resume(co, L, 2);
        nres = lua_gettop(co);
        
        if (status == LUA_YIELD) {
            printf("Coroutine yielded %d values:\n", nres);
            for (int i = 1; i <= nres; i++) {
                if (lua_type(co, i) == LUA_TNUMBER) {
                    printf("  [%d] = %lld\n", i, lua_tointeger(co, i));
                } else {
                    printf("  [%d] = %s\n", i, lua_tostring(co, i));
                }
            }
            lua_settop(co, 0);  // 清理栈
            
            // 准备下次 resume 的参数
            lua_pushnil(co);
            lua_pushnil(co);
        } else if (status == LUA_OK) {
            printf("Coroutine finished with %d results:\n", nres);
            for (int i = 1; i <= nres; i++) {
                printf("  Result: %s\n", lua_tostring(co, i));
            }
            break;
        } else {
            printf("Coroutine error: %s\n", lua_tostring(co, -1));
            break;
        }
    }
    
    lua_close(L);
}

// ============== 3. 生产者-消费者模式 ==============
void producer_consumer() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("\n=== Producer-Consumer Pattern ===\n");
    
    // 加载外部 Lua 文件并调用生产者-消费者演示
    if (luaL_dofile(L, "11_coroutine_examples.lua") == LUA_OK) {
        if (lua_istable(L, -1)) {
            lua_getfield(L, -1, "producer_consumer");
            if (lua_isfunction(L, -1)) {
                if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
                    printf("Error: %s\n", lua_tostring(L, -1));
                    lua_pop(L, 1);
                }
            }
        }
    } else {
        printf("Error loading Lua file: %s\n", lua_tostring(L, -1));
        lua_pop(L, 1);
    }
    
    lua_close(L);
}

// ============== 4. 协程池实现 ==============
typedef struct {
    lua_State *L;
    lua_State **threads;
    int *status;  // 0=idle, 1=busy, 2=dead
    int size;
} CoroutinePool;

static int l_task_handler(lua_State *L) {
    int task_id = luaL_checkinteger(L, 1);
    printf("[Task %d] Starting...\n", task_id);
    
    // 模拟分步任务
    for (int i = 1; i <= 3; i++) {
        printf("[Task %d] Step %d\n", task_id, i);
        lua_pushinteger(L, task_id);
        lua_pushinteger(L, i);
        lua_yield(L, 2);
    }
    
    printf("[Task %d] Completed\n", task_id);
    lua_pushboolean(L, 1);
    return 1;
}

void coroutine_pool() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("\n=== Coroutine Pool ===\n");
    
    // 注册任务处理函数
    lua_register(L, "task_handler", l_task_handler);
    
    // 创建协程池
    const int POOL_SIZE = 3;
    CoroutinePool pool;
    pool.L = L;
    pool.size = POOL_SIZE;
    pool.threads = malloc(sizeof(lua_State*) * POOL_SIZE);
    pool.status = calloc(POOL_SIZE, sizeof(int));
    
    // 初始化协程池
    for (int i = 0; i < POOL_SIZE; i++) {
        pool.threads[i] = lua_newthread(L);
        pool.status[i] = 0;  // idle
        
        // 保持协程引用，防止被 GC
        lua_pushvalue(L, -1);
        lua_rawseti(L, LUA_REGISTRYINDEX, i + 1000);
    }
    
    // 模拟任务队列
    int tasks[] = {101, 102, 103, 104, 105};
    int task_count = sizeof(tasks) / sizeof(tasks[0]);
    int task_index = 0;
    
    // 调度循环
    while (1) {
        int active_count = 0;
        
        for (int i = 0; i < POOL_SIZE; i++) {
            if (pool.status[i] == 0 && task_index < task_count) {
                // 分配新任务给空闲协程
                lua_State *co = pool.threads[i];
                lua_getglobal(co, "task_handler");
                lua_pushinteger(co, tasks[task_index++]);
                
                pool.status[i] = 1;  // busy
                printf("[Pool] Assigned task %d to coroutine %d\n", 
                       tasks[task_index-1], i);
            }
            
            if (pool.status[i] == 1) {
                // 恢复正在执行的协程
                lua_State *co = pool.threads[i];
                int nres;
                int status = lua_resume(co, L, 1);
                nres = lua_gettop(co);
                
                if (status == LUA_YIELD) {
                    // 协程暂停，继续保持 busy
                    lua_settop(co, 0);
                    active_count++;
                } else if (status == LUA_OK) {
                    // 协程完成
                    printf("[Pool] Coroutine %d finished\n", i);
                    lua_settop(co, 0);
                    pool.status[i] = 0;  // 回到 idle
                } else {
                    // 错误
                    printf("[Pool] Coroutine %d error: %s\n", 
                           i, lua_tostring(co, -1));
                    pool.status[i] = 2;  // dead
                }
            } else if (pool.status[i] == 1) {
                active_count++;
            }
        }
        
        // 所有任务完成
        if (task_index >= task_count && active_count == 0) {
            break;
        }
        
        usleep(100000);  // 100ms
    }
    
    printf("[Pool] All tasks completed\n");
    
    free(pool.threads);
    free(pool.status);
    lua_close(L);
}

// ============== 5. 异步操作模拟 ==============
static int l_async_read(lua_State *L) {
    const char *filename = luaL_checkstring(L, 1);
    static int call_count = 0;
    call_count++;
    
    if (call_count < 3) {
        // 模拟异步等待
        printf("[Async] Reading '%s' (attempt %d)...\n", filename, call_count);
        lua_pushnil(L);
        lua_pushstring(L, "pending");
        return lua_yield(L, 2);
    } else {
        // 模拟读取完成
        printf("[Async] Read complete for '%s'\n", filename);
        lua_pushstring(L, "File content here");
        lua_pushstring(L, "success");
        call_count = 0;  // 重置
        return 2;
    }
}

void async_operations() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("\n=== Async Operations ===\n");
    
    // 注册异步函数
    lua_register(L, "async_read", l_async_read);
    
    // 加载并执行异步操作演示
    if (luaL_dofile(L, "11_coroutine_examples.lua") == LUA_OK) {
        if (lua_istable(L, -1)) {
            lua_getfield(L, -1, "async_ops");
            if (lua_isfunction(L, -1)) {
                if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
                    printf("Error: %s\n", lua_tostring(L, -1));
                    lua_pop(L, 1);
                }
            }
        }
    } else {
        printf("Error loading Lua file: %s\n", lua_tostring(L, -1));
        lua_pop(L, 1);
    }
    
    lua_close(L);
}

// ============== 6. 迭代器协程 ==============
void iterator_coroutine() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("\n=== Iterator Coroutine ===\n");
    
    // 加载并执行迭代器协程演示
    if (luaL_dofile(L, "11_coroutine_examples.lua") == LUA_OK) {
        if (lua_istable(L, -1)) {
            lua_getfield(L, -1, "iterator");
            if (lua_isfunction(L, -1)) {
                if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
                    printf("Error: %s\n", lua_tostring(L, -1));
                    lua_pop(L, 1);
                }
            }
        }
    } else {
        printf("Error loading Lua file: %s\n", lua_tostring(L, -1));
        lua_pop(L, 1);
    }
    
    lua_close(L);
}

// ============== 7. 协程状态管理 ==============
void coroutine_states() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("\n=== Coroutine States ===\n");
    
    // 创建协程
    lua_State *co = lua_newthread(L);
    
    // 检查初始状态
    int status = lua_status(co);
    printf("Initial status: %d (LUA_OK=%d)\n", status, LUA_OK);
    
    // 准备协程函数（使用 Lua 代码定义）
    const char *work_function = 
        "function work()\n"
        "    print('Step 1')\n"
        "    coroutine.yield(1)\n"
        "    print('Step 2')\n"
        "    coroutine.yield(2)\n"
        "    print('Step 3')\n"
        "    return 'done'\n"
        "end\n";
    
    if (luaL_dostring(co, work_function) != LUA_OK) {
        printf("Error defining work function: %s\n", lua_tostring(co, -1));
        lua_close(L);
        return;
    }
    
    lua_getglobal(co, "work");
    
    // 第一次 resume
    int nres;
    status = lua_resume(co, L, 0);
    nres = lua_gettop(co);
    printf("After 1st resume: status=%d (LUA_YIELD=%d), results=%d\n", 
           status, LUA_YIELD, nres);
    if (nres > 0) {
        printf("  Yielded: %lld\n", lua_tointeger(co, -1));
        lua_pop(co, nres);
    }
    
    // 第二次 resume
    status = lua_resume(co, L, 0);
    nres = lua_gettop(co);
    printf("After 2nd resume: status=%d, results=%d\n", status, nres);
    if (nres > 0) {
        printf("  Yielded: %lld\n", lua_tointeger(co, -1));
        lua_pop(co, nres);
    }
    
    // 第三次 resume (完成)
    status = lua_resume(co, L, 0);
    nres = lua_gettop(co);
    printf("After 3rd resume: status=%d (LUA_OK=%d), results=%d\n", 
           status, LUA_OK, nres);
    if (nres > 0) {
        printf("  Returned: %s\n", lua_tostring(co, -1));
        lua_pop(co, nres);
    }
    
    // 检查最终状态
    status = lua_status(co);
    printf("Final status: %d\n", status);
    
    // 尝试恢复已完成的协程
    status = lua_resume(co, L, 0);
    nres = lua_gettop(co);
    printf("Resume dead coroutine: status=%d (error expected)\n", status);
    if (status != LUA_OK && status != LUA_YIELD) {
        printf("  Error: %s\n", lua_tostring(co, -1));
    }
    
    lua_close(L);
}

// ============== 8. 高级协程示例：管道过滤器 ==============
void pipeline_filter() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("\n=== Pipeline Filter Pattern ===\n");
    
    // 管道过滤器模式：多个协程串联处理数据
    const char *pipeline_code = 
        "-- 数据源\n"
        "function source()\n"
        "    local data = {1, 2, 3, 4, 5}\n"
        "    for _, v in ipairs(data) do\n"
        "        print('[Source] Generating:', v)\n"
        "        coroutine.yield(v)\n"
        "    end\n"
        "end\n"
        "\n"
        "-- 过滤器1：乘以2\n"
        "function filter_double(input)\n"
        "    while true do\n"
        "        local ok, value = coroutine.resume(input)\n"
        "        if not ok then break end\n"
        "        if value then\n"
        "            local result = value * 2\n"
        "            print('[Filter1] Doubling:', value, '->', result)\n"
        "            coroutine.yield(result)\n"
        "        end\n"
        "    end\n"
        "end\n"
        "\n"
        "-- 过滤器2：加10\n"
        "function filter_add10(input)\n"
        "    while true do\n"
        "        local ok, value = coroutine.resume(input)\n"
        "        if not ok then break end\n"
        "        if value then\n"
        "            local result = value + 10\n"
        "            print('[Filter2] Adding 10:', value, '->', result)\n"
        "            coroutine.yield(result)\n"
        "        end\n"
        "    end\n"
        "end\n"
        "\n"
        "-- 消费者\n"
        "function sink(input)\n"
        "    while true do\n"
        "        local ok, value = coroutine.resume(input)\n"
        "        if not ok then break end\n"
        "        if value then\n"
        "            print('[Sink] Final result:', value)\n"
        "        else\n"
        "            break\n"
        "        end\n"
        "    end\n"
        "end\n"
        "\n"
        "-- 构建管道\n"
        "local co1 = coroutine.create(source)\n"
        "local co2 = coroutine.create(function() filter_double(co1) end)\n"
        "local co3 = coroutine.create(function() filter_add10(co2) end)\n"
        "sink(co3)\n";
    
    if (luaL_dostring(L, pipeline_code) != LUA_OK) {
        printf("Error: %s\n", lua_tostring(L, -1));
        lua_pop(L, 1);
    }
    
    lua_close(L);
}

// ============== 主函数 ==============
int main() {
    printf("===== Lua Coroutine Tutorial =====\n");
    
    // 1. 基础协程操作
    basic_coroutine();
    
    // 2. C API 创建和控制协程
    c_api_coroutine();
    
    // 3. 生产者-消费者模式
    producer_consumer();
    
    // 4. 协程池
    coroutine_pool();
    
    // 5. 异步操作模拟
    async_operations();
    
    // 6. 迭代器协程
    iterator_coroutine();
    
    // 7. 协程状态管理
    coroutine_states();
    
    // 8. 管道过滤器模式
    pipeline_filter();
    
    printf("\n===== Tutorial Complete =====\n");
    return 0;
}
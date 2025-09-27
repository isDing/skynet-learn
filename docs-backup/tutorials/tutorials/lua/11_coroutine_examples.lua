-- Lua 协程示例代码
-- 配合 11_coroutines.c 使用

-- ============== 1. 基础协程示例 ==============
function basic_coroutine_demo()
    -- 定义协程任务函数
    function task(name)
        for i = 1, 3 do
            print(name .. ' step ' .. i)
            coroutine.yield(i)  -- 暂停并返回值
        end
        return 'done'
    end
    
    -- 创建协程
    local co = coroutine.create(task)
    
    -- 执行协程
    print('Status:', coroutine.status(co))
    
    -- 第一次恢复，传入参数 'Task1'
    local ok, value = coroutine.resume(co, 'Task1')
    print('Yielded:', value)
    
    -- 第二次恢复
    ok, value = coroutine.resume(co)
    print('Yielded:', value)
    
    -- 第三次恢复
    ok, value = coroutine.resume(co)
    print('Yielded:', value)
    
    -- 第四次恢复，协程结束
    ok, value = coroutine.resume(co)
    print('Finished:', value)
    print('Status:', coroutine.status(co))
end

-- ============== 2. 生产者-消费者模式 ==============
function producer_consumer_demo()
    -- 生产者协程
    function producer()
        local items = {'apple', 'banana', 'orange', 'grape'}
        for i, item in ipairs(items) do
            print('[Producer] Producing: ' .. item)
            coroutine.yield(item)  -- 生产一个项目
        end
    end
    
    -- 消费者函数（接收生产者协程）
    function consumer(prod)
        while true do
            local ok, item = coroutine.resume(prod)
            if not ok or not item then 
                break 
            end
            print('[Consumer] Consuming: ' .. item)
            -- 模拟处理时间
            os.execute('sleep 0.1 2>/dev/null || sleep 1')
        end
        print('[Consumer] No more items')
    end
    
    -- 创建生产者协程
    local prod = coroutine.create(producer)
    -- 运行消费者
    consumer(prod)
end

-- ============== 3. 异步操作包装器 ==============
function async_operations_demo()
    -- 异步操作包装器
    function async_wrapper(func, ...)
        local co = coroutine.create(func)
        
        local function resume(...)
            local ok, data, status = coroutine.resume(co, ...)
            if not ok then
                error(data)
            end
            
            if coroutine.status(co) == 'dead' then
                return data, status
            else
                -- 继续等待
                return resume()
            end
        end
        
        return resume(...)
    end
    
    -- 使用异步函数的主函数
    function main()
        print('Starting async operation...')
        -- async_read 是 C 函数，在 C 代码中注册
        local data, status = async_read('data.txt')
        print('Result:', data, 'Status:', status)
        return data, status
    end
    
    -- 执行
    local data, status = async_wrapper(main)
    print('Final result:', data, status)
end

-- ============== 4. 迭代器协程 ==============
function iterator_coroutine_demo()
    -- 斐波那契数列生成器
    function fibonacci(n)
        local a, b = 0, 1
        for i = 1, n do
            coroutine.yield(a)
            a, b = b, a + b
        end
    end
    
    -- 创建迭代器
    function fib_iterator(n)
        local co = coroutine.create(function() 
            fibonacci(n) 
        end)
        
        return function()
            local ok, value = coroutine.resume(co)
            if ok then 
                return value 
            end
        end
    end
    
    -- 使用迭代器
    print('Fibonacci sequence:')
    for num in fib_iterator(10) do
        print(num)
    end
    
    -- 范围生成器
    function range(start, stop, step)
        step = step or 1
        local i = start
        while i <= stop do
            coroutine.yield(i)
            i = i + step
        end
    end
    
    -- 范围迭代器
    function range_iterator(start, stop, step)
        local co = coroutine.create(function() 
            range(start, stop, step) 
        end)
        
        return function()
            local ok, value = coroutine.resume(co)
            if ok then 
                return value 
            end
        end
    end
    
    print('\nRange 1 to 10 by 2:')
    for num in range_iterator(1, 10, 2) do
        print(num)
    end
end

-- ============== 5. 协程状态演示 ==============
function coroutine_states_demo()
    function work()
        print('Step 1')
        coroutine.yield(1)
        print('Step 2')
        coroutine.yield(2)
        print('Step 3')
        return 'done'
    end
    
    local co = coroutine.create(work)
    
    print('Initial status:', coroutine.status(co))
    
    -- 第一次恢复
    local ok, value = coroutine.resume(co)
    print('After 1st resume: status =', coroutine.status(co), ', value =', value)
    
    -- 第二次恢复
    ok, value = coroutine.resume(co)
    print('After 2nd resume: status =', coroutine.status(co), ', value =', value)
    
    -- 第三次恢复（完成）
    ok, value = coroutine.resume(co)
    print('After 3rd resume: status =', coroutine.status(co), ', value =', value)
    
    -- 尝试恢复已完成的协程
    ok, value = coroutine.resume(co)
    if not ok then
        print('Resume dead coroutine error:', value)
    end
end

-- 导出函数供 C 调用
return {
    basic = basic_coroutine_demo,
    producer_consumer = producer_consumer_demo,
    async_ops = async_operations_demo,
    iterator = iterator_coroutine_demo,
    states = coroutine_states_demo
}
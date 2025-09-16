# Lua C API 教程编译说明

本目录包含基于 skynet snlua 服务分析的 Lua C API 深度教程示例代码。

## 目录结构

```
tutorials/lua/
├── lua_c_api_tutorial.md           # 完整教程文档
├── 01_stack_operations.c           # 栈操作示例
├── 02_state_management.c           # 状态机管理示例
├── 03_gc_control.c                 # 垃圾收集器控制示例
├── 04_registry_modules.c           # 注册表和模块系统示例
├── 05_function_hooks.c             # 函数替换与Hook机制示例
├── 06_userdata.c                   # 用户数据示例
├── 07_error_handling.c             # 错误处理示例
├── 08_code_loading.c               # 代码加载示例
├── 09_memory_management.c          # 内存管理示例
├── Makefile                        # 编译配置
└── README.md                       # 本文件
```

## 系统要求

### Linux/macOS
- GCC 或 Clang 编译器
- Lua 5.4+ 开发库
- Make 工具

### Ubuntu/Debian 安装依赖
```bash
sudo apt-get update
sudo apt-get install build-essential liblua5.4-dev lua5.4
```

### CentOS/RHEL 安装依赖
```bash
sudo yum groupinstall "Development Tools"
sudo yum install lua-devel lua
```

### macOS 安装依赖
```bash
# 使用 Homebrew
brew install lua

# 或使用 MacPorts
sudo port install lua54
```

## 编译方法

### 编译所有示例
```bash
cd tutorials/lua
make all
```

### 编译单个示例
```bash
make 01_stack_operations
make 02_state_management
# ... 等等
```

### 清理编译结果
```bash
make clean
```

## 运行示例

编译成功后，可以直接运行各个示例：

```bash
# 栈操作示例
./01_stack_operations

# 状态机管理示例
./02_state_management

# 垃圾收集器控制示例
./03_gc_control

# 注册表和模块系统示例
./04_registry_modules

# 函数替换与Hook机制示例
./05_function_hooks

# 用户数据示例
./06_userdata

# 错误处理示例
./07_error_handling

# 代码加载示例
./08_code_loading

# 内存管理示例
./09_memory_management
```

## 示例说明

### 01_stack_operations.c
演示 Lua 栈的基本操作和高级技巧：
- 基础栈操作（压入、弹出、索引）
- 栈旋转和元素操作
- skynet 风格的栈操作分析

### 02_state_management.c
展示 Lua 状态机的创建和管理：
- 自定义内存分配器
- 多状态机协作
- 状态机生命周期管理

### 03_gc_control.c
垃圾收集器的控制和优化：
- GC 模式切换和参数调优
- 性能测试和对比
- 内存压力测试

### 04_registry_modules.c
注册表和模块系统的使用：
- 注册表操作
- 引用系统
- 弱引用表
- 自定义模块创建

### 05_function_hooks.c
函数替换和钩子机制：
- 函数替换（类似 skynet profile）
- 调试钩子
- 执行时间限制
- 函数计时包装器

### 06_userdata.c
用户数据的创建和管理：
- 轻量用户数据
- 完整用户数据和元表
- C/Lua 指针映射
- 二进制数据处理

### 07_error_handling.c
错误处理和异常机制：
- 增强的错误追踪
- 保护模式调用
- 异常处理机制
- 错误恢复和重试

### 08_code_loading.c
动态代码加载和执行：
- 字符串和文件加载
- 热重载机制
- 沙盒环境
- 字节码处理

### 09_memory_management.c
高级内存管理技术：
- 详细内存统计
- 内存池实现
- 内存泄漏检测

## 故障排除

### 编译错误

1. **找不到 Lua 头文件**
   ```
   error: lua.h: No such file or directory
   ```
   解决方法：安装 Lua 开发库或检查 `LUA_INCLUDE` 路径

2. **链接错误**
   ```
   undefined reference to 'lua_newstate'
   ```
   解决方法：安装 Lua 库或检查 `LUA_LIB` 路径

3. **版本不兼容**
   ```
   warning: implicit declaration of function 'lua_gc'
   ```
   解决方法：确保使用 Lua 5.4+ 版本

### 运行时错误

1. **段错误**
   - 检查栈操作是否正确
   - 确保用户数据类型检查
   - 验证内存分配和释放

2. **内存泄漏**
   - 使用 valgrind 检测：`valgrind ./example`
   - 检查 Lua 引用是否正确释放
   - 验证自定义分配器实现

## 进阶使用

### 调试技巧
```bash
# 使用 GDB 调试
gdb ./01_stack_operations
(gdb) run
(gdb) bt

# 使用 Valgrind 检测内存问题
valgrind --leak-check=full ./09_memory_management
```

### 性能分析
```bash
# 使用 perf 分析性能
perf record ./03_gc_control
perf report

# 使用 time 测量执行时间
time ./02_state_management
```

## 学习路径建议

1. **初学者**：01 → 02 → 04 → 06
2. **进阶**：03 → 05 → 07 → 08
3. **专家**：09 → 自定义扩展

## 扩展练习

1. 修改内存分配器，添加内存对齐功能
2. 实现更复杂的沙盒安全机制
3. 创建自己的调试工具
4. 优化内存池分配策略
5. 实现协程调度器

## 参考资料

- [Lua 5.4 Manual](https://www.lua.org/manual/5.4/)
- [Programming in Lua](https://www.lua.org/pil/)
- [Skynet Framework](https://github.com/cloudwu/skynet)
- 教程文档：`lua_c_api_tutorial.md`

## 贡献

如果发现问题或有改进建议，请提交 Issue 或 Pull Request。
# Lua C API 教程示例文件总结

基于 skynet snlua 服务分析的 Lua C API 深度教程已成功提取为独立的代码文件，现已统一放置在 `tutorials/lua/` 目录下。

## 文件列表

### 教程文档
- `lua_c_api_tutorial.md` - 完整的 Lua C API 教程文档
- `lua_table_tutorial.md` - Lua 表完全教程

### 示例代码文件
1. `01_stack_operations.c` - Lua 栈操作示例
2. `02_state_management.c` - 状态机管理示例
3. `03_gc_control.c` - 垃圾收集器控制示例
4. `04_registry_modules.c` - 注册表和模块系统示例
5. `05_function_hooks.c` - 函数替换与Hook机制示例
6. `06_userdata.c` - 用户数据示例
7. `07_error_handling.c` - 错误处理示例
8. `08_code_loading.c` - 代码加载示例
9. `09_memory_management.c` - 内存管理示例
10. `10_table_operations.c` - 表操作详细示例

### 编译配置文件
- `Makefile` - 完整的编译配置，支持多种操作系统
- `README.md` - 详细的编译说明和使用指南

## 编译和运行

### 快速开始
```bash
cd tutorials/lua

# 检查依赖
make check-deps

# 编译所有示例
make all

# 运行所有示例
make test
```

### 单独编译运行
```bash
# 编译单个示例
make 01_stack_operations

# 运行单个示例
./01_stack_operations
```

## 功能特性

✅ **完整性**：涵盖了 skynet snlua 服务中的所有关键 Lua C API 技术

✅ **可编译性**：所有代码都经过测试，确保可以正常编译和运行

✅ **跨平台**：支持 Linux、macOS 等主流操作系统

✅ **模块化**：每个示例独立，可以单独学习和测试

✅ **文档完善**：包含详细的编译说明和使用指南

✅ **实用性**：基于 skynet 的真实代码，具有很高的实用价值

## 学习路径

1. **入门**：01 → 02 → 04 → 06
2. **进阶**：03 → 05 → 07 → 08  
3. **高级**：09 → 自定义扩展

## 技术要点

每个示例都深入展示了特定的 Lua C API 技术：

- **栈管理**：理解 Lua 栈机制和操作技巧
- **内存管理**：自定义分配器和性能优化
- **错误处理**：完善的异常处理机制
- **模块系统**：动态加载和热重载
- **用户数据**：C/Lua 数据交换
- **性能监控**：函数Hook和性能统计

这些示例不仅适合学习 Lua C API，也是理解 skynet 框架内部机制的重要参考资料。
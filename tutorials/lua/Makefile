# Makefile for Lua C API Tutorial Examples
# Based on skynet snlua service analysis

# 编译器和标志
CC = gcc
CFLAGS = -std=c99 -Wall -Wextra -O2 -g
LDFLAGS = -llua -lm -ldl

# Lua 路径配置（可根据系统调整）
LUA_INCLUDE = /usr/include/lua5.4
LUA_LIB = /usr/lib/x86_64-linux-gnu

# 如果系统中 Lua 安装在不同位置，取消注释并修改以下行
# LUA_INCLUDE = /usr/local/include/lua5.4
# LUA_LIB = /usr/local/lib
# CFLAGS += -I$(LUA_INCLUDE)
# LDFLAGS += -L$(LUA_LIB)

# 检测操作系统
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
    # macOS 特定配置
    LUA_INCLUDE = /usr/local/include/lua5.4
    LUA_LIB = /usr/local/lib
    CFLAGS += -I$(LUA_INCLUDE)
    LDFLAGS += -L$(LUA_LIB)
endif

# 源文件和目标文件
SOURCES = 01_stack_operations.c \
          02_state_management.c \
          03_gc_control.c \
          04_registry_modules.c \
          05_function_hooks.c \
          06_userdata.c \
          07_error_handling.c \
          08_code_loading.c \
          09_memory_management.c \
          10_table_operations.c \
          11_coroutines.c
TARGETS = $(SOURCES:.c=)

# 默认目标
.PHONY: all clean help test

all: $(TARGETS)

# 通用编译规则
%: %.c
	@echo "编译 $<..."
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)
	@echo "完成：$@"

# 特定目标（可添加特殊编译选项）
01_stack_operations: 01_stack_operations.c
	@echo "编译栈操作示例..."
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

02_state_management: 02_state_management.c
	@echo "编译状态机管理示例..."
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

03_gc_control: 03_gc_control.c
	@echo "编译垃圾收集器控制示例..."
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

04_registry_modules: 04_registry_modules.c
	@echo "编译注册表和模块示例..."
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

05_function_hooks: 05_function_hooks.c
	@echo "编译函数Hook示例..."
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

06_userdata: 06_userdata.c
	@echo "编译用户数据示例..."
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

07_error_handling: 07_error_handling.c
	@echo "编译错误处理示例..."
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

08_code_loading: 08_code_loading.c
	@echo "编译代码加载示例..."
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

09_memory_management: 09_memory_management.c
	@echo "编译内存管理示例..."
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

10_table_operations: 10_table_operations.c
	@echo "编译表操作示例..."
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

11_coroutines: 11_coroutines.c
	@echo "编译协程示例..."
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

# 清理目标
clean:
	@echo "清理编译文件..."
	rm -f $(TARGETS)
	rm -f *.o
	rm -f core.*
	rm -f /tmp/lua_temp_module.lua
	rm -f /tmp/test_module.lua
	rm -f /tmp/fibonacci.luac
	@echo "清理完成"

# 测试目标
test: all
	@echo "运行所有示例..."
	@for target in $(TARGETS); do \
		echo "=== 运行 $$target ==="; \
		./$$target; \
		echo ""; \
	done

# 单独测试目标
test-%: %
	@echo "=== 运行 $< ==="
	./$<

# 检查依赖
check-deps:
	@echo "检查编译依赖..."
	@which $(CC) > /dev/null || (echo "错误：找不到 $(CC) 编译器" && exit 1)
	@echo "检查 Lua 开发库..."
	@echo '#include <lua.h>' | $(CC) -E -I$(LUA_INCLUDE) - > /dev/null 2>&1 || \
		(echo "错误：找不到 Lua 头文件，请安装 Lua 开发库" && \
		 echo "Ubuntu/Debian: sudo apt-get install liblua5.4-dev" && \
		 echo "CentOS/RHEL: sudo yum install lua-devel" && \
		 echo "macOS: brew install lua" && exit 1)
	@echo "依赖检查通过"

# 安装依赖（需要 sudo 权限）
install-deps:
	@echo "安装编译依赖..."
	@if command -v apt-get > /dev/null; then \
		echo "检测到 Debian/Ubuntu 系统"; \
		sudo apt-get update && sudo apt-get install -y build-essential liblua5.4-dev lua5.4; \
	elif command -v yum > /dev/null; then \
		echo "检测到 CentOS/RHEL 系统"; \
		sudo yum groupinstall -y "Development Tools" && sudo yum install -y lua-devel lua; \
	elif command -v brew > /dev/null; then \
		echo "检测到 macOS 系统"; \
		brew install lua; \
	else \
		echo "无法自动安装依赖，请手动安装 Lua 开发库"; \
		exit 1; \
	fi

# 调试版本
debug: CFLAGS += -DDEBUG -O0
debug: $(TARGETS)

# 发布版本
release: CFLAGS += -DNDEBUG -O3
release: clean $(TARGETS)

# 内存检查（需要 valgrind）
memcheck: all
	@if command -v valgrind > /dev/null; then \
		for target in $(TARGETS); do \
			echo "=== 内存检查 $$target ==="; \
			valgrind --leak-check=full --show-leak-kinds=all ./$$target; \
			echo ""; \
		done; \
	else \
		echo "未找到 valgrind，跳过内存检查"; \
		echo "安装 valgrind: sudo apt-get install valgrind"; \
	fi

# 性能分析（需要 perf）
profile: all
	@if command -v perf > /dev/null; then \
		echo "=== 性能分析 ==="; \
		for target in $(TARGETS); do \
			echo "分析 $$target..."; \
			perf record -g ./$$target; \
			perf report --stdio > $$target.perf.txt; \
			echo "结果保存到 $$target.perf.txt"; \
		done; \
	else \
		echo "未找到 perf，跳过性能分析"; \
	fi

# 代码格式化（需要 clang-format）
format:
	@if command -v clang-format > /dev/null; then \
		echo "格式化代码..."; \
		clang-format -i *.c; \
		echo "格式化完成"; \
	else \
		echo "未找到 clang-format，跳过代码格式化"; \
	fi

# 静态分析（需要 cppcheck）
static-analysis:
	@if command -v cppcheck > /dev/null; then \
		echo "静态代码分析..."; \
		cppcheck --enable=all --std=c99 *.c; \
	else \
		echo "未找到 cppcheck，跳过静态分析"; \
		echo "安装 cppcheck: sudo apt-get install cppcheck"; \
	fi

# 帮助信息
help:
	@echo "Lua C API 教程示例 Makefile"
	@echo ""
	@echo "可用目标："
	@echo "  all              - 编译所有示例"
	@echo "  clean            - 清理编译文件"
	@echo "  test             - 运行所有示例"
	@echo "  test-<example>   - 运行特定示例（如：test-01_stack_operations）"
	@echo "  check-deps       - 检查编译依赖"
	@echo "  install-deps     - 安装编译依赖（需要 sudo）"
	@echo "  debug            - 编译调试版本"
	@echo "  release          - 编译发布版本"
	@echo "  memcheck         - 内存检查（需要 valgrind）"
	@echo "  profile          - 性能分析（需要 perf）"
	@echo "  format           - 代码格式化（需要 clang-format）"
	@echo "  static-analysis  - 静态代码分析（需要 cppcheck）"
	@echo "  help             - 显示此帮助信息"
	@echo ""
	@echo "示例："
	@echo "  make all                    # 编译所有示例"
	@echo "  make 01_stack_operations    # 编译栈操作示例"
	@echo "  make test                   # 运行所有示例"
	@echo "  make test-06_userdata       # 运行用户数据示例"
	@echo "  make clean                  # 清理编译文件"
	@echo ""
	@echo "编译器配置："
	@echo "  CC = $(CC)"
	@echo "  CFLAGS = $(CFLAGS)"
	@echo "  LDFLAGS = $(LDFLAGS)"
	@echo "  LUA_INCLUDE = $(LUA_INCLUDE)"
	@echo "  LUA_LIB = $(LUA_LIB)"

# 确保所有目标不会与文件名冲突
.PHONY: check-deps install-deps debug release memcheck profile format static-analysis
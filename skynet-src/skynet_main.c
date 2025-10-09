#include "skynet.h"           // 核心 API 定义

#include "skynet_imp.h"        // 内部实现接口
#include "skynet_env.h"        // 环境变量管理
#include "skynet_server.h"     // 服务管理接口

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <lua.h>              // Lua 虚拟机
#include <lualib.h>
#include <lauxlib.h>
#include <signal.h>           // 信号处理
#include <assert.h>

static int
optint(const char *key, int opt) {
	const char * str = skynet_getenv(key);
	if (str == NULL) {
		char tmp[20];
		sprintf(tmp,"%d",opt);
		skynet_setenv(key, tmp);
		return opt;
	}
	return strtol(str, NULL, 10);
}

static int
optboolean(const char *key, int opt) {
	const char * str = skynet_getenv(key);
	if (str == NULL) {
		skynet_setenv(key, opt ? "true" : "false");
		return opt;
	}
	return strcmp(str,"true")==0;
}

static const char *
optstring(const char *key,const char * opt) {
	const char * str = skynet_getenv(key);
	if (str == NULL) {
		if (opt) {
			skynet_setenv(key, opt);
			opt = skynet_getenv(key);
		}
		return opt;
	}
	return str;
}

static void
_init_env(lua_State *L) {
	lua_pushnil(L);  /* first key */
	while (lua_next(L, -2) != 0) {
		// 验证键类型必须是字符串
		int keyt = lua_type(L, -2);
		if (keyt != LUA_TSTRING) {
			fprintf(stderr, "Invalid config table\n");
			exit(1);
		}
		const char * key = lua_tostring(L,-2);
		if (lua_type(L,-1) == LUA_TBOOLEAN) {
			// 处理布尔值
			int b = lua_toboolean(L,-1);
			skynet_setenv(key,b ? "true" : "false" );
		} else {
			// 处理字符串值
			const char * value = lua_tostring(L,-1);
			if (value == NULL) {
				fprintf(stderr, "Invalid config table key = %s\n", key);
				exit(1);
			}
			skynet_setenv(key,value);
		}
		lua_pop(L,1);
	}
	lua_pop(L,1);
}

int sigign() {
	struct sigaction sa;
	sa.sa_handler = SIG_IGN;  // 忽略 SIGPIPE，防止网络连接断开时进程被 SIGPIPE 信号终止
	sa.sa_flags = 0;
	sigemptyset(&sa.sa_mask);
	sigaction(SIGPIPE, &sa, 0);
	return 0;
}

static const char * load_config = "\
	local result = {}\n\
	local function getenv(name) return assert(os.getenv(name), [[os.getenv() failed: ]] .. name) end\n\
	local sep = package.config:sub(1,1)\n\
	local current_path = [[.]]..sep\n\
	local function include(filename)\n\
		local last_path = current_path\n\
		local path, name = filename:match([[(.*]]..sep..[[)(.*)$]])\n\
		if path then\n\
			if path:sub(1,1) == sep then	-- root\n\
				current_path = path\n\
			else\n\
				current_path = current_path .. path\n\
			end\n\
		else\n\
			name = filename\n\
		end\n\
		local f = assert(io.open(current_path .. name))\n\
		local code = assert(f:read [[*a]])\n\
		code = string.gsub(code, [[%$([%w_%d]+)]], getenv)\n\
		f:close()\n\
		assert(load(code,[[@]]..filename,[[t]],result))()\n\
		current_path = last_path\n\
	end\n\
	setmetatable(result, { __index = { include = include } })\n\
	local config_name = ...\n\
	include(config_name)\n\
	setmetatable(result, nil)\n\
	return result\n\
";

int
main(int argc, char *argv[]) {
	// 1. 参数检查
	const char * config_file = NULL ;
	if (argc > 1) {
		config_file = argv[1];
	} else { // 配置文件不存在或格式错误
		fprintf(stderr, "Need a config file. Please read skynet wiki : https://github.com/cloudwu/skynet/wiki/Config\n"
			"usage: skynet configfilename\n");
		return 1;
	}

	// 2. 全局初始化
	skynet_globalinit();      // 初始化内存分配器等
	skynet_env_init();        // 初始化环境变量存储

	// 3. 信号处理
	sigign();                 // 忽略 SIGPIPE 信号

	struct skynet_config config;

#ifdef LUA_CACHELIB
	// init the lock of code cache
	luaL_initcodecache();
#endif

	// 4. 配置加载
	struct lua_State *L = luaL_newstate();
	luaL_openlibs(L);	// link lua lib

	int err =  luaL_loadbufferx(L, load_config, strlen(load_config), "=[skynet config]", "t");
	assert(err == LUA_OK);
	lua_pushstring(L, config_file);

	err = lua_pcall(L, 1, 1, 0);
	if (err) {
		// Lua 配置解析错误
		fprintf(stderr,"%s\n",lua_tostring(L,-1));
		lua_close(L);
		return 1;
	}
    // 执行配置加载脚本...
	_init_env(L);            // 将配置转换为环境变量
	lua_close(L);

    // 5. 配置解析
	config.thread =  optint("thread",8);		// 工作线程数量，建议设置为 CPU 核心数
	config.module_path = optstring("cpath","./cservice/?.so");		// C 服务模块搜索路径
	config.harbor = optint("harbor", 1);		// 集群节点 ID，单节点为1，集群为1-255
	config.bootstrap = optstring("bootstrap","snlua bootstrap");	// 启动命令，指定第一个服务
	config.daemon = optstring("daemon", NULL);	// 守护进程 PID 文件路径
	config.logger = optstring("logger", NULL);	// 日志文件路径，NULL 表示输出到标准输出
	config.logservice = optstring("logservice", "logger");			// 日志服务名称
	config.profile = optboolean("profile", 1);	// 是否开启性能分析

    // 6. 启动系统
	skynet_start(&config);
    // 7. 清理退出
	skynet_globalexit();

	return 0;
}

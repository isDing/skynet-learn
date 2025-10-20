#define LUA_LIB

// 本模块将 C 层的内存统计接口暴露给 Lua，便于脚本快速查看 jemalloc 运行状态。

#include <lua.h>
#include <lauxlib.h>

#include "malloc_hook.h"

static int
ltotal(lua_State *L) {
	// 返回全局已分配内存字节数，对调试“整体内存是否上涨”很有帮助。
	size_t t = malloc_used_memory();
	lua_pushinteger(L, (lua_Integer)t);

	return 1;
}

static int
lblock(lua_State *L) {
	// 返回当前内存块数量（分配次数），辅助判断碎片或频繁 alloc/free。
	size_t t = malloc_memory_block();
	lua_pushinteger(L, (lua_Integer)t);

	return 1;
}

static int
ldumpinfo(lua_State *L) {
	// 直接透传到 jemalloc 的统计接口，可传入选项字符串控制输出颗粒度。
	const char *opts = NULL;
	if (lua_isstring(L, 1)) {
		opts = luaL_checkstring(L,1);
	}
	memory_info_dump(opts);

	return 0;
}

static int
ljestat(lua_State *L) {
	// 读取 jemalloc 内部的若干关键指标（需要先刷新 epoch），
	// 以表格形式返回给 Lua。
	static const char* names[] = {
		"stats.allocated",
		"stats.resident",
		"stats.retained",
		"stats.mapped",
		"stats.active" };
	static size_t flush = 1;
	mallctl_int64("epoch", &flush); // refresh je.stats.cache
	lua_newtable(L);
	int i;
	for (i = 0; i < (sizeof(names)/sizeof(names[0])); i++) {
		lua_pushstring(L, names[i]);
		lua_pushinteger(L,  (lua_Integer) mallctl_int64(names[i], NULL));
		lua_settable(L, -3);
	}
	return 1;
}

static int
lmallctl(lua_State *L) {
	// 允许 Lua 直接查询 mallctl 指标，学习 jemalloc 时很方便。
	const char *name = luaL_checkstring(L,1);
	lua_pushinteger(L, (lua_Integer) mallctl_int64(name, NULL));
	return 1;
}

static int
ldump(lua_State *L) {
	// 调用 C 侧 dump_c_mem 打印每个服务的内存占用。
	dump_c_mem();

	return 0;
}

static int
lcurrent(lua_State *L) {
	// 返回当前服务（句柄）的内存使用量，常用于查找热点服务。
	lua_pushinteger(L, malloc_current_memory());
	return 1;
}

static int
ldumpheap(lua_State *L) {
	// 触发 jemalloc heap profile dump，可配合 jeprof 分析内存热点。
	mallctl_cmd("prof.dump");
	return 0;
}

static int
lprofactive(lua_State *L) {
	// 开关 jemalloc profile（prof.active），便于在运行中动态开启/关闭采样。
	bool *pval, active;
	if (lua_isnone(L, 1)) {
		pval = NULL;
	} else {
		active = lua_toboolean(L, 1) ? true : false;
		pval = &active;
	}
	bool ret = mallctl_bool("prof.active", pval);
	lua_pushboolean(L, ret);
	return 1;
}

LUAMOD_API int
luaopen_skynet_memory(lua_State *L) {
	luaL_checkversion(L);

	luaL_Reg l[] = {
		{ "total", ltotal },
		{ "block", lblock },
		{ "dumpinfo", ldumpinfo },
		{ "jestat", ljestat },
		{ "mallctl", lmallctl },
		{ "dump", ldump },
		{ "info", dump_mem_lua },
		{ "current", lcurrent },
		{ "dumpheap", ldumpheap },
		{ "profactive", lprofactive },
		{ NULL, NULL },
	};

	luaL_newlib(L,l);

	return 1;
}

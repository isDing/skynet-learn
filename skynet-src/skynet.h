#ifndef SKYNET_H
#define SKYNET_H

#include "skynet_malloc.h"

#include <stddef.h>
#include <stdint.h>

#define PTYPE_TEXT 0        // 文本消息（调试用）
#define PTYPE_RESPONSE 1    // 响应消息
#define PTYPE_MULTICAST 2   // 组播消息
#define PTYPE_CLIENT 3      // 客户端消息
#define PTYPE_SYSTEM 4      // 系统消息
#define PTYPE_HARBOR 5      // 跨节点消息
#define PTYPE_SOCKET 6      // 网络消息
// read lualib/skynet.lua examples/simplemonitor.lua
#define PTYPE_ERROR 7	    // 错误消息
// read lualib/skynet.lua lualib/mqueue.lua lualib/snax.lua
#define PTYPE_RESERVED_QUEUE 8  // 保留
#define PTYPE_RESERVED_DEBUG 9  // 调试
#define PTYPE_RESERVED_LUA 10   // Lua消息
#define PTYPE_RESERVED_SNAX 11  // SNAX框架消息

#define PTYPE_TAG_DONTCOPY 0x10000
#define PTYPE_TAG_ALLOCSESSION 0x20000

struct skynet_context;

void skynet_error(struct skynet_context * context, const char *msg, ...);
const char * skynet_command(struct skynet_context * context, const char * cmd , const char * parm);
uint32_t skynet_queryname(struct skynet_context * context, const char * name);
int skynet_send(struct skynet_context * context, uint32_t source, uint32_t destination , int type, int session, void * msg, size_t sz);
int skynet_sendname(struct skynet_context * context, uint32_t source, const char * destination , int type, int session, void * msg, size_t sz);

int skynet_isremote(struct skynet_context *, uint32_t handle, int * harbor);

typedef int (*skynet_cb)(struct skynet_context * context, void *ud, int type, int session, uint32_t source , const void * msg, size_t sz);
void skynet_callback(struct skynet_context * context, void *ud, skynet_cb cb);

uint32_t skynet_current_handle(void);
uint64_t skynet_now(void);
void skynet_debug_memory(const char *info);	// for debug use, output current service memory to stderr

#endif

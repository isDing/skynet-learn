#ifndef SKYNET_CONTEXT_HANDLE_H
#define SKYNET_CONTEXT_HANDLE_H

#include <stdint.h>

// handle 的位域布局
// |<- 8 bits ->|<--- 24 bits --->|
// |  harbor_id |   local_handle  |

// reserve high 8 bits for remote id
#define HANDLE_MASK 0xffffff          // 低 24 位掩码
#define HANDLE_REMOTE_SHIFT 24        // harbor 位移

struct skynet_context;

uint32_t skynet_handle_register(struct skynet_context *);
int skynet_handle_retire(uint32_t handle);
struct skynet_context * skynet_handle_grab(uint32_t handle);
void skynet_handle_retireall();

uint32_t skynet_handle_findname(const char * name);
const char * skynet_handle_namehandle(uint32_t handle, const char *name);

void skynet_handle_init(int harbor);

#endif

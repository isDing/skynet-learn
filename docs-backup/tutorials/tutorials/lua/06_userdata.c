#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

typedef struct {
    int id;
    const char* name;
    void* data;
} Context;

static int get_context_info(lua_State *L) {
    lua_getfield(L, LUA_REGISTRYINDEX, "context_ptr");
    Context* ctx = (Context*)lua_touserdata(L, -1);
    lua_pop(L, 1);
    
    if (ctx) {
        lua_newtable(L);
        lua_pushinteger(L, ctx->id);
        lua_setfield(L, -2, "id");
        lua_pushstring(L, ctx->name);
        lua_setfield(L, -2, "name");
        return 1;
    }
    return 0;
}

void lightuserdata_demo() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("=== Light Userdata Demo ===\n");
    
    Context ctx = {12345, "test_context", NULL};
    
    lua_pushlightuserdata(L, &ctx);
    lua_setfield(L, LUA_REGISTRYINDEX, "context_ptr");
    
    lua_pushcfunction(L, get_context_info);
    lua_setglobal(L, "get_context_info");
    
    luaL_dostring(L, 
        "local info = get_context_info()\n"
        "if info then\n"
        "    print('Context ID:', info.id)\n"
        "    print('Context Name:', info.name)\n"
        "else\n"
        "    print('No context available')\n"
        "end\n"
    );
    
    lua_close(L);
}

typedef struct {
    char* buffer;
    size_t size;
    size_t capacity;
} Buffer;

static int buffer_gc(lua_State *L) {
    Buffer* buf = (Buffer*)lua_touserdata(L, 1);
    if (buf->buffer) {
        printf("Freeing buffer (%zu bytes)\n", buf->capacity);
        free(buf->buffer);
        buf->buffer = NULL;
    }
    return 0;
}

static int buffer_append(lua_State *L) {
    Buffer* buf = (Buffer*)luaL_checkudata(L, 1, "Buffer");
    size_t len;
    const char* data = luaL_checklstring(L, 2, &len);
    
    if (buf->size + len > buf->capacity) {
        size_t new_capacity = (buf->size + len) * 2;
        buf->buffer = (char*)realloc(buf->buffer, new_capacity);
        buf->capacity = new_capacity;
        printf("Buffer resized to %zu bytes\n", new_capacity);
    }
    
    memcpy(buf->buffer + buf->size, data, len);
    buf->size += len;
    
    return 0;
}

static int buffer_tostring(lua_State *L) {
    Buffer* buf = (Buffer*)luaL_checkudata(L, 1, "Buffer");
    lua_pushlstring(L, buf->buffer, buf->size);
    return 1;
}

static int buffer_len(lua_State *L) {
    Buffer* buf = (Buffer*)luaL_checkudata(L, 1, "Buffer");
    lua_pushinteger(L, buf->size);
    return 1;
}

static const luaL_Reg buffer_methods[] = {
    {"append", buffer_append},
    {"tostring", buffer_tostring},
    {"__gc", buffer_gc},
    {"__len", buffer_len},
    {"__tostring", buffer_tostring},
    {NULL, NULL}
};

static int create_buffer(lua_State *L) {
    size_t initial_capacity = luaL_optinteger(L, 1, 256);
    
    Buffer* buf = (Buffer*)lua_newuserdata(L, sizeof(Buffer));
    buf->buffer = (char*)malloc(initial_capacity);
    buf->size = 0;
    buf->capacity = initial_capacity;
    
    luaL_getmetatable(L, "Buffer");
    lua_setmetatable(L, -2);
    
    printf("Created buffer with capacity %zu\n", initial_capacity);
    return 1;
}

void userdata_demo() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    
    printf("=== Full Userdata Demo ===\n");
    
    luaL_newmetatable(L, "Buffer");
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");
    luaL_setfuncs(L, buffer_methods, 0);
    lua_pop(L, 1);
    
    lua_pushcfunction(L, create_buffer);
    lua_setglobal(L, "Buffer");
    
    luaL_dostring(L, 
        "local buf = Buffer(100)\n"
        "print('Buffer created')\n"
        "\n"
        "buf:append('Hello, ')\n"
        "buf:append('World!')\n"
        "buf:append(' This is a test.')\n"
        "\n"
        "print('Content:', buf:tostring())\n"
        "print('Size:', #buf)\n"
    );
    
    lua_gc(L, LUA_GCCOLLECT, 0);
    
    lua_close(L);
}

void pointer_mapping_demo() {
    printf("=== Pointer Mapping Demo ===\n");
    printf("Simplified pointer mapping demonstration\n");
}

void binary_data_demo() {
    printf("=== Binary Data Demo ===\n");
    printf("Simplified binary data demonstration\n");
}

int main() {
    lightuserdata_demo();
    printf("\n");
    userdata_demo();
    printf("\n");
    pointer_mapping_demo();
    printf("\n");
    binary_data_demo();
    
    return 0;
}

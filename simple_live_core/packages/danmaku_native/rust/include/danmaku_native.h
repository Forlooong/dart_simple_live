#ifndef SIMPLE_LIVE_DANMAKU_NATIVE_H
#define SIMPLE_LIVE_DANMAKU_NATIVE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct DmSession DmSession;
typedef struct { uint8_t *data; size_t len; } DmBuffer;
uint32_t dm_abi_version(void);
DmSession *dm_create(uint32_t protocol);
int32_t dm_reset(DmSession *session);
void dm_dispose(DmSession *session);
int32_t dm_decode_batch(DmSession*,const uint8_t*,size_t,DmBuffer*);
int32_t dm_replace_rules(DmSession*,const uint8_t*,size_t,DmBuffer*);
int32_t dm_filter_batch(DmSession*,const uint8_t*,size_t,DmBuffer*);
int32_t dm_encode(DmSession*,const uint8_t*,size_t,DmBuffer*);
void dm_free_buffer(uint8_t *data,size_t len);
/* Exactly one owner/call per handle. Free each returned buffer once, even on
 * nonzero status. Status: 0 success, 1 malformed, 2 resource limit, 3 invalid
 * request, 4 caught panic. CBOR version 1; user strings are UTF-16LE bytes.
 * Protocol 0 is filter/encode only; 1 Bilibili, 2 Douyu, 3 Huya, 4 Douyin. */
#ifdef __cplusplus
}
#endif
#endif

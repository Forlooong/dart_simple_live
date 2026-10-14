/* Bounded ECMAScript compatibility for danmaku. See UPSTREAM.md. */
#include "quickjs.h"
#include <stdint.h>
#include <stdlib.h>
#ifdef _WIN32
#define SL_EXPORT __declspec(dllexport)
#else
#define SL_EXPORT __attribute__((visibility("default")))
#endif
#ifdef _WIN32
#include <windows.h>
static uint64_t now_ms(void) { return GetTickCount64(); }
#else
#include <time.h>
static uint64_t now_ms(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (uint64_t)value.tv_sec * 1000 + value.tv_nsec / 1000000;
}
#endif

SL_EXPORT JSValue SL_NewString16(JSContext *ctx, const uint16_t *data, int length);
typedef struct {
    JSRuntime *rt;
    JSContext *ctx;
    JSValue rules;
    JSValue constructor;
    uint32_t count;
    uint64_t deadline;
    int interrupted;
} SLRegex;

static int interrupt(JSRuntime *rt, void *opaque) {
    (void)rt;
    SLRegex *filter = opaque;
    if (now_ms() >= filter->deadline) filter->interrupted = 1;
    return filter->interrupted;
}
static int clear_error(SLRegex *filter) {
    JSValue error = JS_GetException(filter->ctx);
    JS_FreeValue(filter->ctx, error);
    return filter->interrupted ? -2 : -1;
}
SL_EXPORT void sl_regex_begin(SLRegex *filter) {
    JS_UpdateStackTop(filter->rt);
    filter->interrupted = 0;
    filter->deadline = now_ms() + 100;
}
SL_EXPORT SLRegex *sl_regex_create(void) {
    SLRegex *filter = calloc(1, sizeof(*filter));
    if (!filter) return NULL;
    filter->rt = JS_NewRuntime();
    if (!filter->rt) { free(filter); return NULL; }
    JS_SetMemoryLimit(filter->rt, 32 * 1024 * 1024);
    JS_SetMaxStackSize(filter->rt, 512 * 1024);
    sl_regex_begin(filter);
    JS_SetInterruptHandler(filter->rt, interrupt, filter);
    filter->ctx = JS_NewContext(filter->rt);
    if (!filter->ctx) { JS_FreeRuntime(filter->rt); free(filter); return NULL; }
    filter->rules = JS_NewArray(filter->ctx);
    JSValue global = JS_GetGlobalObject(filter->ctx);
    filter->constructor = JS_GetPropertyStr(filter->ctx, global, "RegExp");
    JS_FreeValue(filter->ctx, global);
    return filter;
}
SL_EXPORT int sl_regex_add(SLRegex *filter, const uint16_t *text, uint32_t length) {
    JS_UpdateStackTop(filter->rt);
    if (length > 4096 || filter->count >= 2000) return -3;
    JSValue pattern = SL_NewString16(filter->ctx, text, (int)length);
    if (JS_IsException(pattern)) return clear_error(filter);
    JSValue rule = JS_CallConstructor(filter->ctx, filter->constructor, 1, &pattern);
    JS_FreeValue(filter->ctx, pattern);
    if (JS_IsException(rule)) return clear_error(filter);
    if (JS_SetPropertyUint32(filter->ctx, filter->rules, filter->count++, rule) < 0)
        return clear_error(filter);
    return 0;
}
/* 1 = blocked, 0 = keep, negative = error; a whole batch shares one deadline. */
SL_EXPORT int sl_regex_match(SLRegex *filter, const uint16_t *text, uint32_t length) {
    JS_UpdateStackTop(filter->rt);
    if (interrupt(filter->rt, filter)) return -2;
    JSValue message = SL_NewString16(filter->ctx, text, (int)length);
    if (JS_IsException(message)) return clear_error(filter);
    int verdict = 0;
    for (uint32_t i = 0; i < filter->count; i++) {
        JSValue rule = JS_GetPropertyUint32(filter->ctx, filter->rules, i);
        JSValue test = JS_GetPropertyStr(filter->ctx, rule, "test");
        JSValue result = JS_Call(filter->ctx, test, rule, 1, &message);
        JS_FreeValue(filter->ctx, test);
        JS_FreeValue(filter->ctx, rule);
        if (JS_IsException(result)) { verdict = clear_error(filter); break; }
        verdict = JS_ToBool(filter->ctx, result);
        JS_FreeValue(filter->ctx, result);
        if (verdict != 0) break;
    }
    JS_FreeValue(filter->ctx, message);
    return verdict;
}
SL_EXPORT void sl_regex_destroy(SLRegex *filter) {
    if (!filter) return;
    JS_UpdateStackTop(filter->rt);
    JS_FreeValue(filter->ctx, filter->constructor);
    JS_FreeValue(filter->ctx, filter->rules);
    JS_FreeContext(filter->ctx);
    JS_FreeRuntime(filter->rt);
    free(filter);
}

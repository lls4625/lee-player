/* Self-contained libmpv ABI test double. No player, renderer or audio output. */
#include <stdint.h>
#include <stddef.h>
#include <string.h>

typedef struct { const char *name; int format; void *data; } mpv_event_property;
typedef struct { int event_id; int error; uint64_t reply_userdata; void *data; } mpv_event;
static mpv_event event;
static mpv_event_property property;
static char value_storage[512];
static char name_storage[256];
static char *value;
static int ready, submit_error, submissions, frees, last_format;
static uint64_t last_id;
static void (*wakeup)(void *);
static void *wakeup_context;
static int sync_gets;

int mpv_get_property_async(void *ctx, uint64_t id, const char *name, int format) {
  (void)ctx;
  ++submissions;
  last_id = id;
  last_format = format;
  strncpy(name_storage, name, sizeof(name_storage) - 1);
  name_storage[sizeof(name_storage) - 1] = 0;
  return submit_error;
}

/* Payload is borrowed and invalidated by the NEXT wait_event, matching mpv. */
mpv_event *mpv_wait_event(void *ctx, double timeout) {
  (void)ctx; (void)timeout;
  if (ready) { ready = 0; return &event; }
  memset(value_storage, '!', sizeof(value_storage) - 1);
  value_storage[sizeof(value_storage) - 1] = 0;
  event.event_id = 0;
  event.data = NULL;
  return &event;
}

void mpv_free(void *ptr) { (void)ptr; ++frees; }
void fake_reset(void) {
  ready = submit_error = submissions = frees = last_format = 0;
  last_id = 0;
  sync_gets = 0;
  memset(&event, 0, sizeof(event));
  memset(&property, 0, sizeof(property));
}
/* Additional no-op entry points let the real NativePlayer initialization and
   its one NativeCallable event pump be tested without media or system audio. */
void *mpv_create(void) { return (void *)(uintptr_t)1; }
int mpv_initialize(void *ctx) { (void)ctx; return 0; }
int mpv_set_option_string(void *ctx, const char *key, const char *value_) {
  (void)ctx; (void)key; (void)value_; return 0;
}
int mpv_set_property(void *ctx, const char *key, int format, void *data) {
  (void)ctx; (void)key; (void)format; (void)data; return 0;
}
int mpv_observe_property(void *ctx, uint64_t id, const char *key, int format) {
  (void)ctx; (void)id; (void)key; (void)format; return 0;
}
int mpv_request_log_messages(void *ctx, const char *level) {
  (void)ctx; (void)level; return 0;
}
int mpv_hook_add(void *ctx, uint64_t id, const char *name, int priority) {
  (void)ctx; (void)id; (void)name; (void)priority; return 0;
}
void mpv_set_wakeup_callback(void *ctx, void (*callback)(void *), void *data) {
  (void)ctx; wakeup = callback; wakeup_context = data;
}
void fake_wake(void) { if (wakeup) wakeup(wakeup_context); }
int mpv_command(void *ctx, const char **args) { (void)ctx; (void)args; return 0; }
void mpv_terminate_destroy(void *ctx) { (void)ctx; }
const char *mpv_get_property_string(void *ctx, const char *name) {
  (void)ctx; (void)name; ++sync_gets; return "legacy-sync";
}
int fake_sync_gets(void) { return sync_gets; }
void fake_submit_error(int error) { submit_error = error; }
int fake_submissions(void) { return submissions; }
int fake_frees(void) { return frees; }
int fake_last_format(void) { return last_format; }
uint64_t fake_last_id(void) { return last_id; }
const char *fake_last_name(void) { return name_storage; }
void fake_reply(uint64_t id, const char *text, int error, int format, int null_mode) {
  strncpy(value_storage, text, sizeof(value_storage) - 1);
  value_storage[sizeof(value_storage) - 1] = 0;
  value = null_mode == 3 ? NULL : value_storage;
  property.name = name_storage;
  property.format = format;
  property.data = null_mode == 2 ? NULL : &value;
  event.event_id = 3;
  event.error = error;
  event.reply_userdata = id;
  event.data = null_mode == 1 ? NULL : &property;
  ready = 1;
}

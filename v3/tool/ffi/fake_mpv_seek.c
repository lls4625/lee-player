/* libmpv ABI fixture for real NativePlayer seek/command lifecycle tests.
 * Only controls command receipts and EOF events. No decoding or seek-position
 * measurement: command targets are not proof of actual media seek accuracy. */
#define mpv_create property_fixture_create
#define mpv_wait_event property_fixture_wait_event
#define mpv_set_wakeup_callback property_fixture_wakeup_callback
#define mpv_command property_fixture_command
#define mpv_set_property property_fixture_set_property
#define mpv_terminate_destroy property_fixture_terminate_destroy
#include "fake_mpv_property.c"
#undef mpv_create
#undef mpv_wait_event
#undef mpv_set_wakeup_callback
#undef mpv_command
#undef mpv_set_property
#undef mpv_terminate_destroy
#include <stdlib.h>

enum { CAPACITY = 256, CONTEXTS = 64 };
typedef struct {
  mpv_event events[CAPACITY], output;
  mpv_event_property eof_property;
  int eof_value;
  unsigned read_index, write_index;
  void (*callback)(void *);
  void *callback_data;
  int hold_seek, command_count, seek_count, pause_value, pause_sets;
  uint64_t last_seek_id;
  char arguments[CAPACITY][3][80];
} seek_context;
static seek_context seek_contexts[CONTEXTS];
static unsigned created;
static seek_context *context(void *ctx) { return (seek_context *)ctx; }
static void queue(void *ctx, int kind, uint64_t id, void *data) {
  seek_context *c = context(ctx);
  if (c->write_index - c->read_index >= CAPACITY) abort();
  mpv_event *e = &c->events[c->write_index++ % CAPACITY];
  e->event_id = kind;
  e->error = 0;
  e->reply_userdata = id;
  e->data = data;
  if (c->callback) c->callback(c->callback_data);
}
void *mpv_create(void) {
  if (created == CONTEXTS) abort();
  seek_context *c = &seek_contexts[created++];
  memset(c, 0, sizeof(*c));
  return c;
}
mpv_event *mpv_wait_event(void *ctx, double timeout) {
  (void)timeout;
  seek_context *c = context(ctx);
  if (c->read_index < c->write_index) {
    c->output = c->events[c->read_index++ % CAPACITY];
  } else {
    memset(&c->output, 0, sizeof(c->output));
  }
  return &c->output;
}
void mpv_set_wakeup_callback(void *ctx, void (*callback)(void *), void *data) {
  seek_context *c = context(ctx);
  c->callback = callback;
  c->callback_data = data;
  if (callback && c->read_index < c->write_index) callback(data);
}
static void record_command(void *ctx, const char **args) {
  seek_context *c = context(ctx);
  if (c->command_count == CAPACITY) abort();
  int index = c->command_count++;
  for (int a = 0; a < 3 && args[a]; ++a) {
    strncpy(c->arguments[index][a], args[a], 79);
    c->arguments[index][a][79] = 0;
  }
  if (strcmp(args[0], "seek") == 0) ++c->seek_count;
}
int mpv_command(void *ctx, const char **args) {
  record_command(ctx, args);
  return 0;
}
int mpv_command_async(void *ctx, uint64_t id, const char **args) {
  seek_context *c = context(ctx);
  record_command(ctx, args);
  if (strcmp(args[0], "seek") == 0) {
    c->last_seek_id = id;
    if (c->hold_seek) return 0;
  }
  queue(ctx, 5, id, NULL); /* MPV_EVENT_COMMAND_REPLY */
  return 0;
}
int mpv_set_property(void *ctx, const char *key, int format, void *data) {
  seek_context *c = context(ctx);
  if (strcmp(key, "pause") == 0 && format == 3) {
    c->pause_value = *(unsigned char *)data;
    ++c->pause_sets;
  }
  return 0;
}
int mpv_set_property_async(void *ctx, uint64_t id, const char *key,
                           int format, void *data) {
  mpv_set_property(ctx, key, format, data);
  queue(ctx, 4, id, NULL); /* MPV_EVENT_SET_PROPERTY_REPLY */
  return 0;
}
void mpv_terminate_destroy(void *ctx) { (void)ctx; }
void fake_seek_hold(void *ctx, int hold) { context(ctx)->hold_seek = hold; }
void fake_seek_release(void *ctx, uint64_t id) { queue(ctx, 5, id, NULL); }
uint64_t fake_seek_last_id(void *ctx) { return context(ctx)->last_seek_id; }
int fake_seek_count(void *ctx) { return context(ctx)->seek_count; }
int fake_command_count(void *ctx) { return context(ctx)->command_count; }
int fake_pause_value(void *ctx) { return context(ctx)->pause_value; }
int fake_pause_sets(void *ctx) { return context(ctx)->pause_sets; }
int fake_has_callback(void *ctx) { return context(ctx)->callback != NULL; }
const char *fake_command_argument(void *ctx, int index, int argument) {
  if (index < 0 || index >= context(ctx)->command_count || argument < 0 || argument > 2)
    return "";
  return context(ctx)->arguments[index][argument];
}
void fake_seek_eof(void *ctx) {
  seek_context *c = context(ctx);
  c->eof_value = 1;
  c->eof_property.name = "eof-reached";
  c->eof_property.format = 3; /* MPV_FORMAT_FLAG */
  c->eof_property.data = &c->eof_value;
  queue(ctx, 22, 0, &c->eof_property); /* MPV_EVENT_PROPERTY_CHANGE */
}

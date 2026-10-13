/* Lifecycle/transport fixture for the real MediaKitPlayback and NativePlayer.
 * No decoding, hardware, iOS audio session, texture renderer or audible output.
 * Property values only provide deterministic acknowledgements to Dart. */
#define mpv_command_async background_base_command_async
#define mpv_get_property_async background_base_get_property_async
#define mpv_observe_property background_base_observe_property
#define mpv_set_option_string background_base_set_option_string
#include "fake_mpv_seek.c"
#undef mpv_command_async
#undef mpv_get_property_async
#undef mpv_observe_property
#undef mpv_set_option_string
#include <stdio.h>

typedef struct {
  mpv_event_property replies[CAPACITY], idle;
  char names[CAPACITY][80], values[CAPACITY][80];
  char *pointers[CAPACITY];
  unsigned writes;
  int idle_value;
  int loaded, render_ready, video_selected, early_video_enables;
  char vid[16], aid[16], sid[16];
} background_context;
static background_context background_contexts[CONTEXTS];
static background_context *background(void *ctx) {
  return &background_contexts[context(ctx) - seek_contexts];
}
int mpv_command_async(void *ctx, uint64_t id, const char **args) {
  if (strcmp(args[0], "loadlist") == 0 || strcmp(args[0], "loadfile") == 0) {
    background_context *b = background(ctx);
    b->loaded = 1;
    b->video_selected = b->render_ready && strcmp(b->vid, "auto") == 0;
  }
  if (strcmp(args[0], "stop") == 0) {
    background(ctx)->loaded = 0;
    background(ctx)->video_selected = 0;
  }
  return background_base_command_async(ctx, id, args);
}
int mpv_observe_property(void *ctx, uint64_t id, const char *key, int format) {
  (void)format;
  if (strcmp(key, "idle-active") == 0) {
    background_context *b = background(ctx);
    b->idle_value = 1;
    b->idle = (mpv_event_property){"idle-active", 3, &b->idle_value};
    queue(ctx, 22, id, &b->idle);
  }
  return 0;
}
int mpv_set_property_string(void *ctx, const char *key, const char *value_) {
  background_context *b = background(ctx);
  if (strcmp(key, "vid") == 0) {
    if (b->loaded && strcmp(value_, "no") != 0 && !b->render_ready) {
      /* libmpv VO initialization fails; creating a context later does not
         retry selection. This models the ordering in the user's r8 log. */
      ++b->early_video_enables;
      b->video_selected = 0;
      snprintf(b->vid, sizeof(b->vid), "no");
      return -12;
    }
    snprintf(b->vid, sizeof(b->vid), "%s", value_);
    b->video_selected = b->loaded && b->render_ready && strcmp(value_, "no") != 0;
  }
  if (strcmp(key, "aid") == 0) snprintf(b->aid, sizeof(b->aid), "%s", value_);
  if (strcmp(key, "sid") == 0) snprintf(b->sid, sizeof(b->sid), "%s", value_);
  return 0;
}
int mpv_set_option_string(void *ctx, const char *key, const char *value_) {
  return mpv_set_property_string(ctx, key, value_);
}
int mpv_get_property_async(void *ctx, uint64_t id, const char *name, int format) {
  background_context *b = background(ctx);
  unsigned i = b->writes++ % CAPACITY;
  const char *text = "0";
  if (strcmp(name, "duration") == 0) text = "120";
  if (strcmp(name, "time-pos") == 0) text = "35";
  if (strcmp(name, "pause") == 0) text = context(ctx)->pause_value ? "yes" : "no";
  if (strcmp(name, "seekable") == 0) text = "yes";
  if (strcmp(name, "eof-reached") == 0 || strcmp(name, "seeking") == 0 ||
      strcmp(name, "paused-for-cache") == 0) text = "no";
  if (strcmp(name, "speed") == 0) text = "1";
  if (strcmp(name, "vid") == 0) text = b->vid;
  snprintf(b->names[i], sizeof(b->names[i]), "%s", name);
  snprintf(b->values[i], sizeof(b->values[i]), "%s", text);
  b->pointers[i] = b->values[i];
  b->replies[i] = (mpv_event_property){b->names[i], format, &b->pointers[i]};
  queue(ctx, 3, id, &b->replies[i]);
  return 0;
}

/* The actual video controller queries decoder-list before sending Create. */
typedef struct mpv_node mpv_node;
typedef struct { int num; mpv_node *values; char **keys; } mpv_node_list;
struct mpv_node {
  union { char *string; int flag; int64_t int64; double double_; mpv_node_list *list; void *ba; } u;
  int format;
};
int mpv_get_property(void *ctx, const char *name, int format, void *data) {
  (void)ctx; (void)format;
  static char *keys[] = {"codec"};
  static mpv_node codec = {.u.string = "h264", .format = 1};
  static mpv_node_list decoder = {1, &codec, keys};
  static mpv_node entry = {.u.list = &decoder, .format = 8};
  static mpv_node_list list = {1, &entry, NULL};
  if (strcmp(name, "decoder-list") == 0) {
    *(mpv_node *)data = (mpv_node){.u.list = &list, .format = 7};
    return 0;
  }
  return -8;
}
void mpv_free_node_contents(void *data) { (void)data; }
int fake_created_count(void) { return (int)created; }
void *fake_last_context(void) { return created ? &seek_contexts[created - 1] : NULL; }
const char *fake_video_track(void *ctx) { return background(ctx)->vid; }

void fake_render_context_ready(void *ctx, int ready_) {
  background(ctx)->render_ready = ready_;
  if (!ready_) background(ctx)->video_selected = 0;
}
int fake_video_selected(void *ctx) { return background(ctx)->video_selected; }
int fake_early_video_enables(void *ctx) { return background(ctx)->early_video_enables; }

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>

struct retro_system_info {
  const char *library_name;
  const char *library_version;
  const char *valid_extensions;
  bool need_fullpath;
  bool block_extract;
};

static void dummy_video_refresh(const void *, unsigned, unsigned, size_t) {}
static void dummy_audio_sample(int16_t, int16_t) {}
static size_t dummy_audio_sample_batch(const int16_t *, size_t frames) { return frames; }
static void dummy_input_poll() {}
static int16_t dummy_input_state(unsigned, unsigned, unsigned, unsigned) { return 0; }

static bool env_cb(unsigned cmd, void *data) {
  unsigned base = cmd & 0xFFFF;
  if (base == 3 && data) { *(bool *)data = true; return true; }
  if (base == 17 && data) { *(bool *)data = false; return true; }
  if (base == 9 || base == 31) {
    const char **p = (const char **)data;
    if (p) *p = "/tmp";
    return true;
  }
  if (base == 10 || base == 16 || base == 18 || base == 34 || base == 35 ||
      base == 51 || base == 53 || base == 54 || base == 67 || base == 68 ||
      base == 55 || base == 69 || base == 8 || base == 11)
    return true;
  if (base == 52 && data) { *(unsigned *)data = 2; return true; }
  if (base == 39 && data) { *(unsigned *)data = 0; return true; }
  return false;
}

int main(int argc, char **argv) {
  if (argc < 2) return 2;
  void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!h) {
    std::fprintf(stderr, "dlopen failed: %s\n", dlerror());
    return 1;
  }
  auto api_ver = (unsigned (*)())dlsym(h, "retro_api_version");
  auto set_env = (void (*)(bool (*)(unsigned, void *)))dlsym(h, "retro_set_environment");
  auto set_video = (void (*)(void (*)(const void *, unsigned, unsigned, size_t)))dlsym(h, "retro_set_video_refresh");
  auto set_audio = (void (*)(void (*)(int16_t, int16_t)))dlsym(h, "retro_set_audio_sample");
  auto set_audio_batch = (void (*)(size_t (*)(const int16_t *, size_t)))dlsym(h, "retro_set_audio_sample_batch");
  auto set_input_poll = (void (*)(void (*)()))dlsym(h, "retro_set_input_poll");
  auto set_input_state = (void (*)(int16_t (*)(unsigned, unsigned, unsigned, unsigned)))dlsym(h, "retro_set_input_state");
  auto get_info = (void (*)(retro_system_info *))dlsym(h, "retro_get_system_info");
  auto init = (void (*)())dlsym(h, "retro_init");
  auto deinit = (void (*)())dlsym(h, "retro_deinit");
  auto load_game = dlsym(h, "retro_load_game");
  auto run = dlsym(h, "retro_run");
  if (!api_ver || !set_env || !get_info || !init || !deinit || !load_game || !run) {
    std::fprintf(stderr, "missing required libretro symbols in %s\n", argv[1]);
    dlclose(h);
    return 1;
  }
  unsigned v = api_ver();
  if (v != 1) {
    std::fprintf(stderr, "unexpected retro_api_version=%u\n", v);
    dlclose(h);
    return 1;
  }
  set_env(env_cb);
  if (set_video) set_video(dummy_video_refresh);
  if (set_audio) set_audio(dummy_audio_sample);
  if (set_audio_batch) set_audio_batch(dummy_audio_sample_batch);
  if (set_input_poll) set_input_poll(dummy_input_poll);
  if (set_input_state) set_input_state(dummy_input_state);
  retro_system_info info{};
  get_info(&info);
  init();
  deinit();
  std::printf("OK: %s %s (ext=%s)\n",
              info.library_name ? info.library_name : "?",
              info.library_version ? info.library_version : "?",
              info.valid_extensions ? info.valid_extensions : "");
  dlclose(h);
  return 0;
}

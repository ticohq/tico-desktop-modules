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

static bool env_cb(unsigned cmd, void *data) {
  unsigned base = cmd & 0xFFFF;
  if (base == 9 || base == 31) {
    const char **p = (const char **)data;
    if (p) *p = "/tmp";
    return true;
  }
  if (base == 10 || base == 16 || base == 18 || base == 34 || base == 35 ||
      base == 53 || base == 54 || base == 67 || base == 68 || base == 55 ||
      base == 69 || base == 8 || base == 11)
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

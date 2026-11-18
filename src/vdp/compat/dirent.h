/* <dirent.h> for the bare-metal VDP: newlib has none. FabGL's FileBrowser needs the names only;
   the VDP has no file system, so opendir always fails. */
#pragma once
#ifdef __cplusplus
extern "C" {
#endif

#define DT_UNKNOWN 0
#define DT_REG 8
#define DT_DIR 4

struct dirent {
    unsigned char d_type;
    char d_name[256];
};
typedef struct { int unused; } DIR;

static inline DIR *opendir(const char *name) { (void)name; return 0; }
static inline struct dirent *readdir(DIR *d) { (void)d; return 0; }
static inline int closedir(DIR *d) { (void)d; return 0; }
static inline void rewinddir(DIR *d) { (void)d; }
static inline void seekdir(DIR *d, long l) { (void)d; (void)l; }
static inline long telldir(DIR *d) { (void)d; return 0; }

#ifdef __cplusplus
}
#endif

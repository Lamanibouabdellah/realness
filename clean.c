/* spec: PAT:1.0 | fonctionnel: PAF:1.0 */
#include "clean.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <unistd.h>
#include <sys/stat.h>

static const char *PRESERVE[] = { ".git", ".gitignore" };
static const int PRESERVE_COUNT = 2;

static int is_preserved(const char *name) {
    for (int i = 0; i < PRESERVE_COUNT; i++) {
        if (strcmp(name, PRESERVE[i]) == 0) return 1;
    }
    return 0;
}

static int remove_dir(const char *path);

static int remove_file(const char *path) {
    struct stat st;
    if (lstat(path, &st) != 0) return -1;
    if (S_ISDIR(st.st_mode)) return remove_dir(path);
    return unlink(path);
}

static int remove_dir(const char *path) {
    DIR *dir = opendir(path);
    if (!dir) return -1;
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0)
            continue;
        char full[4096];
        snprintf(full, sizeof(full), "%s/%s", path, entry->d_name);
        if (remove_file(full) != 0) {
            fprintf(stderr, "rm: %s\n", full);
        }
    }
    closedir(dir);
    return rmdir(path);
}

int clean(const char *target) {
    DIR *dir = opendir(target);
    if (!dir) { perror("opendir"); return 1; }
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0)
            continue;
        if (is_preserved(entry->d_name)) continue;
        char full[4096];
        snprintf(full, sizeof(full), "%s/%s", target, entry->d_name);
        if (remove_file(full) != 0) {
            fprintf(stderr, "rm: %s\n", full);
        }
    }
    closedir(dir);
    return 0;
}

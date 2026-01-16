#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <dlfcn.h>
#include <unistd.h>

#include "defines.h"
#include "api.h"
#include "utils.h"
#include "manual.h"

// External variables
extern SDL_Surface* screen;
extern int quit;
void Menu_beforeSleep();
void Menu_afterSleep();

static void* plugin_handle = NULL;
static void (*plugin_run)(const ManualHostAPI*, const char*) = NULL;

static int plugin_loaded = 0;
static int plugin_available = -1; // -1: uncheck, 0: no, 1: yes

static void Manual_tryLoad(void) {
    if (plugin_available != -1) return;

    // Try to load the shared library
    // We expect it in lib/ relative to the binary, or in system path
    // Since we don't have rpath linking anymore (dlopen manual), we must be explicit or rely on LD_LIBRARY_PATH
    // Trying absolute path relative to typical install: /mnt/SDCARD/App/lib/libmanual_plugin.so
    // Or just "libmanual_plugin.so" if LD_LIBRARY_PATH is set.

    // Check local lib folder first (preferred)
    char path[256];
    char emu_path[256];
    // This assumes minarch is running from its dir
    if (exists("./lib/libmanual_plugin.so")) {
        plugin_handle = dlopen("./lib/libmanual_plugin.so", RTLD_LAZY | RTLD_LOCAL);
    }
    else {
        // Fallback to searching LD_LIBRARY_PATH
        plugin_handle = dlopen("libmanual_plugin.so", RTLD_LAZY | RTLD_LOCAL);
    }

    if (plugin_handle) {
        plugin_run = dlsym(plugin_handle, "Manual_Run_Impl");
        if (plugin_run) {
            plugin_available = 1;
            plugin_loaded = 1;
            LOG_info("Manual plugin loaded successfully\n");
        } else {
            LOG_error("Manual plugin symbol not found: %s\n", dlerror());
            dlclose(plugin_handle);
            plugin_handle = NULL;
            plugin_available = 0;
        }
    } else {
        // LOG_info("Manual plugin not found: %s\n", dlerror()); // Optional log
        plugin_available = 0;
    }
}

int Manual_isAvailable(void) {
    Manual_tryLoad();
    return plugin_available;
}

void Manual_open(char* rom_path) {
    if (!Manual_isAvailable()) return;

    // Find PDF path (Logic preserved from original manual.c)
    char manual_dir[MAX_PATH];
    char* tmp = strrchr(rom_path, '/');
    if (!tmp) return;

    int len = tmp - rom_path;
    strncpy(manual_dir, rom_path, len);
    manual_dir[len] = '\0';

    char preferred_dir[MAX_PATH];
    snprintf(preferred_dir, sizeof(preferred_dir), "%s/.media/manuals", manual_dir);
    char legacy_dir[MAX_PATH];
    snprintf(legacy_dir, sizeof(legacy_dir), "%s/manuals", manual_dir);

    char* target_dir = NULL;
    if (exists(preferred_dir)) target_dir = preferred_dir;
    else if (exists(legacy_dir)) target_dir = legacy_dir;
    else return;

    DIR *d = opendir(target_dir);
    if (!d) return;

    char *pdf_files[64];
    int count = 0;
    struct dirent *dir;
    while ((dir = readdir(d)) != NULL) {
        if (dir->d_type == DT_REG && suffixMatch(".pdf", dir->d_name)) {
             pdf_files[count++] = strdup(dir->d_name);
             if (count >= 64) break;
        }
    }
    closedir(d);

    if (count == 0) return;

    char rom_name[MAX_PATH];
    getDisplayName(rom_path, rom_name);

    char best_match[MAX_PATH] = {0};
    int found_match = 0;

    for (int i=0; i<count; i++) {
        char manual_name[MAX_PATH];
        getDisplayName(pdf_files[i], manual_name);
        if (strcasecmp(rom_name, manual_name) == 0) {
            snprintf(best_match, sizeof(best_match), "%s/%s", target_dir, pdf_files[i]);
            found_match = 1;
            break;
        }
    }

    if (!found_match && count > 0) {
        snprintf(best_match, sizeof(best_match), "%s/%s", target_dir, pdf_files[0]);
        found_match = 1;
    }

    // Cleanup filenames
    for (int i=0; i<count; i++) free(pdf_files[i]);

    if (found_match) {
        // Populate Host API
        ManualHostAPI host;
        host.screen = screen;
        host.quit = &quit;
        host.PAD_poll = PAD_poll;
        host.PAD_justPressed = PAD_justPressed;
        host.PAD_isPressed = PAD_isPressed;
        host.PAD_reset = PAD_reset;
        host.GFX_startFrame = GFX_startFrame;
        host.GFX_flip = GFX_flip;
        host.GFX_delay = GFX_delay;
        host.PWR_update = PWR_update;
        host.Menu_beforeSleep = Menu_beforeSleep;
        host.Menu_afterSleep = Menu_afterSleep;
        host.LOG_error = (void(*)(const char*,...))LOG_note; // minarch uses LOG_note for general logging

        // Run Plugin
        plugin_run(&host, best_match);
    }
}

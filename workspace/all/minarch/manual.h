#ifndef __MANUAL_H__
#define __MANUAL_H__

#include <SDL2/SDL.h>

// Function pointers for the host API
typedef struct {
    SDL_Surface* screen;
    int* quit;

    // PAD
    void (*PAD_poll)(void);
    int (*PAD_justPressed)(int btn);
    int (*PAD_isPressed)(int btn);
    void (*PAD_reset)(void);

    // GFX
    void (*GFX_startFrame)(void);
    void (*GFX_flip)(SDL_Surface* screen);
    void (*GFX_delay)(void);

    // PWR
    void (*PWR_update)(int* dirty, int* show_setting, void (*beforeSleep)(void), void (*afterSleep)(void));

    // Menu callbacks
    void (*Menu_beforeSleep)(void);
    void (*Menu_afterSleep)(void);

    // Logging
    void (*LOG_error)(const char* fmt, ...);

} ManualHostAPI;

// Interface
void Manual_open(char* rom_path);
int Manual_isAvailable(void);

#endif

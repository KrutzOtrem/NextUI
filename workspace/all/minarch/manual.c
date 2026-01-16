#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>
#include <ctype.h>
#include <SDL2/SDL.h>

#include "defines.h"
#include "api.h"
#include "utils.h"
#include "manual.h"

#ifdef ENABLE_PDF_MANUAL
#include <mupdf/fitz.h>

// External variables from minarch.c
extern SDL_Surface* screen;
extern int quit;
void Menu_beforeSleep();
void Menu_afterSleep();

typedef struct {
    fz_context *ctx;
    fz_document *doc;
    int page_count;
    int current_page;
    float scale;
    float x_offset;
    float y_offset;
    int rotation;
} ManualState;

static ManualState manual = {0};

static void Manual_render(void) {
    if (!manual.doc || !manual.ctx) return;

    fz_page *page = NULL;
    fz_pixmap *pix = NULL;
    fz_matrix ctm;

    // Load page
    fz_try(manual.ctx) {
        page = fz_load_page(manual.ctx, manual.doc, manual.current_page);
    } fz_catch(manual.ctx) {
        LOG_error("Failed to load page %d\n", manual.current_page);
        return;
    }

    // Calculate dimensions
    fz_rect bounds = fz_bound_page(manual.ctx, page);
    float width = bounds.x1 - bounds.x0;
    float height = bounds.y1 - bounds.y0;

    // Initial Auto-fit width if scale is 0
    if (manual.scale == 0) {
        manual.scale = (float)screen->w / width;
    }

    // Set up transform
    ctm = fz_scale(manual.scale, manual.scale);
    // Apply rotation if needed (not implemented in controls yet but good to have)
    // fz_rotate(&ctm, manual.rotation);

    int scaled_w = (int)(width * manual.scale);
    int scaled_h = (int)(height * manual.scale);

    // Render to pixmap
    fz_try(manual.ctx) {
        pix = fz_new_pixmap_from_page(manual.ctx, page, ctm, fz_device_rgb(manual.ctx), 0);
    } fz_catch(manual.ctx) {
        LOG_error("Failed to render page\n");
        fz_drop_page(manual.ctx, page);
        return;
    }

    // Clear screen first
    SDL_FillRect(screen, NULL, SDL_MapRGB(screen->format, 20, 20, 20));

    // Calculate blit positions
    SDL_Rect src_rect, dst_rect;

    // Center horizontally if smaller than screen
    dst_rect.x = (screen->w - scaled_w) / 2;
    if (dst_rect.x < 0) dst_rect.x = 0;

    // Vertical scroll position
    dst_rect.y = (int)manual.y_offset;

    // Source logic for panning
    src_rect.x = 0;
    src_rect.y = 0;
    src_rect.w = scaled_w;
    src_rect.h = scaled_h;

    // Horizontal panning (if scaled width > screen width)
    if (scaled_w > screen->w) {
        src_rect.x = (int)manual.x_offset;
        if (src_rect.x < 0) src_rect.x = 0;
        if (src_rect.x > scaled_w - screen->w) src_rect.x = scaled_w - screen->w;
        dst_rect.x = 0;
        src_rect.w = screen->w;
    }

    // Vertical panning/scrolling
    // Since we render the whole page to a pixmap (which can be large), we just use SDL blit to clip.
    // However, for very large pages, rendering the whole thing might be slow/heavy.
    // MuPDF allows rendering a specific bbox. For optimization later if needed.

    // Adjust dst_rect if it's off screen (standard SDL blit handles clipping, but we want to adjust src_rect for efficiency if we were rendering partial)
    // For now, simple blit of the whole pixmap (clipped by SDL)

    // Handle the scrolling offset:
    // If y_offset is negative (scrolled down), we draw the image higher up.
    // dst_rect.y is negative.

    // Create temporary surface from pixmap data
    // MuPDF RGB pixmaps are r,g,b (no alpha unless requested).
    // fz_device_rgb implies 3 components.
    // However, SDL usually wants 4 byte alignment or specific format.
    // We'll create a surface from the data.

    unsigned char *samples = fz_pixmap_samples(manual.ctx, pix);
    int w = fz_pixmap_width(manual.ctx, pix);
    int h = fz_pixmap_height(manual.ctx, pix);
    int stride = fz_pixmap_stride(manual.ctx, pix);

    // MuPDF provides RGB. SDL_CreateRGBSurfaceWithFormatFrom works best if we match the format.
    // We use SDL_PIXELFORMAT_RGB24.
    SDL_Surface *page_surf = SDL_CreateRGBSurfaceWithFormatFrom(samples, w, h, 24, stride, SDL_PIXELFORMAT_RGB24);

    if (page_surf) {
        SDL_BlitSurface(page_surf, &src_rect, screen, &dst_rect);
        SDL_FreeSurface(page_surf);
    }

    // Cleanup MuPDF objects
    fz_drop_pixmap(manual.ctx, pix);
    fz_drop_page(manual.ctx, page);
}

static void Manual_loop(char* pdf_path) {
    manual.ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
    if (!manual.ctx) {
        LOG_error("Failed to create MuPDF context\n");
        return;
    }

    fz_register_document_handlers(manual.ctx);

    fz_try(manual.ctx) {
        manual.doc = fz_open_document(manual.ctx, pdf_path);
    } fz_catch(manual.ctx) {
        LOG_error("Failed to open PDF: %s\n", pdf_path);
        fz_drop_context(manual.ctx);
        manual.ctx = NULL;
        return;
    }

    fz_try(manual.ctx) {
        manual.page_count = fz_count_pages(manual.ctx, manual.doc);
    } fz_catch(manual.ctx) {
        manual.page_count = 0;
    }

    manual.current_page = 0;
    manual.scale = 0; // Trigger auto-fit
    manual.x_offset = 0;
    manual.y_offset = 0;

    int show_manual = 1;
    int dirty = 1;

    PAD_reset();

    while (show_manual && !quit) {
        GFX_startFrame();
        PAD_poll();

        if (PAD_justPressed(BTN_B)) {
            show_manual = 0;
        }
        else if (PAD_justPressed(BTN_RIGHT)) {
            if (manual.current_page < manual.page_count - 1) {
                manual.current_page++;
                manual.y_offset = 0;
                manual.x_offset = 0;
                // manual.scale = 0; // Reset scale on page turn? Maybe keep it.
                dirty = 1;
            }
        }
        else if (PAD_justPressed(BTN_LEFT)) {
            if (manual.current_page > 0) {
                manual.current_page--;
                manual.y_offset = 0;
                manual.x_offset = 0;
                dirty = 1;
            }
        }
        else if (PAD_isPressed(BTN_DOWN)) {
             manual.y_offset -= 20; // Scroll speed
             dirty = 1;
        }
        else if (PAD_isPressed(BTN_UP)) {
             manual.y_offset += 20;
             if (manual.y_offset > 0) manual.y_offset = 0;
             dirty = 1;
        }
        else if (PAD_isPressed(BTN_R1)) { // Zoom in
            if (manual.scale < 5.0) {
                manual.scale *= 1.05;
                dirty = 1;
            }
        }
        else if (PAD_isPressed(BTN_L1)) { // Zoom out
            if (manual.scale > 0.1) {
                manual.scale /= 1.05;
                dirty = 1;
            }
        }

        // Handle panning X if zoomed in
        if (PAD_isPressed(BTN_R2)) { // Pan Right
             manual.x_offset += 20;
             dirty = 1;
        }
        if (PAD_isPressed(BTN_L2)) { // Pan Left
             manual.x_offset -= 20;
             if (manual.x_offset < 0) manual.x_offset = 0;
             dirty = 1;
        }

        // PWR update (handle sleep etc)
        int show_setting = 0;
        PWR_update(&dirty, &show_setting, Menu_beforeSleep, Menu_afterSleep);

        if (dirty) {
            // Draw
            Manual_render();

            // Draw page info overlay
            char info[64];
            snprintf(info, sizeof(info), "%d / %d", manual.current_page + 1, manual.page_count);
            // Assuming we can use font.small from minarch.c (extern it if needed, or just skip)
            // For now, skipping text overlay to avoid dep on minarch internals not exposed

            GFX_flip(screen);
            dirty = 0;
        } else {
             GFX_delay();
        }
    }

    fz_drop_document(manual.ctx, manual.doc);
    fz_drop_context(manual.ctx);
    manual.doc = NULL;
    manual.ctx = NULL;
}
#endif

void Manual_open(char* rom_path) {
#ifdef ENABLE_PDF_MANUAL
    char manual_dir[MAX_PATH];
    char* tmp = strrchr(rom_path, '/');
    if (!tmp) return;

    int len = tmp - rom_path;
    strncpy(manual_dir, rom_path, len);
    manual_dir[len] = '\0';

    // Check .media/manuals first (preferred)
    char preferred_dir[MAX_PATH];
    snprintf(preferred_dir, sizeof(preferred_dir), "%s/.media/manuals", manual_dir);

    // Fallback to legacy manuals dir
    char legacy_dir[MAX_PATH];
    snprintf(legacy_dir, sizeof(legacy_dir), "%s/manuals", manual_dir);

    char* target_dir = NULL;
    if (exists(preferred_dir)) target_dir = preferred_dir;
    else if (exists(legacy_dir)) target_dir = legacy_dir;
    else {
        LOG_info("No manual directory found in %s\n", manual_dir);
        return;
    }

    // List PDFs
    DIR *d;
    struct dirent *dir;
    d = opendir(target_dir);
    if (!d) return;

    char *pdf_files[64];
    int count = 0;

    while ((dir = readdir(d)) != NULL) {
        if (dir->d_type == DT_REG) {
             if (suffixMatch(".pdf", dir->d_name)) {
                 pdf_files[count] = strdup(dir->d_name);
                 count++;
                 if (count >= 64) break;
             }
        }
    }
    closedir(d);

    if (count == 0) {
        return;
    }

    // Matching
    char rom_name[MAX_PATH];
    getDisplayName(rom_path, rom_name);

    char best_match[MAX_PATH] = {0};
    int found_match = 0;

    for (int i=0; i<count; i++) {
        char manual_name[MAX_PATH];
        getDisplayName(pdf_files[i], manual_name);

        // Case-insensitive comparison
        if (strcasecmp(rom_name, manual_name) == 0) {
            snprintf(best_match, sizeof(best_match), "%s/%s", target_dir, pdf_files[i]);
            found_match = 1;
            break;
        }
    }

    if (!found_match && count > 0) {
        if (count == 1) {
             snprintf(best_match, sizeof(best_match), "%s/%s", target_dir, pdf_files[0]);
             found_match = 1;
        } else {
             // Fallback to first if multiple and no match
             snprintf(best_match, sizeof(best_match), "%s/%s", target_dir, pdf_files[0]);
             found_match = 1;
        }
    }

    if (found_match) {
        Manual_loop(best_match);
    }

    // Cleanup
    for (int i=0; i<count; i++) free(pdf_files[i]);
#else
    LOG_info("PDF Manuals not supported on this platform\n");
#endif
}

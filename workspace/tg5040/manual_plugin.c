#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <SDL2/SDL.h>
#include <mupdf/fitz.h>

// Must match manual.h in minarch
typedef struct {
    SDL_Surface* screen;
    int* quit;
    void (*PAD_poll)(void);
    int (*PAD_justPressed)(int btn);
    int (*PAD_isPressed)(int btn);
    void (*PAD_reset)(void);
    void (*GFX_startFrame)(void);
    void (*GFX_flip)(SDL_Surface* screen);
    void (*GFX_delay)(void);
    void (*PWR_update)(int* dirty, int* show_setting, void (*beforeSleep)(void), void (*afterSleep)(void));
    void (*Menu_beforeSleep)(void);
    void (*Menu_afterSleep)(void);
    void (*LOG_error)(const char* fmt, ...);
} ManualHostAPI;

// Buttons (re-defined locally to avoid dependency on defines.h if complex, but usually simple ints)
// Ideally we include defines.h if it's clean. Assuming standard mapping for now or include defines.h from source tree
#include "../all/common/defines.h"
// We might need relative path to common/defines.h

typedef struct {
    fz_context *ctx;
    fz_document *doc;
    int page_count;
    int current_page;
    float scale;
    float x_offset;
    float y_offset;
} ManualState;

static ManualState manual = {0};

static void Manual_render(const ManualHostAPI* host) {
    if (!manual.doc || !manual.ctx) return;

    fz_page *page = NULL;
    fz_pixmap *pix = NULL;
    fz_matrix ctm;

    fz_try(manual.ctx) {
        page = fz_load_page(manual.ctx, manual.doc, manual.current_page);
    } fz_catch(manual.ctx) {
        if(host->LOG_error) host->LOG_error("Failed to load page %d\n", manual.current_page);
        return;
    }

    fz_rect bounds = fz_bound_page(manual.ctx, page);
    float width = bounds.x1 - bounds.x0;
    float height = bounds.y1 - bounds.y0;

    // Auto-fit HEIGHT
    if (manual.scale == 0) {
        manual.scale = (float)host->screen->h / height;
    }

    ctm = fz_scale(manual.scale, manual.scale);

    int scaled_w = (int)(width * manual.scale);
    int scaled_h = (int)(height * manual.scale);

    fz_try(manual.ctx) {
        pix = fz_new_pixmap_from_page(manual.ctx, page, ctm, fz_device_rgb(manual.ctx), 0);
    } fz_catch(manual.ctx) {
        if(host->LOG_error) host->LOG_error("Failed to render page\n");
        fz_drop_page(manual.ctx, page);
        return;
    }

    SDL_FillRect(host->screen, NULL, SDL_MapRGB(host->screen->format, 20, 20, 20));

    SDL_Rect src_rect, dst_rect;

    dst_rect.y = (host->screen->h - scaled_h) / 2;
    dst_rect.y += (int)manual.y_offset;

    dst_rect.x = (host->screen->w - scaled_w) / 2;
    if (scaled_w > host->screen->w) {
        dst_rect.x = 0 - (int)manual.x_offset;
    }

    src_rect.x = 0;
    src_rect.y = 0;
    src_rect.w = scaled_w;
    src_rect.h = scaled_h;

    if (dst_rect.x < 0) {
        src_rect.x = -dst_rect.x;
        dst_rect.x = 0;
        if (src_rect.x > scaled_w - host->screen->w) src_rect.x = scaled_w - host->screen->w;
        src_rect.w = host->screen->w;
    }
    if (dst_rect.y < 0) {
        src_rect.y = -dst_rect.y;
        dst_rect.y = 0;
        if (src_rect.y > scaled_h - host->screen->h) src_rect.y = scaled_h - host->screen->h;
        src_rect.h = host->screen->h;
    }

    unsigned char *samples = fz_pixmap_samples(manual.ctx, pix);
    int w = fz_pixmap_width(manual.ctx, pix);
    int h = fz_pixmap_height(manual.ctx, pix);
    int stride = fz_pixmap_stride(manual.ctx, pix);

    SDL_Surface *page_surf = SDL_CreateRGBSurfaceWithFormatFrom(samples, w, h, 24, stride, SDL_PIXELFORMAT_RGB24);

    if (page_surf) {
        SDL_BlitSurface(page_surf, &src_rect, host->screen, &dst_rect);
        SDL_FreeSurface(page_surf);
    }

    fz_drop_pixmap(manual.ctx, pix);
    fz_drop_page(manual.ctx, page);
}

// Exported function
void Manual_Run_Impl(const ManualHostAPI* host, const char* pdf_path) {
    if (!host) return;

    manual.ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
    if (!manual.ctx) return;

    fz_register_document_handlers(manual.ctx);

    fz_try(manual.ctx) {
        manual.doc = fz_open_document(manual.ctx, pdf_path);
    } fz_catch(manual.ctx) {
        if(host->LOG_error) host->LOG_error("Failed to open PDF: %s\n", pdf_path);
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
    manual.scale = 0;
    manual.x_offset = 0;
    manual.y_offset = 0;

    int show_manual = 1;
    int dirty = 1;

    host->PAD_reset();

    while (show_manual && !(*host->quit)) {
        host->GFX_startFrame();
        host->PAD_poll();

        if (host->PAD_justPressed(BTN_B)) {
            show_manual = 0;
        }
        else if (host->PAD_justPressed(BTN_RIGHT)) {
            // Smart Nav Logic
            fz_page *p = fz_load_page(manual.ctx, manual.doc, manual.current_page);
            fz_rect b = fz_bound_page(manual.ctx, p);
            float w = (b.x1 - b.x0) * manual.scale;
            fz_drop_page(manual.ctx, p);

            if (w > host->screen->w && manual.x_offset + host->screen->w < w) {
                manual.x_offset += host->screen->w * 0.9;
                if (manual.x_offset > w - host->screen->w) manual.x_offset = w - host->screen->w;
                dirty = 1;
            } else {
                if (manual.current_page < manual.page_count - 1) {
                    manual.current_page++;
                    manual.x_offset = 0;
                    manual.y_offset = 0;
                    dirty = 1;
                }
            }
        }
        else if (host->PAD_justPressed(BTN_LEFT)) {
            if (manual.x_offset > 0) {
                manual.x_offset -= host->screen->w * 0.9;
                if (manual.x_offset < 0) manual.x_offset = 0;
                dirty = 1;
            } else {
                if (manual.current_page > 0) {
                    manual.current_page--;
                    fz_page *p = fz_load_page(manual.ctx, manual.doc, manual.current_page);
                    fz_rect b = fz_bound_page(manual.ctx, p);
                    float w = (b.x1 - b.x0) * manual.scale;
                    fz_drop_page(manual.ctx, p);

                    if (w > host->screen->w) manual.x_offset = w - host->screen->w;
                    else manual.x_offset = 0;

                    manual.y_offset = 0;
                    dirty = 1;
                }
            }
        }
        else if (host->PAD_isPressed(BTN_DOWN)) {
             manual.y_offset -= 20;
             dirty = 1;
        }
        else if (host->PAD_isPressed(BTN_UP)) {
             manual.y_offset += 20;
             if (manual.y_offset > 0) manual.y_offset = 0;
             dirty = 1;
        }
        else if (host->PAD_isPressed(BTN_R1)) {
            if (manual.scale < 5.0) {
                manual.scale *= 1.05;
                dirty = 1;
            }
        }
        else if (host->PAD_isPressed(BTN_L1)) {
            if (manual.scale > 0.1) {
                manual.scale /= 1.05;
                dirty = 1;
            }
        }

        if (host->PAD_isPressed(BTN_R2)) {
             manual.x_offset += 20;
             dirty = 1;
        }
        if (host->PAD_isPressed(BTN_L2)) {
             manual.x_offset -= 20;
             if (manual.x_offset < 0) manual.x_offset = 0;
             dirty = 1;
        }

        int show_setting = 0;
        host->PWR_update(&dirty, &show_setting, host->Menu_beforeSleep, host->Menu_afterSleep);

        if (dirty) {
            Manual_render(host);
            host->GFX_flip(host->screen);
            dirty = 0;
        } else {
             host->GFX_delay();
        }
    }

    fz_drop_document(manual.ctx, manual.doc);
    fz_drop_context(manual.ctx);
}

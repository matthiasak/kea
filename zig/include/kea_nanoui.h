#ifndef KEA_NANOUI_H
#define KEA_NANOUI_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct KeaChrome KeaChrome;

typedef struct {
    uint64_t id;
    const char *title;
    const char *url;
    bool loading;
    bool pinned;
    bool muted;
} KeaTabItem;

typedef struct {
    bool sidebar;
    bool side_on_right;
    float side_width;
    bool chat_open;
    float chat_width;
    bool marks_open;
    float marks_width;
    bool split_active;
    float split_fraction;
    uint64_t active_tab_id;
    const char *address_text;
    const KeaTabItem *tabs;
    size_t tab_count;
} KeaChromeSnapshot;

typedef struct {
    void *userdata;
    void (*on_select_tab)(void *userdata, uint64_t tab_id);
    void (*on_close_tab)(void *userdata, uint64_t tab_id);
    void (*on_new_tab)(void *userdata);
    void (*on_navigate)(void *userdata, const char *input);
    void (*on_resize_panel)(void *userdata, int panel_kind, float width);
} KeaChromeCallbacks;

KeaChrome *kea_chrome_create(void *nswindow, const KeaChromeCallbacks *callbacks);
void kea_chrome_destroy(KeaChrome *chrome);
void kea_chrome_set_state(KeaChrome *chrome, const KeaChromeSnapshot *snapshot);
void kea_chrome_request_frame(KeaChrome *chrome);
void kea_chrome_announce(KeaChrome *chrome, const char *message);
void *kea_chrome_stage_view(KeaChrome *chrome);

#ifdef __cplusplus
}
#endif

#endif /* KEA_NANOUI_H */

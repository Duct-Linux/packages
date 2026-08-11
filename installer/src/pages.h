#pragma once

#include "window.h"

G_BEGIN_DECLS

AdwNavigationPage *duct_page_welcome_new  (DuctWindow *win);
AdwNavigationPage *duct_page_language_new (DuctWindow *win);
AdwNavigationPage *duct_page_keyboard_new (DuctWindow *win);
AdwNavigationPage *duct_page_disk_new     (DuctWindow *win);
AdwNavigationPage *duct_page_timezone_new (DuctWindow *win);
AdwNavigationPage *duct_page_user_new     (DuctWindow *win);
AdwNavigationPage *duct_page_summary_new  (DuctWindow *win);
AdwNavigationPage *duct_page_progress_new (DuctWindow *win);
AdwNavigationPage *duct_page_done_new     (DuctWindow *win);

/* The scaffold every screen shares: a header bar, a scrolling clamped body,
 * and an optional action button along the bottom.
 *
 * `out_body` receives a GtkBox to pack content into; `out_action` receives the
 * bottom-right button, or NULL if action_label was NULL. Keeping this in one
 * place is what stops the nine screens drifting apart. */
AdwNavigationPage *duct_page_scaffold (const char  *title,
                                       const char  *tag,
                                       const char  *action_label,
                                       GtkWidget  **out_body,
                                       GtkWidget  **out_action);

/* A heading and a paragraph, the top of most screens. */
GtkWidget *duct_page_heading (const char *title, const char *subtitle);

G_END_DECLS

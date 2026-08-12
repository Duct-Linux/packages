#pragma once

#include <adwaita.h>

#include "backend/backend.h"

G_BEGIN_DECLS

#define DUCT_TYPE_WINDOW (duct_window_get_type ())
G_DECLARE_FINAL_TYPE (DuctWindow, duct_window, DUCT, WINDOW, AdwApplicationWindow)

/* allow_real is the --real flag. It is threaded through rather than consulted
 * globally so that the one place a destructive backend could be constructed is
 * visible in the code that constructs it. Today it changes nothing: the real
 * backend refuses to exist. */
DuctWindow *duct_window_new (AdwApplication *app, gboolean allow_real);

/* The screens, in order. */
typedef enum {
	DUCT_PAGE_WELCOME,
	DUCT_PAGE_LANGUAGE,
	DUCT_PAGE_KEYBOARD,
	DUCT_PAGE_DISK,
	DUCT_PAGE_TIMEZONE,
	DUCT_PAGE_USER,
	DUCT_PAGE_SUMMARY,
	DUCT_PAGE_PROGRESS,
	DUCT_PAGE_DONE,
	DUCT_N_PAGES
} DuctPageId;

/* What the pages need from the window. */
DuctInstallConfig *duct_window_config      (DuctWindow *self);
DuctPartitionPlan *duct_window_plan        (DuctWindow *self);
void               duct_window_set_plan    (DuctWindow *self, DuctPartitionPlan *plan);
const DuctDisk    *duct_window_disk        (DuctWindow *self);
void               duct_window_set_disk    (DuctWindow *self, const DuctDisk *disk);
gboolean           duct_window_allow_real  (DuctWindow *self);

/* Push the next screen in the order above. */
void duct_window_next    (DuctWindow *self);

/* Walk the whole flow without a human, then quit.
 *
 * This exists because the machine that builds this cannot take a screenshot,
 * and "it links" is not evidence that nine screens construct. It picks the
 * first installable disk from the probe, pushes through every page, waits for
 * the install to run to completion, and exits non-zero if any page failed to
 * appear. Reached with --self-test. */
void duct_window_self_test (DuctWindow *self);
/* Jump back to a specific screen -- the failure page offers "start again",
 * which returns to the disk screen rather than resuming. */
void duct_window_rewind_to (DuctWindow *self, DuctPageId id);

G_END_DECLS

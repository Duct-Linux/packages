#include "window.h"
#include "pages.h"

#include <stdlib.h>

struct _DuctWindow {
	AdwApplicationWindow parent_instance;

	AdwNavigationView *nav;

	DuctInstallConfig *config;
	DuctPartitionPlan *plan;
	DuctDisk          *disk;    /* a copy: the probe list is rebuilt on revisit */

	gboolean allow_real;
	guint    current;           /* DuctPageId of the topmost page */
};

G_DEFINE_FINAL_TYPE (DuctWindow, duct_window, ADW_TYPE_APPLICATION_WINDOW)

static void
duct_window_finalize (GObject *object)
{
	DuctWindow *self = DUCT_WINDOW (object);

	g_clear_pointer (&self->config, duct_install_config_free);
	g_clear_pointer (&self->plan, duct_partition_plan_free);
	g_clear_pointer (&self->disk, duct_disk_free);

	G_OBJECT_CLASS (duct_window_parent_class)->finalize (object);
}

static void
duct_window_class_init (DuctWindowClass *klass)
{
	G_OBJECT_CLASS (klass)->finalize = duct_window_finalize;
}

static void
duct_window_init (DuctWindow *self)
{
	self->config     = duct_install_config_new ();
	self->allow_real = FALSE;
	self->current    = DUCT_PAGE_WELCOME;

	self->nav = ADW_NAVIGATION_VIEW (adw_navigation_view_new ());
	adw_application_window_set_content (ADW_APPLICATION_WINDOW (self),
	                                    GTK_WIDGET (self->nav));

	gtk_window_set_title (GTK_WINDOW (self), "Install Duct");
	gtk_window_set_default_size (GTK_WINDOW (self), 900, 680);

	adw_navigation_view_push (self->nav, duct_page_welcome_new (self));
}

DuctWindow *
duct_window_new (AdwApplication *app, gboolean allow_real)
{
	DuctWindow *self = g_object_new (DUCT_TYPE_WINDOW, "application", app, NULL);

	self->allow_real = allow_real;

	return self;
}

/* --- accessors ----------------------------------------------------------- */

DuctInstallConfig *duct_window_config     (DuctWindow *self) { return self->config; }
DuctPartitionPlan *duct_window_plan       (DuctWindow *self) { return self->plan; }
const DuctDisk    *duct_window_disk       (DuctWindow *self) { return self->disk; }
gboolean           duct_window_allow_real (DuctWindow *self) { return self->allow_real; }

void
duct_window_set_plan (DuctWindow *self, DuctPartitionPlan *plan)
{
	g_clear_pointer (&self->plan, duct_partition_plan_free);
	self->plan = plan;
}

void
duct_window_set_disk (DuctWindow *self, const DuctDisk *disk)
{
	g_clear_pointer (&self->disk, duct_disk_free);

	if (disk == NULL)
		return;

	/* Copied rather than referenced. The disk screen rebuilds its probe list
	 * every time it is shown, which frees the array the caller's pointer came
	 * from -- and a dangling pointer to the disk we are about to erase is not
	 * a bug anyone wants to find the hard way. */
	self->disk = g_new0 (DuctDisk, 1);
	self->disk->node           = g_strdup (disk->node);
	self->disk->model          = g_strdup (disk->model);
	self->disk->serial         = g_strdup (disk->serial);
	self->disk->size           = disk->size;
	self->disk->removable      = disk->removable;
	self->disk->is_boot_medium = disk->is_boot_medium;

	g_free (self->config->disk);
	self->config->disk = g_strdup (disk->node);
}

/* --- navigation ---------------------------------------------------------- */

static AdwNavigationPage *
page_new (DuctWindow *self, DuctPageId id)
{
	switch (id) {
	case DUCT_PAGE_WELCOME:  return duct_page_welcome_new (self);
	case DUCT_PAGE_LANGUAGE: return duct_page_language_new (self);
	case DUCT_PAGE_KEYBOARD: return duct_page_keyboard_new (self);
	case DUCT_PAGE_DISK:     return duct_page_disk_new (self);
	case DUCT_PAGE_TIMEZONE: return duct_page_timezone_new (self);
	case DUCT_PAGE_USER:     return duct_page_user_new (self);
	case DUCT_PAGE_SUMMARY:  return duct_page_summary_new (self);
	case DUCT_PAGE_PROGRESS: return duct_page_progress_new (self);
	case DUCT_PAGE_DONE:     return duct_page_done_new (self);
	default:                 g_assert_not_reached ();
	}
}

void
duct_window_next (DuctWindow *self)
{
	g_return_if_fail (DUCT_IS_WINDOW (self));

	if (self->current + 1 >= DUCT_N_PAGES)
		return;

	self->current++;
	adw_navigation_view_push (self->nav, page_new (self, self->current));
}

void
duct_window_rewind_to (DuctWindow *self, DuctPageId id)
{
	g_return_if_fail (DUCT_IS_WINDOW (self));

	/* Replace the whole stack rather than popping to a tag. After a failed
	 * install the pages behind us describe a machine that no longer exists --
	 * the disk list in particular -- so they are rebuilt, not revisited. */
	g_autoptr (GPtrArray) stack = g_ptr_array_new ();

	self->current = id;
	for (guint i = 0; i <= id; i++)
		g_ptr_array_add (stack, page_new (self, i));

	adw_navigation_view_replace (self->nav,
	                             (AdwNavigationPage **) stack->pdata,
	                             (int) stack->len);
}

/* --- the self test -------------------------------------------------------- */

/* Everything the walk needs to know about where it has got to. */
typedef struct {
	DuctWindow *win;
	guint       seen;      /* bitmask of DuctPageId that became visible */
	guint       ticks;
} SelfTest;

static const char *page_tags[DUCT_N_PAGES] = {
	"welcome", "language", "keyboard", "disk",
	"timezone", "user", "summary", "progress", "done"
};

static gboolean
self_test_tick (gpointer data)
{
	SelfTest *test = data;
	DuctWindow *self = test->win;

	AdwNavigationPage *visible = adw_navigation_view_get_visible_page (self->nav);
	const char *tag = visible != NULL ? adw_navigation_page_get_tag (visible) : NULL;

	for (guint i = 0; i < DUCT_N_PAGES; i++) {
		if (g_strcmp0 (tag, page_tags[i]) == 0) {
			if ((test->seen & (1u << i)) == 0)
				g_print ("  reached %s\n", page_tags[i]);
			test->seen |= (1u << i);
		}
	}

	/* The done page is pushed by the progress page itself when the run
	 * finishes, so the walk stops driving once it has asked for the install
	 * and simply waits for the result. */
	if (g_strcmp0 (tag, "done") == 0) {
		guint expected = (1u << DUCT_N_PAGES) - 1;

		if (test->seen == expected) {
			g_print ("self-test: all %d screens constructed and the install ran\n",
			         DUCT_N_PAGES);
			g_application_quit (G_APPLICATION (
				gtk_window_get_application (GTK_WINDOW (self))));
		} else {
			g_printerr ("self-test: finished having missed a screen (mask %u)\n", test->seen);
			exit (1);
		}
		g_free (test);
		return G_SOURCE_REMOVE;
	}

	if (g_strcmp0 (tag, "progress") != 0)
		duct_window_next (self);

	/* 40 seconds. The dry run sleeps between steps on purpose, so this is
	 * generous rather than tight; a hang should still fail rather than sit
	 * there until someone notices. */
	if (++test->ticks > 200) {
		g_printerr ("self-test: timed out at \"%s\" (mask %u)\n",
		            tag ? tag : "(none)", test->seen);
		exit (1);
	}

	return G_SOURCE_CONTINUE;
}

void
duct_window_self_test (DuctWindow *self)
{
	g_return_if_fail (DUCT_IS_WINDOW (self));

	/* The disk screen normally supplies these when the user picks a disk.
	 * Choosing here rather than driving the radio buttons keeps the walk
	 * independent of how that screen is laid out -- and it exercises exactly
	 * the rule that matters, because it takes the first disk the probe does
	 * not flag as the live medium. */
	gboolean simulated = FALSE;
	g_autoptr (GError) error = NULL;
	g_autoptr (GPtrArray) disks = duct_disk_probe (&simulated, &error);

	if (disks == NULL) {
		g_printerr ("self-test: no disks: %s\n", error->message);
		exit (1);
	}

	for (guint i = 0; i < disks->len; i++) {
		const DuctDisk *disk = g_ptr_array_index (disks, i);

		if (disk->is_boot_medium)
			continue;

		DuctPartitionPlan *plan = duct_partition_plan (disk, &error);
		if (plan == NULL)
			continue;

		duct_window_set_disk (self, disk);
		duct_window_set_plan (self, plan);
		break;
	}

	if (duct_window_plan (self) == NULL) {
		g_printerr ("self-test: no installable disk\n");
		exit (1);
	}

	/* The account screen's fields, which the summary reads back. */
	DuctInstallConfig *cfg = duct_window_config (self);
	cfg->username = g_strdup ("tester");
	cfg->password = g_strdup ("hunter2hunter2");

	SelfTest *test = g_new0 (SelfTest, 1);
	test->win = self;

	g_timeout_add (200, self_test_tick, test);
}

/* --- shared page furniture ----------------------------------------------- */

GtkWidget *
duct_page_heading (const char *title, const char *subtitle)
{
	GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 6);
	gtk_widget_set_margin_bottom (box, 12);

	GtkWidget *label = gtk_label_new (title);
	gtk_label_set_xalign (GTK_LABEL (label), 0.0);
	gtk_label_set_wrap (GTK_LABEL (label), TRUE);
	gtk_widget_add_css_class (label, "title-1");
	gtk_box_append (GTK_BOX (box), label);

	if (subtitle != NULL) {
		GtkWidget *sub = gtk_label_new (subtitle);
		gtk_label_set_xalign (GTK_LABEL (sub), 0.0);
		gtk_label_set_wrap (GTK_LABEL (sub), TRUE);
		gtk_widget_add_css_class (sub, "dim-label");
		gtk_box_append (GTK_BOX (box), sub);
	}

	return box;
}

AdwNavigationPage *
duct_page_scaffold (const char  *title,
                    const char  *tag,
                    const char  *action_label,
                    GtkWidget  **out_body,
                    GtkWidget  **out_action)
{
	GtkWidget *toolbar = adw_toolbar_view_new ();
	adw_toolbar_view_add_top_bar (ADW_TOOLBAR_VIEW (toolbar), adw_header_bar_new ());

	GtkWidget *body = gtk_box_new (GTK_ORIENTATION_VERTICAL, 18);
	gtk_widget_set_margin_top (body, 24);
	gtk_widget_set_margin_bottom (body, 24);
	gtk_widget_set_margin_start (body, 12);
	gtk_widget_set_margin_end (body, 12);

	GtkWidget *clamp = adw_clamp_new ();
	adw_clamp_set_maximum_size (ADW_CLAMP (clamp), 640);
	adw_clamp_set_child (ADW_CLAMP (clamp), body);

	GtkWidget *scroller = gtk_scrolled_window_new ();
	gtk_scrolled_window_set_policy (GTK_SCROLLED_WINDOW (scroller),
	                                GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
	gtk_widget_set_vexpand (scroller, TRUE);
	gtk_scrolled_window_set_child (GTK_SCROLLED_WINDOW (scroller), clamp);

	adw_toolbar_view_set_content (ADW_TOOLBAR_VIEW (toolbar), scroller);

	if (action_label != NULL) {
		GtkWidget *bar = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6);
		gtk_widget_set_margin_top (bar, 12);
		gtk_widget_set_margin_bottom (bar, 12);
		gtk_widget_set_margin_start (bar, 12);
		gtk_widget_set_margin_end (bar, 12);
		gtk_widget_set_halign (bar, GTK_ALIGN_END);

		GtkWidget *button = gtk_button_new_with_label (action_label);
		gtk_widget_add_css_class (button, "suggested-action");
		gtk_widget_add_css_class (button, "pill");
		gtk_box_append (GTK_BOX (bar), button);

		adw_toolbar_view_add_bottom_bar (ADW_TOOLBAR_VIEW (toolbar), bar);

		if (out_action != NULL)
			*out_action = button;
	} else if (out_action != NULL) {
		*out_action = NULL;
	}

	if (out_body != NULL)
		*out_body = body;

	AdwNavigationPage *page = adw_navigation_page_new (toolbar, title);
	adw_navigation_page_set_tag (page, tag);

	return page;
}

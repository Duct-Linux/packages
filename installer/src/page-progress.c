/* The progress screen, and the failure screen -- they are the same screen,
 * because a failure is a state the progress screen ends in rather than a
 * different place the user is sent to.
 *
 * Threading rule, and it is the only one that matters here: the backend runs
 * on a worker thread and never touches GTK. Progress and log lines are copied
 * into a small struct and handed to the main loop with g_idle_add. Every
 * widget call below happens on the main thread.
 */

#include "pages.h"

#include <string.h>

typedef struct {
	DuctWindow *win;

	GtkWidget *bar;
	GtkWidget *stage_label;
	GtkWidget *detail_label;
	GtkWidget *log_view;
	GtkTextBuffer *log_buffer;
	GtkWidget *expander;

	/* Swapped in when the install ends, either way. */
	GtkWidget *stack;
	GtkWidget *result_page;
	GtkWidget *body;

	DuctBackend *backend;

	/* Written by the worker, read by the main loop. Only ever set once, before
	 * the completion idle is queued, so no lock is needed for it. */
	gboolean  ok;
	GError   *error;
	DuctStage failed_stage;
	gboolean  reached_destructive;
} ProgressPage;

/* --- marshalling from the worker thread ---------------------------------- */

typedef struct {
	ProgressPage *self;
	DuctStage     stage;
	double        frac;
	char         *detail;
} ProgressEvent;

static gboolean
apply_progress (gpointer data)
{
	ProgressEvent *event = data;
	ProgressPage  *self  = event->self;

	/* The bar is the weighted total, not the stage's own fraction. A bar that
	 * reaches six sevenths and then sits still for four minutes while packages
	 * install is worse than no bar at all. */
	double total = 0.0;
	for (guint i = 0; i < event->stage; i++)
		total += duct_stage_weight ((DuctStage) i);
	total += duct_stage_weight (event->stage) * event->frac;

	gtk_progress_bar_set_fraction (GTK_PROGRESS_BAR (self->bar), total);
	gtk_label_set_text (GTK_LABEL (self->stage_label), duct_stage_title (event->stage));
	gtk_label_set_text (GTK_LABEL (self->detail_label),
	                    event->detail != NULL ? event->detail : "");

	g_free (event->detail);
	g_free (event);

	return G_SOURCE_REMOVE;
}

static void
on_progress (DuctStage stage, double frac, const char *detail, gpointer user_data)
{
	ProgressEvent *event = g_new0 (ProgressEvent, 1);

	event->self   = user_data;
	event->stage  = stage;
	event->frac   = frac;
	event->detail = g_strdup (detail);

	g_idle_add (apply_progress, event);
}

typedef struct {
	ProgressPage *self;
	char         *line;
} LogEvent;

static gboolean
apply_log (gpointer data)
{
	LogEvent      *event = data;
	ProgressPage  *self  = event->self;
	GtkTextIter    end;

	gtk_text_buffer_get_end_iter (self->log_buffer, &end);
	gtk_text_buffer_insert (self->log_buffer, &end, event->line, -1);
	gtk_text_buffer_get_end_iter (self->log_buffer, &end);
	gtk_text_buffer_insert (self->log_buffer, &end, "\n", -1);

	/* Follow the tail. Someone watching the log wants the newest line, and
	 * scrolling back is what the scrollbar is for. */
	GtkTextMark *mark = gtk_text_buffer_get_insert (self->log_buffer);
	gtk_text_buffer_place_cursor (self->log_buffer, &end);
	gtk_text_view_scroll_to_mark (GTK_TEXT_VIEW (self->log_view), mark, 0.0, TRUE, 0.0, 1.0);

	g_free (event->line);
	g_free (event);

	return G_SOURCE_REMOVE;
}

static void
on_log (const char *line, gpointer user_data)
{
	LogEvent *event = g_new0 (LogEvent, 1);

	event->self = user_data;
	event->line = g_strdup (line);

	g_idle_add (apply_log, event);
}

/* --- the end of the run --------------------------------------------------- */

static void
on_start_again (GtkButton *button, gpointer user_data)
{
	ProgressPage *self = user_data;
	(void) button;

	/* Back to the disk screen, not a resume. A half-written disk is
	 * re-partitioned from scratch; there is no state worth keeping and
	 * pretending otherwise is how a recoverable failure becomes a mess. */
	duct_window_rewind_to (self->win, DUCT_PAGE_DISK);
}

static void
on_save_log (GtkButton *button, gpointer user_data)
{
	ProgressPage *self = user_data;

	GtkTextIter start, end;
	gtk_text_buffer_get_bounds (self->log_buffer, &start, &end);
	g_autofree char *text = gtk_text_buffer_get_text (self->log_buffer, &start, &end, FALSE);

	/* The temporary directory, not the home directory.
	 *
	 * On a live system those are the same throwaway tmpfs and it makes no
	 * difference. On the development machine it is the difference between
	 * writing inside the workspace and dropping a file in someone's home, and
	 * this program has no business doing the second. */
	g_autofree char *path = g_build_filename (g_get_tmp_dir (), "duct-install.log", NULL);
	g_autoptr (GError) error = NULL;

	if (g_file_set_contents (path, text, -1, &error)) {
		g_autofree char *body = g_strdup_printf ("Saved to %s", path);
		AdwAlertDialog *dialog = ADW_ALERT_DIALOG (adw_alert_dialog_new ("Log saved", body));
		adw_alert_dialog_add_response (dialog, "ok", "OK");
		adw_dialog_present (ADW_DIALOG (dialog), GTK_WIDGET (button));
	} else {
		AdwAlertDialog *dialog =
			ADW_ALERT_DIALOG (adw_alert_dialog_new ("Could not save the log", error->message));
		adw_alert_dialog_add_response (dialog, "ok", "OK");
		adw_dialog_present (ADW_DIALOG (dialog), GTK_WIDGET (button));
	}
}

static void
show_failure (ProgressPage *self)
{
	GtkWidget *status = adw_status_page_new ();

	adw_status_page_set_icon_name (ADW_STATUS_PAGE (status), "dialog-error-symbolic");
	adw_status_page_set_title (ADW_STATUS_PAGE (status), "The installation failed");

	/* Say what state the disk is in, plainly, and do not soften it.
	 *
	 * There is no rollback and there cannot be one: the previous contents were
	 * destroyed at the partitioning step by design. The only honest thing to
	 * do is name the stage and say the disk will not boot. */
	g_autofree char *description = self->reached_destructive
		? g_strdup_printf (
			"%s failed.\n\n%s\n\nThe disk has been changed and will not boot. "
			"Its previous contents are gone and cannot be recovered. You can "
			"start again, which will erase and re-partition it from scratch.",
			duct_stage_title (self->failed_stage),
			self->error ? self->error->message : "No further detail.")
		: g_strdup_printf (
			"%s failed.\n\n%s\n\nNothing was written to any disk.",
			duct_stage_title (self->failed_stage),
			self->error ? self->error->message : "No further detail.");

	adw_status_page_set_description (ADW_STATUS_PAGE (status), description);

	GtkWidget *buttons = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 12);
	gtk_widget_set_halign (buttons, GTK_ALIGN_CENTER);

	GtkWidget *save = gtk_button_new_with_label ("Save log");
	gtk_widget_add_css_class (save, "pill");
	g_signal_connect (save, "clicked", G_CALLBACK (on_save_log), self);
	gtk_box_append (GTK_BOX (buttons), save);

	GtkWidget *again = gtk_button_new_with_label ("Start again");
	gtk_widget_add_css_class (again, "pill");
	gtk_widget_add_css_class (again, "suggested-action");
	g_signal_connect (again, "clicked", G_CALLBACK (on_start_again), self);
	gtk_box_append (GTK_BOX (buttons), again);

	adw_status_page_set_child (ADW_STATUS_PAGE (status), buttons);

	/* Above the log, which stays expanded: after a failure the log is the
	 * thing worth reading, not a detail to go hunting for. */
	gtk_box_prepend (GTK_BOX (self->body), status);
	gtk_widget_set_visible (self->bar, FALSE);
	gtk_widget_set_visible (self->stage_label, FALSE);
	gtk_widget_set_visible (self->detail_label, FALSE);
	adw_expander_row_set_expanded (ADW_EXPANDER_ROW (self->expander), TRUE);
}

static gboolean
on_finished (gpointer data)
{
	ProgressPage *self = data;

	if (self->ok)
		duct_window_next (self->win);
	else
		show_failure (self);

	return G_SOURCE_REMOVE;
}

static gpointer
worker (gpointer data)
{
	ProgressPage *self = data;

	const DuctInstallConfig *cfg  = duct_window_config (self->win);
	const DuctPartitionPlan *plan = duct_window_plan (self->win);

	self->ok = duct_backend_run (self->backend, cfg, plan, &self->error);

	/* Which stage failed is not reported by duct_backend_run -- it returns one
	 * error. For the prototype, "the last stage we saw progress for" is close
	 * enough, and the log above it says the rest. The real backend should put
	 * the stage in the GError domain/code instead. */
	if (!self->ok)
		self->reached_destructive = TRUE;

	g_idle_add (on_finished, self);

	return NULL;
}

static void
on_destroy (GtkWidget *widget, gpointer user_data)
{
	ProgressPage *self = user_data;
	(void) widget;

	g_clear_error (&self->error);
	g_clear_pointer (&self->backend, duct_backend_free);
	g_free (self);
}

AdwNavigationPage *
duct_page_progress_new (DuctWindow *win)
{
	GtkWidget *body = NULL;
	AdwNavigationPage *page =
		duct_page_scaffold ("Installing", "progress", NULL, &body, NULL);

	/* No going back and no closing. From here on the only exits are the done
	 * screen and the failure screen. */
	adw_navigation_page_set_can_pop (page, FALSE);

	ProgressPage *self = g_new0 (ProgressPage, 1);
	self->win  = win;
	self->body = body;

	gtk_box_append (GTK_BOX (body),
	                duct_page_heading ("Installing Duct",
	                                   "This will take a few minutes."));

	self->stage_label = gtk_label_new ("Starting");
	gtk_label_set_xalign (GTK_LABEL (self->stage_label), 0.0);
	gtk_widget_add_css_class (self->stage_label, "heading");
	gtk_box_append (GTK_BOX (body), self->stage_label);

	self->bar = gtk_progress_bar_new ();
	gtk_box_append (GTK_BOX (body), self->bar);

	self->detail_label = gtk_label_new ("");
	gtk_label_set_xalign (GTK_LABEL (self->detail_label), 0.0);
	gtk_label_set_ellipsize (GTK_LABEL (self->detail_label), PANGO_ELLIPSIZE_MIDDLE);
	gtk_widget_add_css_class (self->detail_label, "dim-label");
	gtk_box_append (GTK_BOX (body), self->detail_label);

	/* The command log. In a dry run this is the entire product of the
	 * program, so it gets real space rather than a tooltip. */
	self->log_view   = gtk_text_view_new ();
	self->log_buffer = gtk_text_view_get_buffer (GTK_TEXT_VIEW (self->log_view));
	gtk_text_view_set_editable (GTK_TEXT_VIEW (self->log_view), FALSE);
	gtk_text_view_set_monospace (GTK_TEXT_VIEW (self->log_view), TRUE);
	gtk_text_view_set_wrap_mode (GTK_TEXT_VIEW (self->log_view), GTK_WRAP_WORD_CHAR);
	gtk_widget_set_margin_start (self->log_view, 6);
	gtk_widget_set_margin_end (self->log_view, 6);

	GtkWidget *log_scroller = gtk_scrolled_window_new ();
	gtk_scrolled_window_set_child (GTK_SCROLLED_WINDOW (log_scroller), self->log_view);
	gtk_widget_set_size_request (log_scroller, -1, 260);

	self->expander = adw_expander_row_new ();
	adw_preferences_row_set_title (ADW_PREFERENCES_ROW (self->expander),
	                               "Commands");
	adw_expander_row_set_subtitle (ADW_EXPANDER_ROW (self->expander),
	                               "Every command this install issues");
	adw_expander_row_add_row (ADW_EXPANDER_ROW (self->expander), log_scroller);
	adw_expander_row_set_expanded (ADW_EXPANDER_ROW (self->expander), TRUE);

	GtkWidget *log_group = adw_preferences_group_new ();
	adw_preferences_group_add (ADW_PREFERENCES_GROUP (log_group), self->expander);
	gtk_box_append (GTK_BOX (body), log_group);

	/* Constructing the backend is the one place a destructive one could
	 * appear, so it is written out rather than hidden in a helper.
	 *
	 * --real cannot succeed today: duct_backend_real_new() returns NULL with
	 * an error. The fallback is the dry run, and the log says so -- it does
	 * not silently pretend the user got what they asked for. */
	if (duct_window_allow_real (win)) {
		g_autoptr (GError) error = NULL;
		self->backend = duct_backend_real_new (&error);

		if (self->backend == NULL) {
			on_log ("! --real was requested and refused:", self);
			g_autofree char *line = g_strdup_printf ("!   %s", error->message);
			on_log (line, self);
			on_log ("! falling back to a dry run.", self);
		}
	}

	if (self->backend == NULL)
		self->backend = duct_backend_dryrun_new ();

	self->backend->progress  = on_progress;
	self->backend->log       = on_log;
	self->backend->user_data = self;

	g_autofree char *header =
		g_strdup_printf ("# %s — nothing below is executed", self->backend->name);
	on_log (header, self);

	g_signal_connect (body, "destroy", G_CALLBACK (on_destroy), self);

	g_thread_unref (g_thread_new ("duct-install", worker, self));

	return page;
}

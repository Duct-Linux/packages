/* The disk screen.
 *
 * The most dangerous screen in the program, so the rules it enforces are worth
 * stating where they are implemented:
 *
 *   - The disk carrying the live medium is not in the list. Not disabled with
 *     a tooltip -- absent. A control that can be clicked is a control someone
 *     will find a way to click, and the failure here is unrecoverable.
 *   - A disk that is excluded is named at the bottom of the screen with the
 *     reason. Silently dropping hardware is how people conclude the installer
 *     is broken and go looking for a way to force it.
 *   - Every disk is described by model, node and size, in full. That string is
 *     what stands between someone and the wrong disk.
 *   - Selecting a disk computes the plan, which is where a too-small disk or a
 *     late-arriving boot medium is refused -- before Next is enabled.
 */

#include "pages.h"

typedef struct {
	DuctWindow *win;
	GtkWidget  *action;
	GtkWidget  *group;
	GPtrArray  *disks;      /* DuctDisk*, including the excluded ones */
	GtkWidget  *first_radio;
} DiskPage;

static void
on_disk_selected (GtkCheckButton *radio, gpointer user_data)
{
	DiskPage *self = user_data;

	if (!gtk_check_button_get_active (radio))
		return;

	const DuctDisk *disk = g_object_get_data (G_OBJECT (radio), "duct-disk");
	g_return_if_fail (disk != NULL);

	g_autoptr (GError) error = NULL;
	DuctPartitionPlan *plan = duct_partition_plan (disk, &error);

	if (plan == NULL) {
		/* Refused. The reason goes on the button's row rather than into a
		 * dialog: it belongs to that disk, and it should stay visible while
		 * the user looks at the others. */
		duct_window_set_disk (self->win, NULL);
		duct_window_set_plan (self->win, NULL);
		gtk_widget_set_sensitive (self->action, FALSE);

		GtkWidget *row = gtk_widget_get_ancestor (GTK_WIDGET (radio), ADW_TYPE_ACTION_ROW);
		if (row != NULL) {
			adw_action_row_set_subtitle (ADW_ACTION_ROW (row), error->message);
			gtk_widget_add_css_class (row, "error");
		}
		return;
	}

	duct_window_set_disk (self->win, disk);
	duct_window_set_plan (self->win, plan);
	gtk_widget_set_sensitive (self->action, TRUE);
}

static void
on_next (GtkButton *button, gpointer user_data)
{
	DiskPage *self = user_data;
	(void) button;

	if (duct_window_plan (self->win) == NULL)
		return;

	duct_window_next (self->win);
}

static void
on_destroy (GtkWidget *widget, gpointer user_data)
{
	DiskPage *self = user_data;
	(void) widget;

	g_clear_pointer (&self->disks, g_ptr_array_unref);
	g_free (self);
}

AdwNavigationPage *
duct_page_disk_new (DuctWindow *win)
{
	GtkWidget *body = NULL, *action = NULL;
	AdwNavigationPage *page =
		duct_page_scaffold ("Disk", "disk", "Next", &body, &action);

	DiskPage *self = g_new0 (DiskPage, 1);
	self->win    = win;
	self->action = action;

	/* Nothing is selected until the user selects something, and Next stays
	 * dead until a plan has been computed for it. */
	gtk_widget_set_sensitive (action, FALSE);

	gtk_box_append (GTK_BOX (body),
	                duct_page_heading ("Choose a disk",
	                                   "Everything on the disk you choose will be "
	                                   "erased. Duct will use the whole of it."));

	gboolean simulated = FALSE;
	g_autoptr (GError) error = NULL;

	self->disks = duct_disk_probe (&simulated, &error);

	if (self->disks == NULL) {
		GtkWidget *status = adw_status_page_new ();
		adw_status_page_set_icon_name (ADW_STATUS_PAGE (status), "dialog-error-symbolic");
		adw_status_page_set_title (ADW_STATUS_PAGE (status), "No disks found");
		adw_status_page_set_description (ADW_STATUS_PAGE (status), error->message);
		gtk_box_append (GTK_BOX (body), status);
		g_signal_connect (body, "destroy", G_CALLBACK (on_destroy), self);
		return page;
	}

	if (simulated) {
		/* Never quietly. An installer that showed invented hardware without
		 * saying so would be an unforgivable thing to ship, and the banner is
		 * cheaper than the incident. */
		GtkWidget *banner = adw_banner_new (
			"Simulated hardware — this machine has no lsblk, so these disks are examples");
		adw_banner_set_revealed (ADW_BANNER (banner), TRUE);
		gtk_box_append (GTK_BOX (body), banner);
	}

	self->group = adw_preferences_group_new ();
	adw_preferences_group_set_title (ADW_PREFERENCES_GROUP (self->group), "Available disks");
	gtk_box_append (GTK_BOX (body), self->group);

	g_autoptr (GString) excluded = g_string_new (NULL);
	guint offered = 0;

	for (guint i = 0; i < self->disks->len; i++) {
		const DuctDisk *disk = g_ptr_array_index (self->disks, i);

		if (disk->is_boot_medium) {
			g_autofree char *described = duct_disk_describe (disk);
			g_string_append_printf (excluded,
				"%s is not shown: it is the medium this installer booted from.\n",
				described);
			continue;
		}

		GtkWidget *row = adw_action_row_new ();
		g_autofree char *size = duct_disk_format_size (disk->size);

		adw_preferences_row_set_title (ADW_PREFERENCES_ROW (row),
		                               disk->model ? disk->model : "Unknown model");

		g_autofree char *subtitle = (disk->serial != NULL && *disk->serial != '\0')
			? g_strdup_printf ("%s · %s · serial %s", disk->node, size, disk->serial)
			: g_strdup_printf ("%s · %s", disk->node, size);
		adw_action_row_set_subtitle (ADW_ACTION_ROW (row), subtitle);
		adw_action_row_set_subtitle_lines (ADW_ACTION_ROW (row), 0);

		GtkWidget *radio = gtk_check_button_new ();
		if (self->first_radio == NULL)
			self->first_radio = radio;
		else
			gtk_check_button_set_group (GTK_CHECK_BUTTON (radio),
			                            GTK_CHECK_BUTTON (self->first_radio));

		g_object_set_data (G_OBJECT (radio), "duct-disk", (gpointer) disk);
		g_signal_connect (radio, "toggled", G_CALLBACK (on_disk_selected), self);

		adw_action_row_add_prefix (ADW_ACTION_ROW (row), radio);
		adw_action_row_set_activatable_widget (ADW_ACTION_ROW (row), radio);

		if (disk->removable)
			gtk_widget_add_css_class (row, "warning");

		adw_preferences_group_add (ADW_PREFERENCES_GROUP (self->group), row);
		offered++;
	}

	if (offered == 0) {
		GtkWidget *note = gtk_label_new (
			"No disk on this machine can be installed to. The only disk found "
			"is the one this installer is running from.");
		gtk_label_set_wrap (GTK_LABEL (note), TRUE);
		gtk_label_set_xalign (GTK_LABEL (note), 0.0);
		gtk_widget_add_css_class (note, "error");
		gtk_box_append (GTK_BOX (body), note);
	}

	if (excluded->len > 0) {
		g_string_truncate (excluded, excluded->len - 1);   /* the trailing newline */

		GtkWidget *note = gtk_label_new (excluded->str);
		gtk_label_set_wrap (GTK_LABEL (note), TRUE);
		gtk_label_set_xalign (GTK_LABEL (note), 0.0);
		gtk_widget_add_css_class (note, "dim-label");
		gtk_widget_add_css_class (note, "caption");
		gtk_box_append (GTK_BOX (body), note);
	}

	g_signal_connect (action, "clicked", G_CALLBACK (on_next), self);
	g_signal_connect (body, "destroy", G_CALLBACK (on_destroy), self);

	return page;
}

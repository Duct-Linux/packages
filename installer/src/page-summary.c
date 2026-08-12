/* The summary, and the one confirmation.
 *
 * This is the gate. Everything before it was read-only; the next screen starts
 * writing. So this screen has two jobs: show the whole decision in one place,
 * and make the confirmation deliberate without making it tedious.
 *
 * One dialog, not four. An installer that asks repeatedly teaches people to
 * click through, and then the one question that mattered gets clicked through
 * too. The single question is made deliberate by requiring the device name to
 * be typed rather than by being asked twice.
 */

#include "pages.h"

#include <string.h>

typedef struct {
	DuctWindow *win;
	GtkWidget  *entry;      /* inside the dialog */
	char       *expected;   /* the last component of the device node */
} SummaryPage;

static void
add_row (GtkWidget *group, const char *title, const char *value)
{
	GtkWidget *row = adw_action_row_new ();

	adw_preferences_row_set_title (ADW_PREFERENCES_ROW (row), title);
	adw_action_row_set_subtitle (ADW_ACTION_ROW (row), value);
	adw_action_row_set_subtitle_lines (ADW_ACTION_ROW (row), 0);
	adw_preferences_group_add (ADW_PREFERENCES_GROUP (group), row);
}

static void
on_confirm_text_changed (GtkEditable *editable, gpointer user_data)
{
	SummaryPage *self = user_data;
	AdwAlertDialog *dialog = ADW_ALERT_DIALOG (
		g_object_get_data (G_OBJECT (editable), "duct-dialog"));

	const char *typed = gtk_editable_get_text (editable);

	adw_alert_dialog_set_response_enabled (dialog, "erase",
	                                       g_strcmp0 (typed, self->expected) == 0);
}

static void
on_dialog_response (AdwAlertDialog *dialog, const char *response, gpointer user_data)
{
	SummaryPage *self = user_data;
	(void) dialog;

	if (g_strcmp0 (response, "erase") != 0)
		return;

	duct_window_next (self->win);
}

static void
on_install (GtkButton *button, gpointer user_data)
{
	SummaryPage *self = user_data;

	const DuctDisk *disk = duct_window_disk (self->win);
	g_return_if_fail (disk != NULL);

	g_autofree char *described = duct_disk_describe (disk);
	g_autofree char *body = g_strdup_printf (
		"Everything on this disk will be destroyed:\n\n%s\n\n"
		"There is no undo. Type “%s” to confirm.",
		described, self->expected);

	AdwAlertDialog *dialog =
		ADW_ALERT_DIALOG (adw_alert_dialog_new ("Erase this disk?", NULL));

	adw_alert_dialog_set_body (dialog, body);

	self->entry = gtk_entry_new ();
	gtk_entry_set_placeholder_text (GTK_ENTRY (self->entry), self->expected);
	g_object_set_data (G_OBJECT (self->entry), "duct-dialog", dialog);
	g_signal_connect (self->entry, "changed", G_CALLBACK (on_confirm_text_changed), self);
	adw_alert_dialog_set_extra_child (dialog, self->entry);

	adw_alert_dialog_add_responses (dialog,
	                                "cancel", "Cancel",
	                                "erase",  "Erase and install",
	                                NULL);
	adw_alert_dialog_set_response_appearance (dialog, "erase", ADW_RESPONSE_DESTRUCTIVE);
	adw_alert_dialog_set_response_enabled (dialog, "erase", FALSE);
	adw_alert_dialog_set_default_response (dialog, "cancel");
	adw_alert_dialog_set_close_response (dialog, "cancel");

	g_signal_connect (dialog, "response", G_CALLBACK (on_dialog_response), self);

	adw_dialog_present (ADW_DIALOG (dialog), GTK_WIDGET (button));
}

static void
on_destroy (GtkWidget *widget, gpointer user_data)
{
	SummaryPage *self = user_data;
	(void) widget;

	g_free (self->expected);
	g_free (self);
}

AdwNavigationPage *
duct_page_summary_new (DuctWindow *win)
{
	GtkWidget *body = NULL, *action = NULL;
	AdwNavigationPage *page =
		duct_page_scaffold ("Summary", "summary", "Erase disk and install", &body, &action);

	/* The one destructive-looking button in the program. */
	gtk_widget_remove_css_class (action, "suggested-action");
	gtk_widget_add_css_class (action, "destructive-action");

	SummaryPage *self = g_new0 (SummaryPage, 1);
	self->win = win;

	const DuctDisk          *disk = duct_window_disk (win);
	const DuctPartitionPlan *plan = duct_window_plan (win);
	const DuctInstallConfig *cfg  = duct_window_config (win);

	if (disk == NULL || plan == NULL) {
		gtk_widget_set_sensitive (action, FALSE);
		gtk_box_append (GTK_BOX (body),
		                duct_page_heading ("No disk selected",
		                                   "Go back and choose a disk."));
		g_signal_connect (body, "destroy", G_CALLBACK (on_destroy), self);
		return page;
	}

	self->expected = g_path_get_basename (disk->node);

	gtk_box_append (GTK_BOX (body),
	                duct_page_heading ("Ready to install",
	                                   "Nothing has been written yet. Check this, "
	                                   "then confirm."));

	GtkWidget *banner = adw_banner_new ("Dry run — this build will write nothing");
	adw_banner_set_revealed (ADW_BANNER (banner), TRUE);
	gtk_box_append (GTK_BOX (body), banner);

	/* The target, first and in full. */
	GtkWidget *target = adw_preferences_group_new ();
	adw_preferences_group_set_title (ADW_PREFERENCES_GROUP (target),
	                                 "This disk will be erased completely");

	g_autofree char *described = duct_disk_describe (disk);
	add_row (target, "Disk", described);
	gtk_widget_add_css_class (target, "error");
	gtk_box_append (GTK_BOX (body), target);

	/* The layout that will be written. */
	GtkWidget *layout = adw_preferences_group_new ();
	adw_preferences_group_set_title (ADW_PREFERENCES_GROUP (layout), "New partitions");

	g_autofree char *esp_size  = duct_disk_format_size (plan->esp_size);
	g_autofree char *root_size = duct_disk_format_size (plan->root_size);
	g_autofree char *esp  = g_strdup_printf ("%s · FAT32 · mounted at /boot/efi · %s",
	                                         plan->esp_node, esp_size);
	g_autofree char *root = g_strdup_printf ("%s · ext4 · mounted at / · %s",
	                                         plan->root_node, root_size);
	add_row (layout, "EFI system partition", esp);
	add_row (layout, "Duct root", root);
	gtk_box_append (GTK_BOX (body), layout);

	GtkWidget *settings = adw_preferences_group_new ();
	adw_preferences_group_set_title (ADW_PREFERENCES_GROUP (settings), "Settings");
	add_row (settings, "Account", cfg->username ? cfg->username : "");
	add_row (settings, "Computer name", cfg->hostname ? cfg->hostname : "");
	g_autofree char *keyboard = (cfg->kb_variant != NULL && *cfg->kb_variant != '\0')
		? g_strdup_printf ("%s (%s)", cfg->kb_layout, cfg->kb_variant)
		: g_strdup (cfg->kb_layout);
	add_row (settings, "Keyboard", keyboard);
	add_row (settings, "Locale", cfg->locale);
	add_row (settings, "Time zone", cfg->timezone);
	gtk_box_append (GTK_BOX (body), settings);

	/* The exact sfdisk script, behind an expander.
	 *
	 * Most people will never open it. The ones who do are the ones who can
	 * tell whether it is right, and they are worth the twenty lines. */
	GtkWidget *expander = adw_expander_row_new ();
	adw_preferences_row_set_title (ADW_PREFERENCES_ROW (expander),
	                               "Exactly what will be written to the partition table");

	g_autofree char *script = duct_partition_plan_script (plan);
	GtkWidget *script_label = gtk_label_new (script);
	gtk_label_set_xalign (GTK_LABEL (script_label), 0.0);
	gtk_label_set_selectable (GTK_LABEL (script_label), TRUE);
	gtk_label_set_wrap (GTK_LABEL (script_label), TRUE);
	gtk_label_set_wrap_mode (GTK_LABEL (script_label), PANGO_WRAP_WORD_CHAR);
	gtk_widget_add_css_class (script_label, "monospace");
	gtk_widget_add_css_class (script_label, "caption");
	gtk_widget_set_margin_top (script_label, 6);
	gtk_widget_set_margin_bottom (script_label, 6);
	gtk_widget_set_margin_start (script_label, 12);
	gtk_widget_set_margin_end (script_label, 12);
	adw_expander_row_add_row (ADW_EXPANDER_ROW (expander), script_label);

	GtkWidget *detail_group = adw_preferences_group_new ();
	adw_preferences_group_add (ADW_PREFERENCES_GROUP (detail_group), expander);
	gtk_box_append (GTK_BOX (body), detail_group);

	g_signal_connect (action, "clicked", G_CALLBACK (on_install), self);
	g_signal_connect (body, "destroy", G_CALLBACK (on_destroy), self);

	return page;
}

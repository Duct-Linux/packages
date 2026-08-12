#include "pages.h"

static void
on_next (GtkButton *button, gpointer user_data)
{
	(void) button;
	duct_window_next (DUCT_WINDOW (user_data));
}

AdwNavigationPage *
duct_page_timezone_new (DuctWindow *win)
{
	GtkWidget *body = NULL, *action = NULL;
	AdwNavigationPage *page =
		duct_page_scaffold ("Time zone", "timezone", "Next", &body, &action);

	gtk_box_append (GTK_BOX (body),
	                duct_page_heading ("Time zone",
	                                   "The clock the installed system will keep."));

	DuctInstallConfig *cfg = duct_window_config (win);

	/* One entry, for the same reason as the language screen: tzdata is not
	 * packaged, so /usr/share/zoneinfo does not exist on a Duct system and
	 * there is nothing for /etc/localtime to point at. glibc falls back to
	 * UTC. See GAP-ANALYSIS.md item 5. */
	const char * const zones[] = { "UTC", NULL };
	GtkStringList *model = gtk_string_list_new (zones);

	GtkWidget *group = adw_preferences_group_new ();

	GtkWidget *row = adw_combo_row_new ();
	adw_preferences_row_set_title (ADW_PREFERENCES_ROW (row), "Zone");
	adw_combo_row_set_model (ADW_COMBO_ROW (row), G_LIST_MODEL (model));
	adw_action_row_set_subtitle (ADW_ACTION_ROW (row), cfg->timezone);
	adw_preferences_group_add (ADW_PREFERENCES_GROUP (group), row);

	gtk_box_append (GTK_BOX (body), group);

	GtkWidget *note = gtk_label_new (
		"Duct does not ship the time zone database yet, so every installed "
		"system runs on UTC. Adding the database is a packaging change, not "
		"an installer one.");
	gtk_label_set_wrap (GTK_LABEL (note), TRUE);
	gtk_label_set_xalign (GTK_LABEL (note), 0.0);
	gtk_widget_add_css_class (note, "dim-label");
	gtk_widget_add_css_class (note, "caption");
	gtk_box_append (GTK_BOX (body), note);

	g_signal_connect (action, "clicked", G_CALLBACK (on_next), win);

	return page;
}

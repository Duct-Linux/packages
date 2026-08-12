#include "pages.h"

static void
on_next (GtkButton *button, gpointer user_data)
{
	(void) button;
	duct_window_next (DUCT_WINDOW (user_data));
}

AdwNavigationPage *
duct_page_language_new (DuctWindow *win)
{
	GtkWidget *body = NULL, *action = NULL;
	AdwNavigationPage *page =
		duct_page_scaffold ("Language", "language", "Next", &body, &action);

	gtk_box_append (GTK_BOX (body),
	                duct_page_heading ("Language",
	                                   "The language the installed system will use."));

	DuctInstallConfig *cfg = duct_window_config (win);

	GtkWidget *group = adw_preferences_group_new ();

	/* One entry, and the screen says why rather than looking broken.
	 *
	 * glibc's recipe runs no localedef, so the only locales that exist are the
	 * built-in C and C.UTF-8 -- and every package in the tree is configured
	 * --disable-nls, so even with more locales generated there would be no
	 * translated messages behind them. See GAP-ANALYSIS.md items 6 and 7.
	 *
	 * The screen stays in the flow rather than being removed. Taking it out
	 * would mean putting it back later, and a row that explains itself is
	 * better than a gap someone has to go and ask about. */
	const char * const locales[] = { "C.UTF-8", NULL };
	GtkStringList *model = gtk_string_list_new (locales);

	GtkWidget *row = adw_combo_row_new ();
	adw_preferences_row_set_title (ADW_PREFERENCES_ROW (row), "Locale");
	adw_combo_row_set_model (ADW_COMBO_ROW (row), G_LIST_MODEL (model));
	adw_action_row_set_subtitle (ADW_ACTION_ROW (row), cfg->locale);
	adw_preferences_group_add (ADW_PREFERENCES_GROUP (group), row);

	gtk_box_append (GTK_BOX (body), group);

	GtkWidget *note = gtk_label_new (
		"Duct ships only C.UTF-8 today: its C library is built without "
		"additional locales, and its packages are built without translations. "
		"More languages need a locale package first.");
	gtk_label_set_wrap (GTK_LABEL (note), TRUE);
	gtk_label_set_xalign (GTK_LABEL (note), 0.0);
	gtk_widget_add_css_class (note, "dim-label");
	gtk_widget_add_css_class (note, "caption");
	gtk_box_append (GTK_BOX (body), note);

	g_signal_connect (action, "clicked", G_CALLBACK (on_next), win);

	return page;
}

#include "pages.h"

static void
on_next (GtkButton *button, gpointer user_data)
{
	(void) button;
	duct_window_next (DUCT_WINDOW (user_data));
}

AdwNavigationPage *
duct_page_welcome_new (DuctWindow *win)
{
	GtkWidget *body = NULL, *action = NULL;
	AdwNavigationPage *page =
		duct_page_scaffold ("Welcome", "welcome", "Begin", &body, &action);

	GtkWidget *status = adw_status_page_new ();
	adw_status_page_set_icon_name (ADW_STATUS_PAGE (status), "drive-harddisk-symbolic");
	adw_status_page_set_title (ADW_STATUS_PAGE (status), "Install Duct");
	adw_status_page_set_description (
		ADW_STATUS_PAGE (status),
		"This will erase a disk completely and install Duct on it.\n"
		"Nothing is written until you confirm, and you will be shown "
		"exactly which disk before that happens.");
	gtk_widget_set_vexpand (status, TRUE);
	gtk_box_append (GTK_BOX (body), status);

	/* Stated on the first screen, not buried in an about box. Someone who
	 * starts this expecting an installer should find out on screen one that
	 * this build does not install anything. */
	GtkWidget *banner = adw_banner_new (
		"Dry run — this build writes nothing to any device");
	adw_banner_set_revealed (ADW_BANNER (banner), TRUE);
	gtk_box_append (GTK_BOX (body), banner);

	/* The refusals, up front. A user who needs one of these should find out
	 * now rather than on the summary screen. */
	GtkWidget *group = adw_preferences_group_new ();
	adw_preferences_group_set_title (ADW_PREFERENCES_GROUP (group),
	                                 "What this version does not do");

	static const struct { const char *what; const char *why; } refusals[] = {
		{ "Install alongside another operating system",
		  "Duct takes the whole disk. It cannot write a firmware boot entry, "
		  "so it would have to overwrite the shared fallback boot path." },
		{ "Encrypt the disk",
		  "cryptsetup is not part of Duct yet." },
		{ "Use LVM or RAID",
		  "lvm2 and mdadm are not part of Duct yet." },
		{ "Let you partition the disk yourself",
		  "One layout, shown in full before it is written." },
		{ "Connect to a network",
		  "Duct has no network configuration tools yet. Everything is "
		  "installed from this medium." },
	};

	for (guint i = 0; i < G_N_ELEMENTS (refusals); i++) {
		GtkWidget *row = adw_action_row_new ();
		adw_preferences_row_set_title (ADW_PREFERENCES_ROW (row), refusals[i].what);
		adw_action_row_set_subtitle (ADW_ACTION_ROW (row), refusals[i].why);
		adw_action_row_set_subtitle_lines (ADW_ACTION_ROW (row), 0);
		adw_preferences_group_add (ADW_PREFERENCES_GROUP (group), row);
	}

	gtk_box_append (GTK_BOX (body), group);

	g_signal_connect (action, "clicked", G_CALLBACK (on_next), win);

	return page;
}

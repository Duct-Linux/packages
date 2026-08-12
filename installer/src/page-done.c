#include "pages.h"

static void
on_quit (GtkButton *button, gpointer user_data)
{
	(void) user_data;

	GtkRoot *root = gtk_widget_get_root (GTK_WIDGET (button));
	gtk_window_close (GTK_WINDOW (root));
}

static void
on_reboot (GtkButton *button, gpointer user_data)
{
	(void) user_data;

	/* Deliberately not wired up. Rebooting is a real action and this build is
	 * a dry run: nothing was installed, so there is nothing to reboot into.
	 * The real one runs `reboot`, which duct-live's inittab handles
	 * (::ctrlaltdel and ::shutdown), after unmounting the target. */
	AdwAlertDialog *dialog = ADW_ALERT_DIALOG (adw_alert_dialog_new (
		"Not in a dry run",
		"Nothing was installed, so there is nothing to restart into. "
		"The real installer restarts the machine here."));

	adw_alert_dialog_add_response (dialog, "ok", "OK");
	adw_dialog_present (ADW_DIALOG (dialog), GTK_WIDGET (button));
}

AdwNavigationPage *
duct_page_done_new (DuctWindow *win)
{
	GtkWidget *body = NULL;
	AdwNavigationPage *page =
		duct_page_scaffold ("Done", "done", NULL, &body, NULL);

	adw_navigation_page_set_can_pop (page, FALSE);

	const DuctInstallConfig *cfg = duct_window_config (win);

	GtkWidget *status = adw_status_page_new ();
	adw_status_page_set_icon_name (ADW_STATUS_PAGE (status), "emblem-ok-symbolic");
	adw_status_page_set_title (ADW_STATUS_PAGE (status), "Dry run complete");

	g_autofree char *description = g_strdup_printf (
		"No device was written to.\n\n"
		"A real install would now have Duct on %s, with an account for %s, "
		"and the machine would restart into it.",
		cfg->disk ? cfg->disk : "the chosen disk",
		cfg->username ? cfg->username : "you");
	adw_status_page_set_description (ADW_STATUS_PAGE (status), description);

	GtkWidget *buttons = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 12);
	gtk_widget_set_halign (buttons, GTK_ALIGN_CENTER);

	GtkWidget *stay = gtk_button_new_with_label ("Close");
	gtk_widget_add_css_class (stay, "pill");
	g_signal_connect (stay, "clicked", G_CALLBACK (on_quit), NULL);
	gtk_box_append (GTK_BOX (buttons), stay);

	GtkWidget *reboot = gtk_button_new_with_label ("Restart now");
	gtk_widget_add_css_class (reboot, "pill");
	gtk_widget_add_css_class (reboot, "suggested-action");
	g_signal_connect (reboot, "clicked", G_CALLBACK (on_reboot), NULL);
	gtk_box_append (GTK_BOX (buttons), reboot);

	adw_status_page_set_child (ADW_STATUS_PAGE (status), buttons);
	gtk_widget_set_vexpand (status, TRUE);
	gtk_box_append (GTK_BOX (body), status);

	return page;
}

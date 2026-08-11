#include "pages.h"

#include <string.h>

typedef struct {
	DuctWindow *win;
	GtkWidget  *action;

	GtkWidget *full_name;
	GtkWidget *username;
	GtkWidget *password;
	GtkWidget *confirm;
	GtkWidget *hostname;
	GtkWidget *root_same;

	GtkWidget *problem;   /* the one line explaining why Next is dead */
} UserPage;


static void
revalidate (GtkEditable *editable, gpointer user_data)
{
	UserPage *self = user_data;
	(void) editable;

	const char *username = gtk_editable_get_text (GTK_EDITABLE (self->username));
	const char *password = gtk_editable_get_text (GTK_EDITABLE (self->password));
	const char *confirm  = gtk_editable_get_text (GTK_EDITABLE (self->confirm));
	const char *hostname = gtk_editable_get_text (GTK_EDITABLE (self->hostname));

	const char *why = NULL;
	gboolean ok = TRUE;

	if (ok) ok = duct_username_is_valid (username, &why);
	if (ok) ok = duct_hostname_is_valid (hostname, &why);

	if (ok && *password == '\0') {
		/* No empty passwords, and no "you can set one later". There is no sudo
		 * and no doas in Duct, so this password is also how the machine is
		 * administered -- see GAP-ANALYSIS.md item 8. */
		why = "Choose a password. Duct has no sudo, so this is also how you "
		      "will administer the machine.";
		ok = FALSE;
	}
	if (ok && strlen (password) < 8) {
		why = "Use at least 8 characters.";
		ok = FALSE;
	}
	if (ok && g_strcmp0 (password, confirm) != 0) {
		why = "The two passwords do not match.";
		ok = FALSE;
	}

	gtk_label_set_text (GTK_LABEL (self->problem), ok ? "" : why);
	gtk_widget_set_visible (self->problem, !ok);
	gtk_widget_set_sensitive (self->action, ok);
}

static void
on_next (GtkButton *button, gpointer user_data)
{
	UserPage *self = user_data;
	(void) button;

	DuctInstallConfig *cfg = duct_window_config (self->win);

	g_free (cfg->full_name);
	g_free (cfg->username);
	g_free (cfg->hostname);
	if (cfg->password != NULL) {
		memset (cfg->password, 0, strlen (cfg->password));
		g_free (cfg->password);
	}

	cfg->full_name = g_strdup (gtk_editable_get_text (GTK_EDITABLE (self->full_name)));
	cfg->username  = g_strdup (gtk_editable_get_text (GTK_EDITABLE (self->username)));
	cfg->hostname  = g_strdup (gtk_editable_get_text (GTK_EDITABLE (self->hostname)));
	cfg->password  = g_strdup (gtk_editable_get_text (GTK_EDITABLE (self->password)));

	/* lock_root means "root has no password of its own". The switch offers the
	 * opposite phrasing because that is the one people think in. */
	cfg->lock_root = adw_switch_row_get_active (ADW_SWITCH_ROW (self->root_same));

	duct_window_next (self->win);
}

static void
on_destroy (GtkWidget *widget, gpointer user_data)
{
	(void) widget;
	g_free (user_data);
}

AdwNavigationPage *
duct_page_user_new (DuctWindow *win)
{
	GtkWidget *body = NULL, *action = NULL;
	AdwNavigationPage *page =
		duct_page_scaffold ("Account", "user", "Next", &body, &action);

	UserPage *self = g_new0 (UserPage, 1);
	self->win    = win;
	self->action = action;

	gtk_widget_set_sensitive (action, FALSE);

	gtk_box_append (GTK_BOX (body),
	                duct_page_heading ("Create your account",
	                                   "The first account on the installed system."));

	GtkWidget *who = adw_preferences_group_new ();

	self->full_name = adw_entry_row_new ();
	adw_preferences_row_set_title (ADW_PREFERENCES_ROW (self->full_name), "Full name");
	adw_preferences_group_add (ADW_PREFERENCES_GROUP (who), self->full_name);

	self->username = adw_entry_row_new ();
	adw_preferences_row_set_title (ADW_PREFERENCES_ROW (self->username), "Username");
	adw_preferences_group_add (ADW_PREFERENCES_GROUP (who), self->username);

	self->hostname = adw_entry_row_new ();
	adw_preferences_row_set_title (ADW_PREFERENCES_ROW (self->hostname), "Computer name");
	gtk_editable_set_text (GTK_EDITABLE (self->hostname),
	                       duct_window_config (win)->hostname);
	adw_preferences_group_add (ADW_PREFERENCES_GROUP (who), self->hostname);

	gtk_box_append (GTK_BOX (body), who);

	GtkWidget *secret = adw_preferences_group_new ();

	self->password = adw_password_entry_row_new ();
	adw_preferences_row_set_title (ADW_PREFERENCES_ROW (self->password), "Password");
	adw_preferences_group_add (ADW_PREFERENCES_GROUP (secret), self->password);

	self->confirm = adw_password_entry_row_new ();
	adw_preferences_row_set_title (ADW_PREFERENCES_ROW (self->confirm), "Confirm password");
	adw_preferences_group_add (ADW_PREFERENCES_GROUP (secret), self->confirm);

	self->root_same = adw_switch_row_new ();
	adw_preferences_row_set_title (ADW_PREFERENCES_ROW (self->root_same),
	                               "Use this password for the administrator too");
	adw_action_row_set_subtitle (ADW_ACTION_ROW (self->root_same),
		"Duct has no sudo yet, so administering the machine means logging in "
		"as root with su. Turn this off to set a separate root password.");
	adw_action_row_set_subtitle_lines (ADW_ACTION_ROW (self->root_same), 0);
	adw_switch_row_set_active (ADW_SWITCH_ROW (self->root_same), TRUE);
	adw_preferences_group_add (ADW_PREFERENCES_GROUP (secret), self->root_same);

	gtk_box_append (GTK_BOX (body), secret);

	/* One line, under the fields, saying the single reason Next is disabled.
	 * Not a dialog, and not one message per field: a form that scolds you in
	 * three places at once is a form people stop reading. */
	self->problem = gtk_label_new ("");
	gtk_label_set_wrap (GTK_LABEL (self->problem), TRUE);
	gtk_label_set_xalign (GTK_LABEL (self->problem), 0.0);
	gtk_widget_add_css_class (self->problem, "error");
	gtk_widget_set_visible (self->problem, FALSE);
	gtk_box_append (GTK_BOX (body), self->problem);

	g_signal_connect (self->username, "changed", G_CALLBACK (revalidate), self);
	g_signal_connect (self->password, "changed", G_CALLBACK (revalidate), self);
	g_signal_connect (self->confirm,  "changed", G_CALLBACK (revalidate), self);
	g_signal_connect (self->hostname, "changed", G_CALLBACK (revalidate), self);

	g_signal_connect (action, "clicked", G_CALLBACK (on_next), self);
	g_signal_connect (body, "destroy", G_CALLBACK (on_destroy), self);

	return page;
}

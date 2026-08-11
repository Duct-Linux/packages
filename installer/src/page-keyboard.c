#include "pages.h"

typedef struct {
	DuctWindow *win;
	AdwComboRow *combo;
} KeyboardPage;

/* A short list rather than the whole of xkeyboard-config.
 *
 * The real screen reads /usr/share/X11/xkb/rules/base.xml -- xkeyboard-config
 * is packaged, so the data is there on a live system -- and offers layouts and
 * variants from it. That is an XML parse and a searchable list, and it is not
 * what this prototype is for. These are the layouts that cover most of the
 * people likely to boot an early Duct ISO. */
static const struct { const char *layout; const char *variant; const char *name; } layouts[] = {
	{ "us", "",         "English (US)" },
	{ "us", "intl",     "English (US, international)" },
	{ "gb", "",         "English (UK)" },
	{ "de", "",         "German" },
	{ "de", "nodeadkeys", "German (no dead keys)" },
	{ "fr", "",         "French" },
	{ "es", "",         "Spanish" },
	{ "it", "",         "Italian" },
	{ "ch", "de",       "Swiss German" },
	{ "dvorak", "",     "Dvorak" },
};

static void
on_next (GtkButton *button, gpointer user_data)
{
	KeyboardPage *self = user_data;
	(void) button;

	guint index = adw_combo_row_get_selected (self->combo);
	if (index >= G_N_ELEMENTS (layouts))
		index = 0;

	DuctInstallConfig *cfg = duct_window_config (self->win);

	g_free (cfg->kb_layout);
	g_free (cfg->kb_variant);
	cfg->kb_layout  = g_strdup (layouts[index].layout);
	cfg->kb_variant = g_strdup (layouts[index].variant);

	duct_window_next (self->win);
}

static void
on_destroy (GtkWidget *widget, gpointer user_data)
{
	(void) widget;
	g_free (user_data);
}

AdwNavigationPage *
duct_page_keyboard_new (DuctWindow *win)
{
	GtkWidget *body = NULL, *action = NULL;
	AdwNavigationPage *page =
		duct_page_scaffold ("Keyboard", "keyboard", "Next", &body, &action);

	KeyboardPage *self = g_new0 (KeyboardPage, 1);
	self->win = win;

	gtk_box_append (GTK_BOX (body),
	                duct_page_heading ("Keyboard layout",
	                                   "Used by the installer as well as the "
	                                   "installed system, so you can check it "
	                                   "below before typing a password."));

	g_autoptr (GtkStringList) model = gtk_string_list_new (NULL);
	for (guint i = 0; i < G_N_ELEMENTS (layouts); i++)
		gtk_string_list_append (model, layouts[i].name);

	GtkWidget *group = adw_preferences_group_new ();

	GtkWidget *row = adw_combo_row_new ();
	adw_preferences_row_set_title (ADW_PREFERENCES_ROW (row), "Layout");
	adw_combo_row_set_model (ADW_COMBO_ROW (row), G_LIST_MODEL (model));
	adw_preferences_group_add (ADW_PREFERENCES_GROUP (group), row);
	self->combo = ADW_COMBO_ROW (row);

	/* Somewhere to try it. The password screen is two screens away and is a
	 * poor place to discover that the layout is wrong -- especially since the
	 * characters are masked there. */
	GtkWidget *test = adw_entry_row_new ();
	adw_preferences_row_set_title (ADW_PREFERENCES_ROW (test), "Type here to test it");
	adw_preferences_group_add (ADW_PREFERENCES_GROUP (group), test);

	gtk_box_append (GTK_BOX (body), group);

	GtkWidget *note = gtk_label_new (
		"This sets the graphical keyboard layout. The text console on the "
		"installed system will stay on the default layout: Duct does not "
		"package the tool that changes it yet.");
	gtk_label_set_wrap (GTK_LABEL (note), TRUE);
	gtk_label_set_xalign (GTK_LABEL (note), 0.0);
	gtk_widget_add_css_class (note, "dim-label");
	gtk_widget_add_css_class (note, "caption");
	gtk_box_append (GTK_BOX (body), note);

	g_signal_connect (action, "clicked", G_CALLBACK (on_next), self);
	g_signal_connect (body, "destroy", G_CALLBACK (on_destroy), self);

	return page;
}

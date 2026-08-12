/* Duct installer -- entry point.
 *
 * Two things happen here that matter more than the boilerplate around them:
 * the dry run is the default, and --real is accepted but cannot yet be
 * honoured. Both are deliberate. The dry-run path is the specification the
 * destructive path has to match, so it is written and reviewable first.
 */

#include <adwaita.h>

#include "window.h"

static gboolean opt_real      = FALSE;
static gboolean opt_version   = FALSE;
static gboolean opt_self_test = FALSE;

static void
activate (GApplication *app, gpointer user_data)
{
	(void) user_data;

	DuctWindow *window = duct_window_new (ADW_APPLICATION (app), opt_real);

	gtk_window_present (GTK_WINDOW (window));

	if (opt_self_test)
		duct_window_self_test (window);
}

int
main (int argc, char *argv[])
{
	g_autoptr (GOptionContext) context = g_option_context_new ("- install Duct Linux");

	const GOptionEntry entries[] = {
		{ "real", 0, 0, G_OPTION_ARG_NONE, &opt_real,
		  "Perform a real installation. NOT IMPLEMENTED: this build can only dry-run.", NULL },
		{ "version", 0, 0, G_OPTION_ARG_NONE, &opt_version,
		  "Print the version and exit", NULL },
		{ "self-test", 0, 0, G_OPTION_ARG_NONE, &opt_self_test,
		  "Walk every screen without a human and exit", NULL },
		{ NULL, 0, 0, 0, NULL, NULL, NULL }
	};

	g_option_context_add_main_entries (context, entries, NULL);

	g_autoptr (GError) error = NULL;
	if (!g_option_context_parse (context, &argc, &argv, &error)) {
		g_printerr ("duct-installer: %s\n", error->message);
		return 1;
	}

	if (opt_version) {
		g_print ("duct-installer %s\n", PACKAGE_VERSION);
		return 0;
	}

	/* --real refuses to start rather than quietly degrading to a dry run.
	 *
	 * It used to fall back, which was the wrong shape: someone who asked for a
	 * real install and got a dry run has been told something they may not
	 * read, and the program then behaves exactly as if the flag worked. There
	 * is nothing behind this flag yet -- src/backend/real.c does not exist --
	 * and until there is a virtual machine to run it in, the honest response
	 * to being asked for it is to stop. */
	if (opt_real) {
		g_printerr ("duct-installer: --real is not implemented and this build cannot "
		            "install anything.\n"
		            "The destructive backend is unwritten, not disabled: there is no "
		            "code here that\nwrites to a disk. Run without --real for a dry "
		            "run.\n");
		return 1;
	}

	g_print ("duct-installer: dry run — no device will be written to.\n");

	g_autoptr (AdwApplication) app =
		adw_application_new ("de.dss-net.duct.Installer", G_APPLICATION_DEFAULT_FLAGS);

	g_signal_connect (app, "activate", G_CALLBACK (activate), NULL);

	return g_application_run (G_APPLICATION (app), 0, NULL);
}

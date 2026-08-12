/* duct-install-cli -- the installer without a display.
 *
 * WHAT THIS IS FOR. A GTK application cannot be driven over a serial console,
 * and there is no Wayland compositor on the Duct ISO yet, so the graphical
 * installer cannot be exercised inside a virtual machine at all. This binary
 * links the same backend the GUI does -- which is possible only because that
 * backend has no GTK in it by construction -- reads its answers from a file
 * and writes a structured log to stdout, where QEMU puts it on the serial
 * console for images/iso/boot-test.sh to grep.
 *
 * WHAT THIS IS NOT. It is not unattended installation. DESIGN.md lists that as
 * a v1 non-goal and this does not change it. The difference is not cosmetic:
 * a real unattended installer would need a schema for its answers file, a
 * story for secrets that is better than plaintext on disk, and a policy for
 * what to do when an answer is missing or a disk has moved. This has none of
 * those, on purpose. It exists to make one test runnable.
 *
 * That distinction is repeated in --help so that nobody reading the binary
 * later has to find this comment to learn it.
 */

#include "backend/backend.h"

#include <gio/gio.h>
#include <stdio.h>
#include <string.h>

/* The prefix boot-test.sh greps for. One marker per milestone, so a run that
 * stops halfway is distinguishable from one that hung -- which is the whole
 * reason the harness can tell a partial pass from a timeout. */
#define MARK "DUCT-TEST: "

static char     *opt_answers  = NULL;
static char     *opt_target   = NULL;
static gboolean  opt_execute  = FALSE;
static gboolean  opt_list     = FALSE;

static guint commands = 0;

static void
mark (const char *fmt, ...) G_GNUC_PRINTF (1, 2);

static void
mark (const char *fmt, ...)
{
	va_list args;
	va_start (args, fmt);
	g_autofree char *body = g_strdup_vprintf (fmt, args);
	va_end (args);

	/* Flushed immediately. The harness greps a file the guest is still
	 * writing to, and a marker sitting in a stdio buffer when the guest is
	 * killed by a timeout is a marker that never existed. */
	g_print (MARK "%s\n", body);
	fflush (stdout);
}

static void
fail (const char *stage, const char *message)
{
	mark ("FAIL %s: %s", stage, message);
	exit (1);
}

/* A DELIBERATE SAFETY REFUSAL IS NOT A STAGE FAILURE, and the two must not
 * share a marker.
 *
 * The harness asserts both "the refusal happened" and "no stage reported
 * FAIL". While refusing emitted FAIL, a correct run satisfied the first and
 * violated the second with the same line, so every successful run ended in a
 * failed test. The distinction is real -- the installer declining to touch a
 * disk is it working -- so it is carried IN THE DATA rather than recovered by
 * the harness grepping the message text out again.
 *
 * Same principle as `serial=` being emitted empty rather than omitted: say
 * which of the two things happened, do not make the reader infer it.
 *
 * Still a non-zero exit. The invocation did not do what it was asked to do. */
static void
refuse (const char *stage, const char *message)
{
	mark ("REFUSED %s: %s", stage, message);
	exit (1);
}

/* --- backend callbacks ---------------------------------------------------- */

static void
on_log (const char *line, gpointer user_data)
{
	(void) user_data;

	if (g_str_has_prefix (line, "$ "))
		commands++;

	g_print ("    %s\n", line);
	fflush (stdout);
}

static void
on_progress (DuctStage stage, double frac, const char *detail, gpointer user_data)
{
	static DuctStage last = (DuctStage) -1;

	(void) frac;
	(void) user_data;

	/* One line per stage transition, not per step. The serial console is the
	 * only output channel this has and filling it with a line per package
	 * makes the markers hard to find in a failure. */
	if (stage != last) {
		last = stage;
		g_print ("  == %s\n", duct_stage_title (stage));
		fflush (stdout);
	}

	if (detail != NULL && *detail != '\0')
		g_debug ("%s", detail);
}

/* --- answers -------------------------------------------------------------- */

/* GKeyFile rather than TOML.
 *
 * tape's own configuration is TOML, so matching it would be tidier -- but a
 * TOML parser is a dependency, and glib already has a perfectly good key-value
 * parser compiled in. For a file that this program writes the only reader of,
 * tidiness loses to not adding a package to a distribution that has to build
 * everything it ships. */
static DuctInstallConfig *
load_answers (const char *path, GError **error)
{
	g_autoptr (GKeyFile) keys = g_key_file_new ();

	if (!g_key_file_load_from_file (keys, path, G_KEY_FILE_NONE, error))
		return NULL;

	DuctInstallConfig *cfg = duct_install_config_new ();

	/* Every field is optional and falls back to the constructor's default,
	 * which is the value v1 can actually deliver anyway. A missing answer is
	 * not an error here because this is a test fixture, not a provisioning
	 * system -- and that difference is exactly why it is not one. */
	struct { const char *key; char **field; } strings[] = {
		{ "locale",         &cfg->locale     },
		{ "keymap",         &cfg->kb_layout  },
		{ "keymap-variant", &cfg->kb_variant },
		{ "timezone",       &cfg->timezone   },
		{ "hostname",       &cfg->hostname   },
		{ "full-name",      &cfg->full_name  },
		{ "username",       &cfg->username   },
		{ "password",       &cfg->password   },
	};

	for (guint i = 0; i < G_N_ELEMENTS (strings); i++) {
		g_autofree char *value =
			g_key_file_get_string (keys, "install", strings[i].key, NULL);

		if (value == NULL)
			continue;

		g_free (*strings[i].field);
		*strings[i].field = g_steal_pointer (&value);
	}

	g_autoptr (GError) bool_error = NULL;
	gboolean same = g_key_file_get_boolean (keys, "install", "root-password-same", &bool_error);
	if (bool_error == NULL)
		cfg->lock_root = same;

	return cfg;
}

/* --- disks ---------------------------------------------------------------- */

static void
print_disks (GPtrArray *disks)
{
	for (guint i = 0; i < disks->len; i++) {
		const DuctDisk *disk = g_ptr_array_index (disks, i);
		g_autofree char *described = duct_disk_describe (disk);

		g_print ("    %s%s\n", described,
		         disk->is_boot_medium ? "   [live medium — excluded]" : "");
	}

	/* And again, machine-readable, one line per disk.
	 *
	 * This exists so a harness can answer "are serials being reported at all?"
	 * by looking at THE PROBE'S OWN OUTPUT rather than by grepping the console
	 * for the word. An earlier version of the test did the latter and the
	 * probe matched `serial8250: ttyS0` -- the 8250 UART driver's boot banner,
	 * printed on every boot on both architectures, since CONFIG_SERIAL_8250=y
	 * in both kernel fragments. The check for "is this observable" was
	 * satisfied by unrelated kernel output, so the branch that handled the
	 * unobservable case was dead and its place was taken by a false accusation
	 * against the installer.
	 *
	 * `serial=` is empty rather than omitted when a disk has none, so the
	 * distinction between "reported as absent" and "not reported" is carried
	 * in the data instead of inferred from it. */
	for (guint i = 0; i < disks->len; i++) {
		const DuctDisk *disk = g_ptr_array_index (disks, i);

		mark ("disk %s serial=%s%s",
		      disk->node,
		      (disk->serial != NULL) ? disk->serial : "",
		      disk->is_boot_medium ? " excluded=live-medium" : "");
	}

	fflush (stdout);
}

/* Find the requested target among the disks the probe actually returned.
 *
 * The refusal this implements is the point of the whole program: a device node
 * that was typed on a command line, or written into an answers file months
 * ago, is not evidence that the device exists or is what the name suggests. If
 * the probe did not enumerate it, this does not touch it. And if the probe
 * flagged it as the live medium, this does not touch it either -- the same
 * check the disk screen makes, made again here, because the two front ends
 * must not be able to disagree about which disk is untouchable. */
static const DuctDisk *
select_target (GPtrArray *disks, const char *node)
{
	for (guint i = 0; i < disks->len; i++) {
		const DuctDisk *disk = g_ptr_array_index (disks, i);

		if (g_strcmp0 (disk->node, node) != 0)
			continue;

		if (disk->is_boot_medium) {
			g_autofree char *why = g_strdup_printf (
				"%s carries the live medium and will never be installed to", node);
			refuse ("target", why);
		}

		return disk;
	}

	{
		g_autofree char *why = g_strdup_printf (
			"%s was not among the %u disk(s) this system enumerated; refusing to touch it",
			node, disks->len);
		refuse ("target", why);
	}

	return NULL;   /* not reached: fail() exits */
}

/* --- main ----------------------------------------------------------------- */

int
main (int argc, char *argv[])
{
	g_autoptr (GOptionContext) context =
		g_option_context_new ("- install Duct without a display");

	g_option_context_set_summary (context,
		"A test harness for exercising the installer inside a virtual machine,\n"
		"where the graphical installer cannot run. It reads its answers from a\n"
		"file and logs to stdout, which QEMU puts on the serial console.\n"
		"\n"
		"This is NOT unattended installation, and must not be mistaken for it.\n"
		"Unattended installation is an explicit non-goal for Duct v1: it would\n"
		"need a versioned schema for the answers file, a way of handling secrets\n"
		"better than plaintext on disk, and a defined behaviour when an answer is\n"
		"missing or a disk has moved since the file was written. This has none of\n"
		"those. It exists so that one QEMU test can run.");

	g_option_context_set_description (context,
		"The answers file is a key file:\n"
		"\n"
		"  [install]\n"
		"  hostname = duct\n"
		"  username = tester\n"
		"  password = <plaintext — test fixtures only>\n"
		"  locale   = C.UTF-8\n"
		"  keymap   = us\n"
		"  timezone = UTC\n"
		"  root-password-same = true\n"
		"\n"
		"Every key is optional and falls back to the only value v1 can deliver.");

	const GOptionEntry entries[] = {
		{ "answers", 'a', 0, G_OPTION_ARG_FILENAME, &opt_answers,
		  "Key file holding the answers", "FILE" },
		{ "target", 't', 0, G_OPTION_ARG_STRING, &opt_target,
		  "Whole-disk device node to install to. Refused unless this system "
		  "enumerated it.", "DEVICE" },
		{ "execute", 0, 0, G_OPTION_ARG_NONE, &opt_execute,
		  "Actually write to the disk. NOT IMPLEMENTED — there is no destructive "
		  "code in this build.", NULL },
		{ "list-disks", 0, 0, G_OPTION_ARG_NONE, &opt_list,
		  "Probe, print what was found, and exit", NULL },
		{ NULL, 0, 0, 0, NULL, NULL, NULL }
	};

	g_option_context_add_main_entries (context, entries, NULL);

	g_autoptr (GError) error = NULL;
	if (!g_option_context_parse (context, &argc, &argv, &error)) {
		g_printerr ("duct-install-cli: %s\n", error->message);
		return 2;
	}

	/* Refuses to start, rather than quietly doing something safer than asked.
	 *
	 * The same rule as the GUI's --real, for the same reason: a flag that
	 * silently downgrades is how someone later concludes the flag works. There
	 * is no destructive code in this build to gate -- src/backend/real.c does
	 * not exist -- so the honest response is to stop. */
	if (opt_execute) {
		g_printerr ("duct-install-cli: --execute is not implemented.\n"
		            "The destructive backend is unwritten, not disabled: this binary\n"
		            "contains no code that writes to a disk. Run without --execute\n"
		            "for a dry run.\n");
		return 1;
	}

	/* --- probe ------------------------------------------------------------ */

	gboolean simulated = FALSE;
	g_autoptr (GError) probe_error = NULL;
	g_autoptr (GPtrArray) disks = duct_disk_probe (&simulated, &probe_error);

	if (disks == NULL)
		fail ("probe", probe_error->message);

	g_autofree char *boot_disk = duct_disk_boot_medium ();
	guint excluded = 0;

	for (guint i = 0; i < disks->len; i++) {
		const DuctDisk *disk = g_ptr_array_index (disks, i);

		if (!disk->is_boot_medium)
			continue;

		excluded++;

		/* Report the disk that was actually excluded, not just what
		 * duct_disk_boot_medium() returned. The two agree on a live system;
		 * on the simulated fixtures the probe flags a disk while the mount
		 * table lookup returns nothing, and a marker that said "1 excluded,
		 * live medium not identified" in the same line would be reporting
		 * two different things as though they were one. */
		if (boot_disk == NULL)
			boot_disk = g_strdup (disk->node);
	}

	print_disks (disks);

	/* The marker the harness asserts on. It names the excluded disk explicitly
	 * because that is the claim worth checking: in a QEMU guest the ISO is a
	 * whole virtio disk with no partition table, which drives the fallback in
	 * duct_disk_boot_medium() that no other environment reaches. If that
	 * fallback is wrong, this line says so before anything destructive is
	 * possible. */
	mark ("probe ok, %u disk(s), %u excluded, live medium %s%s",
	      disks->len, excluded,
	      boot_disk != NULL ? boot_disk : "not identified",
	      simulated ? " [SIMULATED — no lsblk on this host]" : "");

	if (simulated)
		mark ("WARNING simulated hardware; this run proves nothing about real disks");

	if (opt_list)
		return 0;

	/* --- answers and target ----------------------------------------------- */

	if (opt_answers == NULL)
		fail ("answers", "no --answers file given");

	g_autoptr (GError) answers_error = NULL;
	DuctInstallConfig *cfg = load_answers (opt_answers, &answers_error);
	if (cfg == NULL) {
		/* The PATH, not just the reason. GLib's message for a missing file is
		 * "No such file or directory" with no subject, which read as
		 * `answers: No such file or directory` -- true, and useless to the
		 * only caller there is. This program is driven by a harness that
		 * passes the path in, so the path is the one thing the operator does
		 * not already have in front of them. */
		g_autofree char *why = g_strdup_printf ("%s: %s", opt_answers,
		                                        answers_error->message);
		fail ("answers", why);
	}

	/* VALIDATE THE ANSWERS. The GUI has always checked these on its account
	 * page; this path never did, so a username straight out of a file reached
	 * useradd on the target unchecked -- and this is the path a script uses
	 * unattended, which is the one least likely to have a human notice a bad
	 * value.
	 *
	 * A FAIL rather than a REFUSED: a malformed answers file is something
	 * wrong, not the installer declining to touch a disk. */
	{
		const char *why = NULL;

		if (!duct_username_is_valid (cfg->username, &why))
			fail ("answers", why);
		if (!duct_hostname_is_valid (cfg->hostname, &why))
			fail ("answers", why);
	}

	if (opt_target == NULL)
		fail ("target", "no --target device given");

	const DuctDisk *disk = select_target (disks, opt_target);

	g_free (cfg->disk);
	cfg->disk = g_strdup (disk->node);

	g_autofree char *described = duct_disk_describe (disk);
	mark ("target %s", described);

	/* --- plan -------------------------------------------------------------- */

	g_autoptr (GError) plan_error = NULL;
	DuctPartitionPlan *plan = duct_partition_plan (disk, &plan_error);
	if (plan == NULL) {
		/* Asked of the backend rather than decided here. A disk that is too
		 * small, or that turns out to carry the live medium after all, is
		 * declined -- not a stage that went wrong -- and a marker whose
		 * meaning depended on which function emitted it would not be a
		 * marker at all. */
		if (duct_error_is_refusal (plan_error))
			refuse ("plan", plan_error->message);
		else
			fail ("plan", plan_error->message);
	}

	mark ("plan esp=%s root=%s", plan->esp_node, plan->root_node);

	/* --- run --------------------------------------------------------------- */

	DuctBackend *backend = duct_backend_dryrun_new ();
	backend->log      = on_log;
	backend->progress = on_progress;

	g_autoptr (GError) run_error = NULL;
	gboolean ok = duct_backend_run (backend, cfg, plan, &run_error);

	if (!ok) {
		mark ("FAIL run: %s", run_error->message);
		duct_backend_free (backend);
		duct_install_config_free (cfg);
		duct_partition_plan_free (plan);
		return 1;
	}

	mark ("dry run complete, %u commands, nothing written", commands);

	duct_backend_free (backend);
	duct_install_config_free (cfg);
	duct_partition_plan_free (plan);

	return 0;
}

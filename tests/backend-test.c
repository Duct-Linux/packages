/* Exercises the half of the program that can destroy data, with no GTK
 * involved. These are the properties the safety model claims; a claim in a
 * design document that nothing checks is a wish.
 */

#include "backend/backend.h"

#include <gio/gio.h>
#include <stdio.h>
#include <string.h>

static guint failures = 0;

#define CHECK(cond, what) G_STMT_START {                     \
	if (cond) {                                              \
		g_print ("  ok    %s\n", (what));                    \
	} else {                                                 \
		g_print ("  FAIL  %s\n", (what));                    \
		failures++;                                          \
	}                                                        \
} G_STMT_END

static void
test_probe (void)
{
	g_print ("probe\n");

	gboolean simulated = FALSE;
	g_autoptr (GError) error = NULL;
	g_autoptr (GPtrArray) disks = duct_disk_probe (&simulated, &error);

	CHECK (disks != NULL, "probe returns a list");
	if (disks == NULL)
		return;

	CHECK (disks->len > 0, "the list is not empty");

	guint boot_media = 0;
	for (guint i = 0; i < disks->len; i++) {
		const DuctDisk *disk = g_ptr_array_index (disks, i);
		g_autofree char *described = duct_disk_describe (disk);

		g_print ("        %s%s\n", described,
		         disk->is_boot_medium ? "   [live medium — never offered]" : "");

		if (disk->is_boot_medium)
			boot_media++;

		/* Rule 3 of the safety model: every disk is describable in full. */
		CHECK (strstr (described, disk->node) != NULL, "the description names the device node");
		CHECK (strstr (described, "bytes") != NULL, "the description gives an exact byte count");
	}

	CHECK (boot_media <= 1, "at most one disk is flagged as the live medium");
}

static void
test_boot_medium_is_refused (void)
{
	g_print ("the live medium cannot be planned for\n");

	DuctDisk disk = {
		.node           = (char *) "/dev/sdb",
		.model          = (char *) "SanDisk Ultra USB 3.0",
		.size           = 31037849600ULL,
		.is_boot_medium = TRUE,
	};

	g_autoptr (GError) error = NULL;
	DuctPartitionPlan *plan = duct_partition_plan (&disk, &error);

	CHECK (plan == NULL, "planning is refused");
	CHECK (error != NULL, "and says why");
	if (error != NULL)
		g_print ("        \"%s\"\n", error->message);

	duct_partition_plan_free (plan);
}

static void
test_small_disk_is_refused (void)
{
	g_print ("a disk too small to hold Duct is refused\n");

	DuctDisk disk = {
		.node  = (char *) "/dev/sdz",
		.model = (char *) "Tiny",
		.size  = 4ULL * 1024 * 1024 * 1024,
	};

	g_autoptr (GError) error = NULL;
	DuctPartitionPlan *plan = duct_partition_plan (&disk, &error);

	CHECK (plan == NULL, "planning is refused");
	if (error != NULL)
		g_print ("        \"%s\"\n", error->message);

	duct_partition_plan_free (plan);
}

static void
test_partition_naming (void)
{
	g_print ("partition node naming\n");

	struct { const char *disk; const char *esp; const char *root; } cases[] = {
		{ "/dev/sda",     "/dev/sda1",     "/dev/sda2"     },
		{ "/dev/nvme0n1", "/dev/nvme0n1p1", "/dev/nvme0n1p2" },
		{ "/dev/mmcblk0", "/dev/mmcblk0p1", "/dev/mmcblk0p2" },
	};

	for (guint i = 0; i < G_N_ELEMENTS (cases); i++) {
		DuctDisk disk = {
			.node = (char *) cases[i].disk,
			.size = 500ULL * 1000 * 1000 * 1000,
		};

		g_autoptr (GError) error = NULL;
		DuctPartitionPlan *plan = duct_partition_plan (&disk, &error);

		if (plan == NULL) {
			g_print ("  FAIL  %s did not plan: %s\n", cases[i].disk, error->message);
			failures++;
			continue;
		}

		CHECK (g_strcmp0 (plan->esp_node, cases[i].esp) == 0, cases[i].esp);
		CHECK (g_strcmp0 (plan->root_node, cases[i].root) == 0, cases[i].root);

		duct_partition_plan_free (plan);
	}
}

/* --- a whole dry run ----------------------------------------------------- */

static void
log_line (const char *line, gpointer user_data)
{
	guint *count = user_data;

	(*count)++;
	g_print ("    %s\n", line);
}

/* A refusal must be classifiable as one. The CLI prints REFUSED rather than
 * FAIL on the strength of this, and the difference is what a user reads when
 * the installer correctly declines their too-small disk. */
/* --- the boot-medium fallback, which had never executed -------------------- */

/* A resolver backed by a table instead of /sys, so the branch that decides
 * "this source has no parent, therefore it IS the disk" can be reached on any
 * machine. Entries are pairs: kernel name, parent node or NULL. */
static char *
fake_parent (const char *kernel_name, gpointer user_data)
{
	const char * const *table = user_data;

	for (guint i = 0; table[i] != NULL; i += 2) {
		if (g_strcmp0 (table[i], kernel_name) == 0)
			return table[i + 1] ? g_strdup (table[i + 1]) : NULL;
	}
	return NULL;
}

static void
test_boot_medium_detection (void)
{
	g_print ("identifying the live medium\n");

	/* Real mountinfo shapes. The optional-fields section before the "-" is
	 * variable length on purpose in two of them, because that is the reason
	 * the parser looks for the separator rather than counting fields. */
	const char *qemu_iso =
		"21 1 0:20 / /run/live/medium ro,relatime - iso9660 /dev/vda ro\n";
	const char *usb_partition =
		"19 1 8:17 / /proc rw,relatime - proc proc rw\n"
		"21 1 8:17 / /run/live/medium ro,relatime shared:2 - vfat /dev/sdb1 ro\n";
	const char *nvme_partition =
		"21 1 259:3 / /run/live/medium ro,relatime - ext4 /dev/nvme0n1p3 ro\n";
	const char *no_medium =
		"19 1 0:5 / /proc rw,relatime - proc proc rw\n"
		"20 1 0:6 / /sys rw,relatime - sysfs sysfs rw\n";
	const char *not_a_device =
		"21 1 0:20 / /run/live/medium ro,relatime - overlay overlay ro\n";

	const char *parents[] = {
		"vda",        NULL,            /* whole disk, no partition table */
		"sdb1",       "/dev/sdb",
		"nvme0n1p3",  "/dev/nvme0n1",
		NULL
	};

	struct { const char *what; const char *mountinfo; const char *expect; } cases[] = {
		/* THE CASE THAT HAD NEVER RUN. A QEMU virtio disk carrying ISO9660
		 * directly: no parent, so the source itself is the disk to exclude.
		 * If this returned NULL the installer would offer the live medium. */
		{ "whole disk with no partition table -> itself", qemu_iso,      "/dev/vda" },
		{ "partition on a USB stick -> its parent disk",  usb_partition, "/dev/sdb" },
		{ "nvme partition -> its parent disk",            nvme_partition,"/dev/nvme0n1" },
		{ "no live medium mounted -> nothing",            no_medium,      NULL },
		{ "source is not a device -> nothing",            not_a_device,   NULL },
	};

	for (guint i = 0; i < G_N_ELEMENTS (cases); i++) {
		g_autofree char *got =
			duct_disk_boot_medium_from (cases[i].mountinfo, fake_parent, parents);

		gboolean ok = (cases[i].expect == NULL)
			? (got == NULL)
			: (g_strcmp0 (got, cases[i].expect) == 0);

		if (ok) {
			g_print ("  ok    %s\n", cases[i].what);
		} else {
			g_print ("  FAIL  %s (got %s, expected %s)\n", cases[i].what,
			         got ? got : "NULL", cases[i].expect ? cases[i].expect : "NULL");
			failures++;
		}
	}

	/* Empty input must not be mistaken for "no medium found" by accident --
	 * it reaches the same answer through a different path and should. */
	g_autofree char *empty = duct_disk_boot_medium_from ("", fake_parent, parents);
	CHECK (empty == NULL, "empty mountinfo yields no medium");
	g_autofree char *null_in = duct_disk_boot_medium_from (NULL, fake_parent, parents);
	CHECK (null_in == NULL, "NULL mountinfo yields no medium");
}

static void
test_refusals_are_classified (void)
{
	g_print ("refusals are distinguishable from failures\n");

	DuctDisk small = { .node = (char *) "/dev/sdz", .model = (char *) "Tiny",
	                   .size = 4ULL * 1024 * 1024 * 1024 };
	DuctDisk medium = { .node = (char *) "/dev/sdb", .model = (char *) "Stick",
	                    .size = 31037849600ULL, .is_boot_medium = TRUE };

	g_autoptr (GError) e1 = NULL;
	duct_partition_plan (&small, &e1);
	CHECK (duct_error_is_refusal (e1), "a disk too small is a refusal, not a failure");

	g_autoptr (GError) e2 = NULL;
	duct_partition_plan (&medium, &e2);
	CHECK (duct_error_is_refusal (e2), "the live medium is a refusal, not a failure");

	/* And something that genuinely went wrong is not reclassified. */
	g_autoptr (GError) other = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_FAILED,
	                                                "something broke");
	CHECK (!duct_error_is_refusal (other), "an ordinary error is still a failure");
	CHECK (!duct_error_is_refusal (NULL), "no error is not a refusal");
}

static void
test_dry_run_writes_nothing (void)
{
	g_print ("a complete dry run\n");

	DuctDisk disk = {
		.node   = (char *) "/dev/nvme0n1",
		.model  = (char *) "Samsung SSD 990 PRO 2TB",
		.serial = (char *) "S6B0NJ0T512345",
		.size   = 2000398934016ULL,
	};

	g_autoptr (GError) error = NULL;
	DuctPartitionPlan *plan = duct_partition_plan (&disk, &error);
	g_assert_nonnull (plan);

	DuctInstallConfig *cfg = duct_install_config_new ();
	cfg->username = g_strdup ("yanick");
	cfg->password = g_strdup ("hunter2hunter2");
	cfg->disk     = g_strdup (disk.node);

	guint lines = 0;
	DuctBackend *backend = duct_backend_dryrun_new ();
	backend->log       = log_line;
	backend->user_data = &lines;

	gboolean ok = duct_backend_run (backend, cfg, plan, &error);

	CHECK (ok, "the run completes");
	CHECK (lines > 30, "and logs a substantial number of commands");

	duct_backend_free (backend);
	duct_install_config_free (cfg);
	duct_partition_plan_free (plan);
}

static void
test_real_backend_refuses (void)
{
	g_print ("the real backend does not exist yet\n");

	g_autoptr (GError) error = NULL;
	DuctBackend *backend = duct_backend_real_new (&error);

	CHECK (backend == NULL, "constructing it fails");
	CHECK (error != NULL, "with an explanation rather than silently");
	if (error != NULL)
		g_print ("        \"%s\"\n", error->message);
}

static void
test_stage_weights (void)
{
	g_print ("progress weighting\n");

	double total = 0.0;
	for (guint i = 0; i < DUCT_N_STAGES; i++)
		total += duct_stage_weight ((DuctStage) i);

	CHECK (ABS (total - 1.0) < 1e-9, "the stage weights sum to 1.0");
	CHECK (duct_stage_weight (DUCT_STAGE_COPY) > 0.5,
	       "the copy dominates, so the bar does not stall at the end");
}

int
main (void)
{
	test_probe ();
	test_boot_medium_is_refused ();
	test_small_disk_is_refused ();
	test_partition_naming ();
	test_stage_weights ();
	test_real_backend_refuses ();
	test_boot_medium_detection ();
	test_refusals_are_classified ();
	test_dry_run_writes_nothing ();

	if (failures > 0) {
		g_printerr ("\n%u check(s) failed\n", failures);
		return 1;
	}

	g_print ("\nall checks passed\n");
	return 0;
}

/* Enumerating disks, identifying the one we must never touch, and computing
 * the partition plan.
 *
 * Nothing here writes anything. Probing reads /proc and /sys and runs lsblk;
 * planning is a pure function. Both are safe to call before the user has
 * confirmed anything, which is the point: everything that can be worked out
 * without touching the disk is worked out before the disk is touched.
 */

#include "backend/backend.h"

#include <gio/gio.h>
#include <string.h>

void
duct_disk_free (DuctDisk *disk)
{
	if (disk == NULL)
		return;

	g_free (disk->node);
	g_free (disk->model);
	g_free (disk->serial);
	g_free (disk);
}

char *
duct_disk_format_size (guint64 bytes)
{
	/* Decimal GB/TB, because that is what is printed on the drive, and the
	 * exact byte count alongside it, because that is what identifies it.
	 * A confirmation dialog that says only "2 TB" has not identified anything
	 * on a machine with two 2 TB disks. */
	static const char *units[] = { "bytes", "kB", "MB", "GB", "TB", "PB" };
	double  value = (double) bytes;
	guint   unit  = 0;

	while (value >= 1000.0 && unit < G_N_ELEMENTS (units) - 1) {
		value /= 1000.0;
		unit++;
	}

	g_autofree char *grouped = g_strdup_printf ("%" G_GUINT64_FORMAT, bytes);

	if (unit == 0)
		return g_strdup_printf ("%s bytes", grouped);

	return g_strdup_printf ("%.1f %s (%s bytes)", value, units[unit], grouped);
}

char *
duct_disk_describe (const DuctDisk *disk)
{
	g_return_val_if_fail (disk != NULL, NULL);

	g_autofree char *size = duct_disk_format_size (disk->size);

	/* Model, node and size, every time. This string is what stands between a
	 * user and the wrong disk, so it never abbreviates. */
	if (disk->serial != NULL && *disk->serial != '\0')
		return g_strdup_printf ("%s — %s, serial %s — %s",
		                        disk->model ? disk->model : "Unknown model",
		                        disk->node, disk->serial, size);

	return g_strdup_printf ("%s — %s — %s",
	                        disk->model ? disk->model : "Unknown model",
	                        disk->node, size);
}

/* --- the boot medium ----------------------------------------------------- */

/* Turn a partition's kernel name into its parent disk's node.
 *
 * /sys/class/block/<part> is a symlink into the device tree whose parent
 * directory is the whole disk, so readlink and take the second-to-last
 * component. That handles nvme0n1p3 -> nvme0n1 and sda1 -> sda without
 * having to know either naming scheme, which string-stripping would. */
static char *
parent_disk_of (const char *kernel_name)
{
	g_autofree char *link = g_strdup_printf ("/sys/class/block/%s", kernel_name);
	g_autofree char *real = g_file_read_link (link, NULL);

	if (real == NULL)
		return NULL;

	g_autofree char *dir  = g_path_get_dirname (real);
	g_autofree char *base = g_path_get_basename (dir);

	/* When <part> is already a whole disk its parent is the controller, not
	 * another block device -- so only accept a name that is itself in
	 * /sys/class/block. */
	g_autofree char *check = g_strdup_printf ("/sys/class/block/%s", base);
	if (!g_file_test (check, G_FILE_TEST_EXISTS))
		return NULL;

	return g_strdup_printf ("/dev/%s", base);
}

/* The real resolver: /sys/class/block/<name> is a symlink into the device
 * tree whose parent directory is the whole disk. */
static char *
sysfs_parent (const char *kernel_name, gpointer user_data)
{
	(void) user_data;
	return parent_disk_of (kernel_name);
}

char *
duct_disk_boot_medium_from (const char        *mountinfo,
                            DuctParentResolver resolve_parent,
                            gpointer           user_data)
{
	g_return_val_if_fail (resolve_parent != NULL, NULL);

	if (mountinfo == NULL)
		return NULL;

	g_auto (GStrv) lines = g_strsplit (mountinfo, "\n", -1);

	for (guint i = 0; lines[i] != NULL; i++) {
		/* mountinfo: id parent maj:min root MOUNTPOINT opts... - fstype SOURCE super */
		g_auto (GStrv) fields = g_strsplit (lines[i], " ", -1);
		guint n = g_strv_length (fields);

		if (n < 10 || g_strcmp0 (fields[4], "/run/live/medium") != 0)
			continue;

		/* Find the "-" separator rather than counting to it: the optional
		 * fields before it are variable length, which is the whole reason
		 * mountinfo has a separator at all. */
		for (guint j = 6; j + 2 < n; j++) {
			if (g_strcmp0 (fields[j], "-") != 0)
				continue;

			const char *source = fields[j + 2];
			if (!g_str_has_prefix (source, "/dev/"))
				return NULL;

			g_autofree char *kernel_name = g_path_get_basename (source);
			char *parent = resolve_parent (kernel_name, user_data);

			/* NO PARENT MEANS THE SOURCE IS ITSELF A WHOLE DISK. A USB stick
			 * dd'd with the ISO and mounted as /dev/sdb, or a QEMU virtio disk
			 * holding ISO9660 directly. Returning NULL here would leave the
			 * medium unexcluded and offerable as a target. */
			return parent != NULL ? parent : g_strdup (source);
		}
	}

	return NULL;
}

char *
duct_disk_boot_medium (void)
{
	/* The initramfs mounts the live medium at /run/live/medium and leaves it
	 * mounted for the life of the system -- packages/pkgs/duct-live/files/
	 * initramfs-init, and images/iso/build-iso.sh says so explicitly. So the
	 * mount table is the authority on which device we booted from; there is no
	 * need to guess from labels. */
	g_autofree char *mountinfo = NULL;

	if (!g_file_get_contents ("/proc/self/mountinfo", &mountinfo, NULL, NULL))
		return NULL;   /* not Linux, or no procfs: the caller treats this as "unknown" */

	return duct_disk_boot_medium_from (mountinfo, sysfs_parent, NULL);
}

/* --- probing ------------------------------------------------------------- */

static DuctDisk *
disk_new (const char *node, const char *model, const char *serial,
          guint64 size, gboolean removable)
{
	DuctDisk *disk = g_new0 (DuctDisk, 1);

	disk->node      = g_strdup (node);
	disk->model     = g_strdup (model);
	disk->serial    = g_strdup (serial);
	disk->size      = size;
	disk->removable = removable;

	return disk;
}

/* The fixture set, used when this host has no lsblk.
 *
 * This exists so the whole flow -- including the boot-medium exclusion, which
 * is the part most worth exercising -- can be walked through on a development
 * machine. It is never silently substituted: probe() reports that it did, and
 * the disk screen puts a banner across the top saying so. An installer that
 * quietly showed made-up hardware would be an unforgivable thing to ship. */
static GPtrArray *
probe_simulated (void)
{
	GPtrArray *disks = g_ptr_array_new_with_free_func ((GDestroyNotify) duct_disk_free);

	g_ptr_array_add (disks, disk_new ("/dev/nvme0n1", "Samsung SSD 990 PRO 2TB",
	                                  "S6B0NJ0T512345", 2000398934016ULL, FALSE));
	g_ptr_array_add (disks, disk_new ("/dev/sda", "WDC WD10EZEX-08WN4A0",
	                                  "WD-WCC6Y1234567", 1000204886016ULL, FALSE));

	/* The live USB stick. Flagged, so the exclusion path is exercised rather
	 * than merely written. */
	DuctDisk *stick = disk_new ("/dev/sdb", "SanDisk Ultra USB 3.0",
	                            "4C530001234567890123", 31037849600ULL, TRUE);
	stick->is_boot_medium = TRUE;
	g_ptr_array_add (disks, stick);

	return disks;
}

static gboolean
run_lsblk (char **stdout_out, GError **error)
{
	/* Not on anything that is not Linux, and the check comes before the spawn
	 * rather than relying on the spawn to fail.
	 *
	 * This program is developed on a macOS laptop that must never be touched,
	 * and "lsblk does not exist there so the spawn fails harmlessly" is a
	 * property of the host, not of this code. Enumerating block devices is the
	 * first step of something destructive; it should not be attempted at all
	 * on a machine that is not the target. On a live Duct system /proc is
	 * mounted by the initramfs before anything else runs. */
	if (!g_file_test ("/proc/self/mountinfo", G_FILE_TEST_EXISTS)) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED,
		                     "not a Linux system: block devices will not be enumerated");
		return FALSE;
	}

	/* -b for bytes (never parse "1.8T"), -J for JSON, -d for whole disks only,
	 * -n so there is no header to skip. */
	const char *argv[] = {
		"lsblk", "-J", "-b", "-d", "-n",
		"-o", "NAME,SIZE,MODEL,SERIAL,TYPE,RM",
		NULL
	};

	int exit_status = 0;

	if (!g_spawn_sync (NULL, (char **) argv, NULL,
	                   G_SPAWN_SEARCH_PATH | G_SPAWN_STDERR_TO_DEV_NULL,
	                   NULL, NULL, stdout_out, NULL, &exit_status, error))
		return FALSE;

	if (!g_spawn_check_wait_status (exit_status, error)) {
		g_clear_pointer (stdout_out, g_free);
		return FALSE;
	}

	return TRUE;
}

static void
parse_lsblk_into (const char *json, const char *boot_disk, GPtrArray *disks, GError **error)
{
	/* Deliberately not pulling in json-glib: it is not packaged, and adding a
	 * package to parse one command's output would be a poor trade when the
	 * output is this regular. This is a small hand parser over lsblk's object
	 * list, and it is strict -- anything it does not understand is skipped
	 * rather than guessed at, because a misparsed size or node here is a
	 * wrong disk in a confirmation dialog.
	 *
	 * If json-glib is ever packaged for another reason, replace this. */
	/* Start INSIDE the array, not at the first brace in the document.
	 *
	 * The first `{` in lsblk's output is the top-level wrapper, and the first
	 * `}` is the end of the first DEVICE. Scanning from the document start
	 * therefore made the first "object" span the wrapper plus device one, so
	 * its "name" key parsed as `{ "blockdevices"` and the device was dropped
	 * for having no name -- SILENTLY, because a row without a name is exactly
	 * what this parser is supposed to skip.
	 *
	 * The result was that the FIRST BLOCK DEVICE ON EVERY MACHINE WAS INVISIBLE
	 * to the installer. It survived a day undetected because the only test of
	 * the probe used the simulated fixtures, which never reach this function.
	 */
	const char *p = strchr (json, '[');

	if (p == NULL) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
		                     "lsblk output has no device array");
		return;
	}

	while ((p = strchr (p, '{')) != NULL) {
		const char *end = strchr (p, '}');
		if (end == NULL)
			break;

		g_autofree char *object = g_strndup (p, (gsize) (end - p) + 1);
		p = end + 1;

		g_autofree char *name   = NULL;
		g_autofree char *model  = NULL;
		g_autofree char *serial = NULL;
		g_autofree char *type   = NULL;
		guint64  size = 0;
		gboolean removable = FALSE;
		gboolean have_size = FALSE;

		g_auto (GStrv) fields = g_strsplit (object, ",", -1);

		for (guint i = 0; fields[i] != NULL; i++) {
			g_auto (GStrv) kv = g_strsplit (fields[i], ":", 2);
			if (g_strv_length (kv) != 2)
				continue;

			g_strstrip (kv[0]);
			g_strstrip (kv[1]);

			g_autofree char *key = g_strdup (g_strdelimit (kv[0], "{\"", ' '));
			g_autofree char *val = g_strdup (g_strdelimit (kv[1], "}\"", ' '));
			g_strstrip (key);
			g_strstrip (val);

			if (g_strcmp0 (key, "name") == 0)
				name = g_steal_pointer (&val);
			else if (g_strcmp0 (key, "model") == 0)
				model = g_steal_pointer (&val);
			else if (g_strcmp0 (key, "serial") == 0)
				serial = g_steal_pointer (&val);
			else if (g_strcmp0 (key, "type") == 0)
				type = g_steal_pointer (&val);
			else if (g_strcmp0 (key, "rm") == 0)
				removable = (g_strcmp0 (val, "true") == 0 || g_strcmp0 (val, "1") == 0);
			else if (g_strcmp0 (key, "size") == 0) {
				char *tail = NULL;
				size = g_ascii_strtoull (val, &tail, 10);
				have_size = (tail != val);
			}
		}

		/* Skip anything that is not a whole disk, and anything whose size did
		 * not parse -- a disk we cannot size is a disk we cannot describe, and
		 * offering it would break rule 3 of the safety model. */
		if (name == NULL || !have_size || size == 0)
			continue;
		if (type != NULL && *type != '\0' && g_strcmp0 (type, "disk") != 0)
			continue;

		g_autofree char *node = g_strdup_printf ("/dev/%s", name);
		DuctDisk *disk = disk_new (node,
		                           (model != NULL && *model != '\0') ? model : NULL,
		                           serial, size, removable);

		disk->is_boot_medium = (boot_disk != NULL && g_strcmp0 (node, boot_disk) == 0);
		g_ptr_array_add (disks, disk);
	}

	if (disks->len == 0)
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_NOT_FOUND,
		                     "lsblk reported no disks");
}

GPtrArray *
duct_disk_parse_lsblk (const char *json, const char *boot_disk, GError **error)
{
	GPtrArray *disks = g_ptr_array_new_with_free_func ((GDestroyNotify) duct_disk_free);
	g_autoptr (GError) parse_error = NULL;

	parse_lsblk_into (json, boot_disk, disks, &parse_error);

	if (parse_error != NULL) {
		g_propagate_error (error, g_steal_pointer (&parse_error));
		g_ptr_array_unref (disks);
		return NULL;
	}

	return disks;
}

GPtrArray *
duct_disk_probe (gboolean *simulated, GError **error)
{
	g_autofree char *json = NULL;
	g_autoptr (GError) spawn_error = NULL;

	if (simulated != NULL)
		*simulated = FALSE;

	if (!run_lsblk (&json, &spawn_error)) {
		/* No lsblk: a development machine, not a live ISO. Say so and hand
		 * back the fixtures rather than failing, so the flow can be walked. */
		if (simulated != NULL)
			*simulated = TRUE;
		return probe_simulated ();
	}

	g_autofree char *boot_disk = duct_disk_boot_medium ();

	GPtrArray *disks = g_ptr_array_new_with_free_func ((GDestroyNotify) duct_disk_free);
	g_autoptr (GError) parse_error = NULL;

	parse_lsblk_into (json, boot_disk, disks, &parse_error);

	if (parse_error != NULL) {
		g_propagate_error (error, g_steal_pointer (&parse_error));
		g_ptr_array_unref (disks);
		return NULL;
	}

	return disks;
}

/* --- the plan ------------------------------------------------------------ */

/* 1 GiB. Larger than the customary 512 MiB on purpose: it costs nothing on any
 * disk big enough to install to, and an ESP that runs out of room during a
 * kernel update is a repair job done from a rescue medium. */
#define ESP_SIZE ((guint64) 1024 * 1024 * 1024)

/* Below this there is no point offering the disk at all: 1 GiB of ESP, and a
 * root that has to hold the package set with room to boot afterwards. */
#define MIN_DISK_SIZE ((guint64) 12 * 1024 * 1024 * 1024)

/* nvme0n1 and mmcblk0 number their partitions nvme0n1p1; sda numbers them
 * sda1. The rule is "a trailing digit takes a p", which covers both families
 * and loop devices too. */
static char *
partition_node (const char *disk, guint index)
{
	gsize len = strlen (disk);
	gboolean needs_p = (len > 0 && g_ascii_isdigit (disk[len - 1]));

	return g_strdup_printf ("%s%s%u", disk, needs_p ? "p" : "", index);
}

gboolean
duct_error_is_refusal (const GError *error)
{
	if (error == NULL)
		return FALSE;

	/* The two codes duct_partition_plan uses to decline. Matched on the code
	 * rather than on the message, so rewording a message cannot silently
	 * reclassify a refusal as a failure.
	 *
	 * PERMISSION_DENIED: the disk carries the live medium.
	 * NO_SPACE:          the disk is too small to hold Duct. */
	return g_error_matches (error, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED)
	    || g_error_matches (error, G_IO_ERROR, G_IO_ERROR_NO_SPACE);
}

DuctPartitionPlan *
duct_partition_plan (const DuctDisk *disk, GError **error)
{
	g_return_val_if_fail (disk != NULL, NULL);

	/* Belt and braces. The UI never puts the boot medium in the list, but this
	 * is the last place the plan can be refused before anything is written,
	 * and a device can be hot-plugged between probe and confirm. */
	if (disk->is_boot_medium) {
		g_set_error (error, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED,
		             "%s is the disk this live system booted from and cannot be installed to",
		             disk->node);
		return NULL;
	}

	if (disk->size < MIN_DISK_SIZE) {
		g_autofree char *have = duct_disk_format_size (disk->size);
		g_autofree char *need = duct_disk_format_size (MIN_DISK_SIZE);
		g_set_error (error, G_IO_ERROR, G_IO_ERROR_NO_SPACE,
		             "%s is %s; Duct needs at least %s", disk->node, have, need);
		return NULL;
	}

	DuctPartitionPlan *plan = g_new0 (DuctPartitionPlan, 1);

	plan->disk      = g_strdup (disk->node);
	plan->esp_node  = partition_node (disk->node, 1);
	plan->root_node = partition_node (disk->node, 2);
	plan->esp_size  = ESP_SIZE;

	/* Random rather than derived. Two Duct disks in one machine must not end
	 * up with the same PARTUUID -- the kernel resolves root=PARTUUID= by
	 * scanning partition tables, and a duplicate means it can boot the wrong
	 * one. Deriving them from the device node would produce exactly that
	 * collision on two identical machines cloned from one image.
	 *
	 * Generated once, at plan time, so the value shown on the summary screen
	 * is the value that gets written. */
	plan->esp_partuuid  = g_uuid_string_random ();
	plan->root_partuuid = g_uuid_string_random ();

	/* One MiB for the GPT and alignment at each end. sfdisk would work this
	 * out itself; doing it here means the summary can show a root size that
	 * matches what will exist, rather than one that is 2 MiB optimistic. */
	plan->root_size = disk->size - ESP_SIZE - (2 * 1024 * 1024);

	return plan;
}

void
duct_partition_plan_free (DuctPartitionPlan *plan)
{
	if (plan == NULL)
		return;

	g_free (plan->disk);
	g_free (plan->esp_node);
	g_free (plan->root_node);
	g_free (plan->esp_partuuid);
	g_free (plan->root_partuuid);
	g_free (plan);
}

char *
duct_partition_plan_script (const DuctPartitionPlan *plan)
{
	g_return_val_if_fail (plan != NULL, NULL);

	/* sfdisk's own script format, which is what will be piped to it. Shown in
	 * the summary so that what is about to be written is visible before it is.
	 *
	 * The type GUIDs are spelled out rather than using sfdisk's shorthand: the
	 * shorthand ("U" for ESP) is convenient and unreadable, and this string is
	 * meant to be checked by a human.
	 *
	 * The root type is the generic Linux filesystem GUID rather than one of
	 * the discoverable-partitions architecture GUIDs, because nothing in Duct
	 * implements discoverable partitions and claiming otherwise in the table
	 * would be a lie a future tool might believe.
	 *
	 * The uuid= fields are what make the whole bootloader story work without
	 * an initramfs: the kernel resolves root=PARTUUID= by reading the GPT
	 * directly, so writing the value here means grub.cfg can be generated
	 * from the plan with no probe of the disk afterwards. */
	return g_strdup_printf (
		"label: gpt\n"
		"device: %s\n"
		"unit: sectors\n"
		"\n"
		"%s : size=%" G_GUINT64_FORMAT ", type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, uuid=%s, name=\"EFI System\"\n"
		"%s : type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=%s, name=\"Duct root\"\n",
		plan->disk,
		plan->esp_node, plan->esp_size / 512, plan->esp_partuuid,
		plan->root_node, plan->root_partuuid);
}

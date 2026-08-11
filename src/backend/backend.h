/* The interface between the installer's UI and everything that touches a disk.
 *
 * There is no GTK below this line, and there must not be. The whole process
 * runs as root -- Duct has no polkit, so there is no privilege separation
 * between the widgets and the block devices -- which makes it worth being able
 * to read the dangerous half on its own.
 *
 * Two implementations:
 *
 *   duct_backend_dryrun_new()  records what it would have run and touches
 *                              nothing. The default, and the only one that
 *                              exists today.
 *   duct_backend_real_new()    executes. Not written yet, and deliberately so:
 *                              the dry-run path is the specification the real
 *                              one has to match.
 */

#pragma once

#include <glib.h>

G_BEGIN_DECLS

/* --- what the screens collect ------------------------------------------- */

typedef struct {
	/* Screen 2. One entry today; see GAP-ANALYSIS.md on glibc locales. */
	char *locale;

	/* Screen 3. X11 layout and variant, as xkeyboard-config names them. */
	char *kb_layout;
	char *kb_variant;

	/* Screen 4. The kernel device node of the whole disk, e.g. /dev/nvme0n1. */
	char *disk;

	/* Screen 5. An IANA zone name. UTC today; see GAP-ANALYSIS.md on tzdata. */
	char *timezone;

	/* Screen 6. */
	char *full_name;
	char *username;
	char *password;
	char *hostname;
	gboolean lock_root; /* TRUE: root has no password, use su from the user */
	char *root_password; /* only when !lock_root */
} DuctInstallConfig;

DuctInstallConfig *duct_install_config_new  (void);
void               duct_install_config_free (DuctInstallConfig *cfg);

/* --- disks --------------------------------------------------------------- */

typedef struct {
	char    *node;      /* /dev/nvme0n1 */
	char    *model;     /* "Samsung SSD 990 PRO 2TB" */
	char    *serial;    /* may be NULL */
	guint64  size;      /* bytes */
	gboolean removable;

	/* TRUE when this disk carries the live medium. Such a disk is never
	 * offered: it is left out of the list entirely rather than shown
	 * disabled, and the disk screen says which one it dropped and why. */
	gboolean is_boot_medium;
} DuctDisk;

void duct_disk_free (DuctDisk *disk);

/* Human-readable size: "2.0 TB (2,000,398,934,016 bytes)".
 * Both units on purpose -- a confirmation that says only "2 TB" has not
 * really identified anything. */
char *duct_disk_format_size (guint64 bytes);

/* One line naming a disk in full, for confirmations and summaries. */
char *duct_disk_describe (const DuctDisk *disk);

/* Probe every whole disk on the system.
 *
 * Returns a GPtrArray of DuctDisk*, boot medium included and flagged; it is
 * the caller's job to drop it from the list. `simulated` is set when this host
 * has no lsblk and the fixture set was returned instead -- which is how the
 * flow is exercised on a development machine, and which the UI states plainly
 * rather than pretending. */
GPtrArray *duct_disk_probe (gboolean *simulated, GError **error);

/* The parse, separated from the command that produces the text.
 *
 * This decides EVERY FIELD THE USER READS IN THE CONFIRMATION DIALOG -- node,
 * size, model, serial -- and it sets is_boot_medium, which decides whether the
 * disk the installer booted from is offered as a target. It is a hand-rolled
 * parser rather than json-glib, because json-glib is not packaged and adding a
 * package to parse one command's output is a poor trade.
 *
 * It touches no filesystem, so it is testable anywhere, and it was not tested
 * at all until this was exported -- it sat behind an lsblk spawn and inherited
 * that command's untestability without having any of its own.
 *
 * WHAT TESTS OF THIS DO AND DO NOT PROVE. They exercise the parser against a
 * MODEL of lsblk's output, not against lsblk. A field this model does not
 * anticipate -- a null model, a name containing a space, a size emitted as a
 * quoted string by a version that does it differently -- passes every test here
 * and still misparses in the guest. THE SPLIT SHRINKS THE VM-ONLY SURFACE; IT
 * DOES NOT ELIMINATE IT, and what remains is exactly the seam between this
 * function and the command feeding it. A green suite here is not coverage of
 * the parser end to end. */
GPtrArray *duct_disk_parse_lsblk (const char *json,
                                  const char *boot_disk,
                                  GError    **error);

/* The disk the live medium was booted from, or NULL.
 *
 * /proc/self/mountinfo gives the source device of /run/live/medium -- the
 * initramfs mounts it there and leaves it mounted for the life of the system
 * -- and /sys/class/block/<part>/.. gives its parent disk. */
char *duct_disk_boot_medium (void);

/* The same answer, computed from text and a lookup rather than from the
 * filesystem -- which is what makes it testable.
 *
 * THIS IS THE MOST DANGEROUS FUNCTION IN THE PROGRAM AND ITS MOST IMPORTANT
 * BRANCH HAD NEVER RUN. When the live medium is a whole disk carrying a
 * filesystem directly, with no partition table -- exactly what a QEMU
 * virtio-blk ISO is -- there is no parent block device, and the answer has to
 * be the source device itself. Nothing on a development machine reaches that
 * path, and if it is wrong the installer offers the live medium as an install
 * target.
 *
 * `resolve_parent` is handed a kernel device name and returns its parent disk
 * node, or NULL when there is none. In production that reads
 * /sys/class/block; under test it is a table. Everything else -- finding the
 * mount, locating the source field, deciding what to do when there is no
 * parent -- is pure and is now exercised directly. */
typedef char *(*DuctParentResolver) (const char *kernel_name, gpointer user_data);

char *duct_disk_boot_medium_from (const char        *mountinfo,
                                  DuctParentResolver resolve_parent,
                                  gpointer           user_data);

/* --- the partition plan -------------------------------------------------- */

/* Computed, never chosen. v1 has exactly one layout; see DESIGN.md.
 * plan() is pure: it does no I/O, so the Summary screen can show the exact
 * table that will be written before anything has been touched. */
typedef struct {
	char    *disk;
	char    *esp_node;   /* predicted: <disk>p1 or <disk>1 */
	char    *root_node;
	guint64  esp_size;   /* bytes */
	guint64  root_size;

	/* Chosen here and written INTO the partition table, rather than read back
	 * out of it afterwards.
	 *
	 * sfdisk accepts an explicit uuid= per partition, so the installer knows
	 * the PARTUUID before the table exists. That removes the blkid round-trip
	 * entirely: grub.cfg and fstab can be written from these without probing
	 * the disk, and without depending on udev having caught up. It also means
	 * a failure between partitioning and configuration leaves no ambiguity
	 * about which partition was meant. */
	char    *esp_partuuid;
	char    *root_partuuid;
} DuctPartitionPlan;

DuctPartitionPlan *duct_partition_plan     (const DuctDisk *disk, GError **error);

void               duct_partition_plan_free(DuctPartitionPlan *plan);

/* The sfdisk script the plan corresponds to. Shown in the summary's detail
 * expander, so what will be piped to sfdisk is visible before it is. */
char *duct_partition_plan_script (const DuctPartitionPlan *plan);

/* TRUE when this error is the installer DECLINING to touch a disk, rather than
 * something going wrong.
 *
 * The two must not be reported with the same marker: a refusal is the program
 * working. A user who selects an 8 GiB stick, is correctly declined, and reads
 * "FAIL" has been told the installer broke when it in fact protected them --
 * and unlike a harness, a user does not go and debug it.
 *
 * It lives here, beside the code that SETS these errors, rather than as a list
 * of codes kept by each caller. Three of tonight's defects lived at interfaces
 * where one side encoded a fact and the other decoded it independently; this
 * is the same shape, so the knowledge stays on the side that owns it. */
gboolean duct_error_is_refusal (const GError *error);

/* --- the backend --------------------------------------------------------- */

typedef enum {
	DUCT_STAGE_PARTITION,
	DUCT_STAGE_FORMAT,
	DUCT_STAGE_MOUNT,
	DUCT_STAGE_COPY,
	DUCT_STAGE_CONFIGURE,
	DUCT_STAGE_BOOTLOADER,
	DUCT_STAGE_FINISH,
	DUCT_N_STAGES
} DuctStage;

const char *duct_stage_title (DuctStage stage);

/* Fraction of the whole install this stage is worth.
 *
 * Not 1/7 each. Package installation is the overwhelming majority of the wall
 * clock, and a progress bar that jumps to 6/7 and then sits there for four
 * minutes is worse than no progress bar. */
double duct_stage_weight (DuctStage stage);

/* Progress and logging, called from the worker thread.
 *
 * The UI marshals these onto the main loop itself; no GTK call may happen off
 * the main thread. */
typedef void (*DuctProgressFunc) (DuctStage stage, double frac, const char *detail, gpointer user_data);
typedef void (*DuctLogFunc)      (const char *line, gpointer user_data);

typedef struct _DuctBackend DuctBackend;

struct _DuctBackend {
	const char *name;   /* "dry run" / "real" -- shown in the UI */
	gboolean    destructive;

	/* Every op returns FALSE and sets *error on failure. The caller stops at
	 * the first failure: there is no retry, and no "continue anyway". */
	gboolean (*partition) (DuctBackend *self, const DuctPartitionPlan *plan, GError **error);
	gboolean (*format)    (DuctBackend *self, const DuctPartitionPlan *plan, GError **error);
	gboolean (*mount)     (DuctBackend *self, const DuctPartitionPlan *plan, GError **error);

	/* Copies the live system to the target and removes what is live-only.
	 * Replaced the package-install stage: the squashfs already contains every
	 * file of the installed set plus a populated tape database, so there is
	 * nothing to fetch. See duct_live_only_packages(). */
	gboolean (*copy)      (DuctBackend *self, const DuctInstallConfig *cfg, GError **error);
	gboolean (*configure) (DuctBackend *self, const DuctInstallConfig *cfg,
	                       const DuctPartitionPlan *plan, GError **error);
	gboolean (*bootloader)(DuctBackend *self, const DuctPartitionPlan *plan, GError **error);

	/* Runs on the failure path too: leaving the target mounted turns a failed
	 * install into one that cannot even be retried ("device busy"). */
	gboolean (*finish)    (DuctBackend *self, GError **error);

	void     (*free)      (DuctBackend *self);

	DuctProgressFunc progress;
	DuctLogFunc      log;
	gpointer         user_data;
};

DuctBackend *duct_backend_dryrun_new (void);

/* Not implemented. Returns NULL with an error saying so, which is the whole
 * point: --real is accepted by the command line and refused by the backend,
 * so the flag exists before the code that would honour it. */
DuctBackend *duct_backend_real_new (GError **error);

void         duct_backend_free (DuctBackend *self);

/* Run the whole install, in order, stopping at the first failure. Blocking;
 * call it on a worker thread. */
gboolean duct_backend_run (DuctBackend             *self,
                           const DuctInstallConfig *cfg,
                           const DuctPartitionPlan *plan,
                           GError                 **error);

/* Where the copy comes from: the read-only squashfs, not "/".
 *
 * packages/pkgs/duct-live/files/initramfs-init mounts the squashfs at
 * /run/live/rootfs and stacks a tmpfs over it; the overlay is what becomes /.
 * Copying the overlay would carry every change the live session has made --
 * the generated machine-id, logs, whatever the user did in a terminal. The
 * lower layer is the image as built, which is exactly what should land on the
 * disk. Both stay mounted for the life of the system, so this path is valid
 * whenever the installer runs. */
#define DUCT_LIVE_ROOTFS "/run/live/rootfs"

/* Packages that exist only because the medium is live, and that must be
 * removed from the target after the copy. NULL-terminated.
 *
 * The v1 design rule is that the live set is a SUPERSET of the installed set
 * and divergence is handled by removal only -- v1 may never add a package the
 * medium does not carry, because the moment it must, an on-medium repository
 * comes back and the whole saving is gone. This list is the entire expression
 * of that divergence, which is why it is short and why adding to it is cheap
 * while adding to the other side is a design escalation.
 *
 * Removal goes through `tape remove` against the target's own database rather
 * than `rm`, so the database stays true. That needs no repository: removal
 * reads installed.db and deletes what it lists. */
const char * const *duct_live_only_packages (void);

G_END_DECLS

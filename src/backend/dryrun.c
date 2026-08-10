/* The dry-run backend: the default, and the only one that exists.
 *
 * It logs the exact command line each stage would run and then does nothing.
 * That makes it two things at once -- a way to walk the flow safely, and the
 * specification the real backend has to match. When real.c is written, it
 * should run precisely these commands in precisely this order, and the way to
 * review it is to diff its log against this one.
 *
 * The commands below are not sketches. They are what images/Dockerfile.iso,
 * images/iso/make-boot.sh and images/iso/post-install.sh already do, retargeted
 * from a build root to a mounted disk.
 */

#include "backend/backend.h"

#include <string.h>

#define TARGET      "/mnt"
#define TAPE_CFGDIR "/run/duct-install/tape"

typedef struct {
	DuctBackend base;
	guint       commands;   /* how many commands were logged, for the summary */
} DryRun;

static void
emit (DryRun *self, const char *fmt, ...) G_GNUC_PRINTF (2, 3);

static void
emit (DryRun *self, const char *fmt, ...)
{
	va_list args;
	va_start (args, fmt);
	g_autofree char *body = g_strdup_vprintf (fmt, args);
	va_end (args);

	self->commands++;

	if (self->base.log != NULL) {
		g_autofree char *line = g_strdup_printf ("$ %s", body);
		self->base.log (line, self->base.user_data);
	}
}

static void
note (DryRun *self, const char *fmt, ...) G_GNUC_PRINTF (2, 3);

static void
note (DryRun *self, const char *fmt, ...)
{
	va_list args;
	va_start (args, fmt);
	g_autofree char *body = g_strdup_vprintf (fmt, args);
	va_end (args);

	if (self->base.log != NULL) {
		g_autofree char *line = g_strdup_printf ("  # %s", body);
		self->base.log (line, self->base.user_data);
	}
}

/* Report progress within a stage and give the UI something to render.
 *
 * The sleep is not padding: without it every stage completes in microseconds,
 * the progress screen flashes past, and the one screen whose behaviour under
 * a slow operation matters most never gets exercised. The real backend has no
 * such call. */
static void
step (DryRun *self, DuctStage stage, double frac, const char *detail)
{
	if (self->base.progress != NULL)
		self->base.progress (stage, frac, detail, self->base.user_data);

	g_usleep (120 * 1000);
}

/* --- stages -------------------------------------------------------------- */

static gboolean
dryrun_partition (DuctBackend *backend, const DuctPartitionPlan *plan, GError **error)
{
	DryRun *self = (DryRun *) backend;

	(void) error;

	step (self, DUCT_STAGE_PARTITION, 0.0, "Writing the partition table");

	note (self, "THIS is the point of no return. Everything before it was "
	            "read-only; nothing after it can be undone.");

	/* wipefs first, and this is not belt-and-braces. A disk that already has,
	 * say, an ext4 superblock in the middle of where the new ESP will go keeps
	 * that signature, and blkid will report the partition as two filesystems
	 * at once -- which the mount at the next boot may resolve either way. */
	emit (self, "wipefs --all --force %s", plan->disk);

	g_autofree char *script = duct_partition_plan_script (plan);
	emit (self, "sfdisk --wipe always --wipe-partitions always %s <<'EOF'", plan->disk);

	if (self->base.log != NULL) {
		g_auto (GStrv) lines = g_strsplit (script, "\n", -1);
		for (guint i = 0; lines[i] != NULL; i++) {
			if (*lines[i] == '\0')
				continue;
			g_autofree char *line = g_strdup_printf ("  | %s", lines[i]);
			self->base.log (line, self->base.user_data);
		}
		self->base.log ("  | EOF", self->base.user_data);
	}

	step (self, DUCT_STAGE_PARTITION, 0.6, "Re-reading the partition table");

	/* The kernel does not necessarily notice a new table on a disk that has
	 * partitions in use, and udev needs a moment to create the by-uuid links
	 * that fstab will be written from. */
	emit (self, "partx --update %s", plan->disk);
	emit (self, "udevadm settle");

	step (self, DUCT_STAGE_PARTITION, 1.0, NULL);
	return TRUE;
}

static gboolean
dryrun_format (DuctBackend *backend, const DuctPartitionPlan *plan, GError **error)
{
	DryRun *self = (DryRun *) backend;

	(void) error;

	step (self, DUCT_STAGE_FORMAT, 0.0, "Creating the EFI system partition");

	note (self, "mkfs.vfat comes from dosfstools, which is NOT packaged yet. "
	            "The real backend cannot run this line today. See GAP-ANALYSIS.md item 2.");
	emit (self, "mkfs.vfat -F 32 -n DUCT_ESP %s", plan->esp_node);

	step (self, DUCT_STAGE_FORMAT, 0.5, "Creating the root filesystem");

	note (self, "mkfs.ext4 comes from e2fsprogs, which is NOT packaged yet. "
	            "See GAP-ANALYSIS.md item 1.");
	emit (self, "mkfs.ext4 -F -L duct-root %s", plan->root_node);

	step (self, DUCT_STAGE_FORMAT, 1.0, NULL);
	return TRUE;
}

static gboolean
dryrun_mount (DuctBackend *backend, const DuctPartitionPlan *plan, GError **error)
{
	DryRun *self = (DryRun *) backend;

	(void) error;

	step (self, DUCT_STAGE_MOUNT, 0.0, "Mounting the target");

	emit (self, "mkdir -p %s", TARGET);
	emit (self, "mount %s %s", plan->root_node, TARGET);
	emit (self, "mkdir -p %s/boot/efi", TARGET);
	emit (self, "mount %s %s/boot/efi", plan->esp_node, TARGET);

	step (self, DUCT_STAGE_MOUNT, 0.5, "Mounting the kernel filesystems");

	/* The kernel filesystems, here rather than in configure().
	 *
	 * configure() runs useradd, chpasswd and ldconfig with chroot, and every
	 * one of those needs /proc, /sys and /dev inside the target. Without them
	 * useradd fails in a way that reads as a defect in shadow, which sends
	 * whoever is debugging it into entirely the wrong package. Putting the
	 * mounts here means they are set up once, by the stage whose job is
	 * mounting, and torn down by the finish stage that already runs on the
	 * failure path.
	 *
	 * --rbind rather than --bind for /sys and /dev, because both carry
	 * submounts -- devpts, shm, efivarfs -- that a plain bind would leave
	 * behind. --make-rslave on each afterwards, and this one matters: without
	 * it the recursive unmount in finish() propagates back through the bind
	 * and tears down the *live system's* own /dev and /sys, which takes the
	 * running installer with it. */
	emit (self, "mkdir -p %s/proc %s/sys %s/dev %s/run", TARGET, TARGET, TARGET, TARGET);
	emit (self, "mount -t proc  proc %s/proc", TARGET);
	emit (self, "mount --rbind /sys %s/sys  && mount --make-rslave %s/sys", TARGET, TARGET);
	emit (self, "mount --rbind /dev %s/dev  && mount --make-rslave %s/dev", TARGET, TARGET);
	emit (self, "mount --rbind /run %s/run  && mount --make-rslave %s/run", TARGET, TARGET);

	step (self, DUCT_STAGE_MOUNT, 1.0, NULL);
	return TRUE;
}

static gboolean
dryrun_copy (DuctBackend *backend, const DuctInstallConfig *cfg, GError **error)
{
	DryRun *self = (DryRun *) backend;

	(void) cfg;
	(void) error;

	step (self, DUCT_STAGE_COPY, 0.0, "Measuring the system");

	/* No package manager, no repository, no downloads.
	 *
	 * images/Dockerfile.iso assembles the live rootfs with tape and points
	 * installed-db at /rootfs/var/lib/tape/installed.db, so the squashfs on the
	 * medium already holds every file of the installed set AND a fully
	 * populated package database. Copying it produces a registered system --
	 * one tape can later query, upgrade and remove from -- rather than a
	 * filesystem that merely looks installed.
	 *
	 * The saving is the whole reason: an on-medium repository would have cost
	 * 234-552 MB, and the squashfs and the package tarballs turn out to be two
	 * compressed representations of the same files within 4% of each other.
	 * Against a desktop ISO landing at 600-700 MB that is the difference
	 * between that and 1.4 GB. */
	note (self, "copy-based install: no repository, no downloads. The squashfs "
	            "already holds the installed set and tape's database.");

	/* From the read-only squashfs, NOT from "/".
	 *
	 * / is the overlay: the squashfs with a tmpfs stacked on top, carrying
	 * every change the live session has made -- the generated machine-id, the
	 * logs, whatever someone typed in a terminal. The lower layer is the image
	 * as it was built, which is what should land on a disk. */
	emit (self, "du -sb %s   # total to copy, for honest progress", DUCT_LIVE_ROOTFS);

	step (self, DUCT_STAGE_COPY, 0.05, "Copying the system");

	/* cp -a, not rsync: rsync is not packaged and will not be. -a preserves
	 * mode, ownership, timestamps, symlinks and device nodes, which is all
	 * that is needed from a source that is a read-only image. */
	emit (self, "cp -a %s/. %s/", DUCT_LIVE_ROOTFS, TARGET);

	/* The copy stage can report real progress, which the package stage never
	 * could: the total is known before it starts. */
	for (guint i = 1; i <= 8; i++) {
		g_autofree char *detail = g_strdup_printf ("Copying the system (%u%%)", i * 12);
		step (self, DUCT_STAGE_COPY, 0.05 + 0.75 * ((double) i / 8.0), detail);
	}

	step (self, DUCT_STAGE_COPY, 0.95, "Checking the copy");

	/* NOTHING IS REMOVED AND NOTHING IS SWAPPED. The copy is the whole stage.
	 *
	 * This is the third shape this stage has had, and each replacement was
	 * smaller than the thing it replaced:
	 *
	 *   remove-some   `tape remove -y duct-live busybox`. Fatal: busybox IS
	 *                 the init binary -- duct-live's install.sh links
	 *                 /usr/sbin/init -> ../bin/busybox -- so the target would
	 *                 boot, mount root by PARTUUID and find init dangling.
	 *
	 *   keep-and-swap keep both packages, overwrite /etc/inittab and the rc
	 *                 with installed variants. Also fatal, and worse for being
	 *                 delayed: tape has NO conffile handling. There is no
	 *                 .rpmnew, no .dpkg-dist, no special treatment of config
	 *                 paths anywhere in install.go or upgrade.go -- upgrade
	 *                 stages a temp file and os.Rename's over the target
	 *                 unconditionally. So the first `tape upgrade duct-live`
	 *                 on an installed machine would silently restore the live
	 *                 inittab, whose sysinit runs the live rc, which expects
	 *                 an overlay root that is not there. A machine that had
	 *                 worked for weeks breaks on a routine upgrade, and nobody
	 *                 debugging it would look at an install-time decision.
	 *
	 *   nothing       duct-live ships ONE inittab whose sysinit points at a
	 *                 dispatcher that decides live-versus-installed at RUNTIME,
	 *                 by looking for an overlay root in /proc/mounts. That is a
	 *                 fact about the running system rather than a convention
	 *                 someone can boot without, and the installer never touches
	 *                 it.
	 *
	 * THE INVARIANT that falls out, and it is worth stating as a rule because
	 * it is checkable: the installed set is the live set minus nothing, and no
	 * package-owned file differs between the two. The only difference is
	 * unowned machine-specific state. Operationally --
	 *
	 *     ANYTHING THE INSTALLER WRITES THAT A PACKAGE OWNS IS A BUG.
	 *
	 * The harness checks it after an install rather than the installer
	 * checking itself: installed.db knows every owned path, so the test can
	 * assert that nothing the installer wrote appears in it. See
	 * QEMU-TEST-PLAN.md, test 3. */
	note (self, "nothing removed, nothing swapped: duct-live's inittab dispatches "
	            "on an overlay root at runtime. tape has no conffile handling, so "
	            "overwriting a package-owned file would be reverted by the first "
	            "upgrade.");

	emit (self, "test -x %s/usr/sbin/init   # the busybox symlink survived the copy", TARGET);

	/* The removal rule still stands; it simply has no members. Checked rather
	 * than assumed, so the day somebody adds one the log says so. */
	const char * const *live_only = duct_live_only_packages ();

	if (live_only[0] != NULL) {
		g_autofree char *joined = g_strjoinv (" ", (char **) live_only);

		emit (self, "mkdir -p %s", TAPE_CFGDIR);
		emit (self, "cat >%s/config.toml <<'EOF'\n"
		            "  | [daemon]\n"
		            "  | sysroot      = \"%s\"\n"
		            "  | installed-db = \"%s/var/lib/tape/installed.db\"\n"
		            "  | EOF",
		      TAPE_CFGDIR, TARGET, TARGET);
		emit (self, "TAPE_CONFIG_DIR=%s taped &", TAPE_CFGDIR);
		emit (self, "TAPE_CONFIG_DIR=%s tape remove -y %s", TAPE_CFGDIR, joined);
		emit (self, "kill %%1");
	} else {
		note (self, "no packages to remove: the installed set is the live set "
		            "minus nothing.");
	}

	step (self, DUCT_STAGE_COPY, 1.0, NULL);
	return TRUE;
}

static gboolean
dryrun_configure (DuctBackend             *backend,
                  const DuctInstallConfig *cfg,
                  const DuctPartitionPlan *plan,
                  GError                 **error)
{
	DryRun *self = (DryRun *) backend;

	(void) error;

	step (self, DUCT_STAGE_CONFIGURE, 0.0, "Writing the filesystem table");

	/* By PARTUUID, not by node, and not by filesystem UUID either.
	 *
	 * By node is wrong for the obvious reason: /dev/sda becomes /dev/sdb the
	 * moment another disk is plugged in. Filesystem UUID would work, but it
	 * would mean running blkid and waiting for udev, and it would mean the
	 * fstab could only be written once the filesystems existed. The PARTUUIDs
	 * were chosen at plan time and written into the table by sfdisk, so they
	 * are known before anything is formatted and need no probe at all.
	 *
	 * It also matches root= on the kernel command line, so there is one
	 * identifier for the root filesystem rather than two that have to agree.
	 *
	 * Generated for the TARGET, never copied. The live root is an overlay of a
	 * squashfs and a tmpfs; its fstab describes nothing that exists on a disk.
	 *
	 * Safe to write only because duct-live is giving up /etc/fstab, making the
	 * path unowned. That is what removes the hazard -- an unowned file is one
	 * tape will never touch. Overwriting an owned file is what creates it, and
	 * the first upgrade would revert this. */
	emit (self, "cat >%s/etc/fstab <<'EOF'\n"
	            "  | PARTUUID=%s  /          ext4  defaults,noatime  0 1\n"
	            "  | PARTUUID=%s  /boot/efi  vfat  umask=0077        0 2\n"
	            "  | EOF",
	      TARGET, plan->root_partuuid, plan->esp_partuuid);

	step (self, DUCT_STAGE_CONFIGURE, 0.25, "Setting the hostname and locale");

	emit (self, "echo %s >%s/etc/hostname", cfg->hostname, TARGET);
	emit (self, "echo 'LANG=%s' >%s/etc/locale.conf", cfg->locale, TARGET);

	note (self, "locale is %s because glibc builds no others — GAP-ANALYSIS.md item 6.",
	      cfg->locale);

	/* The console keymap needs kbd (loadkeys), which is not packaged. The X11
	 * layout below is what a graphical session reads and does work. */
	emit (self, "cat >%s/etc/vconsole.conf <<'EOF'\n  | KEYMAP=%s\n  | EOF",
	      TARGET, cfg->kb_layout);
	note (self, "vconsole.conf is written but nothing on the target can apply "
	            "it: kbd is not packaged — GAP-ANALYSIS.md item 9.");

	emit (self, "mkdir -p %s/etc/X11/xorg.conf.d", TARGET);
	emit (self, "cat >%s/etc/X11/xorg.conf.d/00-keyboard.conf <<'EOF'\n"
	            "  |   Option \"XkbLayout\" \"%s\"\n"
	            "  |   Option \"XkbVariant\" \"%s\"\n"
	            "  | EOF",
	      TARGET, cfg->kb_layout, cfg->kb_variant ? cfg->kb_variant : "");

	step (self, DUCT_STAGE_CONFIGURE, 0.45, "Setting the time zone");

	note (self, "tzdata is not packaged, so /usr/share/zoneinfo does not exist "
	            "and this link will dangle — GAP-ANALYSIS.md item 5.");
	emit (self, "ln -sf /usr/share/zoneinfo/%s %s/etc/localtime", cfg->timezone, TARGET);

	step (self, DUCT_STAGE_CONFIGURE, 0.6, "Creating the user account");

	/* ESCALATION, not a thing to fix here. /etc/passwd and /etc/group are
	 * OWNED BY duct-filesystem -- its install.sh writes both -- and useradd
	 * modifies them. By the invariant above, that makes user creation a bug by
	 * definition, and it is the same failure as the inittab swap one step
	 * further on: tape has no conffile handling, so the first
	 * `tape upgrade duct-filesystem` on an installed machine silently restores
	 * a passwd and group with no user accounts in them.
	 *
	 * It is nastier than the inittab case in one respect. /etc/shadow is NOT
	 * owned by anything, so the password hashes survive the upgrade that
	 * deletes the accounts they belong to -- leaving a shadow file describing
	 * users who no longer exist, which is the sort of state that confuses
	 * every tool that reads it.
	 *
	 * /etc/hosts is owned by duct-filesystem too. This installer does not
	 * write it, and must not start: putting the hostname there is the obvious
	 * next convenience and it would reintroduce exactly this bug.
	 *
	 * The fix is in packages/, not here: duct-filesystem has to stop shipping
	 * /etc/passwd and /etc/group, the same way it is giving up /etc/fstab, so
	 * the paths become unowned and tape never touches them. Reported to the
	 * orchestrator; not worked around locally, because every available
	 * workaround is worse than the bug. */
	note (self, "ESCALATED: /etc/passwd and /etc/group are owned by "
	            "duct-filesystem, so useradd writes package-owned files. An "
	            "upgrade would silently delete every account. Needs a packages/ "
	            "change, not a workaround here.");


	emit (self, "chroot %s useradd -m -c '%s' -s /usr/bin/bash %s",
	      TARGET, cfg->full_name ? cfg->full_name : "", cfg->username);
	emit (self, "chroot %s chpasswd <<< '%s:<password>'", TARGET, cfg->username);

	if (cfg->lock_root) {
		/* No sudo and no doas in the tree, so a locked root means the user has
		 * no way to gain privilege at all. Refusing to lock it is the honest
		 * choice until one of those is packaged. */
		note (self, "root cannot be locked: sudo and doas are not packaged, so "
		            "a locked root leaves no way to administer the machine. "
		            "Setting a root password instead — GAP-ANALYSIS.md item 8.");
		emit (self, "chroot %s chpasswd <<< 'root:<password>'   # same as the user's", TARGET);
	} else {
		emit (self, "chroot %s chpasswd <<< 'root:<root password>'", TARGET);
	}

	step (self, DUCT_STAGE_CONFIGURE, 0.8, "Running the post-install fixups");

	/* tape has no install hooks -- a package can put files in place and
	 * nothing else. Everything keyed on the *set* of installed packages has to
	 * be done once, here, exactly as images/iso/post-install.sh does it for
	 * the ISO. ldconfig first: the programs below are linked against libraries
	 * that have just arrived and will not start until the cache knows. */
	emit (self, "chroot %s /usr/sbin/ldconfig", TARGET);

	static const char *setuid_table[] = {
		"/usr/bin/passwd", "/usr/bin/chage", "/usr/bin/newgrp",
		"/usr/bin/gpasswd", "/usr/bin/su", NULL
	};
	for (guint i = 0; setuid_table[i] != NULL; i++)
		emit (self, "chmod 4755 %s%s", TARGET, setuid_table[i]);

	emit (self, "chroot %s /usr/bin/glib-compile-schemas /usr/share/glib-2.0/schemas", TARGET);
	emit (self, "chroot %s /usr/bin/gdk-pixbuf-query-loaders --update-cache", TARGET);
	emit (self, "chroot %s /usr/bin/update-mime-database /usr/share/mime", TARGET);
	emit (self, "chroot %s /usr/bin/fc-cache -f", TARGET);
	emit (self, "chroot %s /usr/bin/gtk4-update-icon-cache -f -t /usr/share/icons/hicolor", TARGET);

	/* GENERATED here, not copied and not merely cleared.
	 *
	 * The image build leaves /etc/machine-id empty (post-install.sh) and
	 * duct-live's rc fills it in on first boot -- but duct-live is exactly
	 * what the copy stage removes, so on an installed system nothing would
	 * ever generate one. An empty machine-id is the documented "not yet set"
	 * state and something has to resolve it; here, that something is the
	 * installer.
	 *
	 * It must not be copied from the live system either: every machine
	 * installed from one ISO would share an identity, which is precisely what
	 * D-Bus, journal identity and DHCP leases key on. And an empty one fails
	 * later, elsewhere, pointing nowhere near the installer.
	 *
	 * This is duct-live's rc verbatim, retargeted, and the details are its
	 * details rather than ours:
	 *
	 *   rm -f first, because the file arrives from the squashfs at 0444 and a
	 *   redirect onto it fails with permission denied. The live system got
	 *   away with replacing it because the overlay allowed it; a plain ext4
	 *   target does not.
	 *
	 *   printf '%s\n', so the file ends in a newline, matching what rc wrote.
	 *
	 *   0444 afterwards, the mode both post-install.sh and rc use.
	 *
	 *   od rather than uuidgen, because there is no uuidgen in the base set. */
	emit (self, "id=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \\n')");
	emit (self, "rm -f %s/etc/machine-id   # 0444 from the image; cannot be written in place", TARGET);
	emit (self, "printf '%%s\\n' \"$id\" >%s/etc/machine-id", TARGET);
	emit (self, "chmod 0444 %s/etc/machine-id", TARGET);

	note (self, "machine-id is generated here because duct-live's rc, which used "
	            "to do it on first boot, has just been removed from the target. "
	            "Asserted non-empty in the finish stage.");

	step (self, DUCT_STAGE_CONFIGURE, 1.0, NULL);
	return TRUE;
}

static gboolean
dryrun_bootloader (DuctBackend *backend, const DuctPartitionPlan *plan, GError **error)
{
	DryRun *self = (DryRun *) backend;

	(void) error;

	step (self, DUCT_STAGE_BOOTLOADER, 0.0, "Building the EFI binary");

	/* No initramfs on the target, and that is a deliberate simplification
	 * rather than an omission.
	 *
	 * duct-live's initramfs-init cannot boot a disk: it parses duct.live.*
	 * only, finds a filesystem by LABEL, mounts a squashfs and stacks an
	 * overlay. There is no root= path in it at all, so an installed system
	 * given that initramfs panics with "no filesystem labelled DUCT_LIVE".
	 * Running duct-mkinitramfs in the target chroot would produce an initramfs
	 * that cannot boot the thing it was made for.
	 *
	 * It is not needed. Seven kernel symbols make an initramfs-less boot work,
	 * all of them =y in the BUILT kernel (checked against /boot/config-*, not
	 * against a fragment):
	 *
	 *   CONFIG_EFI_PARTITION    <- THE LOAD-BEARING ONE. It is the GPT parser,
	 *                              and it is what resolves PARTUUID at all.
	 *                              Without it the five driver symbols below
	 *                              are worthless: the kernel would reach the
	 *                              disk and be unable to find a partition on
	 *                              it. root=UUID= is the form that needs an
	 *                              initramfs; PARTUUID= is read from the GPT.
	 *   CONFIG_DEVTMPFS_MOUNT   <- with no initramfs there is no userspace to
	 *                              mount /dev before init runs, so the kernel
	 *                              has to do it itself.
	 *   CONFIG_EXT4_FS             the root filesystem
	 *   CONFIG_VIRTIO_BLK          the disk, under QEMU
	 *   CONFIG_BLK_DEV_SD          the disk, SCSI/SATA
	 *   CONFIG_SATA_AHCI           the controller
	 *   CONFIG_BLK_DEV_NVME        the controller, NVMe
	 *
	 * Naming all seven, and which one is load-bearing, is the point of this
	 * comment. The first version of this design listed the five drivers and
	 * not EFI_PARTITION -- it was right for reasons its author had not
	 * identified, which is the kind of design somebody later breaks while
	 * optimising it.
	 *
	 * Worth knowing: linux/build.sh asserts nine symbols and every one of them
	 * is live-path -- SQUASHFS, OVERLAY_FS, BLK_DEV_LOOP, ISO9660_FS, VFAT_FS,
	 * BLK_DEV_INITRD, DEVTMPFS, EFI_STUB, MODULES. Not one of the seven above
	 * is asserted, so a kernel bump demoting EFI_PARTITION or DEVTMPFS_MOUNT
	 * to =m would leave the live ISO booting perfectly and every installed
	 * system dead with nothing in CI failing. duct-2 is adding the
	 * installed-path symbols to that assertion, and it lands before any
	 * installer writes to a real disk. */
	note (self, "no initramfs on the target: root=PARTUUID= is resolved by the "
	            "kernel's GPT parser. EFI_PARTITION is the symbol that decides it.");

	/* grub-mkimage, not grub-install: grub-install on an EFI platform wants
	 * efibootmgr to write the NVRAM entry, and efibootmgr is not packaged.
	 * images/iso/make-boot.sh already builds a bootable EFI binary with
	 * mkimage alone; this is that, retargeted at a disk.
	 *
	 * The module list differs from the ISO's. That one embeds iso9660 and udf
	 * and searches for a live marker; a disk install needs ext2 -- which reads
	 * ext4 -- and part_gpt to find the root partition. */
	note (self, "grub-mkimage rather than grub-install: grub-install wants "
	            "efibootmgr for the NVRAM entry and it is not packaged — "
	            "GAP-ANALYSIS.md item 7.");

	emit (self, "chroot %s /usr/bin/grub-mkimage \\\n"
	            "  |   -O x86_64-efi -o /tmp/BOOTX64.EFI -p /boot/grub \\\n"
	            "  |   part_gpt fat ext2 search search_fs_uuid search_part_uuid \\\n"
	            "  |   configfile normal linux boot echo test true \\\n"
	            "  |   loadenv minicmd reboot halt gzio all_video video \\\n"
	            "  |   video_fb efi_gop terminal",
	      TARGET);

	step (self, DUCT_STAGE_BOOTLOADER, 0.5, "Installing to the EFI system partition");

	/* The removable-media fallback path, and only that path. It is what a
	 * firmware boots with no NVRAM entry, which is the situation we are in
	 * without efibootmgr. It is also why v1 cannot dual-boot: another OS using
	 * the same path would be overwritten. */
	emit (self, "mkdir -p %s/boot/efi/EFI/BOOT %s/boot/grub/x86_64-efi", TARGET, TARGET);
	emit (self, "cp %s/tmp/BOOTX64.EFI %s/boot/efi/EFI/BOOT/BOOTX64.EFI", TARGET, TARGET);
	emit (self, "cp %s/usr/lib/grub/x86_64-efi/*.mod %s/boot/grub/x86_64-efi/", TARGET, TARGET);

	note (self, "fallback path only (\\EFI\\BOOT\\BOOTX64.EFI). No NVRAM entry, "
	            "and this would overwrite another OS using the same path — which "
	            "is why v1 refuses to dual-boot.");

	step (self, DUCT_STAGE_BOOTLOADER, 0.8, "Writing the boot menu");

	/* No initrd line, and root= comes straight from the plan -- the PARTUUID
	 * was written into the table by sfdisk, so nothing here had to probe the
	 * disk to find it out. */
	emit (self, "cat >%s/boot/grub/grub.cfg <<'EOF'\n"
	            "  | set default=0\n"
	            "  | set timeout=3\n"
	            "  | menuentry 'Duct Linux' {\n"
	            "  |   search --no-floppy --part-uuid --set=root %s\n"
	            "  |   linux /boot/vmlinuz root=PARTUUID=%s rw\n"
	            "  | }\n"
	            "  | EOF",
	      TARGET, plan->root_partuuid, plan->root_partuuid);

	note (self, "no initrd line: there is no initramfs and none is needed.");

	step (self, DUCT_STAGE_BOOTLOADER, 1.0, NULL);
	return TRUE;
}

static gboolean
dryrun_finish (DuctBackend *backend, GError **error)
{
	DryRun *self = (DryRun *) backend;

	(void) error;

	step (self, DUCT_STAGE_FINISH, 0.0, "Checking the result");

	/* Property assertions, and they run HERE rather than in the stage that
	 * wrote each thing -- after everything that could have written it, and
	 * before the installer is allowed to report success.
	 *
	 * A check that lives next to the code it checks passes for the same reason
	 * that code passes. These are deliberately at the end, reading the target
	 * as it will actually be handed over.
	 *
	 * machine-id is the one that motivated this. An empty one does not fail
	 * here; it fails much later, in DHCP leases and journal identity, pointing
	 * nowhere near the installer. Failing now costs one stat. */
	emit (self, "test -s %s/etc/machine-id   # non-empty, or the install failed", TARGET);
	emit (self, "test -s %s/etc/fstab", TARGET);
	emit (self, "test -f %s/boot/efi/EFI/BOOT/BOOTX64.EFI", TARGET);
	emit (self, "test -f %s/boot/grub/grub.cfg", TARGET);
	emit (self, "test -f %s/boot/vmlinuz", TARGET);

	note (self, "these run after everything that writes them, not beside it: a "
	            "check next to its own code passes for the same reasons that "
	            "code does.");

	step (self, DUCT_STAGE_FINISH, 0.4, "Unmounting");

	emit (self, "sync");

	/* -R unwinds the kernel filesystems mount() put in as well as the two real
	 * ones, deepest first. It is safe only because each rbind above was made
	 * rslave; without that this line would unmount the live system's /dev.
	 *
	 * The order matters on the failure path too: a target left mounted turns
	 * "the install failed" into "the install failed and you cannot retry
	 * without rebooting", and it is also what would leave a dirty ext4 for the
	 * QEMU harness to trip over. */
	emit (self, "umount -R %s", TARGET);

	note (self, "dry run complete: %u commands logged, nothing written.", self->commands);

	step (self, DUCT_STAGE_FINISH, 1.0, NULL);
	return TRUE;
}

static void
dryrun_free (DuctBackend *backend)
{
	g_free (backend);
}

DuctBackend *
duct_backend_dryrun_new (void)
{
	DryRun *self = g_new0 (DryRun, 1);

	self->base.name        = "dry run";
	self->base.destructive = FALSE;
	self->base.partition   = dryrun_partition;
	self->base.format      = dryrun_format;
	self->base.mount       = dryrun_mount;
	self->base.copy        = dryrun_copy;
	self->base.configure   = dryrun_configure;
	self->base.bootloader  = dryrun_bootloader;
	self->base.finish      = dryrun_finish;
	self->base.free        = dryrun_free;

	return &self->base;
}

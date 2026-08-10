/* Backend plumbing shared by every implementation: the config object, stage
 * metadata, the ordered run, and the live-only package list. */

#include "backend/backend.h"

#include <gio/gio.h>
#include <string.h>

DuctInstallConfig *
duct_install_config_new (void)
{
	DuctInstallConfig *cfg = g_new0 (DuctInstallConfig, 1);

	/* The defaults are the only values v1 can actually deliver. See
	 * GAP-ANALYSIS.md: glibc builds no locales and tzdata is not packaged,
	 * so these two are not so much defaults as the entire range. */
	cfg->locale     = g_strdup ("C.UTF-8");
	cfg->timezone   = g_strdup ("UTC");
	cfg->kb_layout  = g_strdup ("us");
	cfg->kb_variant = g_strdup ("");
	cfg->hostname   = g_strdup ("duct");
	cfg->lock_root  = TRUE;

	return cfg;
}

void
duct_install_config_free (DuctInstallConfig *cfg)
{
	if (cfg == NULL)
		return;

	g_free (cfg->locale);
	g_free (cfg->kb_layout);
	g_free (cfg->kb_variant);
	g_free (cfg->disk);
	g_free (cfg->timezone);
	g_free (cfg->full_name);
	g_free (cfg->username);
	g_free (cfg->hostname);

	/* The two secrets. Wiped rather than merely freed -- this process is
	 * long-lived, runs as root, and writes a log the user is invited to save;
	 * leaving a plaintext password in freed heap is a needless way for it to
	 * turn up somewhere it should not. */
	if (cfg->password != NULL) {
		memset (cfg->password, 0, strlen (cfg->password));
		g_free (cfg->password);
	}
	if (cfg->root_password != NULL) {
		memset (cfg->root_password, 0, strlen (cfg->root_password));
		g_free (cfg->root_password);
	}

	g_free (cfg);
}

const char *
duct_stage_title (DuctStage stage)
{
	switch (stage) {
	case DUCT_STAGE_PARTITION:  return "Partitioning the disk";
	case DUCT_STAGE_FORMAT:     return "Creating filesystems";
	case DUCT_STAGE_MOUNT:      return "Mounting the target";
	case DUCT_STAGE_COPY:       return "Copying the system";
	case DUCT_STAGE_CONFIGURE:  return "Configuring the system";
	case DUCT_STAGE_BOOTLOADER: return "Installing the bootloader";
	case DUCT_STAGE_FINISH:     return "Finishing";
	default:                    return "Working";
	}
}

double
duct_stage_weight (DuctStage stage)
{
	/* Reweighted for the copy-based design, and the copy stage is now the one
	 * that can be honest rather than the one that has to be estimated.
	 *
	 * A package install reported progress per package, which is a poor proxy:
	 * packages differ in size by three orders of magnitude, so nine tenths of
	 * the bar could cross in a second and the last tenth take a minute. A
	 * filesystem copy knows its own total up front -- the squashfs mount's
	 * apparent size -- so the copy stage reports bytes copied over bytes to
	 * copy, and that number means what it appears to mean.
	 *
	 * FINISH is heavier than it looks. sync() after writing a couple of
	 * gigabytes to a disk that has been absorbing them into cache is not
	 * instant, and on slow media it is one of the longest stages. Weighting it
	 * at 2% was wrong even under the old design.
	 *
	 * These sum to 1.0; the test checks that they still do. */
	switch (stage) {
	case DUCT_STAGE_PARTITION:  return 0.02;
	case DUCT_STAGE_FORMAT:     return 0.04;
	case DUCT_STAGE_MOUNT:      return 0.01;
	case DUCT_STAGE_COPY:       return 0.70;
	case DUCT_STAGE_CONFIGURE:  return 0.09;
	case DUCT_STAGE_BOOTLOADER: return 0.04;
	case DUCT_STAGE_FINISH:     return 0.10;
	default:                    return 0.0;
	}
}

const char * const *
duct_live_only_packages (void)
{
	/* EMPTY, and deliberately so. The rule survives; its membership is zero.
	 *
	 * This list used to hold duct-live and busybox, and that would have
	 * produced an installed system that reported success and could not boot.
	 * Both entries were wrong, and the second was fatal:
	 *
	 *   busybox IS the init binary. duct-live's install.sh line 46 does
	 *   `ln -sfn ../bin/busybox $DESTDIR/usr/sbin/init`, because busybox
	 *   decides which applet it is from argv[0] -- so a program called init
	 *   that is a symlink to busybox *is* busybox's init. Removing the busybox
	 *   package deletes the target of that symlink. The machine would boot the
	 *   kernel, mount the root by PARTUUID, and find /usr/sbin/init dangling.
	 *
	 *   duct-live owns /etc/inittab, /usr/sbin/init and /etc/fstab -- and is
	 *   being extended to carry the *installed* configuration too, because a
	 *   separate duct-init package cannot exist: two packages owning one path
	 *   is a hard install error in tape with no override, and the
	 *   superset-only rule means duct-init would have to ship alongside
	 *   duct-live on the medium, which would fail at ISO assembly.
	 *
	 * So the target keeps both packages, and divergence is expressed by
	 * swapping configuration files rather than by removing anything. A few
	 * live-only files remain on an installed system -- duct-mkinitramfs, the
	 * live inittab, the live rc. Kilobytes, inert, and strictly better than
	 * deleting packages the installed system depends on.
	 *
	 * THE LESSON, for whoever adds the first entry here. The test is not "is
	 * this live-only tooling" -- busybox looked exactly like live-only tooling.
	 * The test is "does the installed system depend on it", and answering that
	 * means reading the owning package's install.sh, not remembering what the
	 * package is for. */
	static const char * const set[] = { NULL };

	return set;
}

gboolean
duct_backend_run (DuctBackend             *self,
                  const DuctInstallConfig *cfg,
                  const DuctPartitionPlan *plan,
                  GError                 **error)
{
	g_return_val_if_fail (self != NULL, FALSE);
	g_return_val_if_fail (cfg != NULL && plan != NULL, FALSE);

	gboolean ok = TRUE;

	/* Ordered, and it stops at the first failure. There is no "continue
	 * anyway" and no retry: retrying half a disk write is how a recoverable
	 * failure becomes an unrecoverable one. */
	if (ok) ok = self->partition  (self, plan, error);
	if (ok) ok = self->format     (self, plan, error);
	if (ok) ok = self->mount      (self, plan, error);
	if (ok) ok = self->copy       (self, cfg, error);
	if (ok) ok = self->configure  (self, cfg, plan, error);
	if (ok) ok = self->bootloader (self, plan, error);

	/* finish() runs whether or not the install succeeded, and its own failure
	 * must not overwrite the error that actually stopped us -- that one is
	 * what the user needs to read. Leaving the target mounted after a failure
	 * turns "the install failed" into "the install failed and you cannot try
	 * again without rebooting", which is a worse place to leave someone. */
	{
		g_autoptr (GError) finish_error = NULL;

		if (!self->finish (self, &finish_error)) {
			if (ok) {
				g_propagate_error (error, g_steal_pointer (&finish_error));
				ok = FALSE;
			} else if (self->log != NULL) {
				g_autofree char *line =
					g_strdup_printf ("! cleanup also failed: %s", finish_error->message);
				self->log (line, self->user_data);
			}
		}
	}

	return ok;
}

void
duct_backend_free (DuctBackend *self)
{
	if (self == NULL)
		return;

	if (self->free != NULL)
		self->free (self);
	else
		g_free (self);
}

DuctBackend *
duct_backend_real_new (GError **error)
{
	/* The flag exists before the code that honours it, on purpose. Building
	 * the dry-run path first and making it the default is the safety property;
	 * a --real that silently did nothing, or one that did something before the
	 * dry run had been reviewed, would both give that away. */
	g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED,
	                     "The real backend is not implemented. This build can only dry-run: "
	                     "it prints the commands an install would issue and writes nothing.");
	return NULL;
}

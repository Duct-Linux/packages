# e2fsprogs and dosfstools — what the installer needs them to contain

Written against `origin/main` at `5f92445`. The installer is the only consumer
of either package today, so these are requirements rather than a distribution
default. Everything below is traceable to a line the dry-run backend emits;
nothing is here because a distribution usually ships it.

> **SUPERSEDED IN PART — read this first.** Both packages are now written and
> submitted ([packages#14](https://github.com/Duct-Linux/packages/pull/14),
> [packages#15](https://github.com/Duct-Linux/packages/pull/15)), and writing
> them corrected this document. What follows is kept because the *requirements*
> are still right; the flag sets below were derived from documentation and two
> of them were wrong. The recipes are the authority now.
>
> | this document said | what the source says |
> |---|---|
> | `--disable-fsck` avoids a conflict | correct, and it is **required on every Linux build** — `configure.ac:718` decides from `$host_os` and only `gnu*` (HURD) skips it, so `linux-gnu` builds the wrapper by default |
> | `--disable-uuidd` required | **redundant.** configure already prints "Disabling uuidd by default". Kept in the recipe as an explicit statement, and labelled there as not load-bearing |
> | e2fsprogs depends on `glibc`, `util-linux` at runtime | correct, and the reason is sharper than stated here: refusing the private libuuid/libblkid means *linking* against util-linux's, so it is a runtime dependency rather than only a conflict to avoid |
> | (not mentioned) | **`--sysconfdir=/etc` is required.** The shared autotools stage passes `--prefix=/usr` and nothing else, and autotools — unlike meson — does not special-case `/usr`, so `mke2fs.conf` would land in `/usr/etc`. Found by duct-3 at review; my own `[ -f .../etc/mke2fs.conf ]` assertion would have caught it at build time |
> | (not mentioned) | dosfstools needs **no** `--sysconfdir` (nothing goes in `/etc`) and **no** `--disable-nls` (it has no NLS support at all, so the flag would be an unrecognised option). Both omissions are recorded in the recipe with their reasons |
>
> One methodological note worth keeping, because it nearly went the other way:
> I grepped `configure` for the literal flag strings, found three absent, and
> concluded they were not real options. **That conclusion was also wrong** —
> autoconf accepts `--disable-X` for any `--enable-X`, and `configure --help`
> advertises only the enable form. The help text is not the option list. Two
> errors that happened to cancel, which produces confidence with no evidence
> behind it.

The exact commands, from `src/backend/dryrun.c`:

```
mkfs.vfat -F 32 -n DUCT_ESP  /dev/<disk>1     # dosfstools
mkfs.ext4 -F -L duct-root    /dev/<disk>2     # e2fsprogs
```

Two commands. That is the whole of what the *install* needs. What the installed
system needs at boot is a separate and shorter list, below.

---

## dosfstools

**Version:** 4.2 (current release; no version-specific requirement).
**Source:** `https://github.com/dosfstools/dosfstools/releases/download/v4.2/dosfstools-4.2.tar.gz`
**Build system:** autotools. No unusual configure work.

### Binaries required

| binary | why |
|---|---|
| `mkfs.fat` (+ the `mkfs.vfat` / `mkdosfs` aliases) | creates the ESP. Hard requirement — nothing else in the tree can. |
| `fsck.fat` (+ `dosfsck` / `fsck.vfat`) | the installed system's `fstab` gives the ESP a pass number of 2, so a boot-time fsck will look for this. Without it a check is skipped, which is survivable but silently. |

`fatlabel` and `fsck.fat`'s repair modes are not used by the installer. They
come with the package and cost nothing; no need to disable them.

### Options

- `--enable-compat-symlinks` — **required.** Without it the package installs
  only `mkfs.fat` and `fsck.fat`, and the installer calls `mkfs.vfat`. Either
  this flag or a change to the installer; the flag is the better half of that
  choice because `mkfs.vfat` is the name every piece of documentation uses.
- `--without-udev` — nothing here needs udev rules.
- No NLS: consistent with every other package in the tree.

### Dependencies

`glibc` only. No libblkid, no libudev, no iconv beyond glibc's. This is one of
the smallest packages in the tree — a few hundred KB of C.

### What the installer requires of its behaviour

- `-F 32` must be honoured. A 1 GiB partition is within the range where
  `mkfs.fat` would otherwise choose FAT16, and **UEFI firmware is only
  guaranteed to read FAT32 on a fixed disk**. This is the one behavioural
  requirement worth a test.
- `-n DUCT_ESP` sets the volume label. Cosmetic, but the ISO's own ESP uses a
  label too, and consistency helps anyone reading `lsblk` output.

**A caution worth carrying into the recipe.** `mkfs.vfat` is on the project's
own list of *mechanisms that are accepted and silently do nothing*: given a
geometry it dislikes it can warn and carry on rather than refuse. The real
backend must check its exit status **and** verify the result with `blkid`
afterwards, rather than trusting that a zero exit means a FAT32 filesystem
exists. That is the installer's job, not the recipe's, but it is the reason the
recipe should not disable `fsck.fat`.

---

## e2fsprogs

**Version:** 1.47.x (current stable).
**Source:** `https://downloads.sourceforge.net/project/e2fsprogs/e2fsprogs/v1.47.2/e2fsprogs-1.47.2.tar.gz` — or the kernel.org mirror, which is what LFS uses.
**Build system:** autotools, but with a configure line that needs care (below).

### Binaries required

| binary | why |
|---|---|
| `mkfs.ext4` (`mke2fs`) | creates the root filesystem. Hard requirement. |
| `e2fsck` (`fsck.ext4`) | the root's `fstab` pass number is 1. **A system that never fsck's its root is one that eventually does not boot**, and this is the only thing that can. |
| `tune2fs` | not called by v1, but it is how anyone fixes a filesystem the installer produced. Shipping the package without it would be a strange omission. |
| `blkid`, `fsck` | **must NOT be installed** — see conflicts. |

`resize2fs`, `dumpe2fs`, `debugfs` come with the package. Not used by the
installer; no reason to remove them.

### Options — and the one that will bite

```
--enable-elf-shlibs
--disable-fsck            # util-linux owns /usr/sbin/fsck
--disable-libblkid        # util-linux owns libblkid and blkid(8)
--disable-libuuid         # util-linux owns libuuid and uuidgen
--disable-uuidd           # ditto
--disable-nls
```

**The four `--disable-*` flags are not tidiness, they are what makes the
package installable at all.** `util-linux` is already on main and already
installs `blkid`, `fsck`, `libblkid` and `libuuid`. tape treats two packages
claiming one path as a **hard install error with no override** —
`daemon/utils/install.go`, `CheckConflicts` — so an e2fsprogs built with its own
copies would fail to install, not merely duplicate. The `util-linux` recipe hit
exactly this and documents it: `--disable-more --disable-kill` are there
because `uutils-coreutils` owns those paths.

This is the single most likely way the recipe goes wrong, and it fails at
install time with a message about a file conflict rather than anything
mentioning configure flags.

### Dependencies

`glibc`, `util-linux` (for libblkid/libuuid at runtime, since we disabled the
bundled ones). Build-time: `pkgconf`, and `texinfo` if the info pages are
built — `--disable-nls` does not turn those off.

### What the installer requires of its behaviour

- `-F` must force through the "this is a whole device" prompt without a tty.
  The installer runs non-interactively; a `mke2fs` that stops to ask a question
  hangs the install with no output.
- `-L duct-root` sets the label. The installer does **not** mount by label —
  `fstab` and `root=` both use PARTUUID — so this is for humans reading
  `lsblk`, not for the boot path. Worth stating so nobody later "simplifies"
  the boot path onto the label.
- Default features are fine. The installer passes no `-O`, so whatever
  `mke2fs.conf` ships is what gets used, and **`mke2fs.conf` must be
  installed** — without it `mke2fs` falls back to compiled-in defaults that
  differ from every other distribution's ext4.

---

## Build order

Both are leaves. `e2fsprogs` must come after `util-linux` (it links its
libblkid/libuuid); `dosfstools` after `glibc` and nothing else. Neither is
needed by anything already in the tree, so they can go at the end of the
existing order without disturbing it.

Neither is needed to *build* the installer — only to run it.

---

## What the installed system needs versus what the install needs

Worth separating, because it changes what must be in the ISO manifest versus
what must merely exist:

| | install-time | installed system |
|---|---|---|
| `mkfs.vfat` | **required** | no |
| `mkfs.ext4` | **required** | no |
| `e2fsck` | no | **required** (root fsck at boot) |
| `fsck.fat` | no | required-ish (ESP pass 2) |

Both packages therefore need to be **on the ISO** (the installer runs there)
*and* **in the copied set** (the installed system fscks at boot). Under the
copy-based install design that is automatic — the installed set is the live set
— so adding them to `ISO_EXTRA_PACKAGES` covers both. No second decision.

---

## Test that they work, not that they installed

In the spirit of the rest of this project: the recipe check that matters is not
"the binary exists" but "it produces a filesystem the kernel mounts". A
two-line check inside the build, against a file-backed image:

```sh
truncate -s 64M /tmp/t.img && mkfs.ext4 -F -L duct-root /tmp/t.img
blkid -s TYPE -o value /tmp/t.img   # must print ext4, not merely exit 0

truncate -s 260M /tmp/e.img && mkfs.vfat -F 32 -n DUCT_ESP /tmp/e.img
blkid -s TYPE -o value /tmp/e.img   # must print vfat
```

The `blkid` line is the point. `mkfs.vfat` warning and carrying on is a
documented member of the accepted-and-silently-does-nothing category, so exit
status alone does not establish that a FAT32 filesystem exists. 260M rather
than 64M for the FAT image because below ~256 MiB `mkfs.fat -F 32` refuses
outright, and a check that exercised the refusal path would prove the opposite
of what it intends.

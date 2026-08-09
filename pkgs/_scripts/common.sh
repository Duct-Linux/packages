# Shared helpers for Duct package recipes. Sourced, never executed.
#
# tape-builder runs each stage script as a bare file path -- no shell, no
# arguments -- with the working directory fixed at <recipe>/work. That contract
# is why these are files rather than inline commands, and why they take their
# inputs from the environment and from pkg.env instead of from argv.
#
# Paths are derived from $0, never from $PWD.
#
# tape-builder sets the child's working directory to <recipe>/work but passes
# the parent's environment unchanged, so $PWD still holds whatever directory
# tape-builder itself was started in. bash normally repairs that at startup by
# calling getcwd -- but inside duct/chroot that call fails, and the scripts then
# resolved $PWD/.. to "/" and reported "no pkg.env in //".
#
# $0 is reliable: build.go makes pkgPath absolute before joining the script
# name onto it, so every stage script is invoked by absolute path.

set -eu

# A fixed umask, so directory modes in a package do not depend on the
# environment that happened to build it. linux-headers reproduced everywhere
# except in one directory mode -- usr/include arrived 0775 in one environment
# and 0755 in another, purely because the umask differed, which is enough to
# change the archive bytes and nothing else.
umask 022

log() { printf '  [%s] %s\n' "${TAPE_PACKAGE_NAME:-?}" "$*" >&2; }
die() { printf 'error: [%s] %s\n' "${TAPE_PACKAGE_NAME:-?}" "$*" >&2; exit 1; }

SCRIPTS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || die "cannot locate the script directory"

# A stage script is either the recipe's own (its directory holds pkg.env) or one
# of the shared ones in _scripts/ (a sibling of the recipe directories).
if [ -f "$SCRIPTS_DIR/pkg.env" ]; then
	RECIPE_DIR=$SCRIPTS_DIR
else
	[ -n "${TAPE_PACKAGE_NAME:-}" ] || die "TAPE_PACKAGE_NAME is not set"
	RECIPE_DIR=$(dirname -- "$SCRIPTS_DIR")/$TAPE_PACKAGE_NAME
fi

WORK_DIR=$RECIPE_DIR/work

# Guarantee a usable working directory rather than inheriting a broken one.
mkdir -p "$WORK_DIR"
CDPATH= cd -- "$WORK_DIR" || die "cannot enter $WORK_DIR"

# versions.env sits alongside the recipes and pins every upstream tarball to a
# URL and a sha256. It is sourced first so a pkg.env can refer to $MAKE_URL and
# friends instead of repeating them -- one place to bump a version, rather than
# 29 files that can disagree with each other.
VERSIONS_ENV=$RECIPE_DIR/../versions.env
if [ -f "$VERSIONS_ENV" ]; then
	# shellcheck disable=SC1090
	. "$VERSIONS_ENV"
fi

[ -f "$RECIPE_DIR/pkg.env" ] || die "no pkg.env in $RECIPE_DIR"
# shellcheck disable=SC1091
. "$RECIPE_DIR/pkg.env"

# Where unpacked sources land, and where we build them. Out-of-tree by default:
# glibc refuses an in-tree build outright, and it keeps the source pristine so a
# failed build can be re-run without re-fetching.
: "${SRC_DIR:=}"
SRC_PATH=$WORK_DIR/${SRC_DIR}
BUILD_DIR=$WORK_DIR/build

# Downloads are cached outside the recipe so an iteration loop does not re-fetch
# 100 MB of glibc each time. The builder image mounts a persistent directory
# here; the default keeps a bare `tape-builder build` working anywhere.
SRC_CACHE=${DUCT_SRC_CACHE:-${HOME:-/tmp}/.cache/duct/sources}

JOBS=${DUCT_JOBS:-$(nproc 2>/dev/null || echo 1)}

# A recipe can set any of these in pkg.env; exporting them here is what makes
# configure and make actually see them.
#
# This exists mainly for the C standard. gcc 15 defaults to C23, which turns
# several long-tolerated constructs into hard errors -- most sharply, `void f()`
# now means "takes no arguments" rather than "unspecified", so older code that
# calls such a function with arguments no longer compiles. Packages that have
# not caught up ask for -std=gnu17 here rather than being patched.
for _var in CC CXX CFLAGS CXXFLAGS CPPFLAGS LDFLAGS FORCE_UNSAFE_CONFIGURE PKG_CONFIG; do
	eval "_val=\${$_var:-}"
	[ -n "$_val" ] && export "$_var"
done
unset _var _val

# pkg-config, when the build image only has pkgconf.
#
# pkgconf is a drop-in replacement but only answers to that name, and nothing
# looks for it: autoconf's PKG_PROG_PKG_CONFIG searches for "pkg-config" and
# elfutils and kmod both stop dead with "configure: error: pkg-config not
# found". The pkgconf recipe installs the alias -- but a *published* builder
# image predating that fix does not have it, and CI builds every package in the
# published image. So a recipe set that only builds in an image built from
# itself is circular, and this breaks the circle.
#
# A shim on PATH rather than only exporting PKG_CONFIG, because build systems
# are split on which they honour: configure respects the variable, and plenty
# of Makefiles simply run `pkg-config`.
#
# Dead code the moment the builder images are refreshed, and harmless until
# then -- it does nothing at all when a real pkg-config is present.
if ! command -v pkg-config >/dev/null 2>&1 && command -v pkgconf >/dev/null 2>&1; then
	_shim_dir=$WORK_DIR/.duct-bin
	mkdir -p "$_shim_dir"
	printf '#!/bin/sh\nexec pkgconf "$@"\n' >"$_shim_dir/pkg-config"
	chmod 0755 "$_shim_dir/pkg-config"
	PATH=$_shim_dir:$PATH
	export PATH
	PKG_CONFIG=$_shim_dir/pkg-config
	export PKG_CONFIG
	log "no pkg-config in this image; using pkgconf through a shim"
	unset _shim_dir
fi

# The install staging root. tape-builder points TAPE_INSTALL_DIR at
# <recipe>/work/install, and whatever is under it maps 1:1 onto / in the
# installed system -- work/install/usr/bin/ls becomes /usr/bin/ls.
DESTDIR=${TAPE_INSTALL_DIR:?TAPE_INSTALL_DIR is not set}

# strip_payload -- remove debug symbols from the staging root.
#
# Not cosmetic: an unstripped gcc packages at 818 MB, which makes the images it
# goes into unusable. The three cases are handled differently on purpose --
# --strip-all on a shared library or a static archive destroys it, and the
# .o files in /usr/lib (crt1.o and friends) must not be touched at all or
# nothing will link afterwards.
strip_payload() {
	[ "${KEEP_DEBUG:-0}" = "1" ] && { log "keeping debug symbols"; return 0; }
	command -v strip >/dev/null 2>&1 || return 0

	find "$DESTDIR" -type f -name '*.so*' -exec strip --strip-unneeded {} ';' 2>/dev/null || true
	find "$DESTDIR" -type f -name '*.a' -exec strip --strip-debug {} ';' 2>/dev/null || true
	for d in usr/bin usr/sbin usr/libexec; do
		[ -d "$DESTDIR/$d" ] || continue
		find "$DESTDIR/$d" -type f -exec strip --strip-all {} ';' 2>/dev/null || true
	done
}

# finish_install -- everything that happens after `make install`, whatever ran
# it. Autotools and meson stage the same tree and have the same things wrong
# with it, so the tail of the two install stages was identical; it is shared
# here rather than kept in step by hand.
finish_install() {
	# The GNU info directory index. Every GNU package wants to write it, and
	# tape treats two packages claiming one path as a hard error with no
	# override (daemon/utils/install.go). Nothing regenerates it here anyway,
	# since tape has no install hooks -- so it is dropped rather than fought
	# over.
	rm -f "$DESTDIR/usr/share/info/dir"

	# libtool archives point at build-time paths and break anything that later
	# reads them from a different prefix. Distributions drop them; nothing in
	# Duct links with libtool.
	if [ "${KEEP_LA_FILES:-0}" != "1" ]; then
		find "$DESTDIR" -name '*.la' -type f -delete 2>/dev/null || true
	fi

	if [ "${KEEP_DOCS:-0}" != "1" ]; then
		rm -rf "$DESTDIR/usr/share/doc" "$DESTDIR/usr/share/gtk-doc"
	fi

	# A recipe can do its own final touch-ups -- splitting, moving, generating a
	# config file -- without having to replace the whole install stage.
	if [ -x "$RECIPE_DIR/post-install.sh" ]; then
		log "running post-install.sh"
		"$RECIPE_DIR/post-install.sh" || die "post-install.sh failed"
	fi

	strip_payload

	# An empty payload is almost always a recipe bug -- a wrong DESTDIR, a
	# configure that installed to /usr/local, a make install that quietly did
	# nothing. tape would happily package the emptiness and the mistake would
	# surface much later.
	if [ -z "$(find "$DESTDIR" -mindepth 1 -print -quit 2>/dev/null)" ]; then
		die "staging root is empty; nothing would be packaged"
	fi
}

# memory_jobs -- how many compilations this machine can run at once without
# being killed, which for a few packages is a much smaller number than $JOBS.
#
# Most builds are bounded by cores. A handful are bounded by memory: LLVM's
# larger translation units peak around 2 GB in cc1plus, and its link needs
# several more. On a machine with a conventional amount of RAM per core,
# -j$(nproc) on those does not build slowly, it gets OOM-killed -- and what it
# leaves behind names neither memory nor the job count:
#
#   c++: fatal error: Killed signal terminated program cc1plus
#
# Both of the builds that compile LLVM have hit this: the llvm package, and
# rust, whose x.py builds its own vendored copy. They are in different images
# and were found days apart, which is the argument for one implementation here
# rather than the arithmetic copied into each.
#
#   memory_jobs [<gb_per_job>]   -- default 2 GB per job
#
# Being wrong in the cautious direction costs time; being wrong the other way
# costs the whole build.
memory_jobs() {
	_per=${1:-2}
	_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
	if [ "${_kb:-0}" -le 0 ]; then
		echo 1
		return 0
	fi
	_gb=$((_kb / 1024 / 1024))
	_n=$((_gb / _per))
	[ "$_n" -lt 1 ] && _n=1
	[ "$_n" -gt "$JOBS" ] && _n=$JOBS
	echo "$_n"
}

# verify_sha256 <file> <expected>
verify_sha256() {
	_file=$1
	_want=$2
	if command -v sha256sum >/dev/null 2>&1; then
		_got=$(sha256sum "$_file" | cut -d' ' -f1)
	elif command -v shasum >/dev/null 2>&1; then
		_got=$(shasum -a 256 "$_file" | cut -d' ' -f1)
	else
		die "no sha256sum or shasum available to verify $_file"
	fi
	[ "$_got" = "$_want" ] || {
		printf 'error: [%s] sha256 mismatch for %s\n  want %s\n  got  %s\n' \
			"${TAPE_PACKAGE_NAME:-?}" "$_file" "$_want" "$_got" >&2
		return 1
	}
}

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
for _var in CC CXX CFLAGS CXXFLAGS CPPFLAGS LDFLAGS FORCE_UNSAFE_CONFIGURE; do
	eval "_val=\${$_var:-}"
	[ -n "$_val" ] && export "$_var"
done
unset _var _val

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

#!/usr/bin/env bash
# Generate distro/pkgs/versions.env from an upstream LFS release.
#
# Duct takes its version set wholesale from one LFS book rather than picking
# each package individually. LFS ships a combination that is known to build
# together, so when something fails to compile it is a bug in our recipe rather
# than an argument between two upstreams.
#
# LFS publishes md5sums, which is not a digest anyone should rely on today. So
# this script uses the md5 only to confirm that what arrived is the file LFS
# describes, then records the *sha256* of those exact bytes. From that point on
# fetch.sh verifies sha256 and the md5 never matters again.
#
# All or nothing, deliberately: versions.env is rewritten from scratch on every
# run, so pinning a subset would silently drop every other package. Downloads
# are cached, so a full re-run after a one-package change costs seconds.

set -euo pipefail

LFS_VERSION=${LFS_VERSION:-12.4}
LFS_BASE=https://www.linuxfromscratch.org/lfs/downloads/$LFS_VERSION
CACHE=${DUCT_SRC_CACHE:-$HOME/.cache/duct/sources}
DISTRO=$(cd "$(dirname "$0")/.." && pwd)
OUT=$DISTRO/pkgs/versions.env

# The packages Duct builds, in LFS's naming. uutils-coreutils and tape are not
# here: neither is an LFS package, and both are pinned in their own pkg.env.
#
# GNU coreutils is in the list even though Duct ships uutils. The temporary
# tools that populate the chroot have to be dependable above all else, and they
# are replaced wholesale by the real packages afterwards -- so the bootstrap
# uses the implementation LFS is written against, and uutils becomes the
# shipped one at the end.
PACKAGES=(
	linux glibc zlib binutils gmp mpfr mpc gcc ncurses bash coreutils
	m4 bison flex make gawk sed grep findutils diffutils
	tar gzip xz bzip2 patch file pkgconf perl texinfo
	# LFS chapter 7: built inside the chroot as temporary tools, because
	# glibc's own configure refuses to run without bison and python.
	gettext Python util-linux
)

if [ $# -gt 0 ]; then
	echo "error: this script takes no arguments; it always pins the full set" >&2
	exit 2
fi

mkdir -p "$CACHE" "$DISTRO/pkgs"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "==> LFS $LFS_VERSION"
curl -fsSL --max-time 120 -o "$work/wget-list" "$LFS_BASE/wget-list-sysv"
curl -fsSL --max-time 120 -o "$work/md5sums" "$LFS_BASE/md5sums"

md5_of() {
	if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | cut -d' ' -f1
	else md5 -q "$1"; fi
}
sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
	else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

emit() { printf '%s\n' "$*" >>"$OUT.new"; }

# mirrors_for <url> -- every place worth trying for one tarball, best first.
#
# Upstream hosting is not reliable enough to depend on a single URL. The GNU
# redirector returns 502 when a mirror behind it is unhealthy, and
# invisible-mirror.net serves ncurses out of a "current" directory whose dated
# snapshot disappears the moment a newer one lands -- which is why LFS's own
# ncurses URL 404s a few weeks after each book release.
#
# Content is identical whichever one answers, because everything is verified
# against a digest afterwards.
mirrors_for() {
	local u=$1
	printf '%s\n' "$u"
	case "$u" in
		*ftpmirror.gnu.org/*)
			local rest=${u#https://ftpmirror.gnu.org/}
			printf 'https://ftp.gnu.org/gnu/%s\n' "$rest"
			printf 'https://mirrors.kernel.org/gnu/%s\n' "$rest"
			;;
		*invisible-mirror.net/archives/ncurses/current/*)
			# Fall back to the last stable GNU release rather than chasing a
			# snapshot that is guaranteed to vanish.
			printf 'https://ftp.gnu.org/gnu/ncurses/ncurses-6.5.tar.gz\n'
			printf 'https://mirrors.kernel.org/gnu/ncurses/ncurses-6.5.tar.gz\n'
			;;
	esac
}

# download <dest> <url> -- try each mirror in turn; succeed on the first hit.
download() {
	local dest=$1 url=$2 m
	while read -r m; do
		[ -n "$m" ] || continue
		if curl -fsSL --retry 2 --connect-timeout 20 --max-time 900 -o "$dest.part" "$m"; then
			mv "$dest.part" "$dest"
			printf '%s' "$m"
			return 0
		fi
		rm -f "$dest.part"
		echo "     (mirror failed: $m)" >&2
	done < <(mirrors_for "$url")
	return 1
}

: >"$OUT.new"
emit "# Upstream sources for the Duct package set. GENERATED -- do not edit."
emit "#"
emit "# Pinned to Linux From Scratch $LFS_VERSION (sysv), whose package versions are"
emit "# known to build together. Regenerate with tools/pin-versions.sh."
emit "#"
emit "# Each sha256 is of the exact bytes fetched here, after checking them"
emit "# against LFS's published md5. fetch.sh verifies the sha256 and refuses to"
emit "# unpack anything that does not match."
emit ""

failed=()
for pkg in "${PACKAGES[@]}"; do
	# The tarball for <pkg> is the wget-list line whose basename starts with
	# "<pkg>-" followed by a digit -- the digit is what keeps "gcc" from also
	# matching nothing and "m4" from matching "m4-1.4.20" only by luck.
	# The docs tarball for Python sits next to the source one and matches the
	# same shape, so exclude anything with "-docs-" in the name.
	url=$(grep -E "/${pkg}-[0-9][^/]*$" "$work/wget-list" | grep -v -- '-docs-' | head -1 || true)
	if [ -z "$url" ]; then
		echo "  !! $pkg: not in the LFS list" >&2
		failed+=("$pkg")
		continue
	fi

	# LFS's URLs are kept as published. ftpmirror.gnu.org is a redirector rather
	# than a single host, which is exactly what makes it both fast and durable:
	# individual mirrors come and go, the redirector does not. Pinning
	# ftp.gnu.org instead would be "more canonical" and slow enough to stall a
	# 28-package run for no benefit -- integrity comes from the sha256 below,
	# not from which host served the bytes.
	#
	# The only rewrite is LFS's own typo: github.com// with a doubled slash.
	url=${url//github.com\/\//github.com/}

	file=$(basename "$url")
	want_md5=$(grep -E "  ${file}$" "$work/md5sums" | cut -d' ' -f1 || true)

	if [ ! -f "$CACHE/$file" ]; then
		echo "  fetching $file"
		if ! got_url=$(download "$CACHE/$file" "$url"); then
			echo "  !! $pkg: every mirror failed" >&2; failed+=("$pkg"); continue
		fi
		# A fallback mirror may have served a different release than the one LFS
		# named -- the ncurses snapshot case. Record what actually arrived.
		if [ "$got_url" != "$url" ]; then
			echo "     (served by $got_url)"
			url=$got_url
			newfile=$(basename "$url")
			if [ "$newfile" != "$file" ]; then
				mv "$CACHE/$file" "$CACHE/$newfile"
				file=$newfile
				want_md5=$(grep -E "  ${file}$" "$work/md5sums" | cut -d' ' -f1 || true)
			fi
		fi
	fi

	if [ -n "$want_md5" ]; then
		got_md5=$(md5_of "$CACHE/$file")
		if [ "$got_md5" != "$want_md5" ]; then
			echo "  !! $pkg: md5 mismatch (want $want_md5, got $got_md5)" >&2
			failed+=("$pkg"); continue
		fi
	else
		# No md5 to check against means this is not the file LFS listed -- a
		# substituted release. The sha256 still pins it, but say so out loud
		# rather than letting a silent deviation from the book go unnoticed.
		echo "  ?? $pkg: not the file LFS listed; pinned by sha256 only" >&2
	fi

	# Strip the extension, then the name, to get the version. Everything in the
	# list is <name>-<version>.tar.<compression>.
	base=${file%.tar.*}; base=${base%.tgz}
	version=${base#"$pkg"-}

	var=$(echo "$pkg" | tr '[:lower:]-' '[:upper:]_')
	emit "${var}_VERSION=$version"
	emit "${var}_SRCDIR=$base"
	emit "${var}_URL=$url"
	emit "${var}_SHA256=$(sha256_of "$CACHE/$file")"
	emit ""
	echo "  ok  $pkg $version"
done

# LFS's own patches. These are not upstream releases, so they get pinned the
# same way and applied by the recipe that needs them.
emit "# --- LFS patches ---"
emit ""
while read -r purl; do
	[ -n "$purl" ] || continue
	pfile=$(basename "$purl")
	if [ ! -f "$CACHE/$pfile" ]; then
		echo "  fetching $pfile"
		curl -fsSL --retry 3 --max-time 300 -o "$CACHE/$pfile.part" "$purl" || {
			echo "  !! patch $pfile: download failed" >&2; failed+=("$pfile"); continue
		}
		mv "$CACHE/$pfile.part" "$CACHE/$pfile"
	fi
	want_md5=$(grep -E "  ${pfile}$" "$work/md5sums" | cut -d' ' -f1 || true)
	if [ -n "$want_md5" ] && [ "$(md5_of "$CACHE/$pfile")" != "$want_md5" ]; then
		echo "  !! patch $pfile: md5 mismatch" >&2; failed+=("$pfile"); continue
	fi
	# glibc-2.42-fhs-1.patch -> PATCH_GLIBC_FHS
	pvar=PATCH_$(echo "$pfile" | sed -E 's/-[0-9][^-]*-([a-z_]+)-[0-9]+\.patch$/_\1/; s/\.patch$//' | tr '[:lower:]-.' '[:upper:]__')
	emit "${pvar}_URL=$purl"
	emit "${pvar}_SHA256=$(sha256_of "$CACHE/$pfile")"
	emit ""
	echo "  ok  patch $pfile -> ${pvar}"
done < <(grep -E '/patches/lfs/' "$work/wget-list" || true)

mv "$OUT.new" "$OUT"
echo "==> wrote $OUT"

if [ ${#failed[@]} -gt 0 ]; then
	echo "==> FAILED: ${failed[*]}" >&2
	exit 1
fi

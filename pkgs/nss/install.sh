#!/bin/sh
# Install NSS by hand, because NSS HAS NO `make install`.
#
# Everything below copies out of dist/, following BLFS's own install block. The
# Linux* glob is NSS's object-directory name -- Linux3.x_x86_64_glibc_PTH_64_OPT
# and similar -- which encodes the kernel, arch, threading model and whether the
# build was optimized. It is not stable enough to hardcode and not predictable
# enough to guess, so it is globbed and then CHECKED: exactly one must match.
#
# THE ASSERTIONS HERE DO THE JOB A CONFIGURE SCRIPT WOULD HAVE DONE. NSS has no
# configure, so no variable is ever validated -- a misspelling is silently
# ignored and produces a different build with no diagnostic. So each variable
# the build passes is proved by its effect:
#
#   USE_SYSTEM_ZLIB / ZLIB_LIBS   proved by DT_NEEDED naming the system libz.
#                                 A bundled zlib is linked statically and leaves
#                                 NO trace in the link line -- the libraries
#                                 would look identical.
#   NSS_USE_SYSTEM_SQLITE         proved by DT_NEEDED naming libsqlite3.
#   USE_64 (x86_64)               proved by the ELF class of the result.
#   the standalone patch          proved by nss.pc existing at all, since NSS
#                                 ships no pkg-config file upstream.

. "$(dirname "$0")/../_scripts/common.sh"

dist=$SRC_PATH/dist

# EXACTLY ONE object directory. A glob that matched two would install one of
# them arbitrarily; a glob that matched none would install nothing and, with
# `install` failing quietly under some shells, could leave an empty package.
objdirs=$(find "$dist" -maxdepth 1 -name 'Linux*' -type d | wc -l | tr -d ' ')
[ "$objdirs" = "1" ] || \
	die "expected exactly one Linux* object directory under dist/, found $objdirs. NSS names it from kernel, arch, threading and optimisation, so more than one means a stale tree and none means the build did not stage"
objdir=$(find "$dist" -maxdepth 1 -name 'Linux*' -type d)

log "installing from $(basename "$objdir")"
install -d "$DESTDIR/usr/lib" "$DESTDIR/usr/bin" "$DESTDIR/usr/include/nss" \
	"$DESTDIR/usr/lib/pkgconfig"

install -m755 "$objdir"/lib/*.so "$DESTDIR/usr/lib/" || die "could not install the shared libraries"
install -m644 "$objdir"/lib/*.chk "$DESTDIR/usr/lib/" || die "could not install the .chk integrity files"
install -m644 "$objdir"/lib/libcrmf.a "$DESTDIR/usr/lib/" || die "could not install libcrmf.a"
cp -RL "$dist"/public/nss/* "$DESTDIR/usr/include/nss/" || die "could not install the public headers"
cp -RL "$dist"/private/nss/* "$DESTDIR/usr/include/nss/" || die "could not install the private headers"
for b in certutil nss-config pk12util; do
	install -m755 "$objdir/bin/$b" "$DESTDIR/usr/bin/$b" || die "could not install $b"
done
install -m644 "$objdir"/lib/pkgconfig/nss.pc "$DESTDIR/usr/lib/pkgconfig/" || die "could not install nss.pc"

# --- the patch did its job -----------------------------------------------
[ -s "$DESTDIR/usr/lib/pkgconfig/nss.pc" ] || \
	die "nss.pc is missing or empty. NSS ships NO pkg-config file upstream -- it exists only because patches/0001-nss-standalone.patch adds nss/config and appends it to DIRS in manifest.mn. If the patch stopped applying, every library here would still be correct and e-d-s would fail to find nss"

# --- the libraries e-d-s and its consumers link ---------------------------
for lib in libnss3 libnssutil3 libsmime3 libssl3 libsoftokn3; do
	[ -s "$DESTDIR/usr/lib/$lib.so" ] || \
		die "$lib.so is missing or empty; nss.pc's Libs line names all five and a consumer linking against a partial set fails at link time, not here"
done

# --- the build variables, proved by effect rather than by spelling --------
needs() { readelf -d "$1" 2>/dev/null | grep -qE "NEEDED.*\[$2"; }

# The detector is checked before it is trusted: if this grep silently matched
# nothing, every assertion below would pass on every binary in existence.
needs "$DESTDIR/usr/lib/libnss3.so" 'lib' || \
	die "the DT_NEEDED reader found no NEEDED entries at all in libnss3.so, which cannot be true of a linked shared library -- the check is broken, so its results below would be meaningless"

needs "$DESTDIR/usr/lib/libnss3.so" 'libz\.so' || \
	die "libnss3.so does not link the system zlib. USE_SYSTEM_ZLIB=1 and ZLIB_LIBS=-lz were passed, but NSS has no configure to reject a misspelling -- and a bundled zlib is linked statically, leaving the library looking identical while carrying a second copy of a packaged dependency"

needs "$DESTDIR/usr/lib/libsoftokn3.so" 'libsqlite3\.so' || \
	die "libsoftokn3.so does not link the system sqlite. NSS_USE_SYSTEM_SQLITE=1 was passed and silently ignored, or the header check in build.sh passed while the build disagreed -- either way this package now carries its own sqlite"

case "$(uname -m)" in
x86_64)
	readelf -h "$DESTDIR/usr/lib/libnss3.so" 2>/dev/null | grep -q 'ELF64' || \
		die "libnss3.so is not a 64-bit object on x86_64; USE_64=1 was passed and did not take, which is exactly the failure a raw make build cannot report"
	;;
esac

log "installed NSS $(basename "$objdir"), system zlib and sqlite confirmed by DT_NEEDED"
finish_install

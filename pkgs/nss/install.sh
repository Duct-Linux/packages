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
#   USE_SYSTEM_ZLIB / ZLIB_LIBS   proved by the ABSENCE of a staged libzlib.a.
#   NSS_USE_SYSTEM_SQLITE         proved by the ABSENCE of a staged libsqlite3,
#                                 not by DT_NEEDED -- see below.
#   USE_64 (x86_64)               proved by the ELF class of the result.
#   the standalone patch          proved by nss.pc existing at all, since NSS
#                                 ships no pkg-config file upstream.
#
# BOTH "system library" flags are proved by ABSENCE, and that is deliberate.
# DT_NEEDED cannot answer either question:
#
#   zlib     NOTHING WE INSTALL LINKS ZLIB AT ALL. coreconf/zlib.mk is included
#            by exactly four Makefiles -- cmd/{selfserv,tstclnt,signtool,modutil}
#            -- and by no library. We install none of those four. A DT_NEEDED
#            check for libz here can never pass, on any setting.
#   sqlite   lib/softoken/config.mk passes -lsqlite3 EITHER WAY, and
#            coreconf/location.mk defaults SQLITE_LIB_DIR to $(DIST)/lib. A
#            bundled build links NSS's OWN libsqlite3 and DT_NEEDED names it
#            identically. The check would pass on exactly the build it exists
#            to catch.
#
# What does differ is what gets STAGED into dist/, so that is what is checked:
# lib/Makefile builds lib/zlib and lib/sqlite only when the respective flag is
# undefined. Absent flag, present artefact.

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

needs "$DESTDIR/usr/lib/libsoftokn3.so" 'libsqlite3\.so' || \
	die "libsoftokn3.so links no sqlite at all. This is weaker than it looks -- it cannot tell system sqlite from NSS's own, which is what the staging check below is for -- but softoken without any sqlite means the storage backend did not link"

# USE_SYSTEM_ZLIB took: lib/Makefile sets ZLIB_SRCDIR=zlib only when the flag is
# undefined, so a bundled build stages a static libzlib.a here. It would never
# reach $DESTDIR -- we copy only *.so, *.chk and libcrmf.a -- which is exactly
# why it has to be caught at the staging directory instead.
[ ! -e "$objdir/lib/libzlib.a" ] || \
	die "$objdir/lib/libzlib.a exists, so NSS built its own zlib: USE_SYSTEM_ZLIB was not defined. Nothing we install links zlib, so this would ship looking correct while the four cmd/ tools that do use it carry a second copy of a packaged library"

# NSS_USE_SYSTEM_SQLITE took. This one is not cosmetic: a bundled build stages
# libsqlite3.so, and the *.so glob above would have INSTALLED it -- putting a
# second, NSS-built sqlite into /usr/lib on top of the packaged one.
[ ! -e "$objdir/lib/libsqlite3.so" ] || \
	die "$objdir/lib/libsqlite3.so exists, so NSS built its own sqlite: NSS_USE_SYSTEM_SQLITE was not defined (coreconf sets it on Darwin only, never on Linux). The *.so glob in this script would then ship it over the packaged sqlite"
[ ! -e "$DESTDIR/usr/lib/libsqlite3.so" ] || \
	die "a libsqlite3.so was installed into this package, which belongs to the sqlite package alone"

case "$(uname -m)" in
x86_64)
	readelf -h "$DESTDIR/usr/lib/libnss3.so" 2>/dev/null | grep -q 'ELF64' || \
		die "libnss3.so is not a 64-bit object on x86_64; USE_64=1 was passed and did not take, which is exactly the failure a raw make build cannot report"
	;;
esac

log "installed NSS $(basename "$objdir"); no bundled zlib or sqlite was staged"
finish_install

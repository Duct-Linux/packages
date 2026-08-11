#!/bin/sh
# Stage lua, write the pkg-config file it does not ship, and assert the four
# things wireplumber needs -- each of which goes missing on its own.
#
# THERE IS NO DESTDIR. lua's Makefile predates the convention and offers only
# INSTALL_TOP, so the staging root is passed as the prefix. That is safe here
# for a specific reason rather than by luck: the BLFS patch compiles LUA_ROOT
# into luaconf.h as "/usr/", so the interpreter's runtime module search path is
# baked in separately from wherever `make install` happens to write. Staging
# through the prefix would be wrong for a package that derived its runtime
# paths from it.
#
# TO_LIB is overridden because the top-level Makefile still says
#
#     TO_LIB= liblua.a
#
# even after the shared-library patch. The patch teaches src/Makefile to BUILD
# liblua.so and does not teach the install rule to INSTALL it, so an
# unmodified `make install` here would produce a package containing only the
# static library -- which links, installs, and leaves wireplumber with no
# shared lua to load its modules against.
#
# INSTALL_DATA="cp -d" is not cosmetic either. The default is `install -m 0644`,
# which DEREFERENCES symlinks, so liblua.so and liblua.so.5.4 would each become
# a full second and third copy of the library rather than links to it. The
# assertions below check for symlinks specifically, which is what makes that a
# tested property rather than a hoped-for one.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

log "installing into the staging root"
make INSTALL_TOP="$DESTDIR/usr" \
	INSTALL_MAN="$DESTDIR/usr/share/man/man1" \
	INSTALL_DATA="cp -d" \
	TO_LIB="liblua.so liblua.so.5.4 liblua.so.5.4.8" \
	install || die "make install failed"

# Upstream ships no lua.pc, and pkg-config is the ONLY way wireplumber looks for
# lua -- seven dependency() calls in a row, and every one of them is pkg-config.
#
# The Version line is load-bearing and it is the one field that is easy to get
# wrong without noticing. wireplumber tries lua-5.4, lua5.4, lua54, lua-5.3,
# lua5.3 and lua53 first, all unversioned; this file matches NONE of those. It
# is found by the seventh and last fallback:
#
#     dependency('lua', version: ['>=5.3.0'], required: false)
#
# which is the only one carrying a version constraint. So a lua.pc with a
# missing or malformed Version satisfies nothing, and wireplumber's error says
# "Could not find lua. Lua version 5.4 or 5.3 required" -- which points at the
# lua version rather than at the .pc field that is actually wrong.
install -d "$DESTDIR/usr/lib/pkgconfig"
cat >"$DESTDIR/usr/lib/pkgconfig/lua.pc" <<'PC'
prefix=/usr
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include

Name: Lua
Description: An Extensible Extension Language
Version: 5.4.8
Libs: -L${libdir} -llua -lm -ldl
Cflags: -I${includedir}
PC

finish_install

# The library. The versioned file is the real object; the other two must be
# SYMLINKS, which is the assertion on INSTALL_DATA="cp -d" above.
[ -f "$DESTDIR/usr/lib/liblua.so.5.4.8" ] && [ -s "$DESTDIR/usr/lib/liblua.so.5.4.8" ] \
	|| die "liblua.so.5.4.8 was not installed; the shared-library patch or the TO_LIB override did not take effect"
[ -L "$DESTDIR/usr/lib/liblua.so.5.4" ] \
	|| die "liblua.so.5.4 is not a symlink; INSTALL_DATA=\"cp -d\" did not take effect and the soname is a duplicate copy of the library"
[ -L "$DESTDIR/usr/lib/liblua.so" ] \
	|| die "liblua.so is not a symlink; nothing could link -llua against a versioned file alone"

# The static library is deliberately NOT shipped -- it is what TO_LIB excluded.
# Asserted as an outcome, because the override is a make variable and a typo in
# it fails silently by falling back to the default.
if [ -e "$DESTDIR/usr/lib/liblua.a" ]; then
	die "liblua.a was installed; the TO_LIB override did not take effect, so this package may also be missing the shared library it exists to provide"
fi

# The headers wireplumber compiles against.
for header in lua.h luaconf.h lualib.h lauxlib.h; do
	if [ ! -s "$DESTDIR/usr/include/$header" ]; then
		die "/usr/include/$header is missing; wireplumber's Lua modules would not compile"
	fi
done

# The .pc, checked by content rather than existence, and specifically for the
# Version field the last-fallback lookup constrains.
pc=$DESTDIR/usr/lib/pkgconfig/lua.pc
[ -s "$pc" ] || die "lua.pc was not installed"
grep -q '^Version: 5\.4\.8$' "$pc" \
	|| die "lua.pc has no usable Version line; wireplumber's dependency('lua', version: '>=5.3.0') would not match and it would report the lua version as the problem"
grep -q '^Libs:.*-llua' "$pc" || die "lua.pc does not link -llua"

# The interpreter and compiler. Not needed by wireplumber at run time, but they
# are what makes this a lua package rather than a library drop, and luac is used
# by anything precompiling policy scripts.
[ -s "$DESTDIR/usr/bin/lua" ] || die "the lua interpreter was not installed"
[ -s "$DESTDIR/usr/bin/luac" ] || die "luac was not installed"

log "installed lua with its shared library, headers and pkg-config file"

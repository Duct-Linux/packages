#!/bin/sh
# Stage Xwayland, then assert every gate pkg.env pinned -- and the one it
# could not pin.
#
# Assertions are split between the GENERATED HEADERS and the ARTEFACT on
# purpose. The headers are what configure decided; the artefact is what shipped,
# and for this package the two answer different questions. XWL_HAS_GLAMOR exists
# only in a header. The elogind link exists only in the binary, because the
# option that would seem to control it does not.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

finish_install

xwayland=$DESTDIR/usr/bin/Xwayland
dix=$BUILD_DIR/include/dix-config.h
xwl=$BUILD_DIR/include/xwayland-config.h
xkb=$BUILD_DIR/include/xkb-config.h

[ -x "$xwayland" ] && [ -s "$xwayland" ] \
	|| die "Xwayland was not installed as a non-empty executable at /usr/bin/Xwayland"

for h in "$dix" "$xwl" "$xkb"; do
	[ -f "$h" ] || die "no $(basename "$h") in the build tree; none of the configure-outcome assertions below can run"
done

# ===========================================================================
# GLAMOR -- THE GATE WITH NO OPTION BEHIND IT
# ===========================================================================
#
# include/meson.build:318 is
#
#     build_xwayland_glamor = build_glamor and gbm_dep.found()
#
# and gbm_dep is `dependency('gbm', required: false)`. So -Dglamor=true is only
# half of it: a build image whose mesa was configured without -Dgbm=enabled
# produces an Xwayland that configures green, installs, starts, and renders
# every X11 client through the CPU. No option can turn that into an error.
grep -q '^#define XWL_HAS_GLAMOR 1' "$xwl" \
	|| die "XWL_HAS_GLAMOR is not set: gbm was not found, so -Dglamor=true compiled the glamor code and Xwayland will not use it. Every X11 client would be software-rendered, with nothing failing anywhere"
grep -q '^#define GLAMOR_HAS_GBM 1' "$dix" \
	|| die "GLAMOR_HAS_GBM is not set; mesa's gbm was not found at configure time"

# AND THE REASON THE .pc CANNOT BE USED FOR THIS. hw/xwayland/meson.build:196
# builds xwayland.pc's have_glamor from `build_glamor.to_string()` -- the
# OPTION -- not from build_xwayland_glamor. So xwayland.pc reports
# have_glamor=true even in the failure above, and mutter reads that variable to
# decide what this server can do. The .pc is checked below for the EI portal,
# where it is derived from the outcome; for glamor it is not evidence.
pc=$DESTDIR/usr/lib/pkgconfig/xwayland.pc
[ -s "$pc" ] || die "xwayland.pc was not installed; mutter reads this package's capabilities out of it"

# ===========================================================================
# THE THREE PINNED GATES
# ===========================================================================

# DRI3. -Ddri3=true turns meson.build 343-349 into explicit error() calls, so
# this cannot be false without the build having stopped -- which is the point of
# the pin. Asserted because the flag and the outcome are different things and
# an upstream rename of the option would silently restore `auto`.
grep -q '^#define DRI3 1' "$dix" \
	|| die "DRI3 is not set despite -Ddri3=true; X11 clients would be on the copy-every-frame path"
grep -q '^#define HAVE_XSHMFENCE 1' "$dix" \
	|| die "HAVE_XSHMFENCE is not set; libxshmfence was not found and DRI3 cannot work"

# EMULATED INPUT. Both halves: XWL_HAS_EI is XTEST support at all, and
# XWL_HAS_EI_PORTAL is the RemoteDesktop-portal route -Dxwayland_ei=portal was
# chosen for. These two are `#mesondefine` with a BOOLEAN rather than '1', so
# they appear as a bare `#define NAME` -- matched with a trailing anchor so that
# XWL_HAS_EI does not accidentally match the PORTAL line.
grep -qE '^#define XWL_HAS_EI( |$)' "$xwl" \
	|| die "XWL_HAS_EI is not set; libei was not found and this Xwayland has no XTEST support -- synthetic input into X11 windows, which is remote desktop and every accessibility tool, silently does nothing"
grep -qE '^#define XWL_HAS_EI_PORTAL( |$)' "$xwl" \
	|| die "XWL_HAS_EI_PORTAL is not set; liboeffis was not found, so -Dxwayland_ei=portal fell back to the socket route"
# ===========================================================================
# THE .pc CAPABILITY VARIABLES, CHECKED AGAINST THE BINARY THAT SHIPS
# ===========================================================================
#
# THIS IS THE CHECK NOTHING DOWNSTREAM WILL REPEAT, and packaging this file is
# precisely what stops mutter repeating it.
#
# mutter reads have_initfd, have_listenfd, have_terminate_delay,
# have_byte_swapped_clients, have_enable_ei_portal and have_glamor out of this
# .pc with get_variable(...) == 'true' and bakes a HAVE_* into itself for each.
# It DOES own a real probe -- run Xwayland -help and grep for the option -- but
# that probe lives in the ELSE branch, for when xwayland.pc was not found. When
# the .pc IS found, which is the entire point of this package, the variables are
# trusted with no probe at all. So a .pc that overstates the server gives mutter
# a compiled-in capability the binary does not have, and no build check on
# either side ever notices.
#
# hw/xwayland/meson.build 196-213 builds those variables from a MIXTURE:
#   have_glamor, have_glamor_api   from build_glamor -- THE OPTION, not the
#                                  outcome. build_xwayland_glamor is
#                                  `build_glamor and gbm_dep.found()`, so this
#                                  reports true in exactly the case where
#                                  glamor was compiled and cannot be used.
#   have_decorate, have_enable_ei_portal   from real outcomes.
#   the rest                       hardcoded `true`, asserting the binary
#                                  accepts an option nobody re-checked.
#
# SO THE ORACLE IS THE BINARY'S OWN HELP, which is what mutter's else-branch
# would have used. It is faithful rather than merely convenient, because the
# interesting lines are conditionally compiled on the outcome macros:
# hw/xwayland/xwayland.c wraps "-glamor" in #ifdef XWL_HAS_GLAMOR, "-decorate"
# in XWL_HAS_LIBDECOR and "-enable-ei-portal" in XWL_HAS_EI_PORTAL. The help
# text tells the truth about glamor exactly where the .pc does not.
#
# Running the staged binary is safe and has precedent here (cmake and cbindgen
# both do it): os/utils.c:806 handles -help in ProcessCommandLine with
# UseMsg(); exit(0), which is reached from dix_main long before any Wayland
# connection, DRM device or screen is touched.
help_out=$("$xwayland" -help 2>&1) || true
printf '%s\n' "$help_out" | grep -qF -- '-rootless' \
	|| die "could not read the option list out of the staged Xwayland (-help produced nothing recognisable), so the .pc capability variables cannot be checked against the binary. This check is not optional: it is the only thing standing between a wrong .pc and mutter compiling in a capability the server does not have"

PKGCONF=$(command -v pkg-config || command -v pkgconf) \
	|| die "no pkg-config or pkgconf; cannot read the .pc the way mutter will"
pcv() { PKG_CONFIG_LIBDIR="$DESTDIR/usr/lib/pkgconfig" "$PKGCONF" --variable="$1" xwayland 2>/dev/null; }

# Each pair is `variable:option`. Checked in BOTH directions -- a variable
# claiming true whose option is absent is the hazard above, and one claiming
# false whose option is present means the .pc is understating a capability
# mutter would then refuse to use.
# MATCHED ON THE OPTION TOKEN, NOT ON A SUBSTRING OF THE LINE. Each help line
# is "<option><padding><description>", so the first field IS the option name.
# A plain substring search would be wrong on this very output: the deprecation
# line reads `-listen fd  deprecated, use "-listenfd" instead`, so the string
# "-listenfd" occurs on a line that is NOT the -listenfd option -- and a
# conditionally-compiled option mentioned in another option's prose would read
# as present after being compiled out. Comparing whole tokens removes the class,
# and it also lets `+byteswappedclients` be matched literally without its `+`
# being read as a regex quantifier.
help_opts=$(printf '%s\n' "$help_out" | awk 'NF {print $1}')

pc_mismatch=
for pair in \
	have_glamor:-glamor \
	have_glamor_api:-glamor \
	have_decorate:-decorate \
	have_enable_ei_portal:-enable-ei-portal \
	have_initfd:-initfd \
	have_listenfd:-listenfd \
	have_verbose:-verbose \
	have_terminate_delay:-terminate \
	have_no_touch_pointer_emulation:-noTouchPointerEmulation \
	have_force_xrandr_emulation:-force-xrandr-emulation \
	have_geometry:-geometry \
	have_fullscreen:-fullscreen \
	have_host_grab:-host-grab \
	have_byteswappedclients:+byteswappedclients \
	have_hidpi:-hidpi
do
	var=${pair%%:*}
	opt=${pair#*:}
	claimed=$(pcv "$var")
	if printf '%s\n' "$help_opts" | grep -qxF -- "$opt"; then
		actual=true
	else
		actual=false
	fi
	[ "$claimed" = "$actual" ] \
		|| pc_mismatch="$pc_mismatch $var(.pc=${claimed:-unset},binary=$actual)"
done
if [ -n "$pc_mismatch" ]; then
	die "xwayland.pc disagrees with the binary it describes:$pc_mismatch -- mutter reads these variables and does NOT probe when this .pc exists, so each disagreement is a capability mutter would compile in and the server would not provide"
fi
log "xwayland.pc capability variables all agree with the shipped binary's option list."

# ELOGIND, AND THE ASSERTION THAT REVERSED ITSELF.
#
# This block first asserted that Xwayland DOES link libsystemd, on finding 29's
# fourth mechanism: the lookup is `required: false` (meson.build:107) but sits
# in the COMMON dependency list unguarded (meson.build:406), so "the flag
# controls the feature, not the link". CI refuted it on both arches --
# configure reports "Run-time dependency libsystemd found: YES 255", elogind's
# alias, and the shipped binary has no NEEDED entry for it.
#
# The missing step was the LINKER. -Dsystemd_notify=false compiles out every
# sd_notify call, nothing references a libsystemd symbol, and an --as-needed
# link drops an unreferenced library. So the flag does control the link, by
# controlling whether anything calls into it.
#
# Asserted in the direction that is true, and the message names the consequence:
# if a future image's linker keeps the entry, the DECLARATION has to come back.
#
# First, the FEATURE, which is the half that was right all along and is the
# stable fact here -- it depends only on the flag, not on the linker.
#
# Written as a negative rather than as `grep '^#undef HAVE_SYSTEMD_DAEMON'`,
# because that would assert MESON'S SPELLING OF ABSENCE rather than the absence.
# The fact under test is that the macro is not defined; whether meson records
# that as an #undef line or by omitting the line entirely is not this recipe's
# business. The same mistake in xkbcomp's .pc check cost a CI run.
if grep -qE '^#define HAVE_SYSTEMD_DAEMON( |$)' "$dix"; then
	die "HAVE_SYSTEMD_DAEMON is defined despite -Dsystemd_notify=false; the notify support was compiled in"
fi

command -v readelf >/dev/null 2>&1 \
	|| die "no readelf; cannot verify what Xwayland links, and these checks are not optional"
needed=$(readelf -d "$xwayland" 2>/dev/null) \
	|| die "readelf could not read $xwayland"

# Then the LINK, asserted absent.
if echo "$needed" | grep -q 'NEEDED.*libsystemd\.so'; then
	die "Xwayland links libsystemd, which this recipe does not expect and does not declare. The linker kept an entry for a library nothing calls into -- so either --as-needed is not in effect in this image, or something now references a libsystemd symbol. Either way elogind must go back into [dependencies] in TAPEBUILD.toml, because an undeclared runtime link is a package that installs and cannot start"
fi

# ===========================================================================
# THE REST OF THE LINKS, EACH ONE SILENT WHEN ABSENT
# ===========================================================================
#
# Every entry here is looked up in a way that does NOT fail the build when it is
# missing, or is reached through one that does not -- so configure reporting
# success says nothing about any of them.
#
# THE FULL LIST IS LOGGED BEFORE ANYTHING IS ASSERTED, and that is not
# decoration. The linkage of this binary is the fact these checks are about, it
# is not recoverable from the build log otherwise, and two beliefs about it have
# already turned out to be wrong here. Printing it means the next surprise is
# diagnosable from one run instead of one library per run.
log "NEEDED entries in the shipped Xwayland:"
echo "$needed" | grep 'NEEDED' | sed 's/^[[:space:]]*/  /' >&2

# ACCUMULATED RATHER THAN FAILING ON THE FIRST MISS. A loop that dies on entry
# one tells you about entry one; with a six-minute build behind it, that turns a
# wrong list into a wrong list discovered one element at a time. This reports
# every miss in a single run.
#
# libxkbfile IS DELIBERATELY NOT IN THIS LIST even though xwayland takes
# dependency('xkbfile') as a hard requirement. The server VENDORS the .xkm
# reader: xkb/meson.build compiles its own xkmread.c, xkbfmisc.c and xkbout.c,
# and xkb/ddxLoad.c includes "xkbfile.h" -- the local header, in quotes. So
# XkmReadFile resolves to a definition inside the binary, nothing is imported
# from the library, and --as-needed drops it. Grepping for the symbol finds it
# in ddxLoad.c and is misleading; it is DEFINED in xkmread.c one directory over.
# It is declared under [dependencies.build] instead, which is what it is.
missing=
for lib in libgcrypt libei liboeffis libgbm libepoxy libxshmfence libxcvt libXfont2; do
	echo "$needed" | grep -q "NEEDED.*$lib\.so" || missing="$missing $lib"
done
if [ -n "$missing" ]; then
	die "Xwayland does not link:$missing -- each was found at configure time and is absent from the artefact, and nothing about the build said so. See the NEEDED list above"
fi

# AND THE OTHER DIRECTION, WHICH IS THE ONE THAT COSTS A USER RATHER THAN A
# PACKAGER: every NEEDED entry must be something this recipe declares.
#
# The loop above asks "is each library I expected present" and CANNOT, even in
# principle, notice a library I did not think of. libXau was linked into this
# binary and undeclared through several revisions of this file for exactly that
# reason -- os/auth.c calls XauReadAuth to parse .Xauthority, and libXau appears
# in no dependency() call in meson.build, arriving through xdmcp's pkg-config
# closure. An undeclared runtime link installs cleanly and fails at startup on a
# machine that happens not to have the library.
#
# So this is a CLOSED-WORLD check: anything outside the list is a question that
# has to be answered, by declaring it or by explaining it here. A new entry
# appearing is not necessarily a bug -- it is necessarily a decision.
unexpected=
for soname in $(printf '%s\n' "$needed" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p'); do
	case $soname in
		# glibc, declared.
		libc.so.*|libm.so.*|libdl.so.*|libpthread.so.*|librt.so.*|ld-linux*|ld64.so.*) ;;
		# Each of these is a declared runtime dependency in TAPEBUILD.toml.
		libpixman-1.so.*|libXfont2.so.*|libXdmcp.so.*|libXau.so.*) ;;
		libwayland-client.so.*|libxcvt.so.*|libxshmfence.so.*) ;;
		libdrm.so.*|libepoxy.so.*|libgbm.so.*) ;;
		libei.so.*|liboeffis.so.*|libgcrypt.so.*) ;;
		*) unexpected="$unexpected $soname" ;;
	esac
done
if [ -n "$unexpected" ]; then
	die "Xwayland links libraries this recipe does not account for:$unexpected -- either add each to [dependencies] in TAPEBUILD.toml, or add it to the case above with the reason it needs no declaration. An undeclared runtime link is a package that installs and then cannot start"
fi

# libgcrypt is asserted a second time, from the other direction: the sha1
# provider search is a first match over eight candidates, and the runner-up is a
# bare -lcrypto with no version constraint. Two openssl majors are live in this
# index, so an Xwayland that linked libcrypto instead would be one that may or
# may not start depending on which openssl the machine resolved.
if echo "$needed" | grep -q 'NEEDED.*libcrypto\.so'; then
	die "Xwayland links libcrypto; -Dsha1=libgcrypt did not take effect and the sha1 search fell through to an unversioned -lcrypto, which is the one dependency in this tree with two live majors"
fi

# ===========================================================================
# THE KEYMAP PATH, WHICH IS THREE PACKAGES AGREEING ON TWO STRINGS
# ===========================================================================
#
# Neither of these is pinned in pkg.env: both are resolved from xkbcomp.pc
# (meson.build 116-135), falling back to prefix-derived literals that are the
# same values. Pinning them would make the two agree by decree; asserting them
# checks the value that was actually compiled in, whichever route it came by.
#
# XKB_BIN_DIRECTORY is the one that matters at run time: ddxLoad.c 143-157
# concatenates it with "xkbcomp" and runs the result. It does not search $PATH.
grep -q '^#define XKB_BIN_DIRECTORY "/usr/bin"' "$xkb" \
	|| die "XKB_BIN_DIRECTORY is not /usr/bin; the X server would look for xkbcomp somewhere the xkbcomp package does not install it, and the failure is one log line and a dead keyboard"
grep -q '^#define XKB_BASE_DIRECTORY "/usr/share/X11/xkb"' "$xkb" \
	|| die "XKB_BASE_DIRECTORY is not /usr/share/X11/xkb, which is where xkeyboard-config installs its rules"

# ===========================================================================
# THE FONT PATH -- an outcome assertion for a required:false lookup
# ===========================================================================
#
# meson.build 143-149 takes fontutil.pc `required: false` and falls back to a
# literal built from prefix and datadir. The two produce the same string here,
# so this does not distinguish them -- what it DOES catch is a font root that
# moved, which would leave Xwayland naming six directories nothing installs into
# and no built-in fallback advertised anywhere. The built-in fonts that keep the
# server alive regardless are asserted in pkgs/libXfont2.
grep -q '^#define COMPILEDDEFAULTFONTPATH "/usr/share/fonts/X11/misc' "$dix" \
	|| die "the compiled default font path does not start at /usr/share/fonts/X11/misc; it disagrees with font-util's published fontrootdir"

# ===========================================================================
# THE THINGS THAT MUST NOT BE THERE
# ===========================================================================
#
# Written as `if ...; then die; fi` rather than `[ ... ] && die`, because under
# set -eu the second form makes a PASSING negative assertion the script's exit
# status and fails the build precisely when it succeeds.

# -Dsecure-rpc=false. Its default is true and its default does not build here --
# glibc has no rpc/rpc.h and libtirpc is not packaged -- so this is the one flag
# whose absence is a hard error rather than a silent skip. Asserted anyway,
# because the failure would move to configure time in a future image that
# happened to carry libtirpc, and then it would be silent again.
if grep -q '^#define SECURE_RPC' "$dix"; then
	die "SECURE_RPC is set; -Dsecure-rpc=false did not take effect and the SUN-DES-1 authentication path was compiled in"
fi

# -Dxvfb=false. hw/meson.build 1-3 builds a second X server behind it.
if [ -e "$DESTDIR/usr/bin/Xvfb" ]; then
	die "Xvfb was installed; -Dxvfb=false did not take effect and this package ships a second X server"
fi

# -Ddocs=false and friends. The DocBook chain reaches for xorg-sgml-doctools,
# xmlto, xsltproc and fop, none of which is packaged -- so this currently
# resolves the right way for the wrong reason, and pinning it is what makes the
# outcome a decision.
if [ -d "$DESTDIR/usr/share/doc/xwayland" ]; then
	die "documentation was built and staged despite -Ddocs=false"
fi

# -Dglx=false, asserted as the CAPABILITY GAP it is rather than as a tidy-up.
# glx/meson.build:43 takes dependency('gl', '>= 1.2') unguarded inside
# `if build_glx`, and mesa here is -Dglx=disabled with no libGL, so this cannot
# currently be true -- setting it stops the build at configure. The assertion is
# here so that the day libglvnd is packaged and someone flips the flag, the
# expected outcome is written down next to the check that changes.
if grep -qE '^#define GLXEXT( |$)' "$dix"; then
	die "GLXEXT is defined; -Dglx=false did not take effect, which means dependency('gl') resolved -- if libGL is now packaged this assertion is what needs updating, not the flag"
fi

# ===========================================================================
# WHAT THIS PACKAGE DOES NOT DO
# ===========================================================================
#
# NOT AN ASSERTION AND IT CANNOT BE ONE: nothing here starts Xwayland. It is
# launched by the compositor -- mutter passes it a -displayfd and a -listenfd --
# and the desktop file installed below is for a rootful invocation, not the
# session path. So a correct Xwayland package plus no compositor is still no X11.
[ -s "$DESTDIR/usr/share/applications/org.freedesktop.Xwayland.desktop" ] \
	|| die "the Xwayland desktop file was not installed"
log "note: nothing starts Xwayland. mutter launches it with -displayfd/-listenfd; the desktop file is the rootful path."
log "note: xkbcomp and xkeyboard-config are declared dependencies and are used only at run time -- no build check here can see them."
log "note: NO GLX. X11 clients calling glX* get no visual, because mesa ships no libGL and glx/meson.build requires it."
log "note: glamor is unaffected and X11 drawing is still accelerated -- it reaches GL through epoxy and GLES, not through libGL."

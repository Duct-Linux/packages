#!/bin/sh
# Assert BOTH libraries, because building one of them is the default and the
# other is the entire reason this package is here.
#
# -Dlibnma_gtk4 defaults to FALSE. A build that lost that flag produces a
# perfectly good libnma, installs cleanly, and leaves gnome-control-center
# unable to configure: its meson.build requires libnma-gtk4 unconditionally
# under host_is_linux, with no option to drop it. So the GTK 3 library's
# presence proves nothing at all about the flag that matters.

. "$(dirname "$0")/../_scripts/common.sh"

# --- the GTK 3 library, which is the default and the easy half --------------
[ -s "$DESTDIR/usr/lib/libnma.so" ] \
	|| die "libnma.so is missing"
[ -s "$DESTDIR/usr/lib/pkgconfig/libnma.pc" ] \
	|| die "libnma.pc is missing"

# --- the GTK 4 library, which is the point ----------------------------------
[ -s "$DESTDIR/usr/lib/libnma-gtk4.so" ] \
	|| die "libnma-gtk4.so is missing; -Dlibnma_gtk4=true did not take effect (it defaults to FALSE) and gnome-control-center's network panel cannot be built"
[ -s "$DESTDIR/usr/lib/pkgconfig/libnma-gtk4.pc" ] \
	|| die "libnma-gtk4.pc is missing; gnome-control-center resolves this dependency by pkg-config name and would not find it"

# The typelibs. gnome-control-center reaches these widgets through GObject
# introspection, so a build with the libraries and no typelib links and then
# finds nothing at runtime.
[ -s "$DESTDIR/usr/lib/girepository-1.0/NMA-1.0.typelib" ] \
	|| die "NMA-1.0.typelib is missing; -Dintrospection=true did not take effect"
[ -s "$DESTDIR/usr/lib/girepository-1.0/NMA4-1.0.typelib" ] \
	|| die "NMA4-1.0.typelib is missing; the GTK 4 introspection data was not generated"

# --- the two libraries really are built against different toolkits ----------
# Not a formality. Both are produced from one source tree by one meson run, and
# the failure this catches is a GTK 4 library that quietly linked GTK 3 -- which
# would satisfy every check above and then fail to load beside gnome-control-
# center's own GTK 4. Guarded on readelf, and says so when it cannot run:
# an assertion whose tool is absent has not passed.
if command -v readelf >/dev/null 2>&1; then
	readelf -d "$DESTDIR/usr/lib/libnma.so" 2>/dev/null | grep -q "libgtk-3.so" \
		|| die "libnma.so does not link libgtk-3; the GTK 3 library is not what it claims"
	readelf -d "$DESTDIR/usr/lib/libnma-gtk4.so" 2>/dev/null | grep -q "libgtk-4.so" \
		|| die "libnma-gtk4.so does not link libgtk-4; the GTK 4 library was built against the wrong toolkit"
	if readelf -d "$DESTDIR/usr/lib/libnma-gtk4.so" 2>/dev/null | grep -q "libgtk-3.so"; then
		die "libnma-gtk4.so links libgtk-3 as well as libgtk-4; loading both toolkits in one process does not work"
	fi
else
	log "warning: readelf is unavailable, so the toolkit-linkage checks DID NOT RUN."
	log "warning: the library and typelib checks above still passed."
fi

# --- what is absent, and why it is not a defect -----------------------------
# THESE NOTES WENT STALE ONCE AND WERE CORRECTED BY RUNNING THE BUILD. They
# used to say the gcr loss was "consistent" because NetworkManager could not
# read a certificate at all under -Dcrypto=null, and that there was no mobile
# broadband panel under -Dmodem_manager=false. Both were true when written and
# both stopped being true when the NetworkManager recipe changed beside this
# one -- so a note describing a NEIGHBOUR is a note that can rot without this
# file being touched. Kept, but stated as of what NetworkManager is now.
log "note: -Dgcr=false, so there is no advanced certificate chooser widget."
log "note: NetworkManager IS built -Dcrypto=gnutls, so certificates themselves"
log "note: work -- what is missing is the browse-and-inspect UI, not the"
log "note: capability. gcr belongs to another chain and is not packaged."
log "note: -Dmobile_broadband_provider_info=false, so the wizard cannot prefill"
log "note: APN and credentials from an operator list. NetworkManager DOES have"
log "note: mobile broadband (-Dmodem_manager=true); the database is a separate"
log "note: data package nobody has yet, and it needs no rebuild to add."

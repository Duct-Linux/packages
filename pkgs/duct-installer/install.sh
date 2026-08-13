#!/bin/sh

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing the Duct installer into the staging root"
DESTDIR="$DESTDIR" ninja install || die "ninja install failed"

[ -x "$DESTDIR/usr/bin/duct-installer" ] || \
	die "the graphical duct-installer binary was not installed"
[ -x "$DESTDIR/usr/bin/duct-install-cli" ] || \
	die "the serial-console test harness was not installed"

# The live image is a graphical session.  Install a launcher so the installer
# is discoverable from GNOME rather than requiring users to know its command.
install -d -m 0755 "$DESTDIR/usr/share/applications"
cat >"$DESTDIR/usr/share/applications/org.ductlinux.Installer.desktop" <<'EOF'
[Desktop Entry]
Name=Install Duct Linux
Comment=Install Duct Linux to a disk
Exec=duct-installer
Icon=system-software-install
Terminal=false
Type=Application
Categories=System;Utility;
Keywords=install;setup;duct;
StartupNotify=true
EOF
[ -s "$DESTDIR/usr/share/applications/org.ductlinux.Installer.desktop" ] || \
	die "the GNOME desktop entry was not installed"

finish_install
log "installed duct-installer 0.1.0"

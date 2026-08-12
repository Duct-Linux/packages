#!/bin/sh
. "$(dirname "$0")/../_scripts/common.sh"

install -d -m 0755 "$DESTDIR/usr/lib/prmpt" "$DESTDIR/usr/bin" \
	"$DESTDIR/usr/share/applications"
install -m 0755 "$WORK_DIR/Prmpt.AppImage" "$DESTDIR/usr/lib/prmpt/Prmpt.AppImage"
cat >"$DESTDIR/usr/bin/prmpt" <<'EOF'
#!/bin/sh
# Avoid the AppImage FUSE 2 dependency; its embedded runtime extracts to a
# temporary directory and starts the application from there.
exec /usr/lib/prmpt/Prmpt.AppImage --appimage-extract-and-run "$@"
EOF
chmod 0755 "$DESTDIR/usr/bin/prmpt"
cat >"$DESTDIR/usr/share/applications/io.github.dssnet.Prmpt.desktop" <<'EOF'
[Desktop Entry]
Name=Prmpt
Comment=Terminal Emulator
Exec=prmpt
Icon=utilities-terminal
Terminal=false
Type=Application
Categories=System;TerminalEmulator;
StartupNotify=true
EOF
[ -x "$DESTDIR/usr/bin/prmpt" ] || die "Prmpt launcher was not installed"
finish_install

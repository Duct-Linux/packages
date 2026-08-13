#!/bin/sh
. "$(dirname "$0")/../_scripts/common.sh"

install -d -m 0755 "$DESTDIR/usr/lib/prmpt" "$DESTDIR/usr/bin" \
	"$DESTDIR/usr/share/applications"
install -m 0755 "$WORK_DIR/Prmpt.AppImage" "$DESTDIR/usr/lib/prmpt/Prmpt.AppImage"
cat >"$DESTDIR/usr/bin/prmpt" <<'EOF'
#!/bin/sh
# Avoid the AppImage FUSE 2 dependency; its embedded runtime extracts to a
# temporary directory and starts the application from there.
# WebKitGTK's DMA-BUF and accelerated compositing paths can abort a Wayland
# session on virtual GPUs.  Prmpt is a terminal, so the shared-memory software
# path is the safer default and has no meaningful UI-performance cost.
export WEBKIT_DISABLE_DMABUF_RENDERER="${WEBKIT_DISABLE_DMABUF_RENDERER:-1}"
export WEBKIT_DISABLE_COMPOSITING_MODE="${WEBKIT_DISABLE_COMPOSITING_MODE:-1}"
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

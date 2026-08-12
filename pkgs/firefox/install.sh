#!/bin/sh
. "$(dirname "$0")/../_scripts/common.sh"

install -d -m 0755 "$DESTDIR/usr/lib" "$DESTDIR/usr/bin" \
	"$DESTDIR/usr/share/applications" "$DESTDIR/usr/share/icons/hicolor/128x128/apps"
cp -R "$SRC_PATH" "$DESTDIR/usr/lib/firefox"
ln -s ../lib/firefox/firefox "$DESTDIR/usr/bin/firefox"
install -m 0644 "$SRC_PATH/browser/chrome/icons/default/default128.png" \
	"$DESTDIR/usr/share/icons/hicolor/128x128/apps/firefox.png"
cat >"$DESTDIR/usr/share/applications/firefox.desktop" <<'EOF'
[Desktop Entry]
Name=Firefox
Comment=Browse the Web
Exec=firefox %u
Icon=firefox
Terminal=false
Type=Application
Categories=Network;WebBrowser;
MimeType=text/html;x-scheme-handler/http;x-scheme-handler/https;
StartupNotify=true
EOF
[ -x "$DESTDIR/usr/lib/firefox/firefox" ] || die "Firefox binary was not installed"
finish_install


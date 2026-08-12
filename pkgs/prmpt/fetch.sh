#!/bin/sh
. "$(dirname "$0")/../_scripts/common.sh"

archive=$SRC_CACHE/$SRC_FILE
[ -f "$archive" ] || die "$SRC_FILE is absent from the source cache"
verify_sha256 "$archive" "$SRC_SHA256" || die "Prmpt AppImage digest mismatch"
install -m 0755 "$archive" "$WORK_DIR/Prmpt.AppImage"
[ -x "$WORK_DIR/Prmpt.AppImage" ] || die "Prmpt AppImage was not staged"

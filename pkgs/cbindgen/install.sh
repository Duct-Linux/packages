#!/bin/sh
# Stage cbindgen: one binary, and an assertion that it is a working one.
#
# cargo has no install target that stages into a DESTDIR, so the binary is
# copied by hand. That makes "did anything useful get installed" a real
# question rather than a rhetorical one -- a copy from the wrong path installs
# nothing and fails no command.
#
# The version is checked as well as the file, because mozjs's configure does not
# merely look for the program: it runs `cbindgen --version` and compares against
# a minimum of 0.27.0, and a binary that cannot run produces the same
# FatalCheckError as one that is absent.

. "$(dirname "$0")/../_scripts/common.sh"

bin=$SRC_PATH/target/release/cbindgen
[ -s "$bin" ] || die "no cbindgen binary at $bin"

install -Dm755 "$bin" "$DESTDIR/usr/bin/cbindgen" || die "could not stage the cbindgen binary"
[ -s "$DESTDIR/usr/bin/cbindgen" ] || die "staged cbindgen is empty"

# Run the staged copy. This is a native build in a native image, so it executes;
# and it is the exact invocation mozjs's configure makes --
#   version = Version(check_cmd_output(cbindgen, "--version").strip().split(" ")[1])
# -- so a binary that prints nothing, or prints something unparseable, fails
# here rather than three packages later inside a python traceback.
reported=$("$DESTDIR/usr/bin/cbindgen" --version 2>/dev/null) \
	|| die "the staged cbindgen does not run"
case "$reported" in
	"cbindgen "*) : ;;
	*) die "cbindgen --version printed '$reported'; mozjs's configure splits that on a space and reads field 2, so it would not parse" ;;
esac

finish_install
log "installed $reported"

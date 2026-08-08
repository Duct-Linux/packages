#!/bin/sh
# Build CMake with its own bootstrap script.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

# cmake builds itself: bootstrap compiles a minimal cmake with the C++ compiler,
# then that cmake configures the real one. --no-system-libs is the default and
# is kept -- Duct packages none of curl, expat, jsoncpp, librhash or nghttp2, and
# building against bundled copies is what the bootstrap path is for.
#
# --parallel is passed explicitly: bootstrap otherwise builds single-threaded,
# which turns ten minutes into an hour.
#
# OpenSSL is off because Duct does not package it. The cost is that cmake's
# bundled curl cannot verify TLS, so `file(DOWNLOAD https://...)` is untrusted.
# That is acceptable here and nowhere else: this cmake exists to configure LLVM
# from a tarball already verified by sha256, in a container with no network.
#
# ccmake, the curses front end, is off. ncurses defines `bool` as a macro, which
# in C++ turns std::numeric_limits<bool> into a redefinition of
# numeric_limits<unsigned char> and breaks every explicit operator bool in
# cmake's own headers. Nothing here needs an interactive TUI.
log "bootstrapping cmake"
./bootstrap \
	--prefix=/usr \
	--parallel="$JOBS" \
	--no-qt-gui \
	-- -DCMAKE_BUILD_TYPE=Release \
	   -DCMAKE_USE_OPENSSL=OFF \
	   -DBUILD_CursesDialog=OFF \
	|| die "bootstrap failed"

log "building"
make -j"$JOBS" || die "make failed"

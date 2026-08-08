#!/bin/sh
# Stage the Go toolchain.

. "$(dirname "$0")/../_scripts/common.sh"

goroot=$DESTDIR/usr/lib/go
install -d "$goroot" "$DESTDIR/usr/bin"

# GOROOT is a single tree: the compiler looks for its own sources, standard
# library and tools relative to it, so this is copied whole rather than split
# across bin/, lib/ and share/ the way a C package would be.
cd "$SRC_PATH"
for d in bin pkg src lib api go.env VERSION; do
	[ -e "$d" ] || continue
	cp -a "$d" "$goroot/"
done

# Not shipped: the test corpus and the git metadata, which together are larger
# than the toolchain and are of no use on an installed system.
rm -rf "$goroot/pkg/obj" "$goroot/src/cmd/vendor/golang.org/x/tools/gopls"
find "$goroot" -name 'testdata' -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$goroot" -name '*_test.go' -delete 2>/dev/null || true

for b in go gofmt; do
	[ -x "$goroot/bin/$b" ] || die "$b was not built"
	ln -sf ../lib/go/bin/$b "$DESTDIR/usr/bin/$b"
done

# GOTOOLCHAIN=local stops the toolchain fetching and running a *different*
# compiler when a go.mod asks for a newer one, which would make a build depend
# on whatever upstream published that day.
#
# Appended, not written: go.env also carries GOPROXY and GOSUMDB, and replacing
# the file wholesale left GOPROXY empty, so every module fetch failed with
# "GOPROXY list is not the empty string, but contains no entries" -- which looks
# like a network fault and is not one.
if [ -f "$goroot/go.env" ]; then
	grep -v '^GOTOOLCHAIN=' "$goroot/go.env" > "$goroot/go.env.new" || true
	printf 'GOTOOLCHAIN=local\n' >> "$goroot/go.env.new"
	mv "$goroot/go.env.new" "$goroot/go.env"
else
	printf 'GOTOOLCHAIN=local\n' > "$goroot/go.env"
fi

strip_payload

log "installed go into /usr/lib/go with /usr/bin/{go,gofmt}"

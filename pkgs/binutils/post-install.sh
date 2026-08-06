#!/bin/sh
# Drop the static archives.
#
# Two reasons. Nothing in Duct links binutils statically, so they are dead
# weight -- and libiberty.a in particular is also shipped by gcc, which tape
# treats as a file conflict and refuses to install, with no override.

. "$(dirname "$0")/../_scripts/common.sh"

for a in bfd ctf ctf-nobfd opcodes sframe iberty; do
	rm -f "$DESTDIR/usr/lib/lib$a.a"
done

log "static archives removed"

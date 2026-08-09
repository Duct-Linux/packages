#!/bin/sh
# Configure and build busybox from defconfig plus config.fragment.
#
# In-tree, unlike the generic build stage. busybox's kbuild does support O=,
# but its own documentation treats the in-tree build as the supported path, and
# the source is discarded with work/ the moment the package is wrapped -- so
# out-of-tree buys nothing here and costs a class of failure.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

log "starting from defconfig"
make defconfig >/dev/null || die "make defconfig failed"

# Apply the fragment by symbol name rather than by appending it wholesale: a
# duplicate CONFIG_STATIC line would leave the *first* one in force, and the
# first one is defconfig's "not set". Deleting the old line and writing the new
# one is the only way the fragment reliably wins.
fragment=$RECIPE_DIR/config.fragment
[ -f "$fragment" ] || die "config.fragment is missing"

log "applying config.fragment"
while IFS= read -r line; do
	case "$line" in
		'#'*' is not set')
			symbol=${line#\# }
			symbol=${symbol%% *}
			;;
		CONFIG_*=*)
			symbol=${line%%=*}
			;;
		*)
			# Comments and blank lines.
			continue
			;;
	esac

	# ^SYMBOL= catches an enabled setting, ^# SYMBOL is not set the disabled
	# one. Anchoring on both keeps CONFIG_MOUNT from also matching
	# CONFIG_MOUNTPOINT.
	sed -i -e "/^${symbol}=/d" -e "/^# ${symbol} is not set\$/d" .config
	printf '%s\n' "$line" >>.config
done <"$fragment"

# oldconfig resolves whatever the fragment's changes imply -- symbols that
# became reachable, symbols that lost their dependency. Empty answers take the
# default for anything it still has to ask about.
yes '' | make oldconfig >/dev/null || die "make oldconfig failed"

grep -q '^CONFIG_STATIC=y$' .config || \
	die "CONFIG_STATIC did not survive oldconfig; the binary would need glibc at boot"

log "building with -j$JOBS"
make -j"$JOBS" || die "make failed"

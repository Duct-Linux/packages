#!/bin/sh
# Install the freedesktop sound theme, and generate the one file upstream's
# build system would have generated -- then CHECK THAT GENERATION against
# upstream's own template.
#
# See pkg.env for why this recipe does not use upstream's build system. The
# short version: doing so would need intltool and XML::Parser, two unpackaged
# LFS packages, whose entire effect on this package is to strip one underscore
# from _Name in a six-line file that has no translations to merge.
#
# THE DRIFT CHECK IS THE PRICE OF THAT CHOICE. Hand-writing a generated file
# means our copy silently stops matching if upstream's template ever grows real
# content. So index.theme is not simply written from memory: every key in
# upstream's index.theme.in is compared against the set this recipe knows how to
# translate, and an unknown key is a build failure rather than a silent
# omission. intltool-merge's actual transformation is "strip the leading
# underscore from translatable keys and drop nothing", so reproducing it is
# exact for as long as the key set is the one below.

. "$(dirname "$0")/../_scripts/common.sh"

theme_dir=$DESTDIR/usr/share/sounds/freedesktop

log "installing the sound theme"
install -d "$theme_dir/stereo"

# The audio itself. Copied rather than globbed into a variable so a rename
# upstream shows up as a missing file rather than as an empty install.
for f in "$SRC_PATH"/stereo/*.oga; do
	[ -e "$f" ] || die "no .oga files found in the tarball's stereo/ directory"
	install -m 644 "$f" "$theme_dir/stereo/"
done

# THE GENERATED FILE, AND THE CHECK THAT IT IS STILL A FAITHFUL GENERATION.
#
# Keys this recipe knows how to reproduce. A translatable key is written with
# its leading underscore stripped; a plain key is copied verbatim. That is
# precisely what intltool-merge does when there are no translations.
template=$SRC_PATH/index.theme.in
[ -s "$template" ] || die "index.theme.in is missing from the tarball; upstream restructured the package and this recipe's generated index.theme can no longer be trusted to match it"

known='_Name|Name|Directories|OutputProfile|Comment|_Comment|Inherits|Example|Hidden'
unknown=$(grep -o '^[A-Za-z_][A-Za-z_-]*=' "$template" | tr -d '=' | grep -E -v "^($known)$" || true)
if [ -n "$unknown" ]; then
	die "upstream's index.theme.in contains key(s) this recipe does not know how to reproduce: $(echo "$unknown" | tr '\n' ' '). This recipe hand-generates index.theme because building it upstream's way needs intltool and XML::Parser -- see pkg.env -- and that is only safe while the template is the file it was written against. Add the key here, or package intltool and use the real build system"
fi

# Reproduce the generation: strip the underscore from translatable keys, keep
# section headers and plain keys as they are, drop nothing.
sed -e 's/^_//' "$template" > "$theme_dir/index.theme" || die "generating index.theme failed"

[ -s "$theme_dir/index.theme" ] || die "index.theme is empty after generation"
grep -q '^Name=' "$theme_dir/index.theme" || \
	die "the generated index.theme has no Name= key; libcanberra resolves a theme by that name and would not find this one"

count=$(find "$theme_dir/stereo" -name '*.oga' | wc -l | tr -d ' ')
[ "$count" -ge 20 ] || \
	die "only $count sound files were installed. This package exists to give libcanberra something to play -- with the player installed and no sounds, every desktop event is silent and no build check anywhere covers that join"

finish_install
log "installed the freedesktop sound theme with $count sounds"

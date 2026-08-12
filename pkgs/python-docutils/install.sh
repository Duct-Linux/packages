#!/bin/sh
# Install docutils: the module, and the console scripts declared by its own
# pyproject.toml.
#
# WHY THE SCRIPTS ARE GENERATED RATHER THAN COPIED. docutils 0.21 moved its
# commands to [project.scripts] entry points; the tools/ directory still carries
# rst2man.py, but the INSTALLED name upstream defines is generated from the
# entry point, and that is what consumers look for. This tree's python is built
# --without-ensurepip, so there is no pip to expand those entry points and they
# have to be written here.
#
# THE LIST IS DERIVED FROM pyproject.toml, NOT HARDCODED. Only rst2man has a
# consumer today, and it would be easy to install that one alone -- but then the
# recipe silently disagrees with upstream about what this package provides, and
# the next package that wants rst2html finds a docutils that half exists. A
# hand-picked subset is a second source of truth about somebody else's package.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

sitedir=$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])') \
	|| die "cannot ask python3 where its site-packages live"

install -d "$DESTDIR$sitedir" "$DESTDIR/usr/bin"
cp -a docutils "$DESTDIR$sitedir/" || die "could not stage the docutils module"

# Each line of [project.scripts] is `name = "module:function"`.
scripts=$(awk '/^\[project\.scripts\]/{f=1;next} /^\[/{f=0} f && /=/{print}' pyproject.toml)
[ -n "$scripts" ] || \
	die "no [project.scripts] table found in pyproject.toml; upstream restructured the package and this recipe would install a module with no commands, which is the half mutter actually needs"

count=0
echo "$scripts" | while IFS= read -r line; do
	name=$(printf '%s' "$line" | sed 's/[[:space:]]*=.*//')
	target=$(printf '%s' "$line" | sed 's/.*=[[:space:]]*"//; s/"[[:space:]]*$//')
	mod=${target%%:*}
	fn=${target##*:}
	[ -n "$name" ] && [ -n "$mod" ] && [ -n "$fn" ] || continue
	cat > "$DESTDIR/usr/bin/$name" <<EOF
#!/usr/bin/python3
import sys
from $mod import $fn
sys.exit($fn())
EOF
	chmod 755 "$DESTDIR/usr/bin/$name"
done

# rst2man is asserted by name because it is the reason this package exists: a
# docutils with the module and no commands installs cleanly and fails mutter
# under a name that is not this one.
[ -s "$DESTDIR/usr/bin/rst2man" ] || \
	die "rst2man was not generated. It is the only reason this package is in the tree -- mutter's doc/man/meson.build:3 calls find_program('rst2man') with no required:false and subdir('doc/man') is unconditional, so mutter cannot build without it"
[ -f "$DESTDIR$sitedir/docutils/core.py" ] || \
	die "docutils/core.py is missing; every generated script imports from it"

count=$(find "$DESTDIR/usr/bin" -type f | wc -l | tr -d ' ')
finish_install
log "installed docutils with $count console scripts"

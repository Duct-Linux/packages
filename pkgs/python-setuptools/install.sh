#!/bin/sh
# Install setuptools by copying it, like the other pure-Python packages here.
#
# Not by running its own installer: setuptools installs itself with setuptools,
# and there is not one yet. The three directories below are what the wheel
# contains, and copying them is what an installer would end up doing.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

sitedir=$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])') \
	|| die "cannot ask python3 where its site-packages live"

install -d "$DESTDIR$sitedir"

# pkg_resources is separate from setuptools and older code still imports it;
# _distutils_hack is what makes `import distutils` resolve to setuptools' vendored
# copy, which is the only distutils there is on Python 3.12 and later.
for mod in setuptools pkg_resources _distutils_hack; do
	[ -d "$mod" ] || die "$mod is not in the source tree"
	cp -a "$mod" "$DESTDIR$sitedir/" || die "could not stage $mod"
done

# distutils-precedence.pth is not in the sdist -- setuptools generates it when
# it builds a wheel -- and without it the three directories above are inert for
# the one job they are packaged to do. `import distutils` is not satisfied by
# setuptools/_distutils being on disk: it is satisfied by a meta-path finder
# that _distutils_hack installs, and a .pth file is the only thing Python runs
# early enough to install one.
#
# gobject-introspection is precisely the case. With the modules staged but no
# .pth, its meson check for "setuptools" passes and then g-ir-scanner dies at
# `import distutils.cygwinccompiler` with ModuleNotFoundError -- a failure two
# stages later that says nothing about the missing file.
#
# The line is setuptools' own, reproduced rather than invented.
cat >"$DESTDIR$sitedir/distutils-precedence.pth" <<'PTH'
import os; var = 'SETUPTOOLS_USE_DISTUTILS'; enabled = os.environ.get(var, 'local') == 'local'; enabled and __import__('_distutils_hack').add_shim();
PTH

find "$DESTDIR$sitedir" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true

[ -f "$DESTDIR$sitedir/setuptools/__init__.py" ] || die "setuptools was not staged"
[ -d "$DESTDIR$sitedir/setuptools/_distutils" ] || die "the vendored distutils is missing"

finish_install
log "installed setuptools into $sitedir"

#!/bin/sh
# Stage glib-networking, and assert that the backend this recipe argued for is
# the one that actually got built.
#
# This package departs from an explicit upstream instruction to enable the
# openssl backend instead of gnutls (see pkg.env for the argument). The argument
# is worth nothing if the module that ships is not the one it names, and the
# GIO module system makes that failure quiet: a missing TLS module does not
# error, it leaves g_tls_backend_get_default() returning a backend that reports
# no TLS support, and every HTTPS connection fails later with a message about
# TLS not being available rather than about a missing package.
#
# WHAT THIS DOES NOT PROVE, stated plainly because the distinction is the whole
# point of the condition attached to this decision: THIS ASSERTS WHICH MODULE
# WAS BUILT, NOT THAT IT VERIFIES CERTIFICATES CORRECTLY. A weak verifier's
# failure mode is that everything works, so the only evidence that counts is a
# runtime test with a NEGATIVE arm -- an untrusted or mismatched certificate
# must be REJECTED. That cannot run here: the build container has no network by
# design. See VERIFICATION-REQUIRED.md in this directory.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

moddir=$DESTDIR/usr/lib/gio/modules
[ -d "$moddir" ] || die "no GIO module directory was installed"

# POSITIVE CONTROL FIRST: the directory must contain something, or the two
# checks below are well-formed answers to nothing.
[ -n "$(find "$moddir" -name '*.so' -print -quit)" ] || \
	die "the GIO module directory is empty; the module scan below would prove nothing"

finish_install

if [ ! -e "$moddir/libgioopenssl.so" ]; then
	log "GIO modules present:"
	find "$moddir" -name '*.so' | sed 's/^/    /'
	die "the openssl TLS module was not installed; this recipe's whole argument is that it is the backend in use"
fi

if [ -e "$moddir/libgiognutls.so" ]; then
	die "a gnutls TLS module was also installed; the point of -Dgnutls=disabled is that exactly one TLS backend exists in this stack"
fi

log "installed glib-networking with the openssl TLS backend and no gnutls module"

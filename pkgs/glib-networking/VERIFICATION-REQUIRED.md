# glib-networking: the verification this package is conditional on

This recipe enables the **openssl** TLS backend and disables gnutls, against an
explicit upstream instruction. `pkg.env` carries the argument. This file carries
the condition attached to it, because the argument alone is not sufficient.

## Why a build-time check cannot settle it

`install.sh` asserts that `libgioopenssl.so` is installed and `libgiognutls.so`
is not. That establishes **which backend exists**, and nothing more.

The warning upstream gives is real even though its stated reason (licensing) does
not apply to Duct: the openssl backend is the **less exercised path**, and the
failure mode of a weak certificate verifier is that **everything works**. A build
that produces the right module tells you nothing about whether that module
rejects a certificate it should reject.

The build container has no network, by design. So this cannot be measured where
the package is made.

## The test, with the arm that matters

Run on a booted Duct system with `glib-networking`, `libsoup` and
`ca-certificates` installed.

**Positive arm** — a valid endpoint must succeed:

    gio info https://flathub.org/    # or any GIO/libsoup HTTPS fetch

**Negative arm — this is the measurement.** A certificate that should be
rejected must be rejected:

    # untrusted root
    gio info https://untrusted-root.badssl.com/
    # hostname mismatch
    gio info https://wrong.host.badssl.com/
    # expired
    gio info https://expired.badssl.com/

All three must **fail**. If any succeeds, the backend is accepting what it should
reject, and this recipe's decision must be reversed to gnutls.

**The positive arm alone proves only that bytes moved.** Three checks earlier in
this workstream produced confident results from tests that could not fail; a
verifier that accepts everything passes every positive test ever written for it.

## If the negative arm fails

Flip the decision, and the two-stacks argument that motivated it disappears
because gnutls becomes the only TLS implementation in the process:

    -Dgnutls=enabled -Dopenssl=disabled

and package the gnutls chain: nettle with hogweed, libtasn1, and p11-kit, plus
libidn2/libunistring if IDNA support is wanted. gmp is already packaged.
gnutls offers `--with-included-libtasn1` and `--with-included-unistring`, which
reduce that chain at the cost of vendoring — the same trade this workstream
refused for bubblewrap and xdg-dbus-proxy, and for the same reason.

## Status

**NOT YET VERIFIED.** This package should not be treated as finished until the
negative arm has been run on a booted system and recorded here.

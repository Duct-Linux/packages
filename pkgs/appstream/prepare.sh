#!/bin/sh
# Drop AppStream's manual pages.
#
# docs/meson.build is entered unconditionally -- there is no option that skips
# it -- and it hard-errors at configure time:
#
#   ERROR: Unable to find Docbook XSL stylesheets for man pages
#
# It resolves the stylesheet by asking xsltproc for an http:// URL with
# --nonet, which only succeeds if a local XML catalogue maps that URL to an
# installed copy. That would mean packaging docbook-xsl and, more awkwardly,
# owning /etc/xml/catalog -- a single system-wide file assembled from every
# package that registers a DTD, which is the same "no package can own it"
# problem as the caches the image build regenerates.
#
# Every other recipe in this tier already builds without its manual pages for
# exactly this reason: kmod, eudev, dbus, Linux-PAM, wayland and mesa are all
# configured with docs off. AppStream simply does not offer the switch, so the
# same decision is made here with sed instead of with an option.
#
# What is lost is `man appstreamcli`. The library, the tool and the metadata
# parsing libadwaita needs are all unaffected.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

grep -q "^subdir('docs/')" meson.build \
	|| die "meson.build no longer has the docs subdir; check whether this is still needed"

sed -i "/^subdir('docs\/')/d" meson.build || die "could not drop the docs subdir"

log "manual pages dropped; no docbook stylesheets are packaged"

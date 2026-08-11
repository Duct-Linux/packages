#!/usr/bin/env bash
# Build the four-certificate fixture for QEMU-TEST-PLAN.md §5b.
#
#   tls-fixture.sh <outdir>
#
# Entirely offline. A live Duct guest almost certainly cannot obtain an IP --
# no CONFIG_IP_PNP, no dhcpcd, no iproute2, and busybox ships no applet
# symlinks -- so an external endpoint like badssl.com cannot be assumed
# reachable, and a plan that depends on one is a plan that does not run. This
# generates everything locally and serves it on 127.0.0.1, which works under
# `qemu -nic none`.
#
# WHAT IT PRODUCES, and each leaf has EXACTLY ONE defect so a rejection names
# its own cause:
#
#   ca.crt                  the trusted root -- the ONLY thing installed into
#                           the guest's trust store
#   valid.crt/key           signed by ca, CN=localhost, in date   -> must CONNECT
#   untrusted.crt/key       signed by a SECOND ca, CN=localhost   -> must REJECT
#   wronghost.crt/key       signed by ca, CN=not-the-host         -> must REJECT
#   expired.crt/key         signed by ca, CN=localhost, expired   -> must REJECT
#
# The valid arm is not a courtesy. Three rejections with the positive arm also
# failing is consistent with a TLS path that rejects everything -- which fails
# closed, so nobody investigates, and leaves the verification question
# unanswered while looking like a clean result.

set -euo pipefail

out=${1:?usage: tls-fixture.sh <outdir>}
host=${FIXTURE_HOST:-localhost}
mkdir -p "$out"
cd "$out"

log() { echo "tls-fixture: $*"; }

gen_ca() {  # gen_ca <prefix> <cn>
	openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
		-keyout "$1.key" -out "$1.crt" -subj "/CN=$2" 2>/dev/null
}

# The SAN is carried by -extfile at signing time, NOT by -copy_extensions.
#
# Both work under OpenSSL, which is what Duct ships. -copy_extensions does not
# exist in LibreSSL, which is what macOS ships -- so the first version of this
# script generated a CA, a valid leaf, and then died. -extfile is understood by
# both and is the older, more portable spelling.
#
# The extension matters more than it looks: without a SAN the signed
# certificate has no name a modern verifier will accept, so EVERY leaf becomes
# a wrong-host certificate. The wrong-host arm would then pass for the wrong
# reason and the valid arm would fail for one -- a fixture that reports the
# right answers while measuring nothing.
gen_leaf() {  # gen_leaf <prefix> <cn> <ca-prefix> <days>
	local prefix=$1 cn=$2 ca=$3 days=$4
	printf 'subjectAltName=DNS:%s\n' "$cn" > "$prefix.ext"
	openssl req -newkey rsa:2048 -nodes -sha256 \
		-keyout "$prefix.key" -out "$prefix.csr" -subj "/CN=$cn" 2>/dev/null
	openssl x509 -req -in "$prefix.csr" -CA "$ca.crt" -CAkey "$ca.key" \
		-CAcreateserial -out "$prefix.crt" -days "$days" -sha256 \
		-extfile "$prefix.ext" 2>/dev/null
	rm -f "$prefix.csr" "$prefix.ext"
}

log "generating the trusted CA and a second, untrusted one"
gen_ca ca          "Duct Test CA"
gen_ca untrusted-ca "Duct Untrusted CA"

log "valid: signed by ca, CN=$host, in date"
gen_leaf valid "$host" ca 365

log "untrusted: signed by the OTHER ca"
gen_leaf untrusted "$host" untrusted-ca 365

log "wronghost: signed by ca, CN=not-$host"
gen_leaf wronghost "not-$host" ca 365

# An expired certificate cannot be made with -days alone, because x509 -req
# dates from now and takes no negative value. -not_before/-not_after are
# OpenSSL-only; `openssl ca` with -startdate/-enddate works in both OpenSSL and
# LibreSSL, at the cost of the small CA database it insists on.
log "expired: signed by ca, CN=$host, dates in the past"
mkdir -p cadb/newcerts && : > cadb/index.txt && echo 01 > cadb/serial
cat > cadb/ca.cnf <<EOF
[ ca ]
default_ca = CA_default
[ CA_default ]
dir            = $PWD/cadb
database       = \$dir/index.txt
new_certs_dir  = \$dir/newcerts
serial         = \$dir/serial
certificate    = $PWD/ca.crt
private_key    = $PWD/ca.key
default_md     = sha256
policy         = policy_any
copy_extensions = copy
email_in_dn    = no
rand_serial    = no
unique_subject = no
[ policy_any ]
commonName = supplied
EOF
printf 'subjectAltName=DNS:%s\n' "$host" > expired.ext
openssl req -newkey rsa:2048 -nodes -sha256 \
	-keyout expired.key -out expired.csr -subj "/CN=$host" 2>/dev/null
openssl ca -batch -config cadb/ca.cnf -in expired.csr -out expired.crt \
	-startdate 20200101000000Z -enddate 20200102000000Z \
	-extfile expired.ext -notext 2>/dev/null
rm -f expired.csr expired.ext

log "done: $(command ls *.crt | tr '\n' ' ')"

# ---------------------------------------------------------------------------
# SELF-CHECK. Each leaf must have EXACTLY the defect it is named for, verified
# with openssl rather than assumed from the arguments -- because a fixture with
# the wrong defect makes the whole test report a wrong answer confidently, and
# nothing downstream could tell.
# ---------------------------------------------------------------------------
fails=0
check() {  # check <description> <expected: ok|fail> <openssl verify args...>
	local what=$1 expect=$2; shift 2
	if openssl verify "$@" >/dev/null 2>&1; then got=ok; else got=fail; fi
	if [ "$got" = "$expect" ]; then
		echo "  ok    $what ($got, as intended)"
	else
		echo "  FAIL  $what (expected $expect, got $got)"
		fails=$((fails + 1))
	fi
}

echo "self-check:"
check "valid verifies against ca"            ok   -CAfile ca.crt valid.crt
check "untrusted does NOT verify against ca" fail -CAfile ca.crt untrusted.crt
check "expired does NOT verify against ca"   fail -CAfile ca.crt expired.crt
# wronghost is a NAME failure, not a chain failure: it verifies as a chain and
# must fail only when the hostname is checked. Asserting both halves, because a
# wronghost certificate that failed chain verification would reject for the
# wrong reason and the arm would pass while measuring nothing.
check "wronghost verifies as a CHAIN"        ok   -CAfile ca.crt wronghost.crt
# The name check, done by reading the SAN rather than with -verify_hostname:
# LibreSSL's verify has no such option, and this has to run wherever the
# fixture is built. Reading the extension is also the more direct assertion --
# it says what the certificate CLAIMS rather than what one verifier concludes.
san=$(openssl x509 -in wronghost.crt -noout -text 2>/dev/null | grep -A1 "Alternative Name" | tail -1 | tr -d ' ')
if [ "$san" = "DNS:not-$host" ]; then
	echo "  ok    wronghost names not-$host, so it cannot match $host"
else
	echo "  FAIL  wronghost SAN is '$san', expected 'DNS:not-$host'"
	fails=$((fails + 1))
fi
san_valid=$(openssl x509 -in valid.crt -noout -text 2>/dev/null | grep -A1 "Alternative Name" | tail -1 | tr -d ' ')
if [ "$san_valid" = "DNS:$host" ]; then
	echo "  ok    valid names $host, so the positive arm can match"
else
	echo "  FAIL  valid SAN is '$san_valid', expected 'DNS:$host' -- every arm would fail"
	fails=$((fails + 1))
fi

[ "$fails" -eq 0 ] || { echo "tls-fixture: $fails self-check failure(s)" >&2; exit 1; }
echo "tls-fixture: fixture is correct; each leaf has exactly its intended defect"

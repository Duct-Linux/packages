#!/usr/bin/env bash
# Test 1 -- the installer's dry run, inside a live Duct guest.
#
#   qemu-test1.sh <iso> <arch>
#
# WHAT THIS PROVES, and why it is worth a whole VM to prove it.
#
# duct_disk_boot_medium() maps the live medium's mount source to its parent
# disk through /sys/class/block/<part>/.. . When the medium is a whole disk
# with a filesystem directly on it and no partition table -- which is exactly
# what a QEMU virtio-blk ISO is -- there is no parent block device, and the
# function falls back to returning the source unchanged. THAT FALLBACK HAS
# NEVER EXECUTED. Nothing on a development machine reaches it.
#
# If it is wrong, the installer offers the live medium as an install target.
# That is the single worst failure this program has, and it is guarded by a
# code path that has never run. This test runs it, on real hardware
# enumeration, before any destructive code exists to be guarded.
#
# It is a dry run. Nothing is written. The strongest of the pass criteria below
# does not trust that claim -- it checksums the target disk image before and
# after and requires it to be byte-identical.
#
# ---------------------------------------------------------------------------
# PREREQUISITES -- read these before running, both are outside my hands
# ---------------------------------------------------------------------------
#
# 1. The ISO must carry /usr/bin/duct-install-cli. That means a duct-installer
#    package built by the Duct toolchain and added to ISO_EXTRA_PACKAGES. The
#    script checks and says so rather than timing out mysteriously.
#
# 2. Something has to run it in the guest. Two ways, in order of preference:
#
#    TRIGGER=cmdline -- duct.install=1 on the kernel command line, acted on by
#      duct-live's dispatcher. The better mechanism: no terminal interaction,
#      nothing to race. NOW POSSIBLE, not yet the default.
#
#      images#7 added ISO_CMDLINE_EXTRA, so an ISO can carry the parameter:
#
#          make iso ISO_CMDLINE_EXTRA="duct.install=1"
#
#      The mechanism existing is not the same as an ISO carrying it, and the
#      default configuration of a test should be one that can pass. So console
#      stays the default until an ISO built WITH the flag has been produced and
#      run green at least once. There is also a coverage reason: cmdline mode
#      runs the installer once, through the dispatcher, so it cannot exercise
#      the refusal -- console mode issues a second invocation and does.
#
#      DO NOT compare ISO hashes across builds in any criterion. The ISO is not
#      currently reproducible: duct-mkinitramfs packs cpio with wall-clock
#      mtimes, so every build differs, and Docker layer caching hides it by
#      reusing the initramfs between consecutive builds -- which is
#      indistinguishable from reproducibility by hash. The byte-identity checks
#      in this script are unaffected: they compare one file before and after
#      WITHIN a single run, which is the shape that does not have this problem.
#
#      IT CANNOT BE INJECTED FROM HERE. QEMU's -append is documented as
#      applying to -kernel only; with the guest booting its own GRUB from the
#      medium through -bios firmware, -append is SILENTLY IGNORED. An earlier
#      version of this script passed it and would have produced exactly the
#      failure this file spends a page warning about: the installer never runs,
#      the test times out, and the timeout reads as an installer hang.
#
#      So the parameter has to be baked into the ISO's grub.cfg at build time
#      -- images/iso/grub.cfg.in already does template substitution, so this is
#      a build-arg away and belongs to duct-2. Until such an ISO exists, use
#      TRIGGER=console.
#
#    TRIGGER=console -- type the command on the serial console once a shell
#      exists. Needs no change to duct-live, and is here so this test is
#      runnable the day the installer is on the ISO rather than the day the
#      dispatcher lands. It waits for a line printed BY THE CONSOLE SESSION,
#      never for the sysinit ready marker -- see the comment in that branch;
#      using the ready marker is a bug that duct-2 has already shipped once.
#
# Built on images/iso/boot-test.sh and deliberately shaped like it -- same
# container-not-host approach, same firmware handling, same serial-to-a-file so
# the log can be searched while the guest runs and printed whole on failure.

set -euo pipefail

iso=${1:?usage: qemu-test1.sh <iso> <arch>}
arch=${2:?usage: qemu-test1.sh <iso> <arch>}

timeout_s=${TEST_TIMEOUT:-1200}

# How long cmdline mode waits for any sign the installer ran before concluding
# the ISO does not carry the trigger parameter. Well short of the full deadline
# on purpose: a documented-impossible configuration should say so in a minute,
# not in twenty.
cmdline_grace=${CMDLINE_GRACE:-420}
# console, not cmdline, until duct-2's ISO_CMDLINE_EXTRA lands. cmdline is the
# better mechanism and becomes the default the day an ISO can carry the
# parameter -- but defaulting to it now means the default configuration is
# documented-impossible, and burns the whole timeout before saying so.
trigger=${TRIGGER:-console}

# The parameter duct-live's dispatcher acts on. Named by duct-2: any non-empty
# value triggers. duct.install.<key> is reserved for later options --
# duct.install.disk=, duct.install.auto= -- matching how duct.live.label and
# duct.live.device already work.
trigger_param=${DUCT_TRIGGER_PARAM:-duct.install=1}

# The line that means A SHELL EXISTS. Not the sysinit ready marker -- see the
# long comment in the TRIGGER=console branch below, which explains why using
# that one is a bug rather than merely fragile.
#
# An EXTENDED REGEX matching either branch, because since packages#9 both
# announce. console-session execs login(1) when one exists and prints
# "starting a PAM session via ..."; when there is none it prints "no login(1)
# available ...". The old default matched only the fallback, which was correct
# when it was the only branch that spoke and became a trap the moment shadow
# and linux-pam entered a manifest: the guest would take the PAM branch, print
# a line this never looked for, and the harness would wait out its deadline and
# report an installer hang.
#
# Deliberately NOT the bare prefix "duct-live:". initramfs-init prints with
# that same prefix (files/initramfs-init:24) and runs BEFORE any shell exists,
# so matching it would resurrect the exact defect this marker was introduced to
# kill -- waiting on a line that appears on a system with no console session at
# all.
console_marker=${CONSOLE_MARKER:-"duct-live: (starting a PAM session|no login\(1\) available)"}

# Not decoration. lsblk reports it in the SERIAL column, so the test can assert
# the installer picked the disk we MEANT rather than merely a disk -- which is
# the cheapest possible guard against the failure this whole test exists for.
target_serial=${TARGET_SERIAL:-DUCTTEST0001}
target_size=${TARGET_SIZE:-20G}

# Its own tag, not boot-test.sh's. Two scripts sharing one image tag while
# needing different things from it is the second-source-of-truth problem
# relocated into a registry: whichever ran first decides what the other gets.
# $arch in the tag. Without it the aarch64 run builds an image holding
# qemu-system-arm and qemu-efi-aarch64, and a later x86_64 run reuses it by
# cache hit and finds neither of the packages it needs. It fails closed at the
# firmware check, but points the reader at firmware packaging rather than at a
# stale cached image -- the same second-source-of-truth-in-a-registry problem
# the tag was split off to avoid, one dimension over.
image=duct/iso-qemu-test-${arch}:latest

die() { echo "test1: $*" >&2; exit 1; }
log() { echo "test1: $*"; }

[ -f "$iso" ] || die "no such ISO: $iso"

case "$arch" in
	aarch64) qemu_pkg=qemu-system-arm; fw_pkg=qemu-efi-aarch64 ;;
	x86_64)  qemu_pkg=qemu-system-x86; fw_pkg=ovmf ;;
	*) die "no QEMU invocation for $arch" ;;
esac

# QEMU and firmware, and nothing else -- the target is a raw sparse file made
# with truncate(1), so qemu-img is not needed at all.
if ! docker image inspect "$image" >/dev/null 2>&1; then
	log "building $image"
	docker build -t "$image" -f - . <<-EOF
	FROM debian:bookworm-slim
	ENV DEBIAN_FRONTEND=noninteractive
	RUN apt-get update && \\
	    apt-get install -y --no-install-recommends $qemu_pkg $fw_pkg && \\
	    rm -rf /var/lib/apt/lists/*
	EOF
fi

log "booting $iso with a blank ${target_size} target (up to ${timeout_s}s, emulated)"

docker run --rm -i \
	-v "$(cd "$(dirname "$iso")" && pwd)/$(basename "$iso")":/live.iso:ro \
	-e "TIMEOUT=$timeout_s" -e "ARCH=$arch" -e "TRIGGER=$trigger" \
	-e "TRIGGER_PARAM=$trigger_param" \
	-e "TARGET_SERIAL=$target_serial" -e "TARGET_SIZE=$target_size" \
	-e "CONSOLE_MARKER=$console_marker" -e "CMDLINE_GRACE=$cmdline_grace" \
	"$image" bash -s <<'INNER'
set -uo pipefail

case "$ARCH" in
	aarch64)
		fw=/usr/share/qemu-efi-aarch64/QEMU_EFI.fd
		set -- qemu-system-aarch64 -machine virt -cpu max ;;
	x86_64)
		fw=/usr/share/ovmf/OVMF.fd
		set -- qemu-system-x86_64 -machine q35 -cpu max ;;
esac
[ -f "$fw" ] || { echo "test1: no firmware at $fw" >&2; exit 1; }

# A RAW SPARSE FILE, not qcow2, and this is the assertion's whole strength.
#
# qcow2 is a container format QEMU opens read-write and maintains state inside
# -- header fields, refcount tables. This script kills the process rather than
# shutting the guest down cleanly, so a qcow2 could differ with zero guest
# writes, and the byte-identity check would have a benign second explanation
# available. An assertion that MIGHT have an innocent cause is one somebody
# eventually explains away, and this one guards the worst failure the program
# has: offering the live medium as an install target.
#
# With a raw file there is no second explanation. Every byte QEMU writes to it
# is a byte the guest asked for. Unchanged means the guest wrote nothing.
# It also removes qemu-img from the image entirely.
# A WRITABLE COPY of the ISO, and readonly=on deliberately NOT set.
#
# The harness used to bind-mount the ISO :ro and attach it readonly=on, which
# meant the live medium could not be written whatever the installer did -- so
# the test could not distinguish "the installer refused" from "the installer
# tried and QEMU blocked it", and the only evidence for the refusal was a grep
# for the installer's own log line. That is exactly the thing the byte-identity
# checks exist to avoid taking on trust, applied to the target but not to the
# medium.
#
# Given that offering the live medium as an install target is the worst failure
# this program has, the medium deserves the stronger treatment. It now gets the
# same byte-identity check as the target. Cost is one cp.
#
# The bind mount stays :ro so the real ISO on the host cannot be touched.
# Checked, and the size compared. An unchecked cp that runs out of space in
# the container leaves a TRUNCATED file that passes every guard below: it
# exists, sha256sum succeeds on it, and QEMU boots it -- surfacing much later
# as "no console-session marker", which points the reader at console-session
# rather than at the copy. The DESKTOP=1 ISO is around 1 GB, so /tmp headroom
# is a real constraint rather than a theoretical one.
medium=/tmp/live.img
if ! cp /live.iso "$medium"; then
	echo "test1: could not copy the ISO to $medium (space in the container?)" >&2
	exit 1
fi
iso_size=$(stat -c %s /live.iso)
medium_size=$(stat -c %s "$medium")
if [ "$iso_size" != "$medium_size" ]; then
	echo "test1: the ISO copy is TRUNCATED: $medium_size of $iso_size bytes." >&2
	echo "       Almost certainly no space in the container's /tmp." >&2
	exit 1
fi

deadline=$(( SECONDS + TIMEOUT ))

target=/tmp/target.img
truncate -s "$TARGET_SIZE" "$target"

# Two independent measures, because they fail differently.
#
# Allocated blocks is the cheap one and in one way the stronger: a sparse file
# starts with none, and ANY write allocates some, including a write of zeros
# that a checksum would not notice against a zero-filled region. Compared
# before-and-after rather than asserted to be zero, because a filesystem
# without sparse-file support would start non-zero and that is not a failure.
#
# The checksum is the thorough one: it catches a write that happened to land
# where blocks were already allocated.
before_blocks=$(du --block-size=1 "$target" 2>/dev/null | cut -f1)
before_sum=$(sha256sum "$target" 2>/dev/null | cut -d' ' -f1)
before_medium=$(sha256sum "$medium" 2>/dev/null | cut -d' ' -f1)

# There is no `set -e` here (deliberately -- the log must be printed on every
# path), so a failed truncate would leave both variables empty and the
# comparisons below would be "" = "", which is TRUE. Both criteria would print
# PASS against a file that does not exist, and the only tell would be an empty
# pair of parentheses. A measurement that could not be taken must never read as
# a measurement that came out clean.
if [ ! -f "$target" ] || [ -z "$before_blocks" ] || [ -z "$before_sum" ] || [ -z "$before_medium" ]; then
	echo "test1: could not measure the target file before the run." >&2
	echo "       truncate/du/sha256sum failed -- no space, bad TARGET_SIZE, or" >&2
	echo "       /tmp not writable. This is a HARNESS failure; the byte-identity" >&2
	echo "       criteria cannot be evaluated at all." >&2
	exit 1
fi

# NO -append. It applies to -kernel only, and this guest boots its own GRUB
# from the medium through -bios firmware, so -append would be accepted and
# silently ignored -- the worst kind of mechanism. TRIGGER=cmdline requires an
# ISO whose grub.cfg already carries the parameter; see the PREREQUISITES
# comment at the top.

# Two drives.
#
#   vda  the ISO, presented as a plain virtio block device rather than -cdrom,
#        because arm64 `virt` has no IDE bus. This is also what creates the
#        condition the test exists for: a whole disk with ISO9660 directly on
#        it and no partition table.
#   vdb  the blank target, with a serial the guest can read back.
#
# -nic none for the reason boot-test.sh gives: QEMU adds a virtio-net device to
# `virt` by default and then refuses to start without an option ROM that lives
# in a separate 30 MB package, for a test that does no networking.
#
# -no-reboot so a guest that triple-faults stops instead of looping.
qemu_args=(
	-m 2048 -bios "$fw"
	-drive "if=none,id=live,file=$medium,format=raw"
	-device virtio-blk-pci,drive=live
	-drive "if=none,id=target,file=$target,format=raw"
	-device "virtio-blk-pci,drive=target,serial=$TARGET_SERIAL"
	-nic none -nographic -no-reboot
)
# stdin for the guest in BOTH modes, not only console.
#
# This used to be inside the console branch, and that made the D2 clean-shutdown
# guarantee cover only the FALLBACK mode -- not the one this file's own comments
# call the better mechanism and expect to become the default. In cmdline mode
# nothing ever told the guest to shut down, so clean_exit stayed empty and three
# criteria fired on every run: the guest was killed, the medium could not be
# checked, and the target CHANGED. The day ISO_CMDLINE_EXTRA is used and the
# default flips, those would have gone permanently red.
mkfifo /tmp/in
"$@" "${qemu_args[@]}" </tmp/in >/tmp/serial.log 2>&1 &
qemu_pid=$!
exec 3>/tmp/in

# The serial log must EXIST before anything greps it.
#
# Every criterion below reads /tmp/serial.log with `2>/dev/null`, so a log that
# was never created returns "not found" from each of them in turn -- and the
# harness would report "no console-session marker appeared", which accuses
# duct-live of being absent from the manifest. A missing file and a file with
# nothing in it are different facts, and only one of them is about the guest.
#
# QEMU's redirect creates it, so this should never fire. "Should never fire" is
# what these bugs are made of.
[ -f /tmp/serial.log ] || {
	echo "test1: /tmp/serial.log does not exist -- QEMU's redirect did not create" >&2
	echo "       it. This is a HARNESS failure and nothing below can be read." >&2
	kill "$qemu_pid" 2>/dev/null || true
	exit 1
}

if [ "$TRIGGER" = "console" ]; then
	# WAIT FOR THE CONSOLE SESSION, NOT FOR THE SYSINIT READY MARKER.
	#
	# This distinction is a bug, not a nicety, and duct-2 shipped a boot test
	# with exactly this flaw. "Duct live system ready" is printed by the live
	# rc, which busybox init runs as ::sysinit -- TO COMPLETION, BEFORE any of
	# the ::respawn entries that start a console session. So that line appears
	# on a system where no shell exists yet, and just as happily on one where
	# console-session is MISSING ENTIRELY. Their test passed against an image
	# that had no console-session at all.
	#
	# Typing into that gets a timeout that reads as an installer hang: a
	# failure pointing at the program under test rather than at the harness,
	# which is the worst possible misdirection for the first test this
	# installer ever runs.
	#
	# Do not "simplify" this back to the ready marker because it appears
	# earlier and looks equivalent -- that is the exact mistake, and it looks
	# like an improvement right up until it hides a missing shell.
	found_console=
	while [ "$SECONDS" -lt "$deadline" ]; do
		grep -qE "$CONSOLE_MARKER" /tmp/serial.log 2>/dev/null && { found_console=1; break; }
		kill -0 "$qemu_pid" 2>/dev/null || break
		sleep 1
	done

	if [ -z "$found_console" ]; then
		# Named, rather than left to look like a hang. Since packages#9 both
		# branches of console-session announce, so reaching this means no
		# console session started at all -- not that the wrong branch was
		# taken. That is a stronger statement than it used to be, and it is
		# worth making: it points at duct-live being absent or init not
		# reaching its respawn entries, rather than at the installer.
		echo "test1: no console-session marker appeared. Pattern was:" >&2
		echo "         $CONSOLE_MARKER" >&2
		echo "       This is a HARNESS or IMAGE problem, not an installer one." >&2
		echo "       Both branches of console-session announce since packages#9," >&2
		echo "       so this means no console session ran -- check that duct-live" >&2
		echo "       is in the ISO manifest and that init reached its respawn" >&2
		echo "       entries. Override CONSOLE_MARKER if the text has changed." >&2
		kill "$qemu_pid" 2>/dev/null || true
		echo "===== serial console ====="
		cat /tmp/serial.log
		exit 1
	fi

	# Three invocations. The third is the point: the ISO's own disk must be
	# refused, and refused for the right reason.
	printf '\n' >&3
	printf 'duct-install-cli --list-disks\n' >&3
	printf 'duct-install-cli -a /etc/duct-install-answers -t /dev/vdb\n' >&3
	printf 'duct-install-cli -a /etc/duct-install-answers -t /dev/vda\n' >&3
fi

# Wait for the installer to finish, in both modes, before asking for shutdown.
while [ "$SECONDS" -lt "$deadline" ]; do
	grep -q "DUCT-TEST: dry run complete" /tmp/serial.log 2>/dev/null && break
	grep -q "DUCT-TEST: FAIL" /tmp/serial.log 2>/dev/null && break
	kill -0 "$qemu_pid" 2>/dev/null || break

	# cmdline mode fails fast rather than burning the whole deadline. If the
	# ISO does not carry the parameter, nothing will ever run, and twenty
	# minutes of silence is a worse way to learn that than one minute is.
	if [ "$TRIGGER" = "cmdline" ] && [ "$SECONDS" -gt "$CMDLINE_GRACE" ] \
	   && ! grep -q "DUCT-TEST" /tmp/serial.log 2>/dev/null; then
		echo "test1: no DUCT-TEST marker after ${CMDLINE_GRACE}s in cmdline mode." >&2
		echo "       This ISO's grub.cfg almost certainly does not carry" >&2
		echo "       \"$TRIGGER_PARAM\". Use TRIGGER=console." >&2
		break
	fi

	sleep 1
done

# CLEAN SHUTDOWN, IN BOTH MODES, and this is load-bearing rather than tidy.
#
# Both byte-identity criteria measure the HOST file. A guest write still sitting
# in the GUEST page cache has never reached QEMU, so killing QEMU cannot flush
# it and neither measure can see it -- and guest writeback can be 30 seconds
# away. That is exactly the write this test looks for: AN UNINTENDED WRITE IS BY
# DEFINITION ONE NOBODY FSYNCED.
#
# In cmdline mode this reaches the console session that inittab respawns; the
# installer has already run by the time these are typed.
printf 'sync\n' >&3
printf 'poweroff\n' >&3

# Wait for QEMU to EXIT, not for a marker. Waiting for a clean poweroff is what
# makes "the host file is unchanged" and "the guest wrote nothing" the same
# claim.
clean_exit=
while [ "$SECONDS" -lt "$deadline" ]; do
	kill -0 "$qemu_pid" 2>/dev/null || { clean_exit=1; break; }
	sleep 1
done

if [ -z "$clean_exit" ]; then
	echo "test1: guest did not shut down within ${TIMEOUT}s; killing it." >&2
	kill "$qemu_pid" 2>/dev/null || true
fi
wait "$qemu_pid" 2>/dev/null || true

after_blocks=$(du --block-size=1 "$target" 2>/dev/null | cut -f1)
after_sum=$(sha256sum "$target" 2>/dev/null | cut -d' ' -f1)
after_medium=$(sha256sum "$medium" 2>/dev/null | cut -d' ' -f1)

echo "===== serial console ====="
cat /tmp/serial.log
echo "=========================="

# ---------------------------------------------------------------------------
# PASS CRITERIA
#
# Every one is checked, all of them are reported, and the run fails if any
# fails -- rather than stopping at the first, because knowing which subset
# failed is what makes a failure diagnosable.
# ---------------------------------------------------------------------------

fails=0
check() {  # check <description> <test-expression-result>
	if [ "$2" = "0" ]; then
		echo "  PASS  $1"
	else
		echo "  FAIL  $1"
		fails=$((fails + 1))
	fi
}

has() { grep -q "$1" /tmp/serial.log 2>/dev/null && echo 0 || echo 1; }
hasnt() { grep -q "$1" /tmp/serial.log 2>/dev/null && echo 1 || echo 0; }

echo "===== pass criteria ====="

# 0. The guest got far enough to mean anything.
check "the live system booted" "$(has 'Duct live system ready')"
check "duct-install-cli ran at all" "$(has 'DUCT-TEST: probe ok')"

# 1. Real hardware, not the development fixtures. If this fails the rest of the
#    run proves nothing, which is why the CLI prints the warning it does.
# Absence assertions, gated on the probe having run at all. Ungated, they
# print PASS loudest when duct-install-cli never started -- neither string is
# in the log, so both "pass" directly beneath criterion 0 failing. Absence of
# evidence rendered as evidence of correctness.
if [ "$(has 'DUCT-TEST: probe ok')" != "0" ]; then
	echo "  SKIP  the probe never ran; absence checks below prove nothing"
	probe_ran=
else
	probe_ran=1
fi

if [ -n "$probe_ran" ]; then
	check "the probe used real disks, not the simulated fixtures" "$(hasnt 'SIMULATED')"
fi

# 2. THE POINT OF THE TEST. The never-executed fallback in
#    duct_disk_boot_medium() must have identified the ISO's disk, and the
#    installer must have excluded exactly it.
# Both of these were unanchored greps and both could pass on the wrong answer.
# "live medium /dev/vda" is a SUBSTRING of "live medium /dev/vda1" -- and a
# fallback that returned the partition instead of the whole disk is precisely
# the failure this test exists to catch, so the criterion could not distinguish
# the right answer from the most likely wrong one. "1 excluded" likewise
# matches "11 excluded".
#
# Both now read the probe's own per-disk lines, where the node is delimited by
# a literal " serial=" and the count is a count rather than a substring.
if grep -qE "^DUCT-TEST: disk /dev/vda serial=[^ ]* excluded=live-medium" /tmp/serial.log 2>/dev/null; then
	echo "  PASS  the live medium was identified as the whole disk /dev/vda"
else
	echo "  FAIL  /dev/vda was not identified as the live medium"
	grep -E "^DUCT-TEST: disk .*excluded=live-medium" /tmp/serial.log 2>/dev/null \
		| sed 's/^/        got: /' || echo "        got: nothing"
	fails=$((fails + 1))
fi

# `|| echo 0` was wrong here: grep -c PRINTS 0 and EXITS 1 on no match, so the
# fallback appended a second zero and the count rendered as "0\n0" across two
# lines -- damaging the readout that was the entire reason this criterion was
# rewritten from a substring match into a count.
excluded_count=$(grep -cE "^DUCT-TEST: disk .*excluded=live-medium" /tmp/serial.log 2>/dev/null || true)
excluded_count=${excluded_count:-0}
check "exactly one disk was excluded (got $excluded_count)" \
      "$([ "$excluded_count" = "1" ] && echo 0 || echo 1)"

# 3. It picked the disk we meant, proven by the serial rather than by the node.
#
# The serial criterion has a failure mode that is NOT the installer's fault and
# must not be reported as though it were. `-device virtio-blk-pci,serial=` sets
# the property, but whether it reaches `lsblk -o SERIAL` depends on the guest:
# virtio_blk exposing it in sysfs, and udev populating ID_SERIAL from there. If
# that chain is broken the disk is described without a serial, and a naive
# check fails while the installer did everything right.
#
# The discriminator therefore reads THE PROBE'S OWN per-disk lines --
# "DUCT-TEST: disk /dev/vdb serial=DUCTTEST0001", with serial= empty when
# absent -- and not the console log at large.
#
# That distinction is not theoretical. An earlier version grepped the whole
# serial log for the word "serial", which matches `serial8250: ttyS0`, the
# 8250 UART driver's boot banner. CONFIG_SERIAL_8250=y in both kernel
# fragments, so it is printed on every boot on every target: the probe was
# always true, the SKIP branch was dead, and the harness limitation it existed
# to describe would have been reported as "WRONG DISK SELECTED" instead. The
# observability probe must measure the thing whose observability is in
# question.
check "the plan targeted vdb, not vda" "$(has 'plan esp=/dev/vdb1 root=/dev/vdb2')"

if [ -z "$probe_ran" ]; then
	# Ungated, this degraded to a confident SKIP whose every clause was false:
	# it is not a virtio_blk limitation, and the criterion it points at as
	# independent cover has just failed too.
	echo "  SKIP  the probe produced no disk lines; nothing to check a serial against"
elif grep -q "DUCT-TEST: disk /dev/vdb serial=$TARGET_SERIAL" /tmp/serial.log 2>/dev/null; then
	echo "  PASS  the target was the disk carrying serial $TARGET_SERIAL"
elif grep -qE "DUCT-TEST: disk .* serial=[^ ]+" /tmp/serial.log 2>/dev/null; then
	# The probe reported a serial for some disk, just not the expected one.
	# That is a real defect: the wrong disk was selected.
	echo "  FAIL  the probe reported serials, but not $TARGET_SERIAL — WRONG DISK SELECTED"
	fails=$((fails + 1))
else
	# The probe reported every disk with an empty serial.
	#
	# THAT IS THE OBSERVATION. The cause is NOT established by it, and an
	# earlier version of this message asserted one -- "virtio_blk/udev did not
	# surface it. HARNESS limitation, not an installer failure." That
	# exonerates the installer on the strength of something never measured,
	# which is the same defect as accusing it would be and harder to notice,
	# because an exoneration stops people looking.
	#
	# At least three causes produce this identical output, and they are not all
	# on the same side of the fence.
	echo "  SKIP  the probe reported no serial for ANY disk."
	echo "        Observed: every DUCT-TEST disk line has an empty serial=."
	echo "        CAUSE NOT ESTABLISHED. Candidates, needing different owners:"
	echo "          - the guest never surfaced it (virtio_blk/udev): harness"
	echo "          - lsblk was not asked for SERIAL, or renamed the field:"
	echo "            the installer's probe"
	echo "          - QEMU did not apply the serial= property: harness"
	echo "        Distinguishing them means reading /sys/block/vdb/serial in"
	echo "        the guest, which this test does not do."
	echo "        The run is still meaningful: the 'plan targeted vdb'"
	echo "        criterion above covers disk selection independently of this."
fi

# 4. The refusal, exercised directly. Only meaningful for TRIGGER=console,
#    which issues the second invocation; skipped otherwise.
if [ "$TRIGGER" = "console" ]; then
	# REFUSED, not FAIL. A deliberate safety refusal is the installer working,
	# and it used to share a marker with a stage failure -- so a correct run
	# satisfied this criterion and violated "no stage reported FAIL" with the
	# same line, and every successful run ended in a failed test.
	check "installing to the live medium was refused" \
	      "$(has 'DUCT-TEST: REFUSED target: .*carries the live medium')"
else
	# cmdline mode runs the installer once, through the dispatcher, with no
	# way to issue a second invocation. The refusal is therefore untested in
	# this mode -- said out loud rather than left as a criterion that silently
	# is not there.
	echo "  SKIP  the refusal is not exercised in cmdline mode (single invocation)"
fi

# 5. It completed, and nothing failed along the way.
check "the dry run completed" "$(has 'DUCT-TEST: dry run complete')"
if [ -n "$probe_ran" ]; then
	check "no stage reported FAIL" "$(hasnt 'DUCT-TEST: FAIL')"
fi

# 6. The two criteria that do not take the installer's word for anything.
#
# Guarded three ways before they are allowed to mean anything: the after-values
# must have been measurable, and the guest must have shut down cleanly. A kill
# leaves guest writeback unflushed, so an unchanged host file would only show
# that nothing reached the device in the last second -- not that nothing was
# written. Reporting that as PASS would be the strongest claim in this file
# resting on its weakest evidence.
if [ ! -f "$target" ] || [ -z "$after_blocks" ] || [ -z "$after_sum" ]; then
	echo "  FAIL  the target could not be measured after the run — INCONCLUSIVE"
	fails=$((fails + 1))
elif [ -z "$clean_exit" ]; then
	echo "  FAIL  the guest was killed rather than shutting down — INCONCLUSIVE"
	echo "        Guest writeback may not have reached the device. An unintended"
	echo "        write is by definition one nobody fsynced, so this is exactly"
	echo "        the case these criteria cannot rule out after a kill."
	fails=$((fails + 1))
elif [ "$before_blocks" = "$after_blocks" ]; then
	echo "  PASS  the target allocated no new blocks ($before_blocks bytes)"
else
	echo "  FAIL  the target ALLOCATED BLOCKS during a dry run"
	echo "        before $before_blocks bytes allocated"
	echo "        after  $after_blocks bytes allocated"
	fails=$((fails + 1))
fi

# The medium, checked as hard as the target and for a worse failure. It was
# writable for the whole run, so this is proof rather than a request.
if [ -z "$clean_exit" ] || [ -z "$after_medium" ]; then
	echo "  FAIL  the live medium could not be checked — INCONCLUSIVE"
	fails=$((fails + 1))
elif [ "$before_medium" = "$after_medium" ]; then
	echo "  PASS  the live medium is byte-identical — it was writable and was not written"
else
	echo "  FAIL  THE LIVE MEDIUM WAS WRITTEN TO"
	echo "        before $before_medium"
	echo "        after  $after_medium"
	fails=$((fails + 1))
fi

# Three causes, three messages. This branch used to collapse "killed guest",
# "unmeasurable file" and "genuinely different checksum" into "the target
# CHANGED during a dry run" -- which printed that sentence above two IDENTICAL
# checksums whenever the guest had merely been killed. The blocks branch above
# already separated them; this now mirrors it.
if [ -z "$after_sum" ]; then
	echo "  FAIL  the target checksum could not be taken — INCONCLUSIVE"
	fails=$((fails + 1))
elif [ -z "$clean_exit" ]; then
	echo "  FAIL  the guest was killed; the target checksum proves nothing — INCONCLUSIVE"
	fails=$((fails + 1))
elif [ "$before_sum" = "$after_sum" ]; then
	echo "  PASS  the target is byte-identical after the run"
else
	echo "  FAIL  the target CHANGED during a dry run"
	echo "        before $before_sum"
	echo "        after  $after_sum"
	fails=$((fails + 1))
fi

echo "========================="

if [ "$fails" -eq 0 ]; then
	echo "test1: PASS"
	exit 0
fi

# The two failures worth naming, because their generic message sends people to
# the wrong place.
if ! grep -q "DUCT-TEST: probe ok" /tmp/serial.log 2>/dev/null; then
	echo "test1: duct-install-cli never produced a marker." >&2
	echo "       Is /usr/bin/duct-install-cli on the ISO? Is the trigger wired up?" >&2
	echo "       See the PREREQUISITES comment at the top of this script." >&2
fi
if [ "$TRIGGER" = "cmdline" ] && ! grep -q "DUCT-TEST" /tmp/serial.log 2>/dev/null; then
	echo "test1: TRIGGER=cmdline and nothing ran." >&2
	echo "       Does this ISO's grub.cfg carry \"$TRIGGER_PARAM\"? It cannot be" >&2
	echo "       injected from the host: QEMU's -append applies to -kernel only," >&2
	echo "       and this guest boots its own GRUB. Rebuild the ISO with it, or" >&2
	echo "       use TRIGGER=console." >&2
fi
if grep -q "SIMULATED" /tmp/serial.log 2>/dev/null; then
	echo "test1: the guest had no lsblk and fell back to the fixture disks." >&2
	echo "       util-linux is missing from the ISO manifest." >&2
fi

echo "test1: FAIL ($fails criteria)" >&2
exit 1
INNER

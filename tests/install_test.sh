#!/bin/sh
# Tests for skills/prose/install. Run: sh tests/install_test.sh
#
# Each case copies the real script into a fake plugin folder (so the version
# comes from a manifest the test controls), serves fake release assets over
# file://, and fakes `uname` (and sometimes `curl`, `sha256sum`, `shasum`) with
# scripts on PATH. The whole suite runs twice: once in a plain folder and once
# in `a dir/ünï/`, a path with a space and non-ASCII characters (Review Focus 4).

set -u

here=$(cd "$(dirname "$0")" && pwd -P)
install_src="$here/../skills/prose/install"
scratch_root=${TMPDIR:-/tmp}
work=$(mktemp -d "$scratch_root/prose-install-test.XXXXXX") || exit 2
trap 'chmod -R u+rwx "$work" 2>/dev/null; rm -rf "$work"' EXIT
trap 'exit 130' HUP INT TERM

# The shell that runs the script; PROSE_TEST_SH=dash tests it under dash.
test_sh=$(command -v "${PROSE_TEST_SH:-sh}") || exit 2
pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() {
	fail=$((fail + 1))
	printf 'FAIL [%s]: %s\n' "$suite" "$1" >&2
}
check() { # description, then a command
	desc=$1
	shift
	if "$@"; then ok; else bad "$desc"; fi
}
contains() { case $1 in *"$2"*) return 0 ;; *) return 1 ;; esac }
lacks() { case $1 in *"$2"*) return 1 ;; *) return 0 ;; esac }
lines() { # number of lines in the text, with no trailing newline counted
	printf '%s\n' "$1" | awk 'END { print NR }'
}
bin_empty() { # true when the bin directory is missing or has nothing in it
	[ ! -d "$1" ] || [ -z "$(ls -A "$1")" ]
}

# The test's own sha256sum. Where there is only shasum, as on macOS, a
# stand-in runs `shasum -a 256`, so the cases below work the same there.
if ! real_sha=$(command -v sha256sum); then
	real_shasum=$(command -v shasum) || {
		echo "install_test.sh: needs sha256sum or shasum" >&2
		exit 2
	}
	mkdir -p "$work/sha"
	printf '#!/bin/sh\nexec "%s" -a 256 "$@"\n' "$real_shasum" >"$work/sha/sha256sum"
	chmod 755 "$work/sha/sha256sum"
	real_sha="$work/sha/sha256sum"
fi

# ---- the fake release -----------------------------------------------------

release="$work/release"
mkdir -p "$release/v0.1.0"
for p in linux-x86_64 linux-arm64 macos-arm64 windows-x86_64.exe; do
	printf '#!/bin/sh\n# asset %s\necho "prose-check 0.1.0"\n' "$p" >"$release/v0.1.0/prose-check-$p"
done
(cd "$release/v0.1.0" && "$real_sha" prose-check-* >SHA256SUMS)

# A release whose SHA256SUMS does not match the assets.
bad_release="$work/bad-release"
mkdir -p "$bad_release/v0.1.0"
cp "$release/v0.1.0"/prose-check-* "$bad_release/v0.1.0/"
sed 's/^./0/' "$release/v0.1.0/SHA256SUMS" >"$bad_release/v0.1.0/SHA256SUMS"

# ---- fake tools -------------------------------------------------------------

fake="$work/fake"
mkdir -p "$fake"
cat >"$fake/uname" <<'EOF'
#!/bin/sh
case ${1:-} in
-s) echo "${FAKE_OS:-Linux}" ;;
-m) echo "${FAKE_ARCH:-x86_64}" ;;
*) echo "${FAKE_OS:-Linux} ${FAKE_ARCH:-x86_64}" ;;
esac
EOF
chmod 755 "$fake/uname"

# A curl that writes a partial file and then hangs, to test the signal trap.
slowfake="$work/slowfake"
mkdir -p "$slowfake"
cat >"$slowfake/curl" <<'EOF'
#!/bin/sh
out=
while [ $# -gt 0 ]; do
	if [ "$1" = -o ]; then out=$2; shift; fi
	shift
done
[ -n "$out" ] && echo partial >"$out"
exec sleep 30
EOF
chmod 755 "$slowfake/curl"

# A PATH holding only the tools the script needs, so a tool can be left out.
# It does not hold sha256sum or shasum; cases add what they want.
bare="$work/bare"
mkdir -p "$bare"
for t in sh sed awk tr mktemp mkdir rm mv chmod curl kill cat dirname sleep head; do
	src=$(command -v "$t") && ln -s "$src" "$bare/$t"
done
cp "$fake/uname" "$bare/uname"

# A stand-in for BSD env, which has no --default-signal: it rejects that
# option and passes everything else to the real env.
real_env=$(command -v env)
bsdenv="$work/bsdenv"
mkdir -p "$bsdenv"
cat >"$bsdenv/env" <<ENVEOF
#!/bin/sh
case \${1:-} in
--default-signal*) echo "env: illegal option -- -" >&2; exit 1 ;;
esac
exec "$real_env" "\$@"
ENVEOF
chmod 755 "$bsdenv/env"

# ---- one run of the script --------------------------------------------------

# setup_root DIR: a fake plugin folder with the real script and a manifest.
setup_root() {
	rm -rf "$1"
	mkdir -p "$1/.claude-plugin" "$1/skills/prose"
	printf '{\n  "name": "prose",\n  "version": "0.1.0"\n}\n' >"$1/.claude-plugin/plugin.json"
	cp "$install_src" "$1/skills/prose/install"
}

# run ROOT [ARGS...]: runs the script with the fake uname first on PATH.
# Sets $out (stdout and stderr, merged) and $rc. FAKE_OS and FAKE_ARCH, and
# the PROSE_* variables, come from the environment of the caller.
run() {
	root=$1
	shift
	out=$(PATH="$fake:$PATH" HOME="$root/home" "$test_sh" "$root/skills/prose/install" "$@" 2>&1)
	rc=$?
}

run_with_path() { # ROOT PATH [ARGS...]
	root=$1
	p=$2
	shift 2
	out=$(PATH="$p" HOME="$root/home" "$test_sh" "$root/skills/prose/install" "$@" 2>&1)
	rc=$?
}

mtime_text() { find "$1" -prune -exec ls -ld {} + | awk '{print $6, $7, $8}'; }

# signal_checks ROOT BIN [ENVDIR]: starts the script with a curl that hangs, sends
# each signal, and checks that bin/ is left empty. ENVDIR is put first on PATH,
# so a fake env there stands in for BSD's.
#
# A background job of a non-interactive shell starts with SIGINT ignored, and a
# signal ignored at start cannot be trapped, so INT needs
# `env --default-signal=INT`, which GNU env has and BSD env lacks. INT is
# tested only when the probe finds that env option; the others always are.
signal_checks() {
	sc_root=$1
	sc_bin=$2
	sc_path="${3:+$3:}$slowfake:$fake:$PATH"
	sigs="TERM HUP"
	use_env=0
	if PATH="$sc_path" env --default-signal=INT true 2>/dev/null; then
		sigs="TERM INT HUP"
		use_env=1
	fi
	for sig in $sigs; do
		setup_root "$sc_root"
		mkdir -p "$sc_bin"
		if [ "$use_env" -eq 1 ]; then
			(PATH="$sc_path" HOME="$sc_root/home" exec env --default-signal=INT "$test_sh" "$sc_root/skills/prose/install" >"$work/sig.out" 2>&1) &
		else
			(PATH="$sc_path" HOME="$sc_root/home" exec "$test_sh" "$sc_root/skills/prose/install" >"$work/sig.out" 2>&1) &
		fi
		pid=$!
		n=0
		while [ -z "$(ls -A "$sc_bin")" ] && [ "$n" -lt 100 ]; do
			sleep 0.1
			n=$((n + 1))
		done
		check "SIG$sig: the download started before the signal (bin/ had: $(ls -A "$sc_bin"))" [ -n "$(ls -A "$sc_bin")" ]
		kill -s "$sig" "$pid"
		n=0
		while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 50 ]; do
			sleep 0.1
			n=$((n + 1))
		done
		if kill -0 "$pid" 2>/dev/null; then
			kill -9 "$pid"
			bad "SIG$sig: the script did not stop"
		fi
		wait "$pid"
		rc=$?
		check "SIG$sig: exits non-zero (got $rc)" [ "$rc" -ne 0 ]
		check "SIG$sig: bin/ left empty (got: $(ls -A "$sc_bin"))" bin_empty "$sc_bin"
	done
}

suite_run() {
	suite=$1
	base=$2 # the folder everything for this suite lives in
	root="$base/plugin"
	bin="$root/skills/prose/bin"
	url_base="file://$release"
	export PROSE_RELEASE_BASE="$url_base"
	unset PROSE_VERSION

	# 1. installs for each supported platform, and the binary runs
	for combo in "Linux x86_64 linux-x86_64" "Linux aarch64 linux-arm64" "Darwin arm64 macos-arm64"; do
		# shellcheck disable=SC2086 # the words are the point
		set -- $combo
		setup_root "$root"
		FAKE_OS=$1 FAKE_ARCH=$2 run "$root"
		check "install on $1 $2 exits 0 (got $rc: $out)" [ "$rc" -eq 0 ]
		check "install on $1 $2 puts bin/prose-check in place" [ -x "$bin/prose-check" ]
		got=$("$bin/prose-check" --version 2>&1)
		check "installed binary on $1 $2 runs" [ "$got" = "prose-check 0.1.0" ]
		check "installed binary on $1 $2 is the $3 asset" \
			cmp -s "$release/v0.1.0/prose-check-$3" "$bin/prose-check"
		check "installed binary on $1 $2 has mode 755" [ "$(stat -c %a "$bin/prose-check" 2>/dev/null || stat -f %Lp "$bin/prose-check")" = 755 ]
		left=$(ls -A "$bin")
		check "install on $1 $2 leaves only prose-check in bin/ (got: $left)" [ "$left" = prose-check ]
	done

	# 2. unsupported platforms are refused in one line, with no file left
	for combo in "SunOS sun4v" "Darwin x86_64" "Linux riscv64" "Linux i686"; do
		# shellcheck disable=SC2086 # the words are the point
		set -- $combo
		setup_root "$root"
		FAKE_OS=$1 FAKE_ARCH=$2 run "$root"
		check "$1 $2 is refused (rc $rc)" [ "$rc" -ne 0 ]
		check "$1 $2 message says 'unsupported platform: $1' (got: $out)" contains "$out" "unsupported platform: $1"
		check "$1 $2 message is one line" [ "$(lines "$out")" -eq 1 ]
		check "$1 $2 leaves bin/ empty" bin_empty "$bin"
	done

	# 3. a wrong checksum is refused with no binary and no temp file
	setup_root "$root"
	PROSE_RELEASE_BASE="file://$bad_release" run "$root"
	check "wrong checksum exits non-zero" [ "$rc" -ne 0 ]
	check "wrong checksum message names the mismatch (got: $out)" contains "$out" "checksum mismatch"
	check "wrong checksum message is one line" [ "$(lines "$out")" -eq 1 ]
	check "wrong checksum leaves no bin/prose-check" [ ! -e "$bin/prose-check" ]
	check "wrong checksum leaves bin/ empty" bin_empty "$bin"

	# 4. a matching binary is kept; the release is not even asked
	setup_root "$root"
	run "$root"
	touch -t 200001010000 "$bin/prose-check"
	before=$(mtime_text "$bin/prose-check")
	PROSE_RELEASE_BASE="file://$work/nowhere" run "$root"
	check "matching binary: exit 0 with no release reachable (got $rc: $out)" [ "$rc" -eq 0 ]
	check "matching binary: mtime unchanged" [ "$(mtime_text "$bin/prose-check")" = "$before" ]
	check "matching binary: says it is kept (got: $out)" contains "$out" "already installed"

	# 5. --force installs again
	run "$root" --force
	check "--force exits 0 (got $rc: $out)" [ "$rc" -eq 0 ]
	check "--force replaces the binary" [ "$(mtime_text "$bin/prose-check")" != "$before" ]

	# 6. odd states of bin/prose-check all lead to a reinstall
	setup_root "$root"
	mkdir -p "$bin"
	printf '#!/bin/sh\necho "prose-check 0.0.9"\n' >"$bin/prose-check"
	chmod 755 "$bin/prose-check"
	run "$root"
	check "other version: exit 0 (got $rc: $out)" [ "$rc" -eq 0 ]
	check "other version: replaced" [ "$("$bin/prose-check" --version)" = "prose-check 0.1.0" ]

	setup_root "$root"
	mkdir -p "$bin"
	cp "$release/v0.1.0/prose-check-linux-x86_64" "$bin/prose-check"
	chmod 644 "$bin/prose-check"
	FAKE_OS=Linux FAKE_ARCH=x86_64 run "$root"
	check "not executable: exit 0 (got $rc: $out)" [ "$rc" -eq 0 ]
	check "not executable: reinstalled and executable" [ -x "$bin/prose-check" ]

	setup_root "$root"
	mkdir -p "$bin"
	printf '#!/bin/sh\nexit 3\n' >"$bin/prose-check"
	chmod 755 "$bin/prose-check"
	run "$root"
	check "--version fails: exit 0 (got $rc: $out)" [ "$rc" -eq 0 ]
	check "--version fails: replaced" [ "$("$bin/prose-check" --version)" = "prose-check 0.1.0" ]

	setup_root "$root"
	mkdir -p "$bin/prose-check"
	run "$root"
	check "bin/prose-check is a directory: refused (rc $rc)" [ "$rc" -ne 0 ]
	check "bin/prose-check is a directory: one line (got: $out)" [ "$(lines "$out")" -eq 1 ]
	check "bin/prose-check is a directory: nothing moved into it" bin_empty "$bin/prose-check"

	# 7. a missing release names the URL, and leaves nothing
	setup_root "$root"
	PROSE_RELEASE_BASE="file://$work/nowhere" run "$root"
	check "missing release exits non-zero" [ "$rc" -ne 0 ]
	check "missing release names the URL (got: $out)" contains "$out" "file://$work/nowhere/v0.1.0/SHA256SUMS"
	check "missing release message is one line" [ "$(lines "$out")" -eq 1 ]
	check "missing release leaves bin/ empty" bin_empty "$bin"

	# the SHA256SUMS exists but the asset does not
	setup_root "$root"
	mkdir -p "$work/half/v0.1.0"
	cp "$release/v0.1.0/SHA256SUMS" "$work/half/v0.1.0/"
	PROSE_RELEASE_BASE="file://$work/half" run "$root"
	check "missing asset exits non-zero" [ "$rc" -ne 0 ]
	check "missing asset names its URL (got: $out)" contains "$out" "file://$work/half/v0.1.0/prose-check-linux-x86_64"
	check "missing asset leaves bin/ empty" bin_empty "$bin"

	# SHA256SUMS without a line for this asset, or with a malformed one
	setup_root "$root"
	mkdir -p "$work/noentry/v0.1.0"
	cp "$release/v0.1.0"/prose-check-* "$work/noentry/v0.1.0/"
	grep -v 'linux-x86_64' "$release/v0.1.0/SHA256SUMS" >"$work/noentry/v0.1.0/SHA256SUMS"
	PROSE_RELEASE_BASE="file://$work/noentry" run "$root"
	check "no checksum line: exit non-zero" [ "$rc" -ne 0 ]
	check "no checksum line: names SHA256SUMS (got: $out)" contains "$out" "SHA256SUMS"
	check "no checksum line: one line" [ "$(lines "$out")" -eq 1 ]
	check "no checksum line: bin/ empty" bin_empty "$bin"

	setup_root "$root"
	mkdir -p "$work/malformed/v0.1.0"
	cp "$release/v0.1.0"/prose-check-* "$work/malformed/v0.1.0/"
	echo 'nothex  prose-check-linux-x86_64' >"$work/malformed/v0.1.0/SHA256SUMS"
	PROSE_RELEASE_BASE="file://$work/malformed" run "$root"
	check "malformed checksum: exit non-zero" [ "$rc" -ne 0 ]
	check "malformed checksum: bin/ empty" bin_empty "$bin"

	# a SHA256SUMS written with CRLF line endings and `*name` binary marks still works
	setup_root "$root"
	mkdir -p "$work/crlf/v0.1.0"
	cp "$release/v0.1.0"/prose-check-* "$work/crlf/v0.1.0/"
	sed 's/  / */; s/$/\r/' "$release/v0.1.0/SHA256SUMS" >"$work/crlf/v0.1.0/SHA256SUMS"
	PROSE_RELEASE_BASE="file://$work/crlf" run "$root"
	check "CRLF and binary-mark SHA256SUMS: exit 0 (got $rc: $out)" [ "$rc" -eq 0 ]

	# an empty asset does not pass as a binary
	setup_root "$root"
	mkdir -p "$work/empty/v0.1.0"
	cp "$release/v0.1.0/SHA256SUMS" "$work/empty/v0.1.0/"
	: >"$work/empty/v0.1.0/prose-check-linux-x86_64"
	PROSE_RELEASE_BASE="file://$work/empty" run "$root"
	check "empty asset: exit non-zero" [ "$rc" -ne 0 ]
	check "empty asset: bin/ empty" bin_empty "$bin"

	# 8. checksum tools: sha256sum, then shasum -a 256, else a refusal
	setup_root "$root"
	mkdir -p "$work/withshasum"
	cat >"$work/withshasum/shasum" <<EOF
#!/bin/sh
[ "\$1" = -a ] && [ "\$2" = 256 ] || { echo "shasum: unexpected arguments: \$*" >&2; exit 2; }
echo used >"$work/shasum-used"
exec "$real_sha"
EOF
	chmod 755 "$work/withshasum/shasum"
	rm -f "$work/shasum-used"
	run_with_path "$root" "$bare:$work/withshasum"
	check "shasum fallback: exit 0 (got $rc: $out)" [ "$rc" -eq 0 ]
	check "shasum fallback: shasum was used" [ -e "$work/shasum-used" ]
	check "shasum fallback: binary runs" [ "$("$bin/prose-check" --version)" = "prose-check 0.1.0" ]

	setup_root "$root"
	run_with_path "$root" "$bare:$work/withshasum" # install once
	setup_root "$root"
	PROSE_RELEASE_BASE="file://$bad_release" run_with_path "$root" "$bare:$work/withshasum"
	check "shasum fallback: wrong checksum refused" [ "$rc" -ne 0 ]
	check "shasum fallback: wrong checksum leaves bin/ empty" bin_empty "$bin"

	setup_root "$root"
	run_with_path "$root" "$bare"
	check "no checksum tool: exit non-zero" [ "$rc" -ne 0 ]
	check "no checksum tool: names both tools (got: $out)" contains "$out" "sha256sum"
	check "no checksum tool: one line" [ "$(lines "$out")" -eq 1 ]
	check "no checksum tool: bin/ empty" bin_empty "$bin"

	# 9. no curl
	setup_root "$root"
	nocurl="$work/nocurl"
	rm -rf "$nocurl"
	mkdir -p "$nocurl"
	for t in "$bare"/*; do [ "${t##*/}" = curl ] || ln -s "$(readlink "$t" 2>/dev/null || echo "$t")" "$nocurl/${t##*/}"; done
	ln -s "$real_sha" "$nocurl/sha256sum"
	run_with_path "$root" "$nocurl"
	check "no curl: exit non-zero" [ "$rc" -ne 0 ]
	check "no curl: names curl (got: $out)" contains "$out" "curl"
	check "no curl: bin/ empty" bin_empty "$bin"

	# 10. the version: from the manifest, PROSE_VERSION wins, and a missing one is refused
	setup_root "$root"
	rm "$root/.claude-plugin/plugin.json"
	run "$root"
	check "no manifest and no PROSE_VERSION: exit non-zero" [ "$rc" -ne 0 ]
	check "no manifest: names PROSE_VERSION (got: $out)" contains "$out" "PROSE_VERSION"
	check "no manifest: one line" [ "$(lines "$out")" -eq 1 ]
	check "no manifest: bin/ empty" bin_empty "$bin"
	PROSE_VERSION=0.1.0 run "$root"
	check "no manifest, PROSE_VERSION set: exit 0 (got $rc: $out)" [ "$rc" -eq 0 ]

	setup_root "$root"
	PROSE_VERSION=9.9.9 run "$root"
	check "PROSE_VERSION beats the manifest: asks for v9.9.9 (got: $out)" contains "$out" "/v9.9.9/"
	check "PROSE_VERSION beats the manifest: leaves bin/ empty" bin_empty "$bin"
	PROSE_VERSION='../../etc' run "$root"
	check "a version that is not a version is refused" [ "$rc" -ne 0 ]
	check "a bad version leaves bin/ empty" bin_empty "$bin"

	# 11. an unknown option is a usage error
	setup_root "$root"
	run "$root" --bogus
	check "unknown option: exit 2 (got $rc)" [ "$rc" -eq 2 ]
	check "unknown option: names it (got: $out)" contains "$out" "--bogus"

	# 12. a signal during a download removes the temp file. The block runs
	# twice: with the real env, and with a stand-in for a BSD env that rejects
	# --default-signal, so the TERM and HUP checks are proven to work there.
	signal_checks "$root" "$bin"
	signal_checks "$root" "$bin" "$bsdenv"

	# 13. several installs at once all succeed and leave one good binary
	setup_root "$root"
	for i in 1 2 3 4; do
		(PATH="$fake:$PATH" HOME="$root/home" "$test_sh" "$root/skills/prose/install" >"$work/par$i.out" 2>&1; echo $? >"$work/par$i.rc") &
	done
	wait
	allok=1
	for i in 1 2 3 4; do [ "$(cat "$work/par$i.rc")" = 0 ] || allok=0; done
	check "four parallel installs all exit 0" [ "$allok" -eq 1 ]
	check "four parallel installs leave only prose-check in bin/" [ "$(ls -A "$bin")" = prose-check ]
	check "four parallel installs leave a working binary" [ "$("$bin/prose-check" --version)" = "prose-check 0.1.0" ]

	# 14. the script run from another directory, through a relative path
	setup_root "$root"
	out=$(cd "$root/skills" && PATH="$fake:$PATH" "$test_sh" prose/install 2>&1)
	rc=$?
	check "run from another directory: exit 0 (got $rc: $out)" [ "$rc" -eq 0 ]
	check "run from another directory: binary lands beside the script" [ -x "$bin/prose-check" ]
}

for suite_spec in "plain:$work/plain" "unicode-and-space:$work/a dir/ünï"; do
	suite_run "${suite_spec%%:*}" "${suite_spec#*:}"
done

printf 'install_test.sh: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

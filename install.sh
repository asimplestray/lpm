#!/bin/sh
# lpm installer (v2.0).
#
# lpm is distributed as source: git clone + one symlink. This script does
# exactly that:
#   * user-level install by default ($HOME/.local: share/ + bin/), so it
#     NEVER needs sudo;
#   * runs either from inside an lpm checkout, OR over the network
#     ("curl -fsSL .../install.sh | sh"), in which case a repository
#     URL is required.
#
# Usage:
#   sh install.sh [options] [REPO_URL]
#
# Options:
#   --prefix=DIR    install prefix (default: $HOME/.local)
#   --force         keep going when a check fails
#   --help          this help
#
# The single hard dependency is a Lua 5.2+ interpreter (5.4 recommended).
# On Void:  sudo xbps-install -S lua5.4   (only you run sudo, as always)
#
# Final state (default paths):
#   ~/.local/share/lpm    the tree (a real git clone when installed from a
#                         URL: `git -C ~/.local/share/lpm pull` updates it)
#   ~/.local/bin/lpm      launcher symlink
#
# Uninstall:  rm -rf ~/.local/share/lpm ~/.local/bin/lpm

set -u

usage() {
	sed -n '/^# Usage:/,/^# Uninstall:/p' "$0" | sed 's/^# //;s/^#//'
	exit 0
}

prefix="${LPM_PREFIX:-$HOME/.local}"
url="${LPM_REPO_URL:-}"
force=""
src=""

# --------------------------------------------------------------- args
for a in "$@"; do
	case $a in
		--prefix=*) prefix=${a#--prefix=} ;;
		--help|-h)  usage ;;
		--force)    force=1 ;;
		-*)         echo "install.sh: unknown option '$a'" >&2; exit 2 ;;
		*)          url=$a ;;
	esac
done

# ------------------------------------------------- prefix sanity rules
# the same discipline as the lpm caches: absolute path, no '..', never '/'
case $prefix in
	/*) ;;
	*)  echo "install.sh: --prefix must be an absolute path ('$prefix')" >&2; exit 2 ;;
esac
case $prefix in
	*..*) echo "install.sh: '..' is not safe in --prefix" >&2; exit 2 ;;
esac
[ "$prefix" != "/" ] || { echo "install.sh: refusing '/'" >&2; exit 2; }

# --------------------------------------------------- where is the source?
# if this file itself lives in an lpm checkout, THAT tree is what gets
# installed (a copy — your working tree stays yours)
me=$0
if command -v readlink >/dev/null 2>&1; then
	while [ -L "$me" ]; do
		t=$(readlink "$me") || break
		case $t in /*) me=$t ;; *) me=$(dirname -- "$me")/$t ;; esac
	done
fi
me_dir=$(dirname -- "$me")

looks_lpm() { [ -f "$1/lpm/cli.lua" ] && [ -f "$1/bin/lpm" ] && [ -f "$1/README.md" ]; }

if looks_lpm "$me_dir"; then
	src=$me_dir
elif [ "$me_dir" != "$PWD" ] && looks_lpm "$PWD"; then
	src=$PWD
fi

tmp=""
cleanup() { [ -n "$tmp" ] && rm -rf "$tmp"; }
trap cleanup INT TERM

# a previous script-install may exist: only replaced when it IS an lpm tree
# (never user content — if it doesn't look like lpm, we abort instead)
install_tree() {
	target=$1
	if [ -e "$target" ] && ! looks_lpm "$target"; then
		echo "install.sh: '$target' exists and is not an lpm install: refusing to touch it" >&2
		echo "            choose another --prefix, or remove that path yourself" >&2
		exit 1
	fi
}

if [ -n "$src" ]; then
	target="$prefix/share/lpm"
	install_tree "$target"
	echo "installing lpm from local tree $src → $target"
	mkdir -p "$(dirname -- "$target")"
	rm -rf "$target"
	mkdir -p "$target"
	# .git is NOT copied from a working tree (it is workspace state);
	# updates are done by re-running install.sh or re-cloning
	cp -R "$src/lpm" "$target/"
	cp -R "$src/bin" "$target/"
	cp -R "$src/profiles" "$target/"
	cp -R "$src/tests" "$target/"
	cp "$src"/*.md "$src/install.sh" "$target/" 2>/dev/null || true
else
	if [ -z "$url" ]; then
		echo "install.sh: no lpm source found." >&2
		echo "  run it from inside an lpm checkout, or give the repo URL:" >&2
		echo "    sh install.sh <REPO_URL>            (or: \$LPM_REPO_URL=… sh install.sh)" >&2
		exit 2
	fi
	target="$prefix/share/lpm"
	install_tree "$target"
	echo "installing lpm from $url → $target"
	if [ -d "$target/.git" ]; then
		# freshening OUR clone (git pull --ff-only: no rewrite surprises)
		git -C "$target" remote set-url origin "$url" 2>/dev/null || true
		if git -C "$target" pull --ff-only; then :; else
			echo "install.sh: git pull failed; delete '$target' and retry for a fresh clone" >&2
			exit 1
		fi
	else
		mkdir -p "$target"
		if [ -n "$(ls -A "$target" 2>/dev/null)" ]; then
			echo "install.sh: '$target' exists, is not an lpm clone: refusing to touch it" >&2
			exit 1
		fi
		tmp=$(mktemp -d "${TMPDIR:-/tmp}/lpm-install.XXXXXX")
		if ! git clone --depth 1 "$url" "$tmp/lpm"; then
			echo "install.sh: git clone failed (URL? git in PATH?)" >&2
			# target was created empty by us: rmdir removes it ONLY if empty
			rmdir "$target" 2>/dev/null || true
			cleanup
			exit 1
		fi
		if ! looks_lpm "$tmp/lpm"; then
			echo "install.sh: the repository does not look like lpm (no lpm/cli.lua + bin/lpm)" >&2
			echo "            check the URL — it must point at the lpm repository itself" >&2
			rmdir "$target" 2>/dev/null || true
			cleanup
			exit 1
		fi
		# whole clone into the target — .git kept so `git pull` can update;
		# rmdir first: mv into an EXISTING empty dir would nest (lpm/lpm)
		rmdir "$target" 2>/dev/null || { rm -rf "$target"; }
		mv "$tmp/lpm" "$target" || { echo "install.sh: could not move into $target" >&2; cleanup; exit 1; }
		tmp=""
	fi
fi

# ------------------------------------------------------------- interpreter
# the launcher re-detects at runtime; this early check makes the failure
# DIDACTIC (with the honest fix hint) instead of a Lua syntax error
ok_lua=""
for lua in ${LPM_LUA:-} lua5.4 lua5.3 lua5.2 lua; do
	[ -n "$lua" ] || continue
	if command -v "$lua" >/dev/null 2>&1 &&
		"$lua" -e 'if _VERSION:find("Lua 5%.1") then os.exit(1) end goto ok ::ok::' >/dev/null 2>&1; then
		ok_lua=$lua
		break
	fi
done
if [ -z "$ok_lua" ]; then
	echo "install.sh: no Lua 5.2+ interpreter in PATH (5.4 recommended)" >&2
	if [ -n "${LPM_LUA:-}" ]; then
		echo "            (''LPM_LUA='${LPM_LUA}' was given but is not usable)" >&2
	fi
	echo "            on Void: sudo xbps-install -S lua5.4   (run it yourself)" >&2
	if [ "$force" = 1 ]; then
		echo "install.sh: continuing because of --force (lpm will not run)" >&2
	else
		echo "install.sh: install stays incomplete; tree kept at $target" >&2
		exit 1
	fi
fi

# --------------------------------------------------------------- symlink
mkdir -p "$prefix/bin"
if ! ln -sfn "$target/bin/lpm" "$prefix/bin/lpm"; then
	echo "install.sh: cannot create $prefix/bin/lpm" >&2
	exit 1
fi

# --------------------------------------------------- live check on the link
"$prefix/bin/lpm" version || { echo "install.sh: launcher check failed" >&2; exit 1; }

case ":$PATH:" in
	*":$prefix/bin:"*) ;;
	*) echo ""
		echo "NOTE: $prefix/bin is not in \$PATH. add to your shell profile:"
		echo "      export PATH=\"$prefix/bin:\$PATH\"" ;;
esac

echo ""
echo "installed."
echo "  tree:        $target"
echo "  launcher:    $prefix/bin/lpm"
echo "  uninstall:   rm -rf '$target' '$prefix/bin/lpm'"
echo ""
echo "next:"
echo "  $prefix/bin/lpm doctor"
echo "  $prefix/bin/lpm search <package>"
echo "  $prefix/bin/lpm install <package>"
exit 0

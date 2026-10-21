# lpm

**lpm** is a package manager written in 100% Lua that *rents* the repositories
of famous distros to install software on distros with a weaker package
ecosystem — currently **Void Linux, borrowing from Arch** (and experimentally
from Debian).

It never installs anything by itself: the host's native package manager
(xbps) always decides file conflicts, ordering and cleanup. At the end of a
conversion, lpm prints the exact `sudo xbps-install` command for *you* to run.

```
donor (Arch) ──▶ lpm (conversion) ──▶ .xbps ──▶ xbps-install (host Void, ...run by you)
```

## The one rule

**The donor must never be newer than the host.** A converted package that is
newer than the host's system breaks at dynamic-link time (`GLIBC_2.x not
found`) or steals sonames from native packages. Void (rolling) ← Arch
(rolling) respects this by construction, and lpm *enforces it per package*:
every binary's minimum `GLIBC_x.y` is read from the ELF metadata and compared
against the host's glibc using xbps' own comparator — a payload that needs a
newer glibc is not converted, no matter what.

## Install

Requirements: Void Linux with xbps, **Lua 5.2+** (`sudo xbps-install -S
lua5.4`), and nothing else that isn't already on a normal Void install
(`tar`, `zstd`, `gzip`, `sha256sum`, `xbps-*` are all core; lpm uses
subprocesses instead of luarocks/FFI on purpose). The installer never
runs sudo — you run sudo yourself, only ever for xbps.

### With the installer (recommended)

```sh
curl -fsSL https://raw.githubusercontent.com/asimplestray/lpm/main/install.sh | sh     # or: sh install.sh https://github.com/asimplestray/lpm
```

It installs to `$HOME/.local` by default (tree in
`~/.local/share/lpm`, launcher in `~/.local/bin/lpm`), answers
`lpm version` when done and prints the exact `rm -rf` line for
uninstalling. Options: `--prefix=DIR`, `--force`, `--help`.

Later, to update the install that was made from a git URL:

```sh
curl -fsSL https://raw.githubusercontent.com/asimplestray/lpm/main/install.sh | sh     # freshens the clone (git pull --ff-only)
# or, fully manual:
git -C ~/.local/share/lpm pull
```

### Manual (3 steps)

```sh
git clone https://github.com/asimplestray/lpm lpm && cd lpm
./bin/lpm doctor          # confirms every piece, with fix hints
ln -s "$PWD/bin/lpm" ~/.local/bin/lpm   # (or on PATH somewhere)
```

The `bin/lpm` launcher resolves symlinks, so the link in `~/.local/bin`
works even though it points outside the tree.

If `./bin/lpm doctor` shows ✘ items, install what it suggests
(e.g. `sudo xbps-install -S curl`) and run it again until everything is ✔.

## 5-minute tour

```sh
lpm sync                  # download donor indexes (Arch core+extra)
lpm search cowsay
lpm info flex             # donor-side details: version, size, deps
lpm check at              # preflight against *your* host, right now, cheap
lpm install at            # the real thing (see below)
```

`lpm install` runs the full pipeline **without root**:

1. solves the dependency chain *inside the donor* (e.g. `at` → `flex` → `m4`);
   nothing is ever downloaded before the plan is clean;
2. downloads and sha256-verifies each payload;
3. stages it while **ignoring the donor's scripts and metadata** — Arch
   scripts call `systemctl`, Void is runit: **donor code never runs on the
   host**;
4. ELF-scans the staged payload in pure Lua: real `DT_NEEDED` sonames and the
   max `GLIBC_2.x` requirement; anything the host cannot satisfy anywhere
   aborts the whole transaction;
5. converts to `.xbps` with `xbps-create` (deps re-written into xbps
   language, with the empirical formats below) and registers it in the local
   repo `~/.cache/lpm/converted`;
6. runs `xbps-install -n` (dry-run): the host's own solver must accept the
   complete transaction *before* anything is suggested; and
7. prints the final command, e.g.
   `sudo xbps-install -R '~/.cache/lpm/converted' 'm4-...' 'flex-...' 'at-...'` —
   **you** run it.

Any host package whose name (or native virtual name) a chain node would
shadow is a hard block: *"replacing the native is the user's decision"*.
Only names you explicitly typed on the CLI enter as updates — with a notice.

## Command reference

| command | what it does |
|---|---|
| `lpm detect` | what this host is and which profile applies |
| `lpm doctor` | diagnose interpreter, tools, caches and index freshness (with fix hints) |
| `lpm sync [--force]` | download donor indexes (refresh forcibly) |
| `lpm search <term>` | search by name/description |
| `lpm info <pkg>` | donor-side details |
| `lpm check <pkg>` | cheap preflight against the host |
| `lpm install <pkg>…` | the pipeline above; prints the final sudo command |
| `lpm list` | everything converted into the local repo, with per-package host state |
| `lpm remove <pkg>…` | prints `sudo xbps-remove <pkg>` — never runs it |
| `lpm clean [--all]` | wipe the conversion repo (`--all` also donor index caches; they re-download) |
| `lpm version` | `lpm 1.0.0` |

## Why so paranoid?

- **The final `sudo` is yours on purpose.** lpm's conversion path runs as
  your user in `~/.cache/lpm`; being root would be *less* safe, so lpm
  refuses to run as root.
- **Donor scripts never happen.** `.INSTALL`/`.PKGINFO`/`.MTREE`/
  `.BUILDINFO` (Arch) and `control.tar.*` (Debian) are simply never unpacked.
- **The dry-run is the hammer.** `xbps-install -n` is the real solver saying
  “this exact transaction is acceptable”, on the real host, before anything
  is suggested to you.
- **Sonames are checked twice**: once from documented deps, and once from
  what the binaries *actually* `DT_NEEDED` at convert time — the payload's
  truth wins.

## Private libraries (v1.2)

The hardest rule was "the chain must not convert a donor package over a
native one" — which made whole classes of apps (Electron-ish ones pulling
donor `glib2`/`libglvnd` chains, for example) **uninstallable**, honestly.

v1.2 adds the escape hatch, **suggested and designed with the user**: when
the only available provider of a needed soname would **shadow a native host
package**, lpm no longer aborts — it **folds that provider's payload into
the app's own package** instead of installing it system-wide:

```
app's payload
  ├── /usr/bin/app                  ← a generated wrapper now
  ├── /usr/libexec/lpm/app/app      ← the real binary
  └── /usr/lib/lpm/libfoo/…         ← the donor lib, PRIVATE to this app
```

- The wrapper sets `LD_LIBRARY_PATH` **only for that app's process**: the
  system never sees the donor lib, so the native package and everything
  depending on it stay intact.
- Since the libs are files *of the app's own .xbps*, `sudo xbps-remove app`
  removes the whole bubble — no separate packages, no leftover directories,
  still exactly **one sudo command**.
- The same rules still hold *inside* the bubble: every folded payload is
  sha256-checked, ELF-scanned and must not require a newer glibc than the
  host (a donor lib older than the host is precisely why the fold is safe).
- The runtime itself (`glibc`/`linux`/`musl`) is **never** folded — nothing
  interposes on the host's loader, not even privately.
- Nothing to do by hand: `lpm install <app>` prints
  `folding private libs into <app>: /usr/lib/lpm/…` and `wrapped: …` when the
  bubble exists. If there are no private libs, everything behaves exactly
  as in v1.1.

Related fix included: donor soname deps that are *bare* (`libffi.so`) now
match host keys by prefix (`libffi.so.8`) — the lib's ABI is exactly what a
soname number encodes, so the host's (same-ABI, usually newer) library
satisfies the dep without any conversion at all.

## Automatic library aliasing (v1.2.1, upgraded in v2.0)

The old hand-maintained name table was the slow path: every cross-distro
name needed a human entry. It is now the **exception list only** — the
general case is resolved from data that already exists:

- **Layer A — the name *is* the soname.** Debian-style lib names are just
  sonames with the punctuation eaten: `libc6` → `libc.so.6`, `libssl3` →
  `libssl.so.3`, `libgcc-s1` → `libgcc-s.so.1`, `libsqlite3-0` →
  `libsqlite3.so.0`, `libatk-1.0-0` → `libatk-1.0.so.0`. If the host's
  installed shlib map provides that exact ABI, the dep is satisfied by the
  host — no table, no conversion, no download. (Void-current itself adopted
  `lib<N>` naming, which makes this bridge literal; the reconstructed name
  is never trusted blindly — only a real key in the host map counts.)
- **Layer B — the provider's sonames testify.** A virtual dep like the
  donor's `libgl`/`libegl`/`libgles` resolves to *whatever the donor
  provides it with*; if that provider's **declared sonames all exist on the
  host**, it is provably the same component and the dep closes (this is how
  the donor's `libglvnd` stops shadowing anything). Partial splits prove
  nothing — the dep falls back to the normal honest flow.
- **Layer C / host repodata bridge (v2.0).** Both layers now also read the
  **host repository's own repodata** (`shlib-provides`/`provides` per
  package, the very index the native solver consults), not only the
  installed pkgdb. This closes renames that no soname witness on the
  installed system could prove — donor `gtk3` ↔ native `gtk+3` being the
  live case: the chain reports `auto-aliasing: 1 dep(s) ride host
  components by soname bridge: gtk3 → gtk+3`, and the converted `.xbps`
  ships `gtk+3>=0`, which the native solver resolves from the official
  repo. If `xbps` hasn't synced a repo yet on this machine, the bridge
  fetches the same file once via the plain downloader (never sudo) and
  caches the parsed map keyed by the repodata `(mtime:size)`; without any
  repodata the aliasing silently degrades to the v1.2.1 installed-map
  behavior (`lpm doctor` reports how many sonames are readable).
- **Conversion too, not just planning:** the converter rewrites donor dep
  names through the same layers (chain-verified solutions first, exception
  table, transaction witness, then the repodata) when it stamps the
  `.xbps` metadata — `libc6` ships as `glibc>=…`, `gtk3` as `gtk+3>=0`,
  never as an unsolvable foreign name.
- Version operators are satisfied through the same ABI witness, and the
  payload scan remains the final word on host compatibility.

`lpm/aliases.lua` now holds only documented exceptions (`zlib1g` — no
`lib` prefix to reconstruct; `libffi8`/`libuv1`/`libaudit1` — ABIs the
host's map doesn't show). Every row must cite its reason.

## What's new in v2.0 (faster + more honest)

- **Hot paths are 10×+ faster.** Parsed donor indices are cached as Lua
  dumps keyed by the `(mtime:size)` of each `.db` — a warm `lpm search`
  went from ~3.5 s to ~0.3 s (no tar/xz/zstd, no re-parse of 15 000
  packages per command). The host pkgdb is read in **one pass** feeding
  installed/shlibs/provides at once (was three full scans plus a
  subprocess), ~33 ms instead of ~100+ ms.
- **`any`-arch conversions actually index.** `xbps-rindex` 0.60 refuses
  `arch=any` packages while *still exiting 0* (reproduced live), so
  previous conversions could silently vanish from the pool. lpm now
  re-stamps them with the host arch (`x86_64`), prunes the legacy
  `.any.xbps` files on reconversion, and treats any `index: ignoring …`
  output from rindex as a hard error instead of trusting the exit code.
- **Epoch versions** like Arch's `discord-1:1.0.164-1` survive conversion
  (`discord-1:1.0.164.1_1`) and are accepted by xbps 0.60 — validated
  end-to-end.

## Known xbps 0.60 empirics (encoded in the converter)

- `-D`, `--shlib-requires` and `-P` are one flag taking a space-separated
  list in a single argument; a comma just creates a literal dep that no
  solver can match.
- An exact dependency in xbps is the full pkgver *without an operator*:
  `flex-2.6.4.6_1` resolves; `flex=2.6.4.6_1` does not.
- Version strings may contain only alnum, `.`, `~`, `:` and one trailing
  `_rev`; `-`/`+` from donor versions are translated to `.`.
- Provides are `name-<version>`; the split happens on the last `-`, so
  names with hyphens work.
- When the solver resolves a dependency through a *virtual provided by the
  local repo*, it mishandles the global shlib check (reproduced upstream as
  `broken, unresolvable shlib` on unrelated installed packages). lpm avoids
  it by rewriting intra-transaction deps to exact-pkgver form.

## Debian as donor (experimental)

`--donor=debian` adds Debian stable — *older* than a rolling host by
construction, so the one rule holds. Useful when you want a stable library
version that Void's current repoleft behind. The index and payload pipeline
(plain-Lua `ar` parsing, zstd/gzip magic detection, `python3` lzma for xz)
is complete, and simple packages convert end-to-end. Known limit: Perl/XS
stacks (e.g. `cowsay` → `perlapi-*`/`perl-base`) are correctly *blocked* —
Void's perl (5.42) cannot run XS modules compiled for the 5.40 ABI, and
shadowing the native `perl-base` vpkg would corrupt the solver.

## Where things live & uninstall

```
~/.cache/lpm/arch       donor index cache        (lpm clean --all removes)
~/.cache/lpm/debian     same, for --donor=debian
~/.cache/lpm/converted  converted .xbps + repodata (lpm clean removes)
~/.config/lpm/config.lua  optional overrides (db_dir, install_repo_dir, mirrors)
```

lpm itself is a plain directory: remove the symlink and (optionally)
`lpm clean --all`. Anything you already installed on the host stays there
until *you* `xbps-remove` it.

## Mirrors (v1.1)

lpm declares, per donor, a **mirror base** plus the *paths* behind it — the
path layout is the donor's property and is never rewritten; only the base
swaps. Precedence: `--mirror=URL` (one invocation) > `mirrors` in
`~/.config/lpm/config.lua` > profile default. lpm prints an override notice
and refuses non-`http(s)` bases.

```sh
lpm install m4 --mirror=https://mirror.rackspace.com/archlinux
lpm sync --force --donor=debian --mirror=https://mirror.csclub.uwaterloo.ca/debian
```

```lua
-- ~/.config/lpm/config.lua (persistent override)
return { mirrors = { arch = "https://mirrors.kernel.org/archlinux" } }
```

After switching a mirror, refresh the cached index: `lpm sync --force`
(the index cache is per donor, not per mirror).

## FAQ

**Why does install end with a printed command instead of installing?**
By design: the privilege boundary is explicit and evidence-based — the
dry-run output right above it is the record of what the host accepted.

**A conversion went wrong / I want a package gone.**
`lpm clean` (empty the local repo), `lpm remove <pkg>` (print the removal
command). Nothing installed via the final command is removed by lpm.

**Can I change the install path or the cache?**
Yes — `install_repo_dir`/`db_dir` in `~/.config/lpm/config.lua`; the
per-donor mirror override is the `mirrors` table (section above).

**Is this safe?** It is *deliberately limited*: no root, no scripts from
donors, nothing installed without your explicit sudo, every transaction
dry-run-checked first, and hard blocks on anything that would shadow a
native package or need a newer glibc than the host.

## v2.0.1 — three bugs from the real-world batch + frozen-snapshot recipe

A batch of real installs (see Status below) exercised paths the suite
hadn't, and three bugs surfaced. All fixed and reproduced-fix-verified:

1. **Private-bubble crash** (`cli.lua`): the fold path used `tx_shlibs`
   declared *below* its definition — a Lua scoping classic (`local` is
   only visible after the declaration). First private fold crashed;
   now the whole `libffi`/`libxml2` fold machinery runs.
2. **Lost solved-names of plan2** (`cli.lua`): late-queued nodes
   ("sodep revealed post-staging") ran their own `chain.plan`, whose
   `solved` map never merged back — the converted `.xbps` shipped
   *untranslated* dep names (`gdk-pixbuf2`/`libp11-kit` raw inside
   `gcr`, found with bitwarden). plan2 solves now merge into the main
   plan.
3. **Missing shlib-provides** (`convert.lua`): the pool assumed
   xbps-rindex would infer the payload's `DT_SONAME` — it doesn't, and
   xbps 0.60's global shlib check aborts the transaction
   (`unresolvable shlib libsystemd.so.0`) even with the exact provider
   dep present. Converted packages now declare `--shlib-provides`
   explicitly (same format as official Void repodata), excluded for
   the private bubble.

Plus: mirror overrides now warn when the cached donor indices are from
another era (the `.db` cache is sig-keyed and era-blind; each era is
self-consistent only when index+packages come from the same snapshot).

### The frozen-snapshot recipe (when the donor is newer than the host)

Void-current is on glibc 2.41 while Arch-current ships 2.44 — so the
one rule ("donor never newer than the host") honestly rejects several
current Arch packages (every electron42/Qt6-based one, e.g. `code`,
`virtualbox`). The Arch Linux Archive solves this: it contains *every*
historical state of the repos, self-consistent per date:

```sh
# donor era where glibc was 2.41 (matches Void-current, Oct 2026)
lpm sync --force --mirror=https://archive.archlinux.org/repos/2025/05/01
lpm install bitwarden --mirror=https://archive.archlinux.org/repos/2025/05/01
# → bitwarden 2025.2.1.1: ACCEPTED (10-node chain incl. electron34
#   + gcr + gnome-keyring), final sudo command printed
# back to the current era afterwards:
lpm sync --force
```

### Raising the host glibc instead ( Void packages, the other half of the wall)

The archive recipe freezes the *donor*; the alternative is to raise the
*host*. Void-current itself was still on glibc 2.41 in Oct 2026, but the
upstream tarball (2.43/2.44) builds cleanly from Void's own template —
which keeps the loader Void-blessed (never install a foreign distro's
glibc package; only the loader matching the distro configuration is
safe). The bump is three edits + patch triage + the usual local repo
transaction:

```sh
git clone https://github.com/void-linux/void-packages
cd void-packages && ./xbps-src binary-bootstrap
sed -i 's/^version=2\.41/version=2.44/' srcpkgs/glibc/template
./xbps-src -j$(nproc) pkg glibc   # fails once with `SHA256 mismatch … got: <H>`
sed -i "s/^checksum=.*/checksum=\"<H>\"/" srcpkgs/glibc/template
# patch era-backports now fail with "Reversed (or previously applied)"
#   → already upstream in 2.44, remove each one as it errors
sudo xbps-install --repository="$PWD/hostdir/binpkgs" \
    glibc glibc-devel glibc-locales
```

Proven end-to-end Oct 2026 (8 era-2.41 backport patches removed, 2.44
built clean, host `.xbps` transaction accepted). The per-package
preflight then opens by itself: the same `check` that rejected
`code`/`bitwarden`/`obs-studio`/`virtualbox` against glibc 2.41 no
longer shows any ABI line — the wall is one rule, so raising the host
side is the upgrade direction that clears the whole batch at once.

Restrictions unchanged: official repos only — the AUR is out of scope
(lpm resolves against real indexes; there is no AUR index to trust).

## Status

- Version: **2.0.1** (host-repodata name bridge; cached indices; honest `any`
  arch; mirrors per donor; private libs fold; automatic lib aliasing;
  frozen-snapshot mirror recipe; explicit shlib-provides).
- Working host policy: **Void ← Arch (default, stable)**, **Void ← Debian
  (experimental)**.
- Validation: version comparators ported 1:1 from pacman/dpkg/xbps with
  upstream test-vectors; ELF scan without binutils; the Arch chain
  (`at`→`flex`→`m4`) accepted end-to-end by the real host solver, on the
  default mirror and on an overridden one.
- Real-world batch (Oct 2026, Void-current glibc 2.41, arch donor current):
  `discord` ✔, `signal-desktop` ✔ (chain rescued `libxrandr`,
  `systemd-libs`, …), `bitwarden` ✔ via the frozen-snapshot recipe (2.0.1);
  `code`/`obs-studio`/`virtualbox`/`dolphin-emu`/`prismlauncher` ✘ honest
  rejects (donor needs glibc 2.43–2.44 — the one rule, verified before
  anything is installed). Follow-up, same month: host glibc raised to
  2.44 via Void's own template (recipe above) — `check` on those five
  then reports only ordinary provider-deps for the chain pass, no ABI
  line anywhere. No package was ever left half-installed.
- Known limits: x86_64 only (untested elsewhere); Debian-qualified deps
  (`perl:any`) lose the qualifier; big-endian ELF is out of scope.

## License

MIT — see the `LICENSE` file (`Copyright (c) 2026 the lpm authors`).

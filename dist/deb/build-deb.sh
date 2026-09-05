#!/usr/bin/env bash
#
# Build a Debian/Ubuntu binary package (.deb) of Ghostty.
#
# This does a "system package" style build as described in PACKAGING.md: it
# installs into a staging root with DESTDIR and then wraps that root in a .deb.
# It does NOT install any build dependencies; those must already be present.
# See .github/workflows/release-deb.yml for the exact apt package list and for
# the Zig and blueprint-compiler versions this expects.
#
# Usage:
#   dist/deb/build-deb.sh [--version <semver>] [--out <dir>]
#
# Environment:
#   DEB_MAINTAINER        Maintainer field (default: repository author)
#   ZIG_GLOBAL_CACHE_DIR  Offline dependency cache (default: <root>/.zig-deb-cache)

set -euo pipefail

readonly ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

version=""
out_dir="$ROOT/zig-out/deb"

while [ $# -gt 0 ]; do
  case "$1" in
    --version) version="$2"; shift 2 ;;
    --out) out_dir="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Version
#
# Zig wants a semantic version. dpkg wants a version where a stable release
# sorts *after* the dev builds leading up to it, so the semver prerelease
# separator "-" becomes "~", which dpkg orders before everything else.
# ---------------------------------------------------------------------------

if [ -z "$version" ]; then
  base="$(sed -n 's/^[[:space:]]*\.version = "\([^"]*\)".*/\1/p' "$ROOT/build.zig.zon" | head -n1)"
  if [ -z "$base" ]; then
    echo "could not read .version from build.zig.zon" >&2
    exit 1
  fi

  # A "-dev" version gets the commit appended so that every build is
  # distinguishable and dpkg can order them. The "g" prefix keeps the
  # identifier alphanumeric, which semver requires.
  case "$base" in
    *-dev)
      sha="$(git -C "$ROOT" rev-parse --short=7 HEAD 2>/dev/null || echo unknown)"
      version="$base.g$sha"
      ;;
    *) version="$base" ;;
  esac
fi

deb_version="$(printf '%s' "$version" | sed 's/-/~/; s/+/./g')"
arch="$(dpkg --print-architecture)"
maintainer="${DEB_MAINTAINER:-Ahmed Abouzied <ahmedaabouzied44@gmail.com>}"

echo "==> Building ghostty $version (deb version $deb_version, $arch)"

# ---------------------------------------------------------------------------
# Fetch dependencies into an offline cache
# ---------------------------------------------------------------------------

export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$ROOT/.zig-deb-cache}"
mkdir -p "$ZIG_GLOBAL_CACHE_DIR"

echo "==> Fetching Zig dependencies into $ZIG_GLOBAL_CACHE_DIR"
"$ROOT/nix/build-support/fetch-zig-cache.sh"

# Zig 0.16 keeps fetched packages in the global cache as tarballs, but
# --system wants them extracted into directories named for the package hash.
# Each tarball already has exactly that directory at its root, so unpacking
# them side by side produces the layout --system looks for.
system_deps="$ROOT/.zig-deb-system"
mkdir -p "$system_deps"

echo "==> Extracting dependencies into $system_deps"
for archive in "$ZIG_GLOBAL_CACHE_DIR"/p/*.tar.gz; do
  [ -e "$archive" ] || continue
  name="$(basename "$archive" .tar.gz)"
  [ -d "$system_deps/$name" ] || tar -xzf "$archive" -C "$system_deps"
done

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

stage="$out_dir/root"
rm -rf "$stage"
mkdir -p "$stage" "$out_dir"

# --system puts the build in system package mode: dependencies link against
# the distro's shared libraries, the binary is a PIE, man pages are built, and
# the systemd user unit lands in /usr/lib instead of /usr/share.
#
# gtk4-layer-shell is the exception. Ubuntu 24.04 does not ship it, so we opt
# out of system integration and let the build produce the shared library
# itself; it installs alongside the binary and ships inside this package.
echo "==> Running zig build"
DESTDIR="$stage" zig build \
  --prefix /usr \
  --system "$system_deps" \
  -Doptimize=ReleaseFast \
  -Dcpu=baseline \
  -Dversion-string="$version" \
  -fno-sys=gtk4-layer-shell

if [ ! -x "$stage/usr/bin/ghostty" ]; then
  echo "build did not produce $stage/usr/bin/ghostty" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Package
# ---------------------------------------------------------------------------

echo "==> Stripping binaries"
strip --strip-unneeded "$stage/usr/bin/ghostty"
if [ -d "$stage/usr/lib" ]; then
  find "$stage/usr/lib" -type f -name '*.so*' \
    -exec strip --strip-unneeded {} +
fi

echo "==> Adding documentation"
install -Dm644 "$ROOT/LICENSE" "$stage/usr/share/doc/ghostty/copyright"

# dpkg-shlibdeps resolves the runtime dependencies from the ELF files we
# actually produced, so the Depends field always matches the real linkage
# rather than a hand-maintained guess. It insists on a debian/control being
# present in the working directory, hence the throwaway one.
echo "==> Computing dependencies"
mkdir -p "$stage/debian"
printf 'Source: ghostty\n' >"$stage/debian/control"
shlibdeps_log="$out_dir/dpkg-shlibdeps.log"
shlibdeps="$(
  cd "$stage" &&
    dpkg-shlibdeps -O --ignore-missing-info -l"$stage/usr/lib" \
      usr/bin/ghostty 2>"$shlibdeps_log" |
      sed -n 's/^shlibs:Depends=//p'
)"
rm -rf "$stage/debian"

if [ -z "$shlibdeps" ]; then
  echo "dpkg-shlibdeps produced no dependencies:" >&2
  cat "$shlibdeps_log" >&2
  exit 1
fi
echo "    Depends: $shlibdeps"

mkdir -p "$stage/DEBIAN"

installed_size="$(du -ks --exclude=DEBIAN "$stage" | cut -f1)"

cat >"$stage/DEBIAN/control" <<EOF
Package: ghostty
Version: $deb_version
Architecture: $arch
Maintainer: $maintainer
Installed-Size: $installed_size
Depends: $shlibdeps
Provides: x-terminal-emulator
Section: x11
Priority: optional
Homepage: https://ghostty.org
Description: Fast, native, feature-rich terminal emulator
 Ghostty is a terminal emulator that differentiates itself by being fast,
 feature-rich, and native. While there are many excellent terminal emulators
 available, they all force you to choose between speed, features, or native
 UIs. Ghostty provides all three.
 .
 This package is built from a fork of the upstream Ghostty source.
EOF

cat >"$stage/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e

if [ "$1" = "configure" ]; then
  update-alternatives --install /usr/bin/x-terminal-emulator \
    x-terminal-emulator /usr/bin/ghostty 50
fi

exit 0
EOF

cat >"$stage/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e

if [ "$1" = "remove" ]; then
  update-alternatives --remove x-terminal-emulator /usr/bin/ghostty
fi

exit 0
EOF

chmod 0755 "$stage/DEBIAN/postinst" "$stage/DEBIAN/prerm"

# md5sums must list every shipped file but must not list itself, so it is
# generated into a temporary file first.
(
  cd "$stage" &&
    find . -type f ! -path './DEBIAN/*' -printf '%P\0' |
    sort -z |
    xargs -0 --no-run-if-empty md5sum >DEBIAN/md5sums.tmp &&
    mv DEBIAN/md5sums.tmp DEBIAN/md5sums
)
chmod 0644 "$stage/DEBIAN/control" "$stage/DEBIAN/md5sums"

deb="$out_dir/ghostty_${deb_version}_${arch}.deb"
echo "==> Building $deb"
dpkg-deb --root-owner-group --build "$stage" "$deb" >/dev/null

echo
echo "Built: $deb"
ls -lh "$deb" | awk '{print "Size:  " $5}'

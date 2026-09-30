#!/bin/sh
# Installs zeta from the latest GitHub release:
#   curl -fsSL https://raw.githubusercontent.com/and2049/zeta/main/install.sh | bash
# ZETA_VERSION picks a release tag (e.g. v0.1.0); ZETA_INSTALL_DIR the
# directory (default ~/.local/bin).
set -eu

repo="and2049/zeta"
dir="${ZETA_INSTALL_DIR:-$HOME/.local/bin}"
version="${ZETA_VERSION:-latest}"

fail() {
  echo "zeta: $*" >&2
  exit 1
}

case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=darwin ;;
  *) fail "no release for $(uname -s); build from source with Zig 0.16" ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) arch=x86_64 ;;
  arm64 | aarch64) arch=aarch64 ;;
  *) fail "no release for $(uname -m); build from source with Zig 0.16" ;;
esac

asset="zeta-$os-$arch.tar.gz"
if [ "$version" = latest ]; then
  base="https://github.com/$repo/releases/latest/download"
else
  base="https://github.com/$repo/releases/download/$version"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "Downloading $asset ($version)..."
curl -fsSL "$base/$asset" -o "$tmp/$asset" || fail "download failed: $base/$asset"
curl -fsSL "$base/SHA256SUMS" -o "$tmp/SHA256SUMS" || fail "download failed: $base/SHA256SUMS"

expected="$(awk -v f="$asset" '$2 == f { print $1 }' "$tmp/SHA256SUMS")"
if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$tmp/$asset" | awk '{ print $1 }')"
else
  actual="$(shasum -a 256 "$tmp/$asset" | awk '{ print $1 }')"
fi
[ -n "$expected" ] && [ "$expected" = "$actual" ] || fail "checksum mismatch for $asset"

tar -xzf "$tmp/$asset" -C "$tmp"
mkdir -p "$dir"
mv "$tmp/zeta" "$dir/zeta"
chmod 755 "$dir/zeta"
echo "Installed $("$dir/zeta" --version) to $dir/zeta"

case ":$PATH:" in
  *":$dir:"*) ;;
  *) echo "Add $dir to your PATH, e.g.: echo 'export PATH=\"$dir:\$PATH\"' >> ~/.bashrc" ;;
esac

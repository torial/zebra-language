#!/usr/bin/env sh
# Zebra installer for Linux and macOS.
#   curl -fsSL https://raw.githubusercontent.com/torial/zebra-language/main/install/install.sh | sh
# Downloads the latest release for this platform into ~/.zebra and prints the PATH line.
# The release carries its own Zig (zebra/zig/), so nothing else is needed.
set -eu
REPO="torial/zebra-language"
os=$(uname -s); arch=$(uname -m)
case "$os" in
  Linux)  plat=linux ;;
  Darwin) plat=macos ;;
  *) echo "install.sh: unsupported OS '$os' (Linux and macOS; Windows uses install.ps1)"; exit 1 ;;
esac
case "$arch" in
  x86_64|amd64) arch=x86_64 ;;
  arm64|aarch64) arch=aarch64 ;;
  *) echo "install.sh: unsupported architecture '$arch'"; exit 1 ;;
esac
tag="${ZEBRA_VERSION:-}"
if [ -z "$tag" ]; then
  tag=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
fi
[ -n "$tag" ] || { echo "install.sh: could not determine the latest release tag"; exit 1; }
ver=${tag#v}
asset="zebra-${ver}-${plat}-${arch}.tar.gz"
url="https://github.com/$REPO/releases/download/$tag/$asset"
dest="${ZEBRA_HOME:-$HOME/.zebra}"
tmp=$(mktemp -d)
echo "downloading $asset ..."
curl -fsSL "$url" -o "$tmp/$asset"
sums="https://github.com/$REPO/releases/download/$tag/SHA256SUMS.txt"
if curl -fsSL "$sums" -o "$tmp/SHA256SUMS.txt" 2>/dev/null; then
  want=$(grep " $asset\$" "$tmp/SHA256SUMS.txt" | cut -d' ' -f1)
  got=$(cd "$tmp" && (sha256sum "$asset" 2>/dev/null || shasum -a 256 "$asset") | cut -d' ' -f1)
  [ -z "$want" ] || [ "$want" = "$got" ] || { echo "install.sh: checksum mismatch for $asset"; exit 1; }
fi
mkdir -p "$dest"
tar xzf "$tmp/$asset" -C "$tmp"
rm -rf "$dest/current"
mv "$tmp/zebra-${ver}-${plat}-${arch}" "$dest/current"
rm -rf "$tmp"
echo "installed zebra $ver to $dest/current"
"$dest/current/zebra" --version
case ":$PATH:" in
  *":$dest/current:"*) ;;
  *) echo; echo "add it to your PATH:"; echo "  export PATH=\"$dest/current:\$PATH\""; echo "(put that line in your shell profile to keep it)";;
esac

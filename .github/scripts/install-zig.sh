#!/bin/sh
set -eu

version=0.16.0

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)
    package="zig-aarch64-macos-$version"
    checksum=b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489
    archive=tar.xz
    ;;
  Darwin-x86_64)
    package="zig-x86_64-macos-$version"
    checksum=0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7
    archive=tar.xz
    ;;
  Linux-aarch64)
    package="zig-aarch64-linux-$version"
    checksum=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17
    archive=tar.xz
    ;;
  Linux-x86_64)
    package="zig-x86_64-linux-$version"
    checksum=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
    archive=tar.xz
    ;;
  MINGW*-aarch64 | MINGW*-arm64 | MSYS*-aarch64 | MSYS*-arm64)
    package="zig-aarch64-windows-$version"
    checksum=aee38316ee4111717900f45dd3130145c39289e105541d737eb8c5ed653c78ef
    archive=zip
    ;;
  MINGW*-x86_64 | MSYS*-x86_64)
    package="zig-x86_64-windows-$version"
    checksum=68659eb5f1e4eb1437a722f1dd889c5a322c9954607f5edcf337bc3684a75a7e
    archive=zip
    ;;
  *)
    printf 'unsupported runner: %s\n' "$(uname -s)-$(uname -m)" >&2
    exit 1
    ;;
esac

download="$RUNNER_TEMP/zig.$archive"
install_dir="$RUNNER_TEMP/zig"
curl -fsSLo "$download" "https://ziglang.org/download/$version/$package.$archive"

if command -v sha256sum >/dev/null 2>&1; then
  printf '%s  %s\n' "$checksum" "$download" | sha256sum -c -
else
  actual=$(shasum -a 256 "$download" | cut -d ' ' -f 1)
  [ "$actual" = "$checksum" ] || {
    printf 'checksum mismatch: expected %s, got %s\n' "$checksum" "$actual" >&2
    exit 1
  }
fi

mkdir -p "$install_dir"
if [ "$archive" = zip ]; then
  mkdir -p "$RUNNER_TEMP/zig-unpacked"
  unzip -q "$download" -d "$RUNNER_TEMP/zig-unpacked"
  cp -R "$RUNNER_TEMP/zig-unpacked/$package/." "$install_dir/"
else
  tar -xJf "$download" --strip-components=1 -C "$install_dir"
fi

printf '%s\n' "$install_dir" >> "$GITHUB_PATH"

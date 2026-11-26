#!/bin/sh
# Builds optimized per-architecture binaries, verifies them, and writes a release archive.
#
# usage: Scripts/package.sh            (ARCHS="arm64" by default)
#        ARCHS="arm64 x86_64" Scripts/package.sh
#
# Optional signing (credentials come from the environment only, never from the repo):
#   DEVELOPER_ID   codesign identity, e.g. "Developer ID Application: Name (TEAMID)"
#   NOTARY_PROFILE notarytool keychain profile; submits the archive when DEVELOPER_ID is also set
#
# With several ARCHS a universal binary is made with lipo *before* signing.
# Only architectures you ran on matching hardware may be called validated.
set -eu
cd "$(dirname "$0")/.."

ARCHS="${ARCHS:-arm64}"
OUT="dist"
rm -rf "$OUT"
mkdir -p "$OUT/stage/man" "$OUT/stage/completions"

bins=""
for arch in $ARCHS; do
    echo "== building $arch"
    swift build -c release --arch "$arch" --scratch-path ".build/pkg-$arch" -Xswiftc -warnings-as-errors -Xcc -Werror
    bin=".build/pkg-$arch/release/rtop"
    bins="$bins $bin"
done

if [ "$(echo $bins | wc -w)" -gt 1 ]; then
    # shellcheck disable=SC2086
    lipo -create $bins -output "$OUT/stage/rtop"
    label="universal"
else
    cp $bins "$OUT/stage/rtop"
    label="$ARCHS"
fi
chmod 755 "$OUT/stage/rtop"

echo "== verifying"
lipo -info "$OUT/stage/rtop"
vtool -show-build "$OUT/stage/rtop" | grep -E "platform|minos|sdk" || true
echo "linked libraries:"
otool -L "$OUT/stage/rtop" | tail -n +2

version="$("$OUT/stage/rtop" --version | awk '{print $2}')"   # runs on the build machine's architecture
"$OUT/stage/rtop" --generate-man > "$OUT/stage/man/rtop.1"
"$OUT/stage/rtop" --generate-completions zsh  > "$OUT/stage/completions/_rtop"
"$OUT/stage/rtop" --generate-completions bash > "$OUT/stage/completions/rtop.bash"
"$OUT/stage/rtop" --generate-completions fish > "$OUT/stage/completions/rtop.fish"
[ -f LICENSE ] && cp LICENSE "$OUT/stage/LICENSE" || echo "warning: no LICENSE file; add one before releasing"
cp README.md "$OUT/stage/README.md"

if [ -n "${DEVELOPER_ID:-}" ]; then
    echo "== signing"
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$OUT/stage/rtop"
    codesign --verify --strict --verbose=2 "$OUT/stage/rtop"
else
    echo "== not signing (DEVELOPER_ID not set): artifact is UNSIGNED"
fi

name="rtop-$version-$label"
mv "$OUT/stage" "$OUT/$name"
tar -C "$OUT" -czf "$OUT/$name.tar.gz" "$name"

if [ -n "${DEVELOPER_ID:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "== notarizing"
    ditto -c -k --keepParent "$OUT/$name/rtop" "$OUT/$name-notarize.zip"
    xcrun notarytool submit "$OUT/$name-notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    # A bare command-line binary cannot be stapled; Gatekeeper checks the notarization ticket online.
fi

( cd "$OUT" && shasum -a 256 "$name.tar.gz" > SHA256SUMS && cat SHA256SUMS )
echo "== done: $OUT/$name.tar.gz"

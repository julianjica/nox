#!/bin/sh
# Build nox.app into ~/nox/build and install the `nox` command in ~/.local/bin.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/nox.app"

swift build -c release --package-path "$ROOT"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/.build/release/nox" "$APP/Contents/MacOS/nox"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# App icon: drawn by scripts/make-icon.swift (rebuilt only when that script changes).
ICNS="$ROOT/Resources/nox.icns"
if [ ! -f "$ICNS" ] || [ "$ROOT/scripts/make-icon.swift" -nt "$ICNS" ]; then
    SET="$ROOT/.build/nox.iconset"; rm -rf "$SET"; mkdir -p "$SET"
    swift "$ROOT/scripts/make-icon.swift" "$ROOT/.build/icon-1024.png" 2>/dev/null
    for s in 16 32 128 256 512; do
        sips -z $s $s "$ROOT/.build/icon-1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s*2)) $((s*2)) "$ROOT/.build/icon-1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$SET" -o "$ICNS"
fi
mkdir -p "$APP/Contents/Resources"
cp "$ICNS" "$APP/Contents/Resources/nox.icns"
codesign --force --sign - "$APP"

mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/nox" <<EOF
#!/bin/sh
exec "$APP/Contents/MacOS/nox" "\$@"
EOF
chmod +x "$HOME/.local/bin/nox"

echo "Built $APP"

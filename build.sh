#!/bin/bash
# Regenerates the Xcode project, builds Release, and stages the app in dist/.
#
#   ./build.sh            build only; the app lands in dist/Rex Boing.app
#   ./build.sh --install  also copy it to /Applications and (re)launch it
#
# Requires Xcode and XcodeGen (brew install xcodegen).
set -euo pipefail

cd "$(dirname "$0")"

INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen is required: brew install xcodegen" >&2
    exit 1
fi

echo "==> Generating project"
xcodegen generate

echo "==> Building Release"
xcodebuild \
    -project RexBoing.xcodeproj \
    -scheme RexBoing \
    -configuration Release \
    -derivedDataPath .build \
    build \
    | grep -E "error:|warning:|BUILD"

APP=".build/Build/Products/Release/Rex Boing.app"
if [ ! -d "$APP" ]; then
    echo "Build did not produce $APP" >&2
    exit 1
fi

echo "==> Staging dist/Rex Boing.app"
rm -rf dist
mkdir -p dist
cp -R "$APP" dist/

if [ "$INSTALL" -eq 1 ]; then
    TARGET="/Applications/Rex Boing.app"
    echo "==> Installing to $TARGET"
    # Copy beside the old bundle first, so a failed copy (a full disk, an
    # interrupted run) leaves the installed app — and the login item that
    # points at it — alone.
    rm -rf "$TARGET.new"
    ditto "dist/Rex Boing.app" "$TARGET.new"

    # `open` on a path that is already running only re-activates the old
    # process, so a running copy has to be quit first or the new build never
    # starts. Quit exactly the pids running now, and wait for each to go.
    for PID in $(pgrep -x "Rex Boing" || true); do
        echo "==> Quitting the running copy (pid $PID)"
        kill "$PID" 2>/dev/null || true
        for _ in $(seq 1 20); do kill -0 "$PID" 2>/dev/null || break; sleep 0.25; done
        if kill -0 "$PID" 2>/dev/null; then
            echo "pid $PID did not quit; leaving $TARGET as it was" >&2
            rm -rf "$TARGET.new"
            exit 1
        fi
    done

    # Replace the bundle wholesale so stale files from an older build never
    # survive inside it. Preferences live in ~/Library, not in the bundle, so
    # nothing of the user's is lost here.
    rm -rf "$TARGET"
    mv "$TARGET.new" "$TARGET"
    open "$TARGET"
    echo
    echo "Done. Rex Boing is running from $TARGET."
else
    echo
    echo "Done. Run it with:"
    echo '    open "dist/Rex Boing.app"'
    echo "or install it to /Applications with:"
    echo '    ./build.sh --install'
fi

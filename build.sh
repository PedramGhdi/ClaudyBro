#!/bin/bash
set -euo pipefail

VERSION="1.15.2"
APP_NAME="ClaudyBro"
APP_DIR="build/$APP_NAME.app"
DMG_DIR="build/dmg"

# ─── Commands ──────────────────────────────────────────────

case "${1:-build}" in

build)
    echo "=== Building $APP_NAME v$VERSION ==="

    swift package resolve

    # Patch SwiftTerm: treat @ + ~ as word characters so double-clicking selects
    # whole emails and paths. Failures are fatal — silently skipping would ship a
    # build quietly missing the behaviour, which is how a dependency bump breaks
    # things without anyone noticing.
    PATCH="patches/swiftterm-selection.patch"
    if [ -d ".build/checkouts/SwiftTerm" ] && [ -f "$PATCH" ]; then
        if git -C .build/checkouts/SwiftTerm apply --check --reverse "../../../$PATCH" 2>/dev/null; then
            echo "  SwiftTerm patch: already applied"
        elif git -C .build/checkouts/SwiftTerm apply "../../../$PATCH" 2>/dev/null; then
            echo "  SwiftTerm patch: applied"
        else
            echo "ERROR: $PATCH does not apply to this SwiftTerm checkout." >&2
            echo "       SwiftTerm was likely upgraded. Rebase the patch, or drop" >&2
            echo "       it if the change landed upstream." >&2
            exit 1
        fi
    fi

    swift build -c release \
        -Xswiftc -O \
        -Xswiftc -whole-module-optimization

    BIN_PATH=$(swift build -c release --show-bin-path)

    rm -rf "$APP_DIR"
    mkdir -p "$APP_DIR/Contents/MacOS"
    mkdir -p "$APP_DIR/Contents/Resources"

    cp "$BIN_PATH/$APP_NAME" "$APP_DIR/Contents/MacOS/"
    cp Resources/Info.plist "$APP_DIR/Contents/"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_DIR/Contents/Info.plist"
    cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/"

    # Use developer identity if available (TCC remembers permissions),
    # fall back to ad-hoc signing
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | awk -F'"' '{print $2}')
    if [ -n "$SIGN_IDENTITY" ]; then
        codesign --force --sign "$SIGN_IDENTITY" \
            --entitlements Resources/ClaudyBro.entitlements \
            "$APP_DIR"
    else
        codesign --force --sign - \
            --entitlements Resources/ClaudyBro.entitlements \
            "$APP_DIR"
    fi

    SIZE=$(du -sh "$APP_DIR" | cut -f1)
    echo ""
    echo "=== Build Complete ==="
    echo "  App:     $APP_DIR ($SIZE)"
    echo "  Run:     open $APP_DIR"
    echo "  Install: ./build.sh install"
    echo "  DMG:     ./build.sh dmg"
    echo ""
    ;;

install)
    if [ ! -d "$APP_DIR" ]; then
        echo "App not built yet. Run: ./build.sh"
        exit 1
    fi

    echo "=== Installing $APP_NAME to /Applications ==="

    # Kill running instance
    pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
    sleep 0.5

    # Copy to /Applications
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP_DIR" "/Applications/$APP_NAME.app"

    echo "  Installed: /Applications/$APP_NAME.app"
    echo "  Launch:    open /Applications/$APP_NAME.app"
    echo ""

    # Clear quarantine so it opens without Gatekeeper warning
    xattr -dr com.apple.quarantine "/Applications/$APP_NAME.app" 2>/dev/null || true
    ;;

dmg)
    if [ ! -d "$APP_DIR" ]; then
        echo "App not built yet. Run: ./build.sh"
        exit 1
    fi

    echo "=== Creating DMG ==="

    DMG_FILE="build/$APP_NAME-v$VERSION.dmg"
    rm -rf "$DMG_DIR" "$DMG_FILE"
    mkdir -p "$DMG_DIR"

    # Copy app into DMG staging
    cp -R "$APP_DIR" "$DMG_DIR/"

    # Create symlink to /Applications for drag-install
    ln -s /Applications "$DMG_DIR/Applications"

    # Create DMG
    hdiutil create -volname "$APP_NAME" \
        -srcfolder "$DMG_DIR" \
        -ov -format UDZO \
        "$DMG_FILE"

    rm -rf "$DMG_DIR"

    SIZE=$(du -sh "$DMG_FILE" | cut -f1)
    echo ""
    echo "=== DMG Complete ==="
    echo "  File: $DMG_FILE ($SIZE)"
    echo "  Users can open the DMG and drag $APP_NAME to Applications."
    echo ""
    ;;

clean)
    echo "Cleaning build artifacts..."
    rm -rf build/ .build/
    echo "Done."
    ;;

*)
    echo "Usage: ./build.sh [build|install|dmg|clean]"
    echo ""
    echo "  build   - Build the app (default)"
    echo "  install - Install to /Applications"
    echo "  dmg     - Create distributable DMG"
    echo "  clean   - Remove build artifacts"
    ;;
esac

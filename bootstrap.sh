#!/usr/bin/env bash
#
# bootstrap.sh — run on your Mac to generate the Xcode project.
#
# Prereqs: macOS 14+, Xcode 15+ installed
#
set -euo pipefail

cd "$(dirname "$0")"

echo "==> Checking Homebrew"
if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew not found. Install from https://brew.sh first."
  exit 1
fi

echo "==> Checking XcodeGen"
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "Installing XcodeGen..."
  brew install xcodegen
fi

echo "==> Checking xcode-select"
if ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode command-line tools not installed. Run: xcode-select --install"
  exit 1
fi

echo "==> Creating test target stub if missing"
mkdir -p PlayerCutTests
if [ ! -f PlayerCutTests/PlayerCutTests.swift ]; then
  cat > PlayerCutTests/PlayerCutTests.swift <<'EOF'
import XCTest
@testable import PlayerCut

final class PlayerCutTests: XCTestCase {
    func testSmoke() {
        XCTAssertEqual(1 + 1, 2)
    }
}
EOF
fi

echo "==> Running XcodeGen"
xcodegen generate

echo ""
echo "Done. Open PlayerCut.xcodeproj in Xcode."
echo ""
echo "Next:"
echo "  1. Set your Team in the PlayerCut target Signing & Capabilities"
echo "  2. Build (Cmd-B) — should compile cleanly"
echo "  3. Run on a real device (Cmd-R) — capture needs a camera"

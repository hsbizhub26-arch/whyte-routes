#!/bin/bash
set -euo pipefail

# Wrapper that runs the Swift-based icon generator which self-heals the AppIcon.appiconset
# This avoids external dependencies like ImageMagick or Pillow.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if command -v xcrun >/dev/null 2>&1; then
  echo "🔧 Running Swift icon generator via xcrun..."
  xcrun --sdk macosx swift "$SCRIPT_DIR/generate_appicons.swift"
else
  echo "⚠️ xcrun not found; falling back to system swift."
  swift "$SCRIPT_DIR/generate_appicons.swift"
fi

echo "✅ AppIcon.appiconset is ensured and populated (placeholders if needed)."

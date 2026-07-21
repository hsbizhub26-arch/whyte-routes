# Convenience Makefile for Crashlytics dSYM uploads

.PHONY: upload-dsyms upload-dsyms-archive

# Upload dSYMs using the convenience runner. This will pick the latest archive
# if nothing is provided.
upload-dsyms:
	bash Scripts/run_upload_dsyms_now.sh

# Upload a specific archive path: make upload-dsyms-archive ARCHIVE=path/to/App.xcarchive
upload-dsyms-archive:
	bash Scripts/run_upload_dsyms_now.sh $(ARCHIVE)

.PHONY: wire-crashlytics wire-crashlytics-project

wire-crashlytics:
	bash Scripts/wire_auto.sh

# Usage: make wire-crashlytics-project PROJECT=path/to/App.xcodeproj SCHEME=YourScheme
wire-crashlytics-project:
	ruby Scripts/wire_build_phase.rb $(PROJECT) ALL "Crashlytics dSYM Upload"
	ruby Scripts/wire_scheme_post_action.rb $(PROJECT) $(SCHEME)

# --- Release Prep Helpers -------------------------------------------------

# Bump the numeric build number (CURRENT_PROJECT_VERSION) in project.pbxproj
.PHONY: bump-build
bump-build:
	@echo "Bumping build number..."
	@python3 - "$@" <<'PY'
import re, sys
p = 'project.pbxproj'
s = open(p, 'r', encoding='utf-8').read()
# Find CURRENT_PROJECT_VERSION = N; and bump N
pat = re.compile(r"(CURRENT_PROJECT_VERSION\s*=\s*)(\d+)(\s*;)\b")

m = pat.search(s)
if not m:
    print('No CURRENT_PROJECT_VERSION found', file=sys.stderr)
    sys.exit(1)
old = int(m.group(2))
new = old + 1
s2 = pat.sub(lambda mo: f"{mo.group(1)}{new}{mo.group(3)}", s, count=0)
open(p, 'w', encoding='utf-8').write(s2)
print(f"Build number: {old} -> {new}")
PY
	@git add project.pbxproj || true
	@git commit -m "chore: bump build number" || true

# Run preflight checks before archiving
.PHONY: preflight
preflight:
	@bash Scripts/preflight.sh

# Convenience: preflight then open Xcode Organizer guidance
.PHONY: release-ready
release-ready: preflight
	@echo "Preflight passed. Ready to Archive (Product > Archive)."

.PHONY: icons
icons:
	bash Scripts/generate_appicons.sh

.PHONY: launchimage
launchimage:
	@if [ -z "$(SRC)" ]; then echo "Usage: make launchimage SRC=path/to/source.png"; exit 1; fi
	@echo "Generating LaunchImage assets from $(SRC)..."
	@swift Scripts/generate_launchimage.swift --src "$(SRC)"
	@echo "Done. LaunchImage imageset updated."

# Set the Marketing Version (CFBundleShortVersionString) across the project
# Usage: make bump-version VERSION=1.0.1
.PHONY: bump-version
bump-version:
	@if [ -z "$(VERSION)" ]; then echo "Usage: make bump-version VERSION=1.0.1"; exit 1; fi
	@echo "Setting Marketing Version to $(VERSION)..."
	@python3 - "$@" <<'PY'
import re, sys
p = 'project.pbxproj'
s = open(p, 'r', encoding='utf-8').read()
# MARKETING_VERSION = ...; replace all occurrences safely
pat = re.compile(r"(MARKETING_VERSION\s*=\s*)([^;]+)(\s*;)\b")
s2, n = pat.subn(lambda m: f"{m.group(1)}$(VERSION){m.group(3)}", s)
open(p, 'w', encoding='utf-8').write(s2)
print(f"Updated MARKETING_VERSION in {n} place(s)")
PY
	@git add project.pbxproj || true
	@git commit -m "chore: set marketing version to $(VERSION)" || true

.PHONY: fix-icons
fix-icons:
	@echo "Fixing asset catalog build settings (AppIcon + stickers)..."
	@python3 Scripts/fix_asset_catalog_settings.py
	@echo "Done. You may need to clean build folder and rebuild."

.PHONY: import-icons
import-icons:
	@if [ -z "$(SRC)" ]; then echo "Usage: make import-icons SRC=/path/to/AppIcon.appiconset"; exit 1; fi
	@if [ ! -d "$(SRC)" ]; then echo "ERROR: SRC is not a directory: $(SRC)"; exit 1; fi
	@if [ "$(notdir $(SRC))" != "AppIcon.appiconset" ]; then echo "ERROR: SRC must be an AppIcon.appiconset directory"; exit 1; fi
	@dest="WHYTE ROUTES/Resources/Assets.xcassets/AppIcon.appiconset"; \
	mkdir -p "$$dest"; \
	echo "Importing icons from $(SRC) -> $$dest"; \
	cp -f "$(SRC)"/* "$$dest"/; \
	echo "Done. AppIcon set updated."
.PHONY: appicons-from-src
appicons-from-src:
	@if [ -z "$(SRC)" ]; then echo "Usage: make appicons-from-src SRC=path/to/master.png"; exit 1; fi
	@echo "Generating AppIcon assets from $(SRC) with black background..."
	@swift Scripts/generate_appicons_from_source.swift --src "$(SRC)"
	@echo "Done. AppIcon imageset updated."

.PHONY: appicons-desktop
appicons-desktop:
	@echo "Generating AppIcon from Desktop screenshot..."
	@swift Scripts/generate_appicons_from_source.swift --src "file:///Users/hopeheaven/Desktop/Screenshot%202026-02-06%20at%207.08.37%E2%80%AFPM.png"
	@echo "Done. AppIcon imageset updated."
.PHONY: fix-appicon
fix-appicon:
	@echo "Ensuring asset catalog exists..."
	@mkdir -p "WHYTE ROUTES/Resources/Assets.xcassets/AppIcon.appiconset"
	@echo "Generating icons from Desktop screenshot..."
	@swift Scripts/generate_appicons_from_source.swift --src "file:///Users/hopeheaven/Desktop/Screenshot%202026-02-06%20at%207.08.37%E2%80%AFPM.png"
	@echo "Done. Verify target General > App Icon is set to AppIcon, then clean build (Shift+Cmd+K)."


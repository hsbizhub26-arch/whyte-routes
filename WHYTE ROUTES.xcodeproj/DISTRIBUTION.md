// WHYTE ROUTES – Distribution Guide

// This document summarizes the exact steps to produce a clean Release build, archive, and upload to TestFlight, plus a pre‑flight checklist.

// Pre‑flight Checklist
// - [ ] Build succeeds for "Any iOS Device (arm64)" in Release.
// - [ ] No build warnings (Run Script phase is incremental; no warning about missing outputs).
// - [ ] App icons present and valid in Assets.xcassets > AppIcon.
// - [ ] Info.plist privacy strings present (Location, Camera, Photos).
// - [ ] Bundle Identifier: com.hope.WHYTE-ROUTES (Targets > General).
// - [ ] Version (Marketing): 1.0.0 and Build: incremented (Targets > General).
// - [ ] Firebase configured (GoogleService-Info.plist in app target).
// - [ ] Logging reduced in Release (no sensitive data).

// Build Settings (Release)
// - Optimization: Whole Module (-O). Already configured.
// - Dead Code Stripping: Yes (default).
// - Strip Linked Product: Yes (default).
// - Swift Version: 5.x (already configured).

// Run Script Phase
// - Script writes stamp: `$(DERIVED_FILE_DIR)/appicon_gen.stamp`.
// - Output File List: `$(SRCROOT)/Scripts/outputs.xcfilelist`.
// - (Optional) Input File List: `$(SRCROOT)/Scripts/inputs.xcfilelist`.

// Archiving & Uploading
// 1. Product > Scheme > Edit Scheme…
//    - Build Configuration for Archive: Release.
// 2. Product > Archive.
// 3. In the Organizer, select the archive > Distribute App.
//    - Method: App Store Connect > Upload.
//    - Check “Manage Version and Build Number” if using automatic.
//    - Answer export compliance (Yes, using standard encryption for HTTPS).
// 4. Wait for processing in App Store Connect, then add internal testers in TestFlight.

// App Store Connect Metadata
// - Description, Subtitle, Keywords, Support URL, Marketing URL.
// - Screenshots (6.7" iPhone and 5.5" iPhone at minimum; iPad sizes if supported).
// - Privacy Nutrition Labels (data collection categories).
// - Age rating questionnaire.

// Troubleshooting
// - Missing permission prompt: ensure Info.plist keys are present (see above).
// - Run Script runs every build: check Output File List and stamp path.
// - Archive not visible: ensure the selected destination is a real device or “Any iOS Device (arm64)”.

// ---
// If you want this automated further (e.g., fastlane or CI), let me know and I’ll add scripts to bump build numbers and trigger uploads securely.

## CLI helpers

You can use the included Makefile to streamline release prep:

- Bump the build number (CURRENT_PROJECT_VERSION in the project):


## Versioning and TestFlight with fastlane

Optional, but convenient if you have fastlane installed (https://docs.fastlane.tools/getting-started/ios/setup/):

1) Set Marketing Version via Makefile:

# TactileText

TactileText is an interaction-focused reading prototype built with SwiftUI.

## Demo GIF
![TactileText demo](web/media/videosample.gif)

## Demo Mode (No API Required)
This project runs in **offline demo mode by default**.

- No AI API key is needed to launch and explore the UI.
- It ships with a bundled paragraph and manually prepared sentence data.
- Every word in the demo paragraph includes a translation.
- Sentence translations and semantic breakdown data are prepared manually.
- Mouse interactions are enabled for hover/click focus and gutter scroll-depth control.

## Optional AI Enhancement
If you want the real AI-backed version, set `GEMINI_API_KEY` in your Xcode scheme environment variables.

If no key is present, the app stays in offline demo mode and makes no network AI requests.

## Run
1. Open `/Users/tianchenhao/projects/TactileText/TactileText.xcodeproj` in Xcode.
2. Select the `TactileText` scheme.
3. Run on simulator or device.

## Portfolio Notes
Recommended for sharing with recruiters/employers:
- Works out of the box (no credentials).
- Shows interaction design and frontend implementation quality.
- Cleanly separates optional AI integration from the core product demo.

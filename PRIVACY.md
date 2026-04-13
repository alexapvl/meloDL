# Privacy

`meloDL` is designed to keep user activity local whenever possible.

## What data the app handles

- Media URLs that you paste into the app.
- Download settings you choose (format, quality, output folder, etc).
- Local files created by your downloads.

## What data is stored locally

- App preferences in `UserDefaults`.
- Downloaded media files in your chosen output folder.
- Tooling/binary version metadata in Application Support (`meloDL/versions.json`).

## Network usage

`meloDL` connects to external services for these features:

- Downloading media content from user-provided URLs via `yt-dlp`.
- Checking/downloading updated `yt-dlp` and `ffmpeg` binaries from GitHub.
- Checking for app updates via Sparkle feed (`appcast.xml`).

## Data sharing

The app does not include analytics or advertising SDKs and does not intentionally
sell or broker your personal data.

## Third-party terms

Media downloads and usage are subject to the terms, policies, and laws applicable
to each content provider and your jurisdiction. You are responsible for complying
with those rules.

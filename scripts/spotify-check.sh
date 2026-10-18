#!/bin/sh
# Compiles the Spotify/YouTube Music sources with scripts/spotify-check.swift and runs the live check.
set -e
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
swiftc -parse-as-library -o "$OUT/spotify-check" \
  scripts/spotify-check.swift \
  meloDL/Models/SpotifyTrack.swift \
  meloDL/Models/DuplicateMatch.swift \
  meloDL/Models/AudioSettings.swift \
  meloDL/Models/DownloadConfiguration.swift \
  meloDL/Models/AudioTrim.swift \
  meloDL/Services/SpotifyService.swift \
  meloDL/Services/YouTubeMusicMatcher.swift \
  meloDL/Services/DuplicateDetectionService.swift \
  meloDL/Services/TrackIndexStore.swift \
  meloDL/Services/DownloadEngine.swift \
  meloDL/Services/BinaryManager.swift \
  meloDL/Utilities/ErrorLog.swift
"$OUT/spotify-check"

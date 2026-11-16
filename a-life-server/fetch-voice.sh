#!/bin/sh
# Fetches the voice model the characters speak with, Phonon 31m (English,
# Apache 2.0), from the Phonon release the app is built against, and puts it
# where the server offers it to the app: ALIFE_VOICE_DIR, or ~/a-life-voice.
# See Voices in README.md.
set -eu

release="v0.7.1"
archive="phonon-31m-en-coreml.zip"
checksum="058cde756a5e67bcdb986e7c45fe431d41a1a9073e68aabae314c80631a34b76"
voice="${ALIFE_VOICE_DIR:-$HOME/a-life-voice}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "Downloading $archive ($release, about 140 MB)…"
curl -fL --progress-bar -o "$work/$archive" "https://github.com/gradium-ai/xn-ptts/releases/download/$release/$archive"
echo "$checksum  $work/$archive" | shasum -a 256 -c - >/dev/null || {
    echo "The download doesn't match its checksum, so it was thrown away." >&2
    exit 1
}

unzip -q "$work/$archive" -d "$work/unzipped"
model=$(dirname "$(find "$work/unzipped" -name bundle.json | head -n 1)")
rm -rf "$voice"
mkdir -p "$(dirname "$voice")"
mv "$model" "$voice"
echo "The voice model is in $voice. Restart the server for it to offer it to the app."

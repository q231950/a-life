#!/bin/sh
# Fetches the voice model the characters speak with, Phonon 31m (English,
# Apache 2.0), from the Phonon release the app is built against, and puts it
# where the server offers it to the app: ALIFE_VOICE_DIR, or ~/a-life-voice.
# Works on a Mac and on a Linux server, where it needs curl and unzip. See
# Voices in README.md.
set -eu

release="v0.7.1"
archive="phonon-31m-en-coreml.zip"
checksum="058cde756a5e67bcdb986e7c45fe431d41a1a9073e68aabae314c80631a34b76"
voice="${ALIFE_VOICE_DIR:-$HOME/a-life-voice}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "Downloading $archive ($release, about 140 MB)…"
curl -fL --progress-bar -o "$work/$archive" "https://github.com/gradium-ai/xn-ptts/releases/download/$release/$archive"
# sha256sum on Linux, shasum on a Mac.
if command -v sha256sum >/dev/null 2>&1; then
    check="sha256sum -c -"
else
    check="shasum -a 256 -c -"
fi
echo "$checksum  $work/$archive" | $check >/dev/null || {
    echo "The download doesn't match its checksum, so it was thrown away." >&2
    exit 1
}

unzip -q "$work/$archive" -d "$work/unzipped"
model=$(dirname "$(find "$work/unzipped" -name bundle.json | head -n 1)")
# The directory's contents are replaced rather than the directory itself,
# which may be a Docker volume that can't be taken away.
mkdir -p "$voice"
find "$voice" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
cp -R "$model"/. "$voice"/
echo "The voice model is in $voice. Restart the server for it to offer it to the app."

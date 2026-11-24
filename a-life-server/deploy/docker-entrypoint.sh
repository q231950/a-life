#!/bin/sh
# Starts a-life-server in its container, after getting what it needs ready:
# git access with your GitHub token, the Engineer's a*life checkout, and the
# agents file. See "Run it on a server" in a-life-server/README.md.
set -eu

# A fine-grained GitHub token, if you gave one: git uses it for every GitHub
# address, ssh (git@github.com:...) and https alike, for cloning, fetching and
# pushing. It's only kept in this process's environment, never in a file.
if [ -n "${GITHUB_TOKEN:-}" ]; then
    with_token="url.https://x-access-token:${GITHUB_TOKEN}@github.com/.insteadOf"
    export GIT_CONFIG_COUNT=3
    export GIT_CONFIG_KEY_0="$with_token" GIT_CONFIG_VALUE_0="git@github.com:"
    export GIT_CONFIG_KEY_1="$with_token" GIT_CONFIG_VALUE_1="ssh://git@github.com/"
    export GIT_CONFIG_KEY_2="$with_token" GIT_CONFIG_VALUE_2="https://github.com/"
fi

# The Engineer's a*life checkout, cloned the first time, and used as it is
# after that.
if [ -n "${ALIFE_REPO_DIR:-}" ] && [ ! -e "$ALIFE_REPO_DIR/.git" ]; then
    if [ -n "${ALIFE_REPO_URL:-}" ] && GIT_TERMINAL_PROMPT=0 git clone --quiet "$ALIFE_REPO_URL" "$ALIFE_REPO_DIR"; then
        echo "Cloned $ALIFE_REPO_URL into $ALIFE_REPO_DIR for the Engineer to work in."
    else
        echo "There's no a*life checkout in $ALIFE_REPO_DIR, so the Engineer can't start. Set ALIFE_REPO_URL to one it can clone." >&2
        unset ALIFE_REPO_DIR
    fi
fi

# The cast, copied from the one the server ships with the first time.
if [ -n "${ALIFE_AGENTS_FILE:-}" ] && [ ! -e "$ALIFE_AGENTS_FILE" ]; then
    mkdir -p "$(dirname "$ALIFE_AGENTS_FILE")"
    cp /app/agents.yaml "$ALIFE_AGENTS_FILE"
    echo "Copied the shipped agents file to $ALIFE_AGENTS_FILE. Edit it there to change who is on the lot."
fi

exec /app/ALifeServer "$@"

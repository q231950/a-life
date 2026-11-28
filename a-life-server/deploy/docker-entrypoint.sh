#!/bin/sh
# Starts a-life-server in its container, after getting what it needs ready:
# git and gh access with your GitHub token, the Engineer's a*life checkout,
# and the agents file. See "Run it on a server" in a-life-server/README.md.
set -eu

# A fine-grained GitHub token, if you gave one: git uses it for every GitHub
# address, ssh (git@github.com:...) and https alike, for cloning, fetching and
# pushing. The ssh addresses are turned into plain https ones, with no token
# in them, so the token never shows in `git remote -v` or in git's errors.
# git asks a credential helper for the token instead, only for
# https://github.com, and the helper reads it from GITHUB_TOKEN each time it's
# asked, so it's only ever in the environment, never in a file. The helper is
# a few lines of shell rather than `gh auth git-credential`, so git keeps
# working whatever becomes of gh. gh itself needs nothing from here: it signs
# in with GITHUB_TOKEN from the environment by itself.
if [ -n "${GITHUB_TOKEN:-}" ]; then
    export GIT_CONFIG_COUNT=3
    export GIT_CONFIG_KEY_0="url.https://github.com/.insteadOf" GIT_CONFIG_VALUE_0="git@github.com:"
    export GIT_CONFIG_KEY_1="url.https://github.com/.insteadOf" GIT_CONFIG_VALUE_1="ssh://git@github.com/"
    # Single quotes: $1 and $GITHUB_TOKEN are the helper's, read when git
    # calls it, not this script's.
    export GIT_CONFIG_KEY_2="credential.https://github.com.helper"
    export GIT_CONFIG_VALUE_2='!f() { test "$1" = get || exit 0; echo username=x-access-token; echo "password=$GITHUB_TOKEN"; }; f'
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

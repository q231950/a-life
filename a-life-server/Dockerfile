# a-life-server in a container, for running it on a Linux server of your own,
# such as a DigitalOcean droplet. Build it from the root of the a*life
# checkout, since the server needs ALifeKit next to it; docker-compose.yml
# does that for you. See "Run it on a server" in a-life-server/README.md.

# SWIFT_VERSION is the Swift the server is built with and the Swift the
# characters have in the image it runs in; docker-compose.yml takes it from
# .env.
ARG SWIFT_VERSION=6.2
ARG NODE_VERSION=22

# Node, for Claude Code, which the image the server runs in copies from here.
FROM node:${NODE_VERSION}-bookworm-slim AS node

# The build: the server, with the Swift runtime linked in, so that it doesn't
# depend on the Swift the characters use next to it.
FROM swift:${SWIFT_VERSION}-bookworm AS build
WORKDIR /src

# The dependencies first, so they're only fetched again when they change.
COPY ALifeKit ALifeKit
COPY a-life-server/Package.swift a-life-server/Package.resolved a-life-server/
RUN swift package --package-path a-life-server resolve

COPY a-life-server a-life-server
RUN swift build --package-path a-life-server -c release --product ALifeServer --static-swift-stdlib

# The server and its resources (the shipped agents file), side by side, as
# the server looks for them.
WORKDIR /staging
RUN bin="$(swift build --package-path /src/a-life-server -c release --show-bin-path)" \
    && cp "$bin/ALifeServer" . \
    && find -L "$bin" -maxdepth 1 -name '*.resources' -exec cp -R {} . \; \
    && cp /src/a-life-server/Sources/ALifeServer/agents.yaml . \
    && cp /src/a-life-server/fetch-voice.sh /src/a-life-server/deploy/docker-entrypoint.sh .

# What the server runs in: Swift, so that the characters can build and test
# the Swift packages they work on, Node for Claude Code, git for the
# characters' repositories, the GitHub CLI (gh) for their pull requests and
# issues, from GitHub's own apt repository, and curl and unzip for fetching
# the voice model. gh signs in with GITHUB_TOKEN from the environment by
# itself, so it needs no gh auth login. Debian 12, like the build, so the
# server finds the C library it was built against.
FROM swift:${SWIFT_VERSION}-bookworm

COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates tzdata git openssh-client curl unzip \
    && install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Claude Code. It's updated by building the image again, not by itself.
ARG CLAUDE_CODE_VERSION=latest
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" && npm cache clean --force

# The server runs as alife, not root, with uid and gid 1000. Should the Swift
# image ever come with a user of its own on uid 1000, that one becomes alife.
# Its home has a directory for each volume, so that each volume starts out
# belonging to it.
RUN existing="$(getent passwd 1000 | cut -d: -f1)" \
    && if [ -n "$existing" ]; then \
        groupmod -n alife "$(id -gn "$existing")" \
        && usermod -l alife -d /home/alife -m "$existing"; \
    else \
        groupadd --gid 1000 alife \
        && useradd --uid 1000 --gid alife --home-dir /home/alife --create-home --shell /bin/bash alife; \
    fi \
    && mkdir -p /home/alife/a-life-lot /home/alife/a-life-state /home/alife/a-life-voice \
        /home/alife/a-life-projects /home/alife/a-life /home/alife/a-life-cast /home/alife/.claude \
    && chown -R alife:alife /home/alife

COPY --from=build /staging /app
RUN mv /app/fetch-voice.sh /usr/local/bin/fetch-voice.sh

USER alife
WORKDIR /home/alife
# Claude Code keeps its settings, its sessions and its .claude.json in
# CLAUDE_CONFIG_DIR, on a volume of its own. The Engineer works in the a*life
# checkout in ALIFE_REPO_DIR, which the entrypoint clones from ALIFE_REPO_URL
# the first time. The cast is in ALIFE_AGENTS_FILE, which the entrypoint
# copies from the shipped agents file the first time, so that the Team Lead's
# additions and your own edits outlast a new image. The lot, the state, the
# voice model and the projects are where the server keeps them anyway, in
# its home.
ENV HOME=/home/alife \
    CLAUDE_CONFIG_DIR=/home/alife/.claude \
    DISABLE_AUTOUPDATER=1 \
    ALIFE_REPO_DIR=/home/alife/a-life \
    ALIFE_REPO_URL=https://github.com/q231950/a-life.git \
    ALIFE_AGENTS_FILE=/home/alife/a-life-cast/agents.yaml

EXPOSE 8080
ENTRYPOINT ["/app/docker-entrypoint.sh"]
# 0.0.0.0 inside the container only: docker-compose.yml publishes the port on
# the server's 127.0.0.1 and nowhere else.
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]

# Plan: pluggable model providers (Claude CLI or any OpenAI-compatible API)

Goal: let the person choose, from Settings in the running app, whether the characters are played by the `claude` CLI or by any OpenAI-compatible provider (OpenRouter, a local server, …), without restarting the server.

## Where things are today

- Every character is a Claude Code process: `ClaudeCharacter` (a-life-server/Sources/ALifeServer/ClaudeCharacter.swift) drives the `claude` CLI over stream-json, launched by `ClaudeCode` (ClaudeCode.swift).
- The backend is chosen once at startup in `Players.fromEnvironment` (Cast.swift) from `ALIFE_BACKEND` (`claude` or `dummy`), and `configure` (configure.swift) builds one `HostedSession` per character with a fixed `backend: any SessionBackend`.
- Claude Code does the whole agent loop itself: file tools, bash, the helper subagent (a sheep on the lot, `--agents`), and permission requests (`can_use_tool`) that become approvals.
- A plain OpenAI-compatible `/chat/completions` API provides none of that, so the server has to provide the agent loop itself for that route.

## Step 1: Claude Code against another endpoint (quick win)

- Add a provider mode that keeps the `claude` CLI but sets `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` and the model in the environment `ClaudeCode.launch` builds.
- Works with providers that offer an Anthropic-compatible endpoint (e.g. OpenRouter's).
- Tools, helpers, approvals and resume keep working unchanged.

## Step 2: a general OpenAI-compatible backend

New `OpenAICompatibleCharacter: SessionBackend`:

- Its own agent loop over `POST {baseURL}/chat/completions` with `stream: true` and tool calling; keeps the conversation history in memory.
- A small tool set, each confined to the character's workspace (`Character.workspace`: lot, a*life checkout, or project): `read_file`, `write_file`, `edit_file`, `list_files`, `bash`.
- Approvals: tool calls that change things are emitted as the same approval events the app already shows, following the character's `permission_mode` (default / acceptEdits / bypassPermissions…), and honour per-session auto approve.
- Helper: a `delegate` tool runs a nested loop with the helper's prompt and tools from `agents.yaml`, emitted as helper-out / helper-back events so the sheep still appear.
- `interrupt` cancels the running task; `reset` drops the history and starts a new conversation; `shutdown` cancels everything.
- Replies, tool uses and status changes are emitted to `SessionHub` exactly as `ClaudeCharacter` does, so the app needs no changes to show them.

## Step 3: switching provider at runtime

- Server-side provider setting: `claudeCLI` | `claudeCodeEndpoint(baseURL, apiKey, model)` | `openAICompatible(baseURL, apiKey, model)`.
- Persisted in a small config file next to the server's other state (e.g. `ALIFE_PROVIDER_FILE`, default `~/a-life-provider.json`); environment variables stay as the defaults.
- The API key stays on the server: the API only reports whether one is set, never returns it.
- Routes: `GET /v1/provider` (current setting, key redacted) and `PUT /v1/provider` (change it); optionally `POST /v1/provider/test` to list the provider's models.
- Wrap each session's backend in a switcher (an actor implementing `SessionBackend` that delegates to the current one). Changing the provider shuts the old backends down and starts a fresh conversation on the new one, no restart needed.

## Step 4: app and ALifeKit

- ALifeAPI: request/response models for the provider setting.
- ALifeClient: `ALifeServerClient` calls for get / set / test.
- `SettingsView`: a "Model provider" section with a picker (Claude CLI, Claude Code via endpoint, OpenAI-compatible), base URL, model, a `SecureField` for the key, and a "Test connection" button.

## Tests

- Server: the OpenAI backend against a stubbed HTTP provider (streamed text, tool calls, approvals, interrupt, reset, helper); the provider routes (key redaction, switching).
- ALifeKit: encoding/decoding of the provider models.

## Caveat

Once the provider can be changed over the network, anyone who can reach the server can redirect the model calls. That is in line with what the server already allows (characters can run bash), but worth keeping in mind for servers reachable beyond a tailnet.

## Order

Step 2 is by far the biggest piece. Suggested order: steps 1, 3 and 4 first, then step 2.

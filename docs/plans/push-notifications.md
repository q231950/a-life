# Plan: a notification on your phone when a character finishes

## The problem

A character's job can take minutes or hours, and you aren't watching the
lot all that time. While the app is open you hear about it: a character in
earshot says its reply, and one out of earshot calls you. Once the app is
in the background or closed, nothing tells you. You have to open the app
now and then to see whether anyone is done, and then find what it said.

The person asked, in their words: "Please make a plan for sending off
notifications to the iOS app if it is registered to this a*life instance
on this server. Once an engineer finishes a notification should be sent.
Tapping the notification should lead to the response of the agent."

Having read the first version of this plan, they settled two of its
questions, in their words: "All agents should send a notification once
they have finished their work. The reply text should not go through,
better a summary of what the agent has been working on."

So:

- the iOS app can register itself with the server it is connected to, and
  only devices registered with this server hear from it;
- when any character finishes its job, the server sends a push
  notification to every registered device;
- the notification says what the character has been working on in that
  job, in a line the server puts together; the reply itself is never in
  it;
- tapping it opens the app on that character's conversation, at its reply,
  which the app loads from the server as it loads everything else.

**Every character notifies.** The Engineer is one of several (the Builder,
the Flamingo Engineer, the BTLB Engineer, the Team Lead, the
Conservationist and so on), all Claude Code sessions played the same way
by `ClaudeCharacter`. Each sends a notification when it finishes its work.
There is no `notify: false` in the agents file and no switch per character
in the app: the one switch is the app's, for the whole device.

## What there is now

- **The server has no notion of a device.** Front ends follow
  `GET /v1/sessions/{id}/events` and the server doesn't know who they are.
  There's no login: whoever reaches the server over the tailnet can use it.
- **A job's end is one event.** Every backend says it through
  `SessionHub.emit`: `ClaudeCharacter.handleResult` emits the reply (or an
  error) as a `message`, then `statusChanged(.idle, stopReason: .endTurn)`.
  `ClaudeCharacter.ended` does the same, with an error message, when the
  CLI dies mid-job. A tool call that asks emits
  `statusChanged(.idle, .requiresAction)`; an interrupt `.interrupted`; the
  5-hour limit `.usageLimit` with `resumesAt`. `DummyCharacter` emits the
  same events, so the dummies finish jobs too.
- **Nothing summarises a job yet.** The `Narrator` and `SpokenText` (in
  ALifeClient) say the reply itself, with its Markdown taken out, and
  `EventLog.oneLine` cuts the reply to a line; the voice model the server
  offers (`/v1/voice/`, `VoiceModelTests`) is only text to speech, on the
  device. None of it says what a character did, and all of it works on
  the reply, which mustn't go in a notification. What a job did is in its
  events, though: the message from you that started it, each
  `tool.used` (`ToolUse.toolName`, and `input`, which
  `ClaudeCharacter.summarise` already makes short: a command, or the
  file's path for `Edit`, `Write` and `NotebookEdit`), each helper sent
  off (`Subagent.task`, a few words), each approval, and the events'
  times. `SessionContext` has the model and tokens, which say nothing about
  the work.
- **What the server keeps** is in `ALIFE_STATE_DIR` (`continues.json`,
  `usage.json`, `models.json`), each written atomically by a small type of
  its own (`PendingContinues`, `UsageHub`, `ModelChoices`), and nothing is
  written when the tests give no state directory. Restarting the server
  starts every conversation afresh.
- **Dependencies.** The server has Vapor, Yams and ALifeKit. Vapor already
  brings in `async-http-client`, `swift-nio-http2` and `swift-crypto`,
  which is everything an APNs client needs.
- **The app** is a SwiftUI `App` with no app delegate, one multiplatform
  target (`dev.neoneon.alife`), automatic signing, no entitlements file and
  no notification code. `WorldView` keeps `selectedID` and the panel's
  `agentPanelIsExpanded`; picking a character from the log sets both, and
  clears that character's missed call. The conversation is a
  `ScrollViewReader` anchored at the bottom, with no ids on its rows.
- **The away log** (`EventLog`, on this branch) badges only what happened
  while you were away, and `AgentSession.finishedWhileAway` turns a job
  finished while you were gone into a missed call.

## The plan

### 1. The wire format (ALifeAPI)

New types, shared by the server and the app:

- `PushEnvironment`: `sandbox` or `production`, the APNs server a token
  belongs to (a development build gets sandbox tokens, TestFlight and the
  App Store production ones). Unknown values decode as `.unknown` and are
  refused.
- `DeviceRegistrationRequest`: `environment`, `bundle_id`, and an optional
  `name` (the device's name, for the server's log only).
- `DeviceRegistration`, the answer: `server_id`, the server's own id (see
  below), and `push_enabled`, whether this server is set up to send.
- `PushRoute`: what a notification points at, under the payload's `alife`
  key: `server_id`, `session` (the character's id), `conversation`,
  `message` (the reply's message id, if there is one: only its id, never
  its text), `seq` (the
  `session.status` event that ended the job) and `kind` (`finished` for now;
  `error`, and maybe `waiting` later, see below). Unknown kinds decode as
  `.unknown`, so new ones can be added.

The server's id is a UUID made the first time the server has a state
directory, and kept there (in `devices.json`, below). It lets the app tell
a notification from this server from one sent by a server it used to be
connected to.

### 2. Registering a device (server)

New routes, in `routes.swift`:

| Method | Path | Body | What it does |
|---|---|---|---|
| `PUT` | `/v1/devices/{token}` | `DeviceRegistrationRequest` | Registers the device's APNs token (hex), or updates it, and says when it was last seen. Answers `DeviceRegistration`. `400` for a token that isn't hex, an unknown environment, or a bundle id other than the server's `ALIFE_APNS_TOPIC`. |
| `DELETE` | `/v1/devices/{token}` | | Forgets the device. `204`, also if it wasn't registered. |
| `POST` | `/v1/devices/{token}/test` | | Sends that device a test notification ("a*life can reach you"), for the settings' Send a test button and for trying it with curl. `503` if pushes are off. |

`PUT` with the token in the path makes registering idempotent: the app can
do it on every launch, as Apple recommends, without making duplicates.

Registration is taken even while pushes are off (`push_enabled: false`), so
setting the key up later and restarting the server is enough: the devices
are there already.

`DeviceRegistry` (`DeviceRegistry.swift`, an actor) keeps them:

- `devices.json` in `ALIFE_STATE_DIR`: `{server_id, devices: [{token,
  environment, bundle_id, name, registered_at, last_seen}]}`, written
  atomically like `continues.json`. With no state directory (the tests)
  it's only in memory.
- `register`, `unregister`, `all`, and `drop(token:)` for the ones APNs
  turns away.
- Devices not seen for 90 days are dropped when the file is read, so a
  phone you no longer have doesn't stay forever.

It goes on the `state` volume in Docker and into `~/a-life-state` under
systemd, with no change to either beyond the README's list of what is
kept.

### 3. Sending (server)

**The library.** [APNSwift](https://github.com/swift-server-community/APNSwift)
(`swift-server-community/APNSwift`, products `APNS` and `APNSCore`): it
speaks HTTP/2 to APNs with token auth (ES256 JWTs from the `.p8` key, made
and refreshed for you), runs on Linux, and is built on `async-http-client`
and `swift-crypto`, which Vapor already resolves, so it adds only itself to
`Package.resolved`. Vapor's own `vapor/apns` is a thin wrapper around it
that hangs the client on `Application`; this server builds its pieces in
`configure` and hands them round explicitly, so APNSwift on its own fits
better. Check its current major version and its Swift 6 support when
adding it; if it doesn't build in strict concurrency, `@preconcurrency
import` it, and as a last resort the same thing can be written on
`async-http-client` directly (one POST per device to
`/3/device/{token}`, with a JWT signed by `swift-crypto`'s P256).

`PushSender` is a protocol (`send(_ notification:, to device:) async ->
PushResult`, where the result is `delivered`, `goneForGood` or `failed`),
so the tests can use a fake that records what was sent. `APNSPushSender`
is the real one: an `APNSClient` for each environment, made lazily, both
signed with the same key, and shut down in `EndSessionsOnShutdown`.

**Settings**, as environment variables, all needed for pushes to be on:

| Variable | What it is |
|---|---|
| `ALIFE_APNS_KEY_FILE` | The `.p8` key file from your Apple developer account. |
| `ALIFE_APNS_KEY_ID` | Its key id, ten characters. |
| `ALIFE_APNS_TEAM_ID` | Your team id. |
| `ALIFE_APNS_TOPIC` | The app's bundle id, `dev.neoneon.alife` unless you build it under your own. |

If none is set, pushes are off: the server logs "Push notifications are
off. See Push notifications in the README." once, and everything else
works as now. If some are set but not all, or the key can't be read, it
says which and carries on with pushes off rather than refusing to start,
since a phone that doesn't buzz shouldn't keep the characters from
working.

- **Docker.** The four lines go in `.env.example`, commented out. The key
  is a file, so `docker-compose.yml` gets a commented-out read-only bind
  mount, `./AuthKey.p8:/home/alife/a-life-apns/AuthKey.p8:ro`, and
  `ALIFE_APNS_KEY_FILE` points there. Nothing changes in the `Dockerfile`:
  `ca-certificates` is already in the image, and that's all that's needed
  to reach `api.push.apple.com`.
- **systemd.** The key goes in `/home/alife/a-life-apns.p8`, readable by
  `alife` only (`chmod 600`), and the four lines in
  `/home/alife/a-life.env` as for Docker.
- **On a Mac,** they are set as for any other setting.

The server needs to reach `api.push.apple.com` (or
`api.sandbox.push.apple.com`) on port 443 going out; it doesn't need to be
reachable from the internet, so the tailnet-only setup stays as it is.

**What APNs says back** (handled in `APNSPushSender`, tested through the
fake):

- `410 Unregistered`, `400 BadDeviceToken` or `400 DeviceTokenNotForTopic`:
  the token is gone for good; it is dropped from `devices.json` and the
  log says so.
- `403` (a bad key, team or key id) and `400 TopicDisallowed`: the setup is
  wrong; logged as an error once, not per notification, and devices are
  kept.
- `429` and `5xx`: logged; the notification is not sent again. A finished
  job isn't worth piling up retries for.

### 4. When to send (server)

**Where.** A `PushNotifier` actor, set up in `configure` with the hubs,
the registry and the sender, follows each `SessionHub` the way a front end
does. It needs a small new method on the hub, `follow()`, which returns a
stream of live events only, with no replay, so nothing that happened
before the server started, or before the notifier was there, is sent.
`SessionHub.emit` and the backends don't change, and it works for
`ClaudeCharacter` and `DummyCharacter` alike.

**What counts as finished** is decided by `JobWatch`, a plain struct fed
each envelope of one session, which says when to notify and with what. It
has no actors or I/O in it, so the tests can drive it with events. While a
job runs it also keeps the job's record, which the summary is made from
(see 5).

| The job ended with | Notify? | Why |
|---|---|---|
| `statusChanged(.idle, .endTurn)` after a reply | Yes, `finished` | The character is done. |
| `statusChanged(.idle, .endTurn)` after an `error` message | Yes, `error` | It stopped and needs you (a weekly limit, Claude Code dying, a failed clone). Subtitled "Stopped". |
| `.usageLimit` | No | It carries on by itself after the reset; the turn after that notifies when it ends. |
| `.interrupted` | No | You stopped it. |
| `.requiresAction` (waiting for an approval) | Not at first | See the open questions. |

Only a job that was seen running notifies: `JobWatch` arms on
`statusChanged(.running, …)` and disarms once it has sent, or on an
interrupt, a usage limit, or `conversation.started`. So a status said again
without new work, a reset, or a character that never started sends nothing,
and one job sends one notification. The automatic "please continue" after
a usage limit is a job like any other, and notifies when it ends.

A job whose turn ended with helpers still out in the background is
finished as far as the person is concerned; if a helper's report starts a
new turn, that turn notifies again when it ends. That is right, but could
be chatty with many background helpers; see the open questions.

Sending is done in a task of its own, to every registered device for the
server's topic, so a slow APNs doesn't hold up the hub, and one device
failing doesn't stop the others.

### 5. What the notification says: a summary of the job (server)

The body says what the character has been working on in the job that has
just ended, never what it replied. Nothing in a*life summarises a job yet
(see What there is now), so the server puts it together from the job's own
events, which `JobWatch` already sees. It calls no model, so it costs
nothing, is there the moment the job ends, and can't be slow or fail
halfway.

**The job's record.** From `statusChanged(.running, …)` to the end of the
job, `JobWatch` keeps a `JobRecord`:

- **the task**: the last message from you before the job started (a
  `user` message whose speaker isn't `Message.aLife`; the automatic
  "please continue" keeps the task it carries on with). The notifier seeds
  it from `hub.state.messages` when it starts following a hub, so a job
  under way when the server's notifier started still knows its task;
- **files changed**: the distinct paths of the `tool.used` events for
  `Edit`, `MultiEdit`, `Write` and `NotebookEdit` (their `input` is the
  path, from `ClaudeCharacter.summarise`), and of the approvals for them,
  shown by file name. A helper's own tool uses aren't sent as events, so
  files a helper changed only count if it asked first; the helper itself
  is counted below;
- **commands run**: how many `Bash` tool uses there were (not what they
  were: commands can carry anything, tokens included);
- **helpers sent**: how many `subagent.started` there were;
- **how long**: from the `running` event's time to the end's.

The reply, the tool uses' other inputs and error texts are not kept.

**The line.** `JobSummary` (in the server, plain code) makes the body from
the record, in this order, leaving out what is empty:

> Worked on "Add a plan for push notifications" for 12 min: changed
> push-notifications.md and README.md, ran 4 commands, sent 2 helpers.

- The task is its first line, plain (Markdown markers taken out,
  whitespace folded), cut at a word near 60 characters with "…", in
  quotes.
- Files: up to three names, then "and 4 more".
- "for under a minute", "for 12 min", "for 1 h 20 min".
- For a job that stopped on an error: "Stopped after 3 min, working on
  "…"." The error's text isn't in it; you see it when you open the app.
- The whole body is at most 178 characters: the list is shortened first
  ("changed 6 files"), then the task.

**The fallback.** If there's nothing to say (no task known and nothing
done, as for a job that only answered a question with no tools), the body
is "Engineer finished their work." (or "Engineer stopped." for an error).
The same goes for anything unexpected while making the line: the
notification goes out with the fallback rather than not at all.

**What goes through Apple** is then: the character's name, the first line
of what you asked (cut short), file names, counts and a duration. Not the
reply, not the commands, not the errors. The README says so, under Push
notifications. Whether your own words may go at all is an open question.

**A summary by a model** (Haiku, say, in a one-shot `claude --print` with
no tools, given only the job's record) would read better, but costs a
call to a model for every finished job, counted against your 5-hour usage
like any other, adds a few seconds before the notification goes, and can
fail or time out, in which case the line above would go instead. It isn't
in this plan; see the open questions.

### 6. The payload

```json
{
  "aps": {
    "alert": {
      "title": "Engineer",
      "subtitle": "Finished",
      "body": "Worked on \"Add a plan for push notifications\" for 12 min: changed push-notifications.md and README.md, ran 4 commands, sent 2 helpers."
    },
    "sound": "default",
    "thread-id": "engineer",
    "interruption-level": "active"
  },
  "alife": {
    "server_id": "6B0E…",
    "session": "engineer",
    "conversation": "1F3C…",
    "message": "9A21…",
    "seq": 482,
    "kind": "finished"
  }
}
```

- **Title**: the character's name. **Subtitle**: "Finished", or "Stopped"
  for an error.
- **Body**: the job's summary (see 5), or the fallback. Never the reply,
  nor any part of it. `PushNotice` builds the payload from the summary and
  the route.
- **The full reply** isn't in the payload at all, only its message id in
  `alife.message`. Tapping the notification opens the app, which follows
  the character's events from the server as always, and shows the reply
  from there (see 8).
- **`thread-id`** is the character's id, so iOS groups each character's
  notifications together.
- **No `badge`**: the server can't know what you've seen, so the app's icon
  isn't badged from here.
- **Headers**: `apns-push-type: alert`, `apns-priority: 10`,
  `apns-topic` the bundle id, `apns-expiration` a day ahead (a phone off
  for longer doesn't need yesterday's news), no `apns-collapse-id`, so each
  job's notification stays.
- **Size**: APNs takes up to 4 KB. A 178-character body keeps it well
  under; the encoded payload is still checked, and the fallback sent if it
  is ever over.

### 7. Registering in the app (ALifeClient and the app)

**ALifeClient.**

- `ALifeServerClient.registerDevice(token:_:)`, `unregisterDevice(token:)`
  and `sendTestNotification(token:)`.
- `PushRegistration` (observable, on the main actor) owns when to register.
  It is given the `ServerConnection`, the device token (once iOS has given
  one), whether you want notifications, and a store for what it last
  registered (`ALife.pushRegistration` in UserDefaults: the token, and the
  server's URL and id it registered with). It:
  - registers when it has a token, you want notifications and the
    connection has a server;
  - when the server's URL changes, unregisters from the old one (best
    effort: it may be unreachable) and registers with the new;
  - when the token changes, unregisters the old token and registers the
    new;
  - when you turn notifications off, unregisters;
  - registers again on every launch, which keeps `last_seen` fresh;
  - says what happened, for the settings: `registered`, `serverHasNoPush`
    (`push_enabled: false`), `notAllowed` (you said no in iOS), or the
    error.
- Because the token and the platform calls are handed in, it is plain,
  testable code, with the `StubServer` the `ServerConnectionTests` already
  use.
- `PushRoute` is decoded from a notification's `userInfo` by a small
  `PushRoute(userInfo:)` here, so it is tested too.

**The app.**

- `AppDelegate.swift` (iOS only, in `#if os(iOS)`), attached with
  `@UIApplicationDelegateAdaptor` in `ALifeApp`: it gets the device token
  (`didRegisterForRemoteNotificationsWithDeviceToken`, as hex) and the
  failure, and is the `UNUserNotificationCenterDelegate`, set in
  `didFinishLaunching` so a tap that launched the app isn't missed.
- The environment: sandbox for builds signed for development, production
  otherwise. Read from the `aps-environment` in `embedded.mobileprovision`
  when there is one (development and ad hoc builds), and production when
  there isn't (TestFlight and the App Store). `#if DEBUG` alone would get
  a release build run from Xcode wrong.
- **Asking.** The app doesn't ask on launch. **Settings** gets a
  Notifications section: a toggle, "Tell me when a character finishes",
  off until you turn it on. Turning it on asks iOS for permission
  (`.alert`, `.sound`), then calls `registerForRemoteNotifications`. Under
  it, what `PushRegistration` says ("This server isn't set up to send
  notifications. See Push notifications in a-life-server/README.md."),
  and a **Send a test** button. If you said no in iOS, it says so and
  offers a button to iOS's settings for a*life.

### 8. Tapping it (the app)

- **The route.** The delegate's `didReceive` decodes the `PushRoute` and
  hands it to a `NotificationRouter` (observable, in the app, in the
  environment) as `pending`. That is the same whether the app was running,
  in the background, or launched by the tap.
- **Following it.** `WorldView` watches `router.pending` together with the
  sessions. Once a session with that id is listed, it sets `selectedID`,
  sets `agentPanelIsExpanded`, and hands the message id to the
  conversation, as picking an entry in the log does; picking the character
  also clears its missed call, through the `onChange(of: selectedID)` that
  is there already. On a cold launch that waits for `server.connect()` to
  list the sessions; if they haven't come within ten seconds (the server
  is unreachable), the route is dropped and the app is simply open.
- **At the reply.** The conversation's rows get `.id(entry.id)`, and
  `ConversationView` takes an optional message to show: once that message
  is in `session.conversation`, caught up from the server's event stream
  (the notification only carried its id), it scrolls to it, anchored at the top, rather than the bottom, so you read
  the reply from its start. If it isn't there (the conversation was
  started over since), it shows the latest, as now.
- **Another server.** If the route's `server_id` isn't the one the app
  registered with its current server, the app opens as it is and doesn't
  pick anyone, since that character may not exist here or may be someone
  else. Changing servers unregisters from the old one, so this should be
  rare.
- **While you're in the app** (`willPresent`): notifications from the
  server you're connected to and following live aren't shown (`[]`). You
  hear about the job already, by voice or a call, and the away log doesn't
  badge live work either. Ones from another server are shown as a banner.
- **Tidying up.** When you pick a character, its delivered notifications
  (by `thread-id`) are removed from Notification Centre, as its missed
  call is cleared. You've seen what they were about.
- **The away log.** A job you were notified about was finished while you
  were away, so it is in the log as now, with the badge. Tapping the
  notification doesn't mark the log seen: `EventLog` keeps one time for
  what you have seen, not each entry, and the log may hold other news.
  The missed call is cleared, as for any other way of picking the
  character.
- **macOS** isn't part of this: the code is in `#if os(iOS)`, and the Mac
  app works as now. See the open questions.

### 9. What you set up yourself (Apple and Xcode)

These need your Apple developer account and can't be done from here:

1. **The App ID.** In Certificates, Identifiers & Profiles, under
   Identifiers, open `dev.neoneon.alife` and turn on Push Notifications.
   (Xcode does this for you if it manages signing.)
2. **The key.** Under Keys, make a new key with Apple Push Notifications
   service (APNs), for both sandbox and production. Download the `.p8`
   (only once is possible), and note its Key ID and your Team ID. One key
   serves every app and environment of the team.
3. **Xcode.** In the ALife target's Signing & Capabilities, add Push
   Notifications. That makes `ALife/ALife.entitlements` with
   `aps-environment` = `development` and sets `CODE_SIGN_ENTITLEMENTS`.
   Since the target is also the Mac app, limit it to iOS
   (`CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]`), so the Mac build is
   untouched. No background mode is needed: these are alert pushes, not
   silent ones. The CI build, unsigned, isn't affected.
4. **The server.** Copy the key to the server and set the four
   `ALIFE_APNS_*` settings, then restart it.

App Store and TestFlight builds switch the entitlement to `production` by
themselves when exported; the server sends to whichever environment each
device registered with.

### 10. Testing

**Server** (`PushTests.swift`, Linux-friendly like the rest, with a
`RecordingPushSender` fake and no network):

- `JobWatch`: one notice for running → reply → `endTurn`; an `error` notice
  for an error then `endTurn`; none for `interrupted`, `usageLimit`,
  `requiresAction`, a repeated idle status, a status with no run before it,
  or a `conversation.started`; one each for two jobs in a row; the
  automatic continue after a usage limit notifies once, when it ends, with
  the task from before the limit. Its record: the task is your last
  message, not a*life's; files changed are the distinct paths of `Edit`,
  `MultiEdit`, `Write` and `NotebookEdit`; commands and helpers counted;
  the duration from the events' times; seeded from the hub's state.
- `JobSummary`: the line for a full record; the task cut at a word with
  "…" and its Markdown taken out; "and 4 more" past three files; the
  durations; the error form; the 178-character limit, shortening the list
  before the task; the fallback ("Engineer finished their work.") for an
  empty record.
- `PushNotice`: the reply's text is nowhere in the payload, even for a
  reply that names the same files (a test reply with a marker string,
  looked for in the encoded payload); `alife.message` is its id; the
  payload stays under 4 KB for the longest task and paths; `thread-id` and
  the `alife` keys are right.
- `DeviceRegistry`: register, update, unregister, the file round-tripping
  across a restart with the same server id, stale devices dropped, nothing
  written without a state directory.
- The routes, through Vapor's testing: `PUT`, `DELETE` and `test`; `400`s
  for a bad token, environment or bundle id; `push_enabled` false with no
  settings.
- End to end with the dummies (a short `step`): a scripted job sends one
  notification to each registered device, and a `goneForGood` result drops
  that device and keeps the others.
- Reading the settings: none set is off; some set says which are missing;
  all set is on (with a test key made by `swift-crypto` in the test).

**ALifeKit** (`PushRegistrationTests.swift`, with `StubServer`): `PushRoute`
round-trips and decodes from a `userInfo`, unknown kinds are `.unknown`;
`PushRegistration` registers once it has a token and a server, moves to a
new server (unregistering from the old), swaps a changed token, unregisters
when turned off, and reports `serverHasNoPush`.

**By hand**, as none of this can be run here:

1. The tap, without a server: run the app in the iOS Simulator and drop a
   payload on it with `xcrun simctl push booted dev.neoneon.alife
   finished.apns` (the payload above, with a session id that exists).
   Tapping it with the app closed, in the background and open should each
   open that character at its reply; open, it shouldn't show at all.
2. The whole way: a development build on an iPhone, the server on the Mac
   with the four settings and `ALIFE_BACKEND=dummy`, notifications on in
   Settings, Send a test, then tell a dummy something and lock the phone.
   One notification when it finishes, saying what it worked on and not
   what it replied, and none when you stop it.
3. With Claude: the same with a real character, and once more after
   restarting the server, to see the device was remembered.
4. Pruning: delete the app, wait for a job to finish, and see the server
   say it dropped the token (APNs may take a while to report it).

## Done when

- The app registers its token with the server it is connected to when you
  turn notifications on, moves with it when you change servers, and
  unregisters when you turn them off.
- The server keeps registered devices across a restart, sends each one
  notification when any character finishes a job or stops on an error,
  none for an interrupt, a usage limit or a question, and drops tokens
  APNs says are gone.
- The notification says what the character worked on (the task, the
  files it changed, how many commands and helpers, how long), or
  "<Character> finished their work." when there's nothing to say, and
  never the reply's text.
- With no APNs settings the server starts and works as before, and says
  that pushes are off.
- Tapping a notification opens the app on that character's conversation,
  at its reply, from a cold start, from the background and while open.
- The tests above pass, along with all the existing ones, and the app
  builds for iOS and macOS.
- The server's README has Push notifications (setting it up, Docker and
  systemd, what the summary says and so what goes through Apple), the new
  settings, routes and `devices.json`; the app's README table has
  `AppDelegate.swift` and `NotificationRouter`; the Layout table has
  `DeviceRegistry.swift`, `PushNotifier.swift` (with `JobWatch`),
  `JobSummary.swift` and the sender.

## Open questions

1. **Waiting for you.** A character waiting for an approval is stuck until
   you answer, which is arguably the more useful thing to hear about.
   Notify for `requires_action` too (as `kind: waiting`, opening at the
   approval), perhaps with Allow and Deny right on the notification?
2. **Your own words in the summary.** The summary quotes the first line of
   what you asked, cut to about 60 characters, and names the files
   changed. Is that fine to send through Apple, or should it say only what
   was done ("Changed 2 files, ran 4 commands, for 12 min")?
3. **A summary written by a model.** A one-shot Haiku call per finished
   job, given only the job's record, would read better than the line put
   together from it, at the cost of a model call each time (counted
   against your 5-hour usage), a few seconds' delay, and the line above as
   the fallback when it fails. Worth adding, as a setting that is off
   unless you turn it on?
4. **Busy characters.** With many helpers in the background, a character
   can finish several turns in a few minutes. Notify each time, or wait a
   little (say 30 seconds) and send only the last?
5. **Other devices while you're in the app.** Notifications are hidden on
   the device you're using, but your other devices still buzz. Should the
   app tell the server it's open (a short lease, renewed every half
   minute) so the server holds them back altogether?
6. **The app icon's badge.** Should the app badge its icon with the away
   log's count when it goes to the background, so it's there next to the
   notifications?
7. **The Mac.** The same works for the macOS app with little more (an
   `NSApplicationDelegateAdaptor` and the entitlement for macOS). Wanted
   now, or later?

## What was decided

Implemented with the plan's defaults for the open questions:

1. **Waiting for you** doesn't notify: only `finished` and `error` are sent.
2. **Your own words** may go: the summary quotes the first line of what you
   asked, cut short, and names the files changed.
3. **No model-written summary**: the line is put together by `JobSummary`
   from the job's events, and calls no model.
4. **One notification per job**, with no waiting to see if another turn
   follows.
5. **Other devices** aren't held back while you're in the app; only the
   device you're using hides them.
6. **No app icon badge.**
7. **iOS only** for now: everything is in `#if os(iOS)`, the entitlement is
   set for `iphoneos` builds only, and the Mac app works as before.

Two small departures from the text above: the entitlements file is
`ALife.entitlements` at the root of the checkout, next to
`ALife-Info.plist`, rather than in the `ALife/` folder Xcode keeps in sync
with the target, so it is never taken for a resource; and the server uses
APNSwift 7.x, since 8.0 needs macOS 15 and the server still runs on
macOS 14.

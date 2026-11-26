# Plan: real phone calls from the characters

## The problem

When a character finishes a job while the app is open but you're out of
earshot, it rings you in the app: a green phone over its head, and the
call bar with Decline and Take. When the app is in the background or
closed, all you get is a notification (see
[push-notifications.md](push-notifications.md)), which is easy to miss
and silent under most Focus modes, and the call turns into a missed call
you only find the next time you open the app.

The person asked for a plan for real phone calls: the character rings
your iPhone the way a messenger app does, on the lock screen, with the
system's incoming call screen, and when you answer, you hear its report.
That means CallKit for the call, and PushKit VoIP pushes through APNs to
wake the app for it.

So:

- when a character finishes a job, the server rings each iPhone that has
  asked for calls, with a VoIP push;
- the phone shows the system's incoming call screen, from the character,
  by name, even when locked;
- answer, and the character says what it has to say, in its voice, as
  when you take a call in the app;
- decline, or let it ring out, and it behaves like declining or missing
  a call in the app does today;
- where a call isn't wanted or can't be made, the notification goes out
  as now.

Nothing here is built yet. This is the plan only.

## How it relates to the call work so far

- **In-app calls.** "Decline a call, or a missed call, without hearing it"
  and "Put the call bar's buttons underneath the call" were both on the
  `decline-calls` branch and have landed in `main` together, squashed, as
  #46 (`ae028c3`). This plan builds on `main` as it is, and `decline-calls`
  has nothing left that this needs. The `Narrator`'s `take(callFrom:)`,
  `decline(callFrom:)`, `hangUp(on:)`, `clearMissedCall(from:)` and the
  `HeardRepliesStoring` it keeps between launches are what a real call
  maps onto (see 6).
- **Push notifications** (#42, #43): the server's `PushNotifier`,
  `JobWatch`, `JobSummary`, `PushNotice`, `APNSPushSender`,
  `DeviceRegistry` and `devices.json`, and the app's `AppDelegate`,
  `PushRegistration`, `PushPermission` and `NotificationRouter`. A call is
  sent where a notification would be, for the same jobs, and the
  notification is what it falls back to. The `.p8` key and the four
  `ALIFE_APNS_*` settings serve both.
- **Bundle id and team** (#44, #45): the app is `dev.neoneon.alife`, so
  the VoIP topic is `dev.neoneon.alife.voip`, and the team comes from
  `Config/iOS.xcconfig`, so nothing about the team needs to change.

## What there is now

- **The end of a job** is decided by `JobWatch` in `PushNotifier.swift`:
  `finished` after a reply then `end_turn`, `error` after an error; none
  for an interrupt, the usage limit, a question waiting for you, or a
  conversation started over. One job, one `Ending`, with its `JobRecord`,
  conversation, message id and the status event's `seq`.
- **Sending** is `PushNotifier.notify`: it builds a `PushNotice` (title
  the character's name, body the `JobSummary` line, never the reply) and
  hands it to `APNSPushSender`, which sends it with `pushType: .alert` and
  `apns-topic` the bundle id, to each device in `DeviceRegistry`, dropping
  the ones Apple says are gone.
- **Devices** are `RegisteredDevice`s in `devices.json` (token,
  environment, bundle id, name, when registered and last seen), keyed by
  the APNs device token. There's no VoIP token anywhere.
- **The app** asks for notifications in Settings ("Tell me when a
  character finishes"), registers its token through `PushRegistration`,
  and routes a tapped notification through `NotificationRouter` to the
  character's conversation. `ALife.entitlements` has `aps-environment`,
  for `iphoneos` builds only. `ALife-Info.plist` has no background modes.
- **Calls in the app** are the `Narrator`'s (in ALifeClient). A job whose
  lines you missed while the app was open rings when it ends; a job that
  finished while you were away (`AgentSession.finishedWhileAway`) is a
  missed call. Taking one says its lines through `Voices`, Phonon on the
  device, with the audio session set to `.playback`, `.spokenAudio`,
  `.mixWithOthers`.
- **Where it all lives.** `server.connect()` is called in `WorldView`'s
  `.task`, and `WorldView.keepEarshot()` makes the `Narrator`. So both
  only exist once the app's window is up. An app woken in the background
  by a push has no window, which matters (see 5).

## The flow, end to end

1. A character finishes a job. `JobWatch` says so, as now.
2. `PushNotifier` decides, for each registered device, whether to ring it
   or notify it (see 3): it rings a device that has a VoIP token, has
   calls turned on, isn't in its quiet hours, isn't open on the lot right
   now, and isn't already ringing.
3. The server sends that device a VoIP push through APNs:
   `apns-push-type: voip`, `apns-topic: dev.neoneon.alife.voip`,
   `apns-priority: 10`, a short `apns-expiration`, to the device's VoIP
   token, signed with the same `.p8` key. The payload names the call, the
   character and the job, and carries the same summary line the
   notification would, never the reply.
4. iOS wakes or launches the app in the background and calls the
   `PKPushRegistryDelegate`'s
   `pushRegistry(_:didReceiveIncomingPushWith:for:completion:)`. **Before
   it returns, and before anything waits on the network,** the app reports
   a new incoming call to its `CXProvider`
   (`reportNewIncomingCall(with:update:completion:)`). Since iOS 13, an
   app that gets a VoIP push and doesn't report a call is killed, and one
   that keeps doing it stops getting VoIP pushes at all. So every VoIP
   push reports a call, even a malformed or stale one, which is then
   ended at once (see 5).
5. The system's incoming call screen shows "Engineer", "a\*life Audio",
   on the lock screen or as a banner, and rings. Meanwhile the app gets
   ready: it connects to the server, catches up on that character, and
   loads the voices, so answering is quick.
6. **Answer** (`CXAnswerCallAction`): CallKit activates the audio session
   and calls `provider(_:didActivate:)`. Only then does the app start
   speaking: the character's lines from that job, in its voice, as taking
   a call does today. When it's said everything, the app ends the call.
7. **Decline** (`CXEndCallAction` before answering): the job counts as
   dealt with, as Decline in the app does. **No answer** within the
   ringing time: the app ends the call as unanswered, and it is a missed
   call, in the app and in a local notification. **Hang up** while it
   talks: as `hangUp(on:)`.
8. The app tells the server what came of the call, so it stops counting it
   as ringing, and other devices that rang stop too.

## The plan

### 1. The wire format (ALifeAPI)

In `Push.swift`, next to the push types:

- `CallRegistrationRequest`: `voip_token` (hex), `enabled`, and
  `quiet_hours`, an optional `QuietHours` (`start` and `end` as minutes
  past midnight, and `time_zone`, an IANA name, since the server's clock
  isn't the phone's).
- `CallOffer`: what a VoIP push carries under `alife.call`: `id` (a UUID,
  which is also the CallKit call's UUID), `caller` (the character's
  name), `summary` (the `JobSummary` line), and `expires_at`. Alongside
  it, under `alife`, the `PushRoute` the notification carries now
  (`server_id`, `session`, `conversation`, `message`, `seq`, `kind`), so
  the rest of the app reads it the way it reads a notification's route.
- `CallOutcome`: `answered`, `declined`, `missed` and `failed`, with
  unknown values decoding as `.unknown`, so new ones can be added.
- `CallState`, the answer to `GET /v1/calls/{id}`: the call's `outcome`
  so far, `nil` while it rings.

The payload, as it goes to Apple:

```json
{
  "alife": {
    "server_id": "6B0E…",
    "session": "engineer",
    "conversation": "1F3C…",
    "message": "9A21…",
    "seq": 482,
    "kind": "finished",
    "call": {
      "id": "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
      "caller": "Engineer",
      "summary": "Worked on “Add a plan for push notifications” for 12 min: changed push-notifications.md and README.md, ran 4 commands, sent 2 helpers.",
      "expires_at": "2026-11-26T21:00:30Z"
    }
  }
}
```

There's no `aps`: a VoIP push shows nothing by itself. What goes through
Apple is the same as for a notification, the name and the summary, and
never the reply; the README's "What a notification says, and what goes
through Apple" gets a sentence saying so for calls. APNs takes up to 5 KB
for a VoIP push; the summary is at most 178 characters, so it stays well
under, and is still checked as `PushNotice` checks.

### 2. Registering for calls (server and ALifeClient)

**The VoIP token is not the device token.** PushKit gives the app a token
of its own, which changes independently of the one
`registerForRemoteNotifications` gives. It is kept separately, on the
device's record, so a device that can't be rung still gets the
notification, through its other token:

| Method | Path | Body | What it does |
|---|---|---|---|
| `PUT` | `/v1/devices/{token}/calls` | `CallRegistrationRequest` | Adds the device's VoIP token and call settings to its registration. `404` if the device isn't registered for notifications (calls need them, for the fallback and the missed call), `400` for a VoIP token that isn't hex or bad quiet hours. |
| `DELETE` | `/v1/devices/{token}/calls` | | Takes the VoIP token off. The device still gets notifications. |
| `POST` | `/v1/devices/{token}/calls/test` | | Rings the device with a test call from "a\*life", which says "a\*life can reach you" if you answer. `503` if pushes are off. |
| `GET` | `/v1/calls/{id}` | | The call's `CallState`, for another device to see that it was answered elsewhere. |
| `POST` | `/v1/calls/{id}/outcome` | `{"outcome": "answered"}` | What came of the call on this device. |

- `RegisteredDevice` (in `DeviceRegistry.swift`) gets `voipToken` and
  `calls`, both optional, so a `devices.json` from before reads as it is.
  `DeviceRegistry` gets `setCalls(token:_:)`, `clearCalls(token:)` and
  `dropVoIPToken(_:)` for a VoIP token Apple says is gone, which keeps the
  device and its notifications.
- `ALifeServerClient` gets `registerCalls(token:_:)`,
  `unregisterCalls(token:)`, `sendTestCall(token:)` and
  `reportCallOutcome(id:_:)`, `callState(id:)`.
- `PushRegistration` takes the VoIP token too (`setVoIPToken(_:)`) and
  whether calls are wanted, and does for calls what it does for the
  device: registers once it has both tokens, a server and you want them,
  moves with you to a new server, swaps a changed token, and takes it
  back when you turn calls off. Its `Status` gains what the calls part
  came to, for the settings. It's plain code, tested with `StubServer`.

### 3. Ringing, or notifying (server)

**Sending.** `APNSPushSender` gets `ring(_ offer:, to device:)`, sending
an `APNSRequest` with `pushType: .voip`, `topic: credentials.topic +
".voip"`, `priority: .immediately` and an expiration 30 seconds ahead (a
call that can't ring now shouldn't ring later; the `expires_at` in the
payload says the same to the app). Apple's answers are read as for
notifications, with one difference: a VoIP token that is gone for good is
dropped on its own, and the job's notification goes to the device instead.
The `PushSender` protocol gets the same method, so the tests' recording
sender sees calls too. No new key or setting: a `.p8` key with APNs on
signs VoIP pushes as well, and the topic follows from `ALIFE_APNS_TOPIC`.
If Apple turns the VoIP topic down (`TopicDisallowed`, if the App ID
hasn't got Push Notifications), the server says so once and notifies
instead.

**Deciding.** `PushNotifier.notify` asks a new `CallLedger` (plain code,
no I/O, so the tests drive it with a clock) for each device whether to
ring it. It rings when all of these hold, and notifies as now otherwise:

- the device has a VoIP token and calls on;
- the job's `kind` is `finished` or `error` (the same jobs that notify);
- it isn't in the device's quiet hours, in the device's time zone;
- the device isn't present (see below);
- the device isn't ringing already, and its last call started at least
  two minutes ago, and it hasn't been rung more than ten times in the
  last hour. Several characters finishing at once ring once, for the
  first; the rest go as notifications, and show as missed calls in the
  app as they do now;
- this job hasn't rung this device before (by session and `seq`), so a
  repeat never rings twice.

The ledger keeps each call it made (id, device, session, `seq`, when,
outcome) in memory, for an hour. A call it hears nothing about is taken as
missed after 60 seconds. Restarting the server forgets them, which only
loosens the rate limit for a moment.

**Present.** While the app is open on the lot and following the server,
the `Narrator` already rings in the app, so a real call on top would ring
twice. The app renews a short lease, `PUT /v1/devices/{token}/presence`,
every 30 seconds while it is in the foreground and live; the server takes
the device as present for 45 seconds after. A present device is neither
rung nor (as now, by the app hiding it) shown the notification. This also
answers the push plan's open question 5 for the device in your hand.

**Answered elsewhere.** With an iPhone and an iPad both rung, answering on
one should stop the other. A VoIP push can't be used to stop a call
(every VoIP push must report a new one), so the other device, which is
already connecting to the server while it rings, asks `GET
/v1/calls/{id}` every two seconds, and ends its call as answered or
declined elsewhere once the server has an outcome from any device.

### 4. The app: capabilities and setup

What changes in the project, all for iOS only:

- **Push Notifications** is there already (`ALife.entitlements`,
  `aps-environment`), and covers VoIP pushes. Nothing changes.
- **Background modes** `voip` and `audio`, as
  `INFOPLIST_KEY_UIBackgroundModes[sdk=iphoneos*]` (and the simulator's)
  in the project, rather than in `ALife-Info.plist`, which the Mac app
  shares. `voip` lets PushKit wake the app; `audio` keeps the voice going
  with the screen locked.
- **No microphone** for a one-way call. A two-way call (milestone 5)
  would need `NSMicrophoneUsageDescription`, and speech recognition its
  own usage description.
- **A ringtone**, `Ring.caf`, under 30 seconds, in `ALife/` (the folder is
  synced with the target, so it's a resource without touching the
  project), and **an icon** for the call screen, a monochrome template
  image in `Assets.xcassets`.
- **In the developer account**, nothing new: the App ID already has Push
  Notifications, and the same key serves. The VoIP topic needs no
  identifier of its own.
- **China.** Apps with CallKit can't be offered in the China storefront.
  That only matters for the App Store (see 9).

### 5. The app: the call itself

**`PhoneCalls`** (`ALife/PhoneCalls.swift`, iOS only, `@MainActor`) is the
`PKPushRegistryDelegate` and the `CXProviderDelegate`, and owns the
`PKPushRegistry` (`desiredPushTypes = [.voIP]`), the `CXProvider` and a
`CXCallController`. The `AppDelegate` makes it in
`didFinishLaunchingWithOptions`, every launch, since PushKit only delivers
a push that woke the app to a registry made at launch.

- **The provider.** A `CXProviderConfiguration` with
  `supportedHandleTypes = [.generic]`, `supportsVideo = false`,
  `maximumCallGroups = 1`, `maximumCallsPerCallGroup = 1`,
  `iconTemplateImageData` and `ringtoneSound = "Ring.caf"`, and
  `includesCallsInRecents` as the settings say (see 7). The call screen
  names the app from its display name, "a\*life".
- **The token.** `pushRegistry(_:didUpdate:for:)` hands the VoIP token,
  as hex, to `PushRegistration.setVoIPToken(_:)`, as the device token is
  handed over now; `didInvalidatePushTokenFor` takes it back.
- **An incoming push.** `CallOffer(payload:)` (in ALifeClient, tested)
  reads it. Then, at once, a `CXCallUpdate` with
  `remoteHandle = CXHandle(type: .generic, value: route.session)`,
  `localizedCallerName = offer.caller`, `hasVideo = false`, and holding,
  grouping, ungrouping and DTMF off, is reported with the offer's id as
  the call's UUID, and the completion handler is called after. If the
  payload can't be read, or the offer has expired, or a call with that id
  is already going, a call is still reported (from "a\*life" for one that
  can't be read) and then ended straight away with `.unanswered` (or
  `.failed`), so the rule in the flow's step 4 always holds.
- **Getting ready while it rings.** After reporting, `PhoneCalls` makes
  sure there's a connection to the server and a voice: `server.connect()`
  if it isn't connected, and `voices.load(from:)`. It starts asking the
  server for the call's state, for answered elsewhere.
- **The connection and the narrator move up.** Today `WorldView` connects
  and makes the `Narrator`, and an app woken by PushKit has no window, so
  neither would exist. `ALifeApp` makes the `Narrator` (it has the
  `ServerConnection`, `Voices` and `server.log` already), puts it in the
  environment, and hands it to the `AppDelegate` as it hands over the
  registration now; it calls `server.connect()` once, at launch.
  `WorldView.keepEarshot()` only feeds the narrator who is in earshot, and
  `speakers` stay as they are. Calling `connect()` from both is harmless,
  as it is now, but only the app's is needed.
- **What it says** when you answer is what the character said in the job
  that rang: its replies after your last message, up to and including
  `route.message`, read with `SpokenText` as the `Narrator` reads them. A
  small `CallScript.lines(in:endingAt:)` in ALifeClient picks them from
  `AgentSession.conversation`, so it doesn't matter whether the app was
  open in the background (the job's lines are in `newMessages`) or
  launched by the push (they're in `finishedWhileAway`). The `Narrator`
  gets `take(remoteCall:lines:lastMessageID:voice:)`, which says them as a
  taken call and marks them heard, so the same job doesn't then turn into
  a missed call in the app. If the server can't be reached within ten
  seconds of answering (the phone's Tailscale isn't up, say), the call
  says the summary from the payload, which it has anyway, and then "I
  couldn't reach the server for the rest: it's in the app."
- **Audio.** Before the call is reported, the audio session is set to
  `.playAndRecord` with mode `.voiceChat` (CallKit's own; without
  `.mixWithOthers`); speech only starts in `provider(_:didActivate:)`, and
  stops in `didDeactivate`. `Voices.freshPlayer()` sets its own category
  for every line today; it gets an `isInCall` switch, set by
  `PhoneCalls`, under which it leaves the session alone. Phonon is made
  to run on the CPU while the app is in the background, if the Neural
  Engine turns it down there. If the voices aren't ready by the time you
  answer (the model takes a moment to load on a cold launch),
  `AVSpeechSynthesizer` says the first line, so you never pick up to
  silence. The ending: once the last line is said, the app ends the call
  through the `CXCallController`.
- **Answering on the lock screen** leaves the app in the background,
  where it may stay for as long as the call lasts; unlocking and opening
  it shows the lot as usual, with the character's conversation picked.

### 6. Decline, missed and hang up, onto what there is

| On the phone | `PhoneCalls` sees | What happens, mapped onto the app's calls |
|---|---|---|
| Answer | `CXAnswerCallAction` | `Narrator.take(remoteCall:…)`: said in its voice, and heard. Outcome `answered`. |
| Decline | `CXEndCallAction`, not answered | As `decline(callFrom:)`: the job counts as dealt with. The reply id from the route is written to the `HeardRepliesStoring` straight away (a new `Narrator.markHandled(messageID:from:)`), so it isn't a missed call in the app later, even if the narrator hasn't seen the job yet. `PushPermission.removeDelivered(about:)` as the call bar's Decline does, and the log gets "Declined a call". Outcome `declined`. |
| Lets it ring out | No action within 45 seconds | The app ends it with `reportCall(with:endedAt:reason: .unanswered)`. Nothing is marked heard, so the job is the app's missed call, as a job finished while you were away is now. A local notification "Missed call from Engineer", with the summary as its body and the `PushRoute` in its `userInfo`, goes into Notification Centre, so tapping it opens the conversation through `NotificationRouter`, as today. Outcome `missed`. |
| Hangs up while it talks | `CXEndCallAction`, answered | As `hangUp(on:)`: the rest is let go, and the call is in the log. |
| Answered or declined on another device | the server's `CallState` | Ended with `.answeredElsewhere` or `.declinedElsewhere`, and marked heard. |
| Stale push or one that can't be read | | Reported and ended at once as `.unanswered` or `.failed`; a missed call if it had a route. |

The server doesn't also send the notification to a device it rang, so
there aren't two of everything; the missed call's local notification
stands in for it.

### 7. Settings (the app)

Under Notifications in `SettingsView`, below "Tell me when a character
finishes" and only while it's on:

- **Ring me when a character finishes**, off until you turn it on. It
  needs notifications, for the fallback and the missed call, so it can
  only be turned on with them, and goes off with them.
- **Quiet hours**, off, or from and to, sent with the registration with
  the phone's time zone. During them, the server notifies rather than
  rings.
- **Show calls in Recents**, off by default (see the open questions).
  With it on, a call shows in the Phone app's Recents, and calling it back
  from there opens a\*life with an `INStartCallIntent`, which the app
  takes as Call back on that character's missed call.
- **Test call**, which rings the phone through the server.
- A line on Focus: calls ring through your Focus only if a\*life's calls
  are allowed in it, which is up to iOS, not the app.

Focus and the silent switch are left to iOS: CallKit calls follow them as
any calling app's do, and the app doesn't try to break through. Quiet
hours are the server's, since the app can't refuse a VoIP push once it
has come.

### 8. What it says: the options

| Option | Good | Not so good |
|---|---|---|
| **A. The device says it, with Phonon** (`Voices`, as calls in the app now) | Nothing new on the server; the same voice as in the app; the reply never leaves your tailnet; works whether the server is on the Mac or the droplet. | The model has to load on a cold launch (a few seconds, covered by the ringing and by `AVSpeechSynthesizer` if not); the reply has to be fetched over Tailscale while you answer. |
| **B. The server renders a clip** at the end of the job, which the app plays (`GET /v1/calls/{id}/audio`) | Plays at once; the phone needn't load a model. | Phonon is Core ML on Apple silicon, so only a server on the Mac could; the droplet would need another TTS or a cloud one (which would send the reply out); costs the server time on every job; still fetched over Tailscale. |
| **C. Only the summary**, from the payload | Always there, even with no connection. | Says what was done, not what the character said. |
| **D. A live, two-way call**: you speak back, and the character hears you | A real conversation; makes the case for VoIP pushes stronger (see 9). | Speech recognition, the microphone, sending what you say as a message and saying the answer as it streams: a project of its own. |

**The plan:** A, getting ready while it rings, with C as the fallback when
the server can't be reached, and `AVSpeechSynthesizer` covering a voice
that isn't loaded yet. B isn't planned. D is the last milestone, and
optional.

### 9. App Review, and other ways

Apple says VoIP pushes are for incoming calls only, and since iOS 13 the
system enforces that a call is reported for each one. These calls are
real CallKit calls with audio: someone (the character) calls, you answer
and hear them, or don't. That is the honest case for it. Against it: the
caller isn't a person and it is one way, so it is close to a voicemail
that rings you, and a reviewer may read it as a notification dressed as
a call, which guideline-wise is a rejection risk.

- **For the person's own use,** none of this matters: development, ad hoc
  and internal TestFlight builds aren't reviewed. a\*life is built and run
  by the person for their own server, so this is the case to plan for.
- **For the App Store or external TestFlight,** the risk is real. Making
  the call two-way (D) makes it a conversation, which is the strongest
  argument. Otherwise, keep calls behind the opt-in and explain them in
  the review notes.
- **Other ways, if review says no:**
  - **Time-sensitive notifications** (`interruption-level:
    time-sensitive`, with the Time Sensitive Notifications capability):
    one line in `PushNotice` and an entitlement; breaks through Focus if
    you allow it, but doesn't ring like a call.
  - **Communication notifications** (an `INSendMessageIntent` donated in a
    notification service extension): the notification shows the character
    as the sender, with its picture, and Focus can allow it by person.
  - **Critical alerts** need an entitlement Apple grants for health and
    safety, which this isn't.
  - **LiveCommunicationKit** (iOS 17.4 and later) is Apple's newer way to
    report conversations to the system, alongside CallKit. It still wakes
    the app with a VoIP push and has the same rules, so it doesn't lower
    the review risk; worth a look only if CallKit's UI isn't wanted.
  - **AlarmKit** (iOS 26) rings through silent mode and Focus with a full
    screen alert, but its alarms are scheduled on the device, and nothing
    reliable wakes the app to schedule one when a job ends.

### 10. Testing

**Server** (`CallTests.swift`, next to `PushTests.swift`, with the
recording sender and no network):

- `CallNotice`: the reply's text is nowhere in the payload (the marker
  test `PushNotice` has), `alife.call` has the id, caller, summary and
  expiry, the route is there, and it's under 5 KB for the longest summary.
- The recording sender sees `.voip`, the `.voip` topic, priority 10 and a
  30-second expiration for a call, and `.alert` as before for a
  notification.
- `CallLedger`: rings a device with calls on; notifies one without a VoIP
  token, with calls off, in quiet hours (across midnight, and in another
  time zone than the server's), present, or ringing already; the
  two-minute gap and ten-an-hour limit; one call per job and device; an
  unheard-of call taken as missed after 60 seconds.
- `PushNotifier`: a VoIP token Apple says is gone is dropped, the device
  kept, and that job's notification sent instead; a failed call notifies.
- `DeviceRegistry`: a `devices.json` from before reads, VoIP tokens and
  call settings round-trip, clearing calls keeps the device.
- The routes: `PUT` and `DELETE` calls, `404` for an unregistered device,
  `400`s, the test call, presence, `GET` and `POST` on a call.
- End to end with the dummies: a scripted job rings a device with calls
  on and notifies one without.

**ALifeKit:**

- `CallOffer(payload:)`: reads a full payload, tolerates unknown keys,
  refuses one without an id, and says when it has expired.
- `PushRegistration`: registers calls once it has both tokens, moves them
  with the server, swaps a changed VoIP token, takes calls back on their
  own or with notifications.
- `CallScript.lines(in:endingAt:)`: picks the replies after your last
  message up to the given one, skips tool uses and errors, and gives
  nothing for an id it doesn't have.
- `NarratorTests`: `take(remoteCall:…)` says the lines and marks them
  heard, so the narrator then leaves no missed call for that job;
  `markHandled` does the same for a job it hasn't seen yet.
- A `CallBook` (the state of each call: ringing, answered, ended, and
  why), plain code in ALifeClient, so the table in 6 is tested without
  CallKit: answered then ended is heard; ended unanswered by you is
  declined; timed out is missed; expired is missed; an outcome from
  elsewhere ends it.

**By hand**, on an iPhone, since PushKit doesn't deliver VoIP pushes to
the Simulator and CallKit's call screen and audio session aren't to be
trusted there:

1. A debug-only "Ring me" in Settings that hands a made-up `CallOffer` to
   `PhoneCalls`, with no server: rings, answer, decline, ring out.
2. A VoIP push straight to APNs's sandbox with curl, with a JWT made from
   the `.p8` key (the server's test call does the same thing, and is
   easier):

   ```sh
   curl -v --http2 \
     -H "authorization: bearer $JWT" \
     -H "apns-topic: dev.neoneon.alife.voip" \
     -H "apns-push-type: voip" \
     -H "apns-priority: 10" \
     -H "apns-expiration: 0" \
     -d @call.json \
     https://api.sandbox.push.apple.com/3/device/$VOIP_TOKEN
   ```

   with the app in the foreground, the background, force quit, and the
   phone locked.
3. The whole way: the server on the Mac with `ALIFE_BACKEND=dummy` and the
   four settings, calls on, then a dummy job with the phone locked. Answer
   and hear it; decline and see no missed call in the app; let it ring out
   and see a missed call, in the app and in Notification Centre; open the
   app on the lot and see a finishing job ring in the app, not the phone.
4. With Tailscale off on the phone: the call says the summary.
5. Two devices: answer on one, and the other stops.

The CI build is unsigned and builds for the Simulator and the Mac, so it
checks that the iOS-only code is behind `#if os(iOS)`, and nothing more.

## Milestones

1. **A spike, on the device.** PushKit and CallKit in the app behind a
   debug switch, the VoIP token printed, a call rung with curl, a tone
   played on answer. Proves the capabilities, the background modes and
   the audio session before anything else is built.
2. **The server.** The wire types, the VoIP token on the device's record,
   the call routes, `CallNotice`, the sender's `ring`, `CallLedger` and
   the fallback, the README's API section and Push notifications, all
   with tests. Off for every device until one asks, so it can land on its
   own.
3. **The app's calls.** `PhoneCalls`, the narrator and the connection
   moved up to `ALifeApp`, `CallScript`, answer, decline, missed and hang
   up as in 6, the missed call's notification, Ring me and Test call in
   Settings, the README's table for `PhoneCalls.swift`. Usable from here.
4. **The rest.** Quiet hours, presence, answered elsewhere, Recents and
   calling back, the ringtone and icon.
5. **Optional: a two-way call.** Speech recognition on the device, what
   you say sent as a message, and the reply said as it comes, within the
   same call.

## Done when

- With Ring me on, a character finishing a job rings the iPhone with the
  system's call screen, by name, locked or not, in the foreground (only
  when not on the lot), in the background and after being force quit.
- Answering says what the character said in that job, in its voice, and
  it then isn't a missed call in the app; with no server, it says the
  summary.
- Declining counts the job as dealt with; ringing out leaves a missed
  call, in the app and in Notification Centre; hanging up lets the rest
  go.
- A device without a VoIP token, with calls off, in quiet hours or
  already ringing gets the notification as now; no device is rung twice
  for one job, nor more often than the limits.
- The server with no APNs settings, and the Mac app, work as before.
- The tests above pass with all the existing ones, and the app builds for
  iOS and macOS.
- The READMEs say it all: the calls in the app's section on notifications
  and its file table, and in the server's README, the routes, what goes
  through Apple, the settings and `devices.json`.

## Open questions

1. **Errors.** Should a job that stopped on an error ring, or only
   notify? The plan rings for both, as they notify alike.
2. **Waiting for you.** A character waiting for your answer to a tool call
   is the thing most worth ringing about, and a two-way call could even
   take "allow" or "deny". Ring for `requires_action` too, later?
3. **Recents.** Show calls in the Phone app's Recents, with call back from
   there? Off by default in the plan, since they would sit with your real
   calls.
4. **How long it talks.** A long reply read out could take minutes.
   Should a call say the summary first and then ask before reading the
   lot, or cut it after a while and leave the rest in the app?
5. **Several at once.** The plan rings for the first character and
   notifies for the rest. Should the call say that others finished too
   ("…and the Builder is done as well")?
6. **Tailscale on the phone.** Answering needs the phone to reach the
   server. Is the Tailscale app set to stay connected (On Demand), or
   should the plan assume it often isn't, and lean more on the summary?
7. **The App Store.** Is a\*life ever going to the App Store or external
   TestFlight? If not, the review risk in 9 can be set aside; if so, it
   argues for doing the two-way call before shipping calls at all.
8. **The iPad and the Mac.** The iPad is covered with the iPhone. Whether
   CallKit and VoIP pushes would work for the Mac app too needs checking
   against Apple's current documentation; leave the Mac out, as the
   notifications do?

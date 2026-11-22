# Plan: a log instead of calls on launch

## The problem

Right after the app launches, characters ring you and speak about work their
subagents (helpers, the sheep) finished while the app was closed. As a user you
don't expect to hear about that out loud. You'd rather see what happened while
you were gone, at a glance, when you want to.

## Likely cause

`WorldView.keepEarshot()` calls `narrator.letGo(of: speakers)` once, when the
view's task starts. At that moment `server.connect()` may not have listed the
sessions yet, so there is nothing to let go of. When the sessions and their
messages arrive moments later, `Narrator.listen(to:inEarshot:)` treats them as
new: lines from characters out of earshot are kept in `missed`, and once a
character isn't on the job any more `ring()` turns them into calls. Work still
running on the server when the app opens (subagents reporting back) adds to
this, since it finishes during the first moments after launch.

## The plan

### 1. A log of what happened (ALifeKit, ALifeClient)

A new `EventLog` (observable, on the main actor) records the notable things
each character does, each with a time and the session it belongs to:

- a reply from the character (agent message, first line or a short summary)
- a helper (subagent) sent off, and a helper back
- a job finished (stopped with `end_turn`), or interrupted
- a tool call waiting for your approval
- an error

Entries are kept per run of the app plus whatever was caught up on at launch;
a sensible cap (for example the last 500) keeps it small. The time the log was
last looked at is remembered (UserDefaults or similar) so entries can be
marked seen or unseen across launches.

### 2. What happened while you were away goes to the log, not to your ears

- Everything replayed or caught up on when the app connects, and whatever
  finishes while it is still catching up, is logged under "While you were
  away" and is never spoken and never becomes a call.
- Fix the timing in `WorldView`: the narrator lets go of each session's
  messages once that session has first been caught up (not only at the moment
  the view appears), so the first listing of sessions is never taken as new.
- Calls and voices carry on as now for work that finishes while you are in
  the app: you hear characters in earshot, and ones out of earshot call you
  when done. Every call is also written to the log, so hanging up loses
  nothing.

### 3. A log button

- A button in the top bar (`SessionStatusBar`) opens the log as a sheet (or
  popover on macOS).
- It shows a badge with the number of unseen entries.
- The log lists entries newest first, grouped by character or as one timeline,
  with the "While you were away" entries highlighted at the top until seen.
- Tapping an entry selects that character (opens its chat in the agent panel).
- Opening the log marks its entries as seen.

## Done when

- Launching the app while characters have finished work (or have helpers that
  report back during launch) plays no voices and rings no calls; that work
  shows up in the log under "While you were away", with a badge on the button.
- The log button shows the full log at any time.
- Calls and voices still work for jobs that finish while the app is open, and
  calls are logged too.
- Tests cover the narrator not ringing for caught-up work, and the log
  recording and marking entries seen. All existing tests pass.
- README updated where it describes voices and calls.

## As built

- **The cause, checked.** `AgentSession.newMessages` already left out what
  was replayed on connecting (events up to `caughtUpAt`), so `letGo` at the
  start of `keepEarshot()` had nothing to do whichever came first. What rang
  was live events from jobs already under way when the app opened: helpers
  reporting back and replies after the listing were new by sequence number,
  every character was out of earshot, and `ring()` called once the job ended.
- **The fix.** An `AgentSession` is `isCatchingUp` from when it is first
  listed until everything listed has been replayed and the character isn't
  running (its job is done, or it is waiting for you), or until you answer it
  or send it something. What it does meanwhile is logged as while you were
  away and never reaches `newMessages`, so the narrator can't say it or ring
  about it, however SwiftUI batches the updates. `Narrator.letGo(of:)` is
  gone. A reconnect while the app is open doesn't start catching up again,
  so a dropped connection doesn't silence a job you are waiting on; what was
  replayed after it is still logged as while you were away.
- **Times.** Events carry a `time` (seconds since 1970, by the server's
  clock) so what was caught up on shows when it happened. It is optional:
  older servers leave it out and the log uses the time it arrived.
- **The log** is `EventLog` in ALifeClient, `ServerConnection.log`, one
  timeline oldest first (shown newest first), capped at 500. Seen means
  older than the time you last looked, kept in UserDefaults
  (`ALife.logLastSeen`) and taken from the newest entry's own time, so clock
  differences between the server and the device don't hide new entries.
  Changing servers clears the entries but not what you have seen.
- **The button** is in the status pill on both platforms and opens a sheet
  (`EventLogView`), with a red badge for unseen entries. Unseen entries from
  while you were away are picked out at the top until the sheet closes;
  opening it (and closing it) marks everything seen. Tapping an entry picks
  that character and unfolds the panel.

## Missed calls

Staying quiet about what happened while you were away left one thing out:
a character that finished a job while you were gone had something to tell
you, and nothing said so. Now it leaves you a missed call.

- **Which characters.** An `AgentSession` keeps `finishedWhileAway`: when
  catching up ends with the character's job done (`end_turn`) or with it
  waiting for you, the replies it gave since it was last told something
  (the last 20 at most). Characters that were stopped, or ended on an
  error, leave none. Sending it something or answering it empties it.
- **The call.** `Narrator.Speaker` carries `finishedWhileAway`, and
  `listen(to:inEarshot:)` turns it into a `Call` with `isMissed` set: one
  per character, with its spoken lines, in its voice, and nothing said.
  `isCalling(_:)` and `incomingCalls` are only the calls ringing now, so no
  phone rings over its head; `missedCalls` and `hasMissedCall(_:)` are the
  missed ones. It still counts in `hasSomethingToSay(_:)`, so the character
  waits at its desk until you have dealt with it. Each missed call is
  logged as `.missedCall`, while you were away.
- **Calling back** is `take(callFrom:)`, as for any call: its lines are
  said next, wherever you stand. `clearMissedCall(from:)` lets it go
  unheard, and leaves a ringing call alone; the app calls it when you pick
  that character (on the lot, in the panel or from the log), and telling
  it something hangs up as before. Something new said live on top of a
  missed call turns it into a ringing call.
- **Only once.** The narrator remembers the last reply you heard from each
  character, by message id, in a `HeardRepliesStoring`
  (`UserDefaultsHeardRepliesStore`, `ALife.lastHeardReply`, in the app; in
  memory by default): a line said to you, a call taken, hung up on or
  cleared. A job whose last reply you heard isn't a missed call on the next
  launch; a call left ringing when the app closed is. On the first launch
  with this, every character whose last job ended done has a missed call.
- **In the app.** The panel's call bar shows a ringing call first, as
  before, and otherwise the first missed call, with a red handset, a
  **Call back** button and how many more were missed. Each character's
  button shows a red handset while it has one.

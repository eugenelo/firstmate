---
title: "Fix OMP quiet mode integration and wake-drain input loss"
status: done
branch: dev-cycle/omp-quiet-wake-input
created: 2026-09-15
---

# Request

Produce a minimal fix for the following two issues:

- quiet mode not integrated properly in OMP
- when typing in the OMP tui, if I get interrupted by bin/fm-wake-drain.sh, my wip input disappears from the tui

Settled with the user on 2026-09-15:

- Quiet mode: minimal fix; omp joins Pi's no-daemon path and quiet mode on omp is posture-only.
- Draft-loss proof: manual tmux transcript in the run directory only; no tracked live-harness guard.

# Goal

Two harness-specific defects in the omp (Oh My Pi) primary integration get their smallest correct fix, for the captain who runs firstmate on omp.

First, `/quiet` (and `/afk`) on omp must stop launching the away daemon.
omp uses the same extension-owned watcher model as Pi (`bin/fm-wake-lib.sh:213`), and the daemon is a second watcher owner that fights the extension for the singleton lock while the extension keeps waking main on every actionable close anyway.
After the fix, omp follows the Pi path exactly: the confirmed away-posture record is the whole entry, no daemon terminal or `state/.afk` flag is created, and the ordinary supervision session keeps running under the record.

Second, a watcher wake delivered by `.omp/extensions/fm-primary-omp-watch.ts` must not erase text the captain has typed into the omp composer.
Today the wake is injected as a user-role message, and omp's TUI clears the editor whenever a user message it did not submit locally starts a turn.
After the fix the wake arrives as a custom message on the same follow-up schedule, which omp's TUI renders without touching the editor, so a half-typed draft survives the wake turn.

Out of scope: making the away daemon coexist with the omp extension, porting the Pi supervision branch to omp, adding a durable quiet-versus-away mode to the posture record, a tracked live TUI guard, and any consistency sweep of docs or scripts beyond the sentences that state the changed facts.

# Done when

- [ ] On an omp primary, `bin/fm-afk-launch.sh start` and `start-native` refuse with the "the away daemon is no longer launched on omp" line, exit non-zero, and leave no `state/.afk`, `state/.afk-daemon-terminal`, or `state/.afk-contract` behind, and `tests/fm-afk-launch.test.sh` covers omp in the same refusal unit as `pi` and `pi-signed`.
- [ ] The `/afk` skill's per-harness entry step, the `AGENTS.md` away-mode stub, the `bin/fm-afk-launch.sh` header, and `docs/supervision-protocols/omp.md` say that omp, like Pi, launches no daemon and keeps the ordinary supervision session under the posture record, and no tracked doc still lists omp among the daemon harnesses.
- [ ] `.omp/extensions/fm-primary-omp-watch.ts` delivers every watcher wake through `pi.sendMessage` as a `firstmate-watcher-wake` custom message with `deliverAs: "followUp"` and `triggerTurn: true`, never through `pi.sendUserMessage`, and `tests/fm-omp-harness.test.sh` asserts that shape and that consuming the wake at its custom-role `message_start` keeps it off the replacement handoff.
- [ ] In a real omp TUI (omp 18.2.0 is installed on this machine), text typed into the composer before an extension-delivered watcher wake is still in the composer after the wake turn has started, with the before and after pane captures kept in the run directory.
- [ ] (optional) `FM_OMP_LIVE_E2E=1 tests/fm-omp-primary-live-e2e.test.sh` passes, proving the custom wake still arrives as one follow-up turn with exactly one `fm_watch_arm_omp` call.

# Show

All steps run from the worktree `/home/elo/repos/firstmate-fork-omp-quiet-wake-input`; artifacts go under `.dev-cycle/runs/omp-quiet-wake-input/`.

1. Daemon refusal on omp, saved as `afk-omp-refusal.txt`:

   ```sh
   st=$(mktemp -d) && mkdir -p "$st/state"
   FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_SUPERVISOR_TARGET=unused FM_SUPERVISOR_BACKEND=tmux \
     bash -c '. bin/fm-afk-launch.sh; fm_afk_launch_primary_harness() { printf omp; }; fm_afk_launch_main start'; echo "rc=$?"
   ls -A "$st/state"
   ```

   A person sees one log line containing `the away daemon is no longer launched on omp`, a non-zero `rc`, and an empty `state/` listing.
   Repeat with `start-native` and see the same refusal.

2. Wake delivery shape over a fake omp API, saved as `omp-wake-shape.txt`: run `bin/fm-test-run.sh tests/fm-omp-harness.test.sh` and keep its output.
   A person sees the `.omp watch extension` case pass with its updated description naming the custom-message follow-up.

3. Draft survival in the real omp TUI, saved as `omp-draft-before.txt` and `omp-draft-after.txt`.
   Build an isolated lab the way `tests/fm-omp-primary-live-e2e.test.sh:98-127` does (clone this worktree into a temp directory, copy pending edits in, create `state/`, `config/`, `data/`), then start omp interactively inside a throwaway tmux session with the same environment that test uses (`tests/fm-omp-primary-live-e2e.test.sh:191-196` minus `--mode rpc --no-session`).
   For example, with `PROJECT` set to the lab checkout: `tmux new-session -d -s omp-draft -x 160 -y 45 -c "$PROJECT" "env -u CLAUDECODE -u PI_CODING_AGENT -u FM_HOME -u FM_STATE_OVERRIDE FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 omp --cwd $PROJECT --config $PROJECT/.omp/fm-worker-overlay.yml --auto-approve --model openai-codex/gpt-6-astra --thinking low"`.
   Wait for `state/.omp-watch-extension-loaded`, create `state/omp-demo.meta`, submit the prompt `Call the fm_watch_arm_omp tool exactly once now, then reply with its result text verbatim and nothing else.` through `tmux send-keys`, and wait for the arm result and an idle composer.
   Type a draft with `tmux send-keys -t omp-draft -l 'captain draft that must survive the wake'` and no Enter, then `tmux capture-pane -p -t omp-draft > omp-draft-before.txt`.
   Fire a real actionable close with `printf 'done: omp draft demo\n' > "$PROJECT/state/omp-demo.status"`, wait until the pane shows the `FIRSTMATE WATCHER WAKE: signal:` row and the wake turn is running, then `tmux capture-pane -p -t omp-draft > omp-draft-after.txt`.
   A person sees the draft text in both captures and the wake row only in the second.
   This uses the captain's existing omp login and spends a few tokens on two short turns; if no provider is reachable, record the provider error next to the captures, because the editor clear fires at the wake's `message_start` before any provider call, so the after capture still decides the item.
   Kill the tmux session and remove the lab afterwards.

4. (optional) `FM_OMP_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-omp-primary-live-e2e.test.sh`, output saved as `omp-live-e2e.txt`.

# Checks

- `bin/fm-lint.sh bin/fm-afk-launch.sh tests/fm-afk-launch.test.sh tests/fm-omp-harness.test.sh`
- `bin/fm-test-run.sh tests/fm-afk-launch.test.sh tests/fm-omp-harness.test.sh tests/fm-supervision-instructions.test.sh`
- `bin/fm-doc-audience-check.sh`

# Design

Load `skill://firstmate-coding-guidelines` before editing: every file below is shared tracked material.

## Issue 1: quiet mode on omp launches a daemon that cannot own the watcher

Root cause.

- `bin/fm-afk-launch.sh:196-204` (`fm_afk_launch_daemon_allowed`) refuses the daemon only for `pi|pi-signed`; `.agents/skills/afk/SKILL.md:48` tells the agent to run `bin/fm-afk-launch.sh start` on `omp`, and `.agents/skills/quiet/SKILL.md:26-33` follows those same steps with `FM_AFK_MODE=quiet`.
- omp's supervision model is `extension` (`bin/fm-wake-lib.sh:213`): `.omp/extensions/fm-primary-omp-watch.ts:895` owns the watcher by spawning `bin/fm-watch-arm.sh --restart`, and `:590-591` delivers every actionable close to main; the file has no `state/.afk` awareness at all.
- The daemon is a second owner of the same singleton: `bin/fm-supervise-daemon.sh:1697-1701` starts its own `fm-watch.sh` child and `:1719-1755` restarts it on every exit, while the extension's `--restart` stops whatever pid holds this home's `.watch.lock` (`bin/fm-watch-arm.sh:54-57,410-413`).
  With `state/.afk` present the watcher goes one-shot for the daemon (`bin/fm-watch.sh:303-307`), the extension classifies each close as actionable, respawns, and wakes main, so quiet mode saves no turns and the two supervisors keep killing each other's watcher.
- The daemon's typed injection into the captain pane is also unverified for an omp primary composer: the composer matrix in `docs/verification/runtime-backends.md:449-475` covers claude, codex, opencode, pi, grok, and muse only.
- Pi hit the identical conflict and resolved it by not launching the daemon (`bin/fm-afk-launch.sh:194-204`, `docs/pi-supervision-branch.md:153`); the omp protocol already declares the Pi branch out of scope and every wake main-bound (`docs/supervision-protocols/omp.md:26`).

Fix: omp joins the Pi no-daemon path.

- `bin/fm-afk-launch.sh:200`: refuse `pi|pi-signed|omp`; update the header sentences at `:15-19` and the comment at `:194-195` so the owner names omp.
- `tests/fm-afk-launch.test.sh:92-117`: extend the refusal loop to `pi pi-signed omp` (rename the unit if its name reads Pi-only).
- `.agents/skills/afk/SKILL.md:42-43` (the "Pi and pi-signed: stop here" bullet becomes Pi, pi-signed, and omp), `:48` (drop `omp` from the daemon list), and the description at `:5` if it still says "no daemon on Pi" alone.
- `AGENTS.md:146` and `:459` (the inline stub sentences naming Pi as the never-daemon harness) and `:247` ("on Pi keep the ordinary supervision session"): add omp in the same clause; no new lines.
- `docs/supervision-protocols/omp.md:3`: match `docs/supervision-protocols/pi.md:3` ("no legacy away daemon flag is active") so the record alone never pauses supervision.
- One-word touches where the fact is restated: `docs/herdr-backend.md:325`, `docs/architecture.md:141`, `.agents/skills/harness-adapters/references/harness/omp.md` "Primary integration".
- `bin/fm-afk-return.sh`, `bin/fm-session-start.sh:878-899`, and `bin/fm-supervision-instructions.sh:138-145,227-235` need no change: they key on `state/.afk`, which omp will never write, and already print the no-daemon wording.

Consequence to state plainly: after this fix quiet mode on omp is posture-only, exactly as on Pi today.
The record holds captain-held items and merge grants (`bin/fm-watch.sh:309-315`), but omp has no supervision branch, so every actionable wake still reaches main as a turn; the mode's turn-saving half does not exist on omp.
The quiet-versus-away distinction lives only in the `state/.afk` flag (`bin/fm-wake-lib.sh:330-350`), so on omp, as on Pi, "ordinary chat does not exit quiet" is a conversational rule with no durable marker.

## Issue 2: a delivered wake erases the captain's composer draft

Root cause, traced in the omp source at `/home/elo/.local/share/agent-env/runtime/bun-1.3.14/install/cache/@oh-my-pi/pi-coding-agent@18.1.14@@@1/src` (18.1.14 source; the installed binary reports 18.2.0 and its `dist/cli.js` carries the same minified branch `if (!e.message.synthetic) { if (!l) { this.ctx.editor.setText(""); } }`).

- The extension delivers a wake with `pi.sendUserMessage(content, { deliverAs: "followUp" })` at `.omp/extensions/fm-primary-omp-watch.ts:502`.
- omp queues that as a plain user-role follow-up: `session/agent-session.ts:7175-7177` calls `#queueUserMessage`, which at `:6735-6743` enqueues `{ role: "user", attribution: "user" }` with no `synthetic` flag, and `#scheduleIdleQueueDrain` starts the turn when idle or after the current run.
- When that user message starts, omp's interactive event controller clears the editor unless the message was locally submitted: `modes/controllers/event-controller.ts:953-961`.
  "Locally submitted" means it went through `startPendingSubmission` (`modes/interactive-mode.ts:1973-2023`), which only the composer and a few internal prompts use, so an extension-injected user message is never local and the draft is erased.
- A custom-role message takes the other branch at `event-controller.ts:882-912`, which renders it and never touches the editor.

Fix: deliver the wake as a custom message on the same schedule.

- In `sendWake` (`.omp/extensions/fm-primary-omp-watch.ts:490-512`) replace the `sendUserMessage` call with `pi.sendMessage({ customType: "firstmate-watcher-wake", content, display: true }, { deliverAs: "followUp", triggerTurn: true })`, and add `sendMessage` to the local `ExtensionAPI` type at `:59-64` (the guard extension already declares it at `.omp/extensions/fm-primary-turnend-guard.ts:46`).
  Idle: `agent-session.ts:7116-7122` starts the turn through `#promptAgentInitiatedMessage`.
  Streaming: `:7057-7063` queues it on the follow-up queue exactly as today.
  Keep the `encodeFirstmateOperationalInput("watcher", ...)` content unchanged so the operational-prefix rules in `AGENTS.md` section 8 still recognise it.
- Leave `attribution` at its default (`agent`, `session/messages.ts:689-695`): a user-attributed queued message is what omp hands back into the editor on Esc or Alt+Up dequeue (`agent-session.ts:7197-7204`), which would paste the wake text into the captain's draft.
- Consumption tracking (`:514-529`, `:1022-1029`): the prompt message still raises `message_start` (`pi-agent-core@18.1.14/src/agent-loop.ts:994-998`), so match `message.role === "custom"` with `customType === "firstmate-watcher-wake"` and the text from `userMessageText(message.content)` (content may arrive as a string or text parts).
  Drop the `before_agent_start` consumer: omp raises that event only inside `#promptWithMessage` (`agent-session.ts:6191`, emission at `:6316-6320`), the path `prompt()` takes, while `#promptAgentInitiatedMessage` (`:6923-6943`) calls `agent.prompt(message)` directly, so a custom wake can never match there again.
- Rewrite the header contract at `.omp/extensions/fm-primary-omp-watch.ts:9-11` and `:33-42` to state the custom-message delivery, why (the TUI editor clear), and the single `message_start` consumption signal.
- `tests/fm-omp-harness.test.sh:536-574`: the fake API records `sendMessage` instead of `sendUserMessage`; assert the payload `customType`, `display: true`, the unchanged `⁣FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: signal: omp-e2e done` prefix, and `deliverAs: "followUp"` plus `triggerTurn: true`; drive consumption with a `message_start` whose message is `{ role: "custom", customType: "firstmate-watcher-wake", content: <sent content> }`; keep the handoff-file assertion.
  Also assert that the extension never calls `sendUserMessage` (leave the fake without it, or make it throw).

Accepted trade-offs.

- A wake turn no longer raises `before_agent_start`, so the session-start digest that `.omp/extensions/fm-primary-turnend-guard.ts:550-555` attaches there rides the captain's next prompt-flow turn rather than a wake turn.
  This only matters for a wake replayed immediately after `/new`, `/resume`, or `/fork`; the first process start cannot deliver a wake before the captain's arming prompt.
- Esc during a queued custom follow-up drops it (`agent-session.ts:7200-7204`); the durable queue replays it on the next `bin/fm-wake-drain.sh`, the same recovery an accepted-but-unconsumed record already relies on.
- `tests/fm-omp-primary-live-e2e.test.sh:241` greps the rpc log for the wake text; the custom message's `message_start` frame still carries it, so the opt-in guard should pass unchanged, but its `#3` comment ("arrives as one follow-up turn") stays accurate either way.

## Files to touch

- `bin/fm-afk-launch.sh`, `tests/fm-afk-launch.test.sh`
- `.agents/skills/afk/SKILL.md`, `AGENTS.md`, `docs/supervision-protocols/omp.md`, `docs/herdr-backend.md`, `docs/architecture.md`, `.agents/skills/harness-adapters/references/harness/omp.md`
- `.omp/extensions/fm-primary-omp-watch.ts`, `tests/fm-omp-harness.test.sh`

Repo style for all of them: one sentence per line in Markdown, plain dash, shellcheck-clean shell, no new test runner.

## Open for the user

- Posture-only quiet mode on omp.
  The minimal fix removes the daemon from omp, which means `/quiet` on omp no longer batches routine wakes; it only records the posture and holds captain-owned items, as on Pi.
  Getting turn savings back on omp is a separate piece of work (daemon and extension coexistence with a verified omp composer guard, or a port of the Pi supervision branch); say so if that is what "integrated properly" was meant to deliver, and this brief should be revised rather than built.
- Tracked live guard.
  The draft-survival proof is a manual tmux transcript in the run directory, because the editor clear only exists in omp's interactive mode and the existing live guard drives rpc mode.
  Per `firstmate-coding-guidelines` a harness-dependent behaviour normally gets a `live-harness-optin` guard too; that is out of scope here unless you want it.

# Log

- 2026-09-15 created
- 2026-09-15 brief written by architect; user settled both open choices (minimal no-daemon path, transcript-only proof); status ready then building
- 2026-09-15 build round 1 (builder): report .dev-cycle/runs/omp-quiet-wake-input/brief/build-1.md, Ready: Yes; decisions: dropped the await on sendMessage (synchronous API), tmux-only lab for the TUI demo; optional live e2e fails at pre-existing tests/fm-omp-primary-live-e2e.test.sh:261 GNU stat fallback, not claimed
- 2026-09-15 verify round 1 (verifier): .dev-cycle/runs/omp-quiet-wake-input/brief/verify-1.md, 1 blocking (docs/architecture.md:440 still counted omp among daemon harnesses by complement)
- 2026-09-15 fix round 2 (builder): .dev-cycle/runs/omp-quiet-wake-input/brief/build-2.md; docs/architecture.md:440 and the stale userMessageText comment corrected
- 2026-09-15 verify round 2 (verifier): .dev-cycle/runs/omp-quiet-wake-input/brief/verify-2.md, clean; optional live e2e not claimed (pre-existing tests/fm-omp-primary-live-e2e.test.sh:261 GNU stat fallback)
- 2026-09-15 whole brief complete and committed; status done

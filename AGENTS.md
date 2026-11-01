# Notchline

`make help` lists every entry point. Prefer it over inventing a command.
`make check` runs the tests and is what the pre-push hook runs.

Contributor-facing conventions are in [CONTRIBUTING.md](CONTRIBUTING.md).

## Product model

What the app knows, and what it doesn't. Treat these as facts when writing
code, user-facing text, notifications and plans.

- The app knows conditions, forecasts and avalanche danger for the selected
  location, and the scores and confidence it computes from them.
- The app makes recommendations: the best window, when to be on the lift and,
  on the Mac with a home set, when to leave. A recommendation is advice for
  that window, not a statement about the user's day.
- The app never knows whether the user looked at something, intends to go, is
  on the way or went. Opening the app, viewing a score, a good score and a
  departure time passing say nothing about any of these.
- The only signal that the user skied is a rating they choose to enter for a
  day. Nothing asks for one.
- So user-facing text never implies intent, departure or attendance. No "plan"
  or "planned" for the user's day, no "Go anyway", no reminders to leave, and
  no prefilling what the user did from what the app recommended.
- "Plan" and "planner" in code (`SkiDayPlanner`, `SkiDayPlan`,
  `NotchlineCore.plan`) name the computation that scores days. Don't carry
  those words into what the user sees. Say scores, forecast or updated
  instead.

When a feature seems to need something the app doesn't know, such as whether
the user is going, ask rather than infer it.

## Decided questions

Things this repo has already answered, where the obvious move is the wrong
one. This is not an introduction; the README is that.

### `make audit` is not part of `make check`

`make audit` reports known vulnerabilities in this repo's dependencies. It is
deliberately unreachable from `make check`, from `make release`, and from any
git hook. Two reasons, and they pull the same way.

It needs the network, and the gate does not. A gate that reaches the network
fails when a registry is slow or a laptop is offline, which has nothing to do
with whether the change is sound.

More importantly it would block at the wrong moment. A dependency advisory is
published on someone else's schedule, never on yours, and the fix is often a
transitive bump that needs its own test run and a judgement call. A gate that
refuses a push because of an advisory filed an hour ago is a gate people learn
to bypass, and a bypassed gate protects nothing while still looking like it
does.

So it reports and blocks nothing. `.github/workflows/audit.yml` runs it weekly
and that failing run is the notification. Patching is by hand: read the
report, decide, bump, let `make check` prove it, and release deliberately.
Nothing here bumps a dependency or releases on its own.

### There is no `lint` target yet

`swift format lint` with its default rules reports around nine thousand
findings against this codebase's existing style. Adding it to the gate means
either reformatting every file or writing a `.swift-format` config that
describes the style actually in use. Both are style decisions, so neither was
made as a side effect of wiring up the gate. `make check` runs the tests.

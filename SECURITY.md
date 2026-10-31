# Security

## Reporting a vulnerability

Please report security issues privately, through GitHub's
[private vulnerability reporting](https://github.com/appdin/notchline/security/advisories/new)
rather than as a public issue. That keeps the report between us until there is
a fix to ship.

Useful things to include, as far as you have them: what you did, what
happened, the Notchline version (menu bar, About), and your macOS or Android
version. A proof of concept helps but is not required to file.

Expect an acknowledgement within a week. Notchline is maintained by one
person in their spare time, so a fix may take longer than that; if it does,
you will hear where it stands rather than nothing.

Please do not test against anyone else's machine, and do not probe the
upstream weather and avalanche services. They are public services run by
other people, mostly government agencies, and load testing them is not in
scope here.

## What is in scope

Notchline is a macOS menu bar app and an Android app. It reads from public
weather and avalanche APIs and has no backend of its own, no accounts and no
server-side state. In practice the interesting surface is:

- Parsing untrusted responses from upstream APIs, which is everything the app
  does with data it did not create.
- The release and update path: the signed and notarized build, the Homebrew
  cask and formula, the Android package.
- Anything that could make the app read or write outside its own container,
  or run code it was not shipped with.

Dependencies are scanned weekly for known advisories, and a finding there is
already visible without a report. Reporting one anyway is welcome if you
think the usual channel has missed it or will.

## What is not in scope

- **Wrong or stale conditions data.** If the snow depth, forecast or
  avalanche danger is incorrect, that is a bug and belongs in a normal issue,
  not a security report. It usually means the upstream source changed or went
  down.
- **The avalanche danger display itself.** Notchline shows a summary and says
  so. Decisions about avalanche terrain should come from the forecast center,
  not from this app, and that is a documented limitation rather than a
  vulnerability. The README says the same thing.

## Supported versions

The current release is the supported one. Notchline is pre-1.0 and there is no
backport branch; fixes go into the next release and reach existing installs
through Homebrew or the Android package.

# Contributing

Notchline is maintained by one person in their spare time. Issues and pull
requests are welcome, and a reply may take a week or two.

## Where things go

| What | Where |
|---|---|
| A security issue | [Report it privately](https://github.com/appdin/notchline/security/advisories/new), not as an issue. See [SECURITY.md](SECURITY.md). |
| The app misbehaves | A bug report issue |
| A number or avalanche rating looks wrong | A "wrong conditions data" issue. It needs a comparison against the source, so the template asks for one. |
| A new ski area | See [Adding a resort](README.md#adding-a-resort). Open an issue first if it needs a new data provider. |
| Anything else | A blank issue is fine |

## Before opening a pull request

Everything needed to build and test is in [Development](README.md#development),
and [Adding a resort](README.md#adding-a-resort) covers the most common change
end to end, including the fixtures a new data source needs.

Two things worth knowing in advance:

- `make test` runs against saved fixtures and should pass before you open the
  PR. A new data source needs a saved response in
  `Tests/NotchlineTests/Fixtures/` so its parsing stays tested when the
  upstream service changes shape.
- New data providers go through the shared helpers in `NotchlineCore` for text
  parsing, unit conversion and local time, and record a warning rather than
  dropping an error silently. `SharedBehaviorTests` checks most of that, so it
  will usually tell you before a reviewer does.

Please open an issue before a large change, so you do not spend a weekend on
something that turns out to be a no. For a one-line fix, just send it.

## What is likely to be declined

- Anything that presents avalanche danger as more authoritative than the
  forecast center's own forecast. The app shows a summary and says so, and
  that is deliberate.
- Features that need a backend. Notchline reads public APIs directly and has
  no server, no accounts and nothing to operate, which is most of why it is
  maintainable by one person.
- New dependencies, unless the thing they do is genuinely hard. The
  dependency list is short on purpose and is scanned weekly for advisories.

None of these is a rule about code quality. They are about what this app is,
and saying them here is cheaper than saying them in a review.

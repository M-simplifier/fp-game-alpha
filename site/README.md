# Public introduction site

The Japanese page introduces **壊れないゲーム開発** to individual developers who
want to make their own game with AI, regardless of Haskell experience. Its main
action copies a game brief and the public development entry for the reader's AI.
The [research and design rationale](../research/public-page/README.ja.md) records
sources, project-specific hypotheses and limits.

## Static publication

`index.html`, `style.css` and `site.js` run without a build framework or package
installation. GitHub Pages publishes this directory after the repository checks
pass on main. Pull requests validate the page without deployment permissions.
Only the current main revision may deploy; a completed older run is skipped.

The page uses system fonts and loads its Afterlight screenshot directly from the
existing public game guide. No game image binary is copied into the source-only
alpha export. The screenshot links back to its source guide. The icon and site
code are authored here under the repository's MIT license. Source licensing is
not a claim about arbitrary downstream game assets or runtime distributions.

The brief stays in the reader's page and clipboard. There is no form endpoint,
analytics, local storage or third-party script. External navigation and the
Afterlight image use their respective public hosts.

## Reproduce checks and preview

From the repository root:

```text
python tools/check_site.py
node --check site/site.js
python -m http.server 8768 --directory site
```

The static checker verifies local assets, fragment targets, links into this
repository, source provenance and the accepted/refused trace relationship. It
does not execute JavaScript, fetch external sites or certify accessibility.

The Station panel presents saved stdout packets from the compiled Haskell
headless player. It is not a live browser port. The two inputs are
`act 1 local` followed by the same `act 1 local`; the latter is refused by the
transport's visible-turn check. See [the source revision and packets](evidence/station-trace.json).
The Domain's own stale-token check is a separate boundary.

For a new record, build the Station player with `tools/play.py`, send those two
newline-delimited commands to the executable and capture all three JSON lines,
including its initial packet. Record the exact source revision and source
fingerprint with the packets. Keep real output fields; do not reconstruct them
from page copy. A changed current source does not invalidate a pinned historical
record, but any new behavior claim needs a corresponding new execution.

## Consumer verification

The page was exercised in Chrome on Windows on 2026-10-04:

- Desktop and 320/390px viewports; no document-wide horizontal overflow at 320px.
- Both recorded trace steps: energy 8 → 7 → 7, turn 1 → 2 → 2, delivered 0 → 1 → 1.
  Reset returned the initial draft to its initial packet.
- Brief and target entry, copy by click and keyboard, and exact clipboard/text
  area equality. The copied instruction included the entered brief, source
  revision recording, skill path and GAME-SPEC/continuation requirements.
- Keyboard skip link with visible focus, disclosure expansion and manual text
  selection/copy. The temporary viewport override was reset after inspection.

The fallback for a denied clipboard operation opens and selects the ordinary
text area; that denial branch was source-reviewed, not triggered by changing
browser permissions. Manual copying from the same text area was exercised.
Without JavaScript the copy button stays disabled and unnamed fields cannot
serialize the brief into a native form URL. A project link and manual instruction
remain available; this path was source-reviewed, not tested with scripting disabled.

These observations do not establish that a new reader completed the AI-led game
workflow, that beginners understood the design, or that the whole site conforms
to WCAG. Do not promote copy-button success into game-development acceptance.

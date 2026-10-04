---
name: haskell-editor-setup
description: Set up or repair Haskell Design reading tools and VS Code or Neovim editing for this foundation or an independent Haskell game, using its actual compiler, Cabal components and HLS configuration.
---

# Set up Haskell reading and editing

Follow the canonical [Haskell Design guide](../../../docs/haskell-design.md).
The tool source is [editors/haskell-design](../../../editors/haskell-design/README.md).
This skill is a small routing entry, not a separate setup specification.

- Identify the target game, chosen editor/profile and extension host. Preserve its
  compiler, layout, flags and existing settings; the tool checkout may be elsewhere.
- For reading alone, build or reuse the native reader, then use `map`, `outline`
  and `show`. An editor, HLS and project dependency build are unnecessary for
  syntax-only reading. Read implementations and relevant tests before changing code.
- For editing, follow the guide's adapter and project-wiring steps. Build the actual
  game components, including relevant tests; a sample fixture is not completion.
  Use the bundled generic `scripts/configure-cabal.mjs` only when its single-package
  Cabal assumptions fit. Review proposals before applying and merge conflicts safely.
- Keep GHC inference explicitly trusted and optional. It supports GHC 9.6.x;
  do not change an existing game's compiler merely to satisfy the analyzer.
  Preserve HLS and syntax browsing when inference is unsupported.
- Reuse installed toolchains and cached dependencies, bound build concurrency and
  disk use, and do not install or rebuild tools on every editor startup.
- Verify the requested editor on the game's own source: HLS diagnostics/completion,
  navigation, design/source switching, unsaved edits and Undo. Report what actually
  ran, the folder/command to open, and any missing layer; never infer a platform
  pass from a different OS or from unit tests alone.

For an independent new game, keep a reachable copy or pinned public link to the
canonical guide and tool distribution in its continuation instructions. If copying
this skill, include its helper and MIT license and update these relative links to
that game's recorded guide/tool location. Generated host paths and caches stay local.
No private dotfiles, reference-game setup scripts or reference-game assets are needed.

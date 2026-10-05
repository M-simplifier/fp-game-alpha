# Alpha acceptance contract

Each published path must appear in the machine-readable publication manifest
with provenance, license, maturity and an export decision. Preserve the public
repository's history and MIT copyright notice. Import selected technical files
as ordinary new commits, never a private repository's Git history.

The alpha baseline requires:

1. The shared libraries build and their laws/regressions pass from a fresh
   public clone, with no sibling checkout, personal path or private dependency.
2. The native CLI's optional terminal template passes doctor, create-plan,
   create, build, check, test and deterministic run. Creation refuses an existing
   destination and offers a mutation-free dry run. Unsupported targets fail explicitly.
3. Native saved-source checks return actual compiler diagnostics. The separate
   inspect/context helper returns compiler-backed module structure and type
   context, including nonzero failure on an invalid request. Editor support
   calls these same backends and does not claim an empty command succeeded.
4. Reference refactors preserve existing behavior and regression evidence.
   Explain data flow and boundary-sensitive counterexamples for learners.
5. Documents are canonical. Skills route to them; local links and skill
   contracts are checked in CI.
6. Export inspection rejects credentials, personal absolute paths, internal
   instructions, undeclared repository links, unknown/binary assets and files
   missing a license or provenance record. Record each file's result.

Native terminal build/run, native graphics, Web build/browser execution,
server deployment, mobile devices and performance are separate acceptance
claims. Mark each completed, experimental or blocked with concrete evidence.
Publish incremental milestones without describing the entire program as done.

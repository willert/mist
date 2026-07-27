# Proposal: verify a generation before promoting it

Status: NOT IMPLEMENTED, deliberately deferred (2026-07-27). Recorded while the
reasoning is fresh. Its main near-term effect was to settle the scope of the
inject/merge overhaul, which is being done first - see "Why this decided the
inject/merge scope" below.

## Problem

`./mpan-install` builds a generation, lets cpanm run each dist's own test suite
as it installs, and then promotes the generation by repointing the
`perl5/<arch_path>` selector symlink. Nothing in that sequence ever asks whether
the *project* still works against the newly built dependency set.

The two existing gates prove adjacent things:

- cpanm's per-dist tests prove each dependency passes its own suite in isolation.
- the release clean-room proves the mirror is *complete* (a missing tarball fails
  it), while running `--notest`, so a vendored-but-broken dep sails through.

Neither catches the case that actually bites: every dependency installs and
tests green, the mirror is complete, and the application is broken by the
combination. Today that is discovered after promotion, in the live environment,
and the remedy is a rollback that the operator has to notice they need.

The generation ladder already gives the hard part for free: the new environment
is built beside the live one and becomes live only by a single symlink repoint.
That is exactly the shape a verification gate wants. The build is already a
candidate; nothing currently gets to vote on it.

## Where this came from

A 2026-07-27 session tracing `docs/bug-init-creates-pregeneration-libdir.md`,
which ended in the finding that `mist inject` and `mist merge` install into the
*live* generation (`App::Mist::Context::_build_local_lib` resolves the selector
symlink), bypassing the stage-then-swap discipline every other build path
follows. Asking "could we test the build before committing to it" fell out of
that discussion, and answering it settled the inject/merge question.

## What already exists, and why this is smaller than it looks

Three pieces are in place, all verified in `lib/Mist/Script/install.pm` at the
time of writing:

- **A pre-promote window.** `finalize` scripts run at `:615`; the promote
  sequence does not begin until `:655` (`_activate_generation`), followed by the
  rc rename at `:678` and the wrapper rename at `:716`. Between `:615` and `:655`
  the generation is fully built and nothing is live.
- **Test-phase dependencies are already installed.**
  `App::Mist::Context::fetch_prereqs` uses `merged_requirements`, which folds
  `on test => sub { ... }` into the installed set (asserted in
  `t/context-fetch-prereqs.t`). A deploy host therefore already has what the
  project's own suite needs.
- **A declared-script mechanism.** The mistfile `script` verb with its
  `prepare` / `finalize` phases is already read host-side (`:577`, `:615`).

So the gate is a new phase in an existing mechanism, run in an existing window.

## Design sketch

Add a declared `verify` phase. It runs after `finalize` and before
`_activate_generation`. A non-zero exit means the generation is not promoted:
the previously active generation stays live, and the built-but-unpromoted
generation is left on disk for inspection.

Declared, never inferred. An unconditional `prove -l t/` is wrong: plenty of
deploy hosts have no database, no network egress, no fixtures. Requiring the
project to name the command keeps the gate opt-in by construction and lets a
project run something narrower than its full suite (a smoke script that loads
the app and exits, say).

Failure handling falls out of the existing model. Not promoting is the entire
rollback - there is nothing to undo, because nothing was swapped. The unpromoted
generation stays addressable, and the documented manual repoint
(`ln -sfn generations/<arch>-<N> perl5/<arch>`) already works as the "I looked at
it, promote it anyway" escape hatch.

## The trap: which environment the verification runs under

This is the part that is easy to get wrong and fails *silently open*.

At the point where the gate would run, the staged wrapper and rc exist
(`$body_new`, `$rc_new`, staged at `:554`-`:561`) but have not been renamed into
place. The rc's content references `$generic_libdir` - the generic selector path
- which still points at the **old** generation until `:655`.

So running the verification through the staged wrapper, or through anything that
resolves the generic path, tests the currently-live environment and passes
regardless of what was just built. The gate has to run against the generation
directory directly.

Any implementation needs a test that would fail if this regressed, because the
symptom of getting it wrong is "the gate always passes", which looks exactly like
"the gate works".

## Why this decided the inject/merge scope

`mist inject` and `mist merge` both install into the live generation. If
promotion becomes gated on the project's own tests, they become the only way to
change the running environment with **no** verification at all - not the
per-dist tests, not the mirror-completeness check, not the new gate. A
verification gate on the front door is worth much less with that side door open.

That is what turned "fix inject, and maybe merge" into "fix both". The
side-effect-free path already exists and is proven: `inject --full-dependency-tree`
resolves into a throwaway contained lib (`App::Mist::Command::inject.pm:88`-`:95`)
while `--save-dists` still vendors into the real `mpan-dist`. Promoting that from
special case to default is the whole change, and `perl5/` becomes populated only
by `./mpan-install`.

## Invariants this should preserve

- A generation, once promoted, is immutable. The gate does not weaken this; the
  inject/merge overhaul is what restores it.
- Nothing is created at `perl5/<arch_path>` other than the selector symlink.
- A failed gate leaves the live environment untouched, exactly as a failed build
  does today.
- The gate is skippable, because a host that cannot run the suite must still be
  installable. Skipping is a declared decision, not an inferred one.

## Rejected alternatives

- **Reuse `finalize` instead of adding a phase.** `finalize` already runs in the
  right window, so this is tempting. Rejected because the two have different
  failure semantics: a `finalize` script's exit status is currently ignored
  (`system( @$_ ) for ...`), and giving it promote-blocking power retroactively
  would change the meaning of every existing declaration.
- **Run the gate after promotion and roll back on failure.** Strictly worse: it
  exposes the live environment to the broken set, and rollback is not free once
  long-running processes have mapped the new generation's files.
- **Calling it a "candidate" build.** The term is taken - `mist release
  --dry-run` produces release candidates promoted with `--candidate=<id>`.
  Overloading it would be actively confusing. "Unpromoted generation" is
  accurate and already the vocabulary the installer uses.

## Open questions

- Does the gate belong on every install, or only on ones that changed something?
  A no-op `./mpan-install` that installs nothing arguably should not pay for a
  full suite run.
- What does `--build-only` do? It never promotes, so the gate has nothing to
  guard - but running it would still be a useful "would this have been
  promotable" check.
- How does this interact with `--bundle`, which is deliberately an incremental,
  targeted install? Gating a security erratum behind the full suite may be the
  wrong trade under time pressure.
- Should a failed gate leave a marker in the generation, so a later run can tell
  "built but rejected" from "built but interrupted"?

## Test plan

- The gate blocks promotion: build a generation whose verify command exits
  non-zero, assert the selector still points at the previous generation and the
  new generation still exists on disk.
- The gate passes through: verify exits zero, selector moves.
- **The environment trap:** a verify command that reports which generation it
  actually sees must see the new one. This is the assertion that catches a
  regression to "always passes".
- No declared verify phase means no behaviour change at all.
- `t/mpan-install-activation.t` is the natural home; it already builds real
  generations in a sandbox and asserts on selector movement.

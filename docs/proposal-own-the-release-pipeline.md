# Proposal: own mist's release pipeline (stop shadowing Minilla)

## TL;DR

mist customises Minilla's release pipeline by **shadowing upstream class names**
(`lib/Minilla/CLI/*`, `lib/Minilla/Release/*`). That only works when `./lib`
outranks the vendored `perl5/` Minilla in `@INC` - and it does not in the real
`mist release` process, so **stock Minilla runs and every mist override is
inert**. The fix is to stop overriding by name: own a small mist release pipeline
(`Mist::Release::*` steps + a thin orchestrator), compose it from mist's own steps
plus the unchanged upstream steps referenced by their full names, and **keep
`Minilla::WorkDir` for the dist building**. The buggy part is thin (~277 lines to
relocate); the heavy part (the dist builder) stays upstream and is never touched.

## The bug, concretely

- **Evidence.** `mist release --dry-run` prints `DRY-RUN.  Would have tagged
  version <X>` - the message string of *upstream* `Minilla::Release::Tag`. mist's
  `Minilla::Release::TagPublish` (which prints a different line) is never loaded,
  even though it is the step named in mist's `Minilla::CLI::Release` step list.
- **Root cause.** `lib/App/Mist.pm` BEGIN runs `local::lib->import($mist_lib)`
  (~line 35), which **prepends `perl5/` to `@INC`** - *after* `script/mist:6`
  (`use lib "$Bin/../lib"`) prepended `./lib`. So in the App::Mist process the
  vendored upstream Minilla (`perl5/.../Minilla/...`) precedes mist's overrides
  (`./lib/Minilla/...`). `require Minilla::CLI::Release` resolves to upstream;
  upstream's step list names `Tag`, `BumpVersion`, `Commit`, never mist's
  variants.
- **Scope.** The Tag step is *confirmed* upstream (its message printed). By the
  same `@INC` mechanism the whole override layer is shadowed:
  `BumpVersionSmart` (the in-flight smart-bump), `CommitLocal` (no-push on
  `local_release`), `TagLocal`, `TagPublish`, `CheckChangesNoEdit`, `LocalTest`,
  and the two CLI dispatchers. So `mist release` / `mist local_release` run stock
  Minilla today. Recent 0.41/0.42 releases did not surface it because upstream
  bump/tag/push matches mist's for a clean ascending release; the divergence only
  shows in the in-flight and `local_release` paths.
- **Why it hid.** The intended regression test (`t/release-dry-run-no-version.t`)
  runs under `prove -Ilib`, which puts `./lib` first - so it exercised mist's
  `TagPublish`, code the real release never runs. A test that passes against code
  the product does not load is worse than none.

## Two fixes

- **A - minimal `@INC` reprepend.** Re-prepend the mist lib dir after
  `local::lib->import`, so the overrides win. Two lines, but it *keeps* the
  shadow-by-name pattern: the next `local::lib` / install / `@INC` change
  re-breaks it silently, exactly as now. Treats the symptom.
- **B - own the pipeline (recommended).** Stop overriding Minilla classes; give
  mist its own release pipeline in its own namespace. No class can shadow it, the
  coupling becomes explicit, and the failure mode is gone for good.

## Design (option B)

- **Rename the overrides out of `Minilla::*` into `Mist::Release::*`** (steps) and
  a `Mist::Release` orchestrator (or inline in the command). No upstream name can
  shadow them.
- **`App::Mist::Command::release` / `local_release` call the mist orchestrator
  directly**, instead of `Minilla::CLI->new->run( release => ... )`.
- **The orchestrator's step list composes three sources:**
  - mist's own steps: `Mist::Release::{BumpVersionSmart, CheckChangesNoEdit,
    CommitLocal, TagLocal, TagPublish, LocalTest}`;
  - unchanged upstream steps **referenced by full name** (no override, no shadow):
    `Minilla::Release::{CheckUntrackedFiles, CheckOrigin, CheckReleaseBranch,
    RegenerateFiles, RunHooks, DistTest, MakeDist, RewriteChanges}`;
  - `UploadToCPAN` stays a no-op under the `do_not_upload_to_cpan` guard.
- **Keep `Minilla::WorkDir` and `Minilla::Project`** (the model;
  `Mist::Minilla::Project` already extends it), called directly. Keep
  `Minilla::Util` / `Minilla::Logger`.

## Keep, do not reimplement

- **`Minilla::WorkDir`** - the dist builder (git file-gather, MYMETA, MANIFEST,
  tarball, test-the-extracted-tarball). Used by `merge` (`work_dir->dist()`) as
  well as the release. Mature, fiddly, and **not the bug** - it is called by API,
  never shadowed.
- **`RegenerateFiles` / META.json generation** from cpanfile.

The moment "take over Minilla" starts meaning "reimplement `WorkDir`", the cost
flips. That is explicitly out of scope.

## Carry-over couplings (already in `release.pm`)

- The `Minilla::Project::verify_prereqs` monkeypatch (`release.pm:123`).
- The `CheckChanges` `{{$NEXT}}` regex kept consistent with upstream
  (`release.pm:382`).
- The `do_not_upload_to_cpan` guard, `MINILLA_DISABLE_WRITE_RELEASE_TEST`, and the
  sealed `--mirror-only` clean-room dist-test live in the `release.pm` wrapper and
  already apply regardless of which Minilla loads.

## Surface and effort

- ~277 lines of existing override code to relocate, plus a ~50-line orchestrator.
  Net new logic is small; most of it is moving and renaming.
- The genuinely new work is a **release test that drives the actual orchestrator**
  (the gap that hid this bug) - not a `-Ilib` unit test of a single step in
  isolation. Highest-value piece.

## Sequencing

- **Ship 0.43 now via stock Minilla.** It works for a clean 0.42 -> 0.43 bump; the
  `release.pm` wrapper customisations still apply; only the inert step overrides
  differ, and none matter for this bump.
- **Then do the take-over as its own change**, behind the release test. Do not
  entangle the refactor with getting 0.43 out.

## Risks

- Still coupled to `Minilla::WorkDir` and the upstream step API
  (`->run($project, $opts)`, `$project->dist()`). That coupling exists today; this
  makes it legible (one step list) instead of invisible shadow-magic.
- An upstream Minilla step-API change would need adapting - but it would surface in
  the one orchestrator, not as a silent behaviour swap.

# Proposal: `mist merge` should honor the sibling's declared version pins

## TL;DR

When `mist merge S` runs in consumer `C`, and `S`'s cpanfile pins a dependency
to a version newer than `C`'s `mpan-dist` carries, the merge install dies instead
of pulling the newer version from `S`'s mirror. The fix is to scope cpanm's
`--cascade-search` to the merge path (the `mirror_only` install), so resolution
cascades among the curated file-mirrors - never to live CPAN. `--save-dists` then
vendors just the resolved delta into `C`. No mirror-copying, no version inference.

This is deliberately narrow. An earlier draft of this proposal tried to make `C`'s
`mpan-dist` a per-package superset of `S`'s by copying tarballs (or by inferring
version floors from `S`'s mirror index). Both are rejected below: they treat the
contents of a mirror as a statement of *requirements*, which it is not.

## Where this came from

Found during a cross-repo dependency-currency sweep over the Exparse and WeCARE
mist stacks (bumping XML::LibXML to a security release, retiring an unmaintained
XML::Hash::LX, de-flaking Test::XML::Simple, moving TimeDate to current). Several
consumers of a freshly-bumped `core` hit friction re-merging it. Triaging that
friction split it into one real merge bug and one mis-attributed one.

## The one real failure: a declared pin the consumer's mirror shadows

`core`'s cpanfile now pins `Test::XML::Simple => '1.06'`; consumer `C`'s
`mpan-dist` still indexes `1.05`. `mist merge ../core` dies with:

    Installing the dependencies failed: Installed version (1.05) of
    Test::XML::Simple is not in range '1.06'

and bails before refreshing the mistfile block. The requirement is real and
declared (it is in `core`'s cpanfile), and `core`'s own `mpan-dist` carries
`1.06` - merge just fails to reach it. Today's workaround is a manual
`mist inject 'Test::XML::Simple@1.06'` into `C` before re-merging. That manual
step is exactly what this proposal removes.

## Not our bug: an undeclared transitive version

`core` pulls `TimeDate` transitively with no version pin. `C` had `TimeDate 2.30`
(whose `t/getdate.t` fails against current system tzdata); the bare requirement is
satisfied by 2.30, so merge does not upgrade it, and the breakage only surfaces on
`C`'s next from-scratch `./mpan-install`.

It is tempting to make merge "notice" that `core` vendors 2.35 and pull it
forward. Resist it. `core` does not *need* 2.35 in any dependency sense - the API
it uses exists in 2.30; 2.30 is merely unbuildable now because *its own tests*
fail against current tzdata. "core wants 2.35" was never true. The only signal
pointing at 2.35 is that 2.35 happens to sit in core's `mpan-dist` - and a
mirror's contents are not a dependency contract.

So this is an under-declared cpanfile in the sibling, not a merge bug. The fix
lives in `core`: bump its mirror and add `requires 'TimeDate', '>= 2.35';` to its
cpanfile (a transitive floor is a legitimate thing to pin). That one line
**converts this into the real failure above**, which the cascade-search fix then
handles. mist's job is to honor declared contracts, not to invent them from
whatever a mirror happens to hold.

## Root cause (grounded in the code)

`lib/App/Mist/Command/merge.pm` `execute()` builds the sibling's dist, constructs
the package manager with `mirror_only => 1` (resolution strictly from pinned
file-mirrors, never CPAN), adds `S`'s `mpan-dist` as a mirror, then installs `S`'s
mistfile call stack and the dist itself.

`lib/Mist/PackageManager/MPAN.pm` assembles the mirror list with `C`'s own
`mpan-dist` **first** (the `around _build_mirror_list`), and `merge`'s
`add_mirror` appends `S`'s mirror **last**. `install()` passes `--save-dists`
(anything resolved is vendored into `C`) and `--mirror-only` under `mirror_only`,
but `--cascade-search` is present only as a commented-out line.

Without `--cascade-search`, cpanm does not fall through to a later mirror when an
earlier one already answers for a module. `C`'s own mirror answers `Test::XML::Simple`
with `1.05`, that fails the `>= 1.06` requirement, and the install errors instead
of cascading to `S`'s mirror (which has `1.06`). That is the failure.

Because `--save-dists` is already on, **fixing resolution fixes the symptom with
no copy step**: once cpanm resolves `1.06` from `S`'s mirror, it auto-vendors into
`C`'s `mpan-dist`, and the existing indexer's highest-version-wins (see
`Mist::Role::CPAN::PackageIndex`, and the 0.37 numeric-version ordering fix) makes
`02packages` point at `1.06` while `1.05` lingers harmlessly. No downgrade is
possible because re-index always picks the max.

## The fix

In `MPAN.pm`, couple `--cascade-search` to `mirror_only` so the two are
inseparable - cascade-search can never appear without `--mirror-only`, i.e. it can
never reach CPAN. Extract the option list into a pure method so the coupling is
testable without running cpanm:

    sub cpanm_install_options {
      my $self = shift;
      return (
        '--quiet',
        '--local-lib-contained' => $self->local_lib,
        '--save-dists'          => $self->mpan_dist,
        $self->cpanm_mirror_options,
        ( $self->mirror_only ? ( '--mirror-only', '--cascade-search' ) : () ),
      );
    }

    sub install {
      my ( $self, @cmd_args ) = @_;
      $self->run_bundled_cpanm_script( $self->cpanm_install_options, @cmd_args );
    }

Properties:

- **Scoped by construction.** `mirror_only` is set only by `merge` (`inject` and
  `upgrade` build `MPAN` without it and legitimately reach CPAN). Pairing the two
  flags in one ternary makes "cascade-search without mirror-only" - the
  reproducibility-breaking combination - structurally unrepresentable, not merely
  avoided by discipline.
- **Build-master only.** `MPAN.pm` is not fatpacked into `mpan-install`
  (`compile.pm` embeds only `Mist::Distribution`, `Mist::Environment`,
  `Mist::Script::*`). No `mist compile`, no installer regen, no drift guard. The
  host install path is untouched.
- **No new vendoring logic.** `--save-dists` already vendors; the indexer already
  does max-version-wins. The gap was purely *resolution*.

## Rejected alternatives (recorded so they are not re-proposed)

### Hard mirror-union: copy `S`'s `mpan-dist/authors` into `C`'s

Bulk-copy `S`'s whole tarball tree into `C` with a per-package version compare,
making `C`'s mirror a literal superset of `S`'s. **Vetoed.** It is harmless to
correctness and corrosive to everything the mirror model is for: every consumer's
committed git mirror bloats with every sibling's full closure (including test-deps
it never uses - the draft called this "harmless over-vendoring"), tarballs
duplicate N-ways across the stack, and `S` stops being the single source of truth
for its own dists (you have snapshotted it). `C` already gets the tarballs it
*uses* via `--save-dists`; copying the ones it does not is pure cost.

### Closure inference: propagate `S`'s mirror versions as `>=` floors

Read `S`'s `02packages` and inject `Module@>=ver` constraints into the merge
resolution, so even undeclared transitive versions get pulled forward. **Rejected
for the same reason as the union, one level up:** it launders the mirror's
*contents* into a dependency *contract* nobody declared. A floor that exists only
because a tarball happens to sit in a mirror is not a requirement; baking it in
makes accidental mirror state permanently load-bearing. The legitimate version of
this is a one-line `requires` in the sibling's cpanfile - see "Not our bug" above.

## The load-bearing mechanism, verified by spike

The fix rests on one cpanm semantic: does `--cascade-search` cascade when an
earlier mirror has the module but at an *unsatisfying* version, or only when the
module is *absent*? The real failure is "present but too old" (`C` has 1.05, needs
1.06), so if cascade only triggered on absence the flag would do nothing and the
approach would be dead.

**It cascades on present-but-unsatisfying.** Confirmed with a hermetic two-mirror
probe (no network, synthetic `Foo` tarballs, the bundled `share/cpanm`), mirror
`A` first indexing `Foo 1.0`, mirror `B` last indexing `Foo 2.0`:

- Requesting `Foo~2.0` **without** `--cascade-search` fails with
  `Found Foo 1.0 which doesn't satisfy 2.0.` - the mode-1 error verbatim, and
  proof that cascade is *necessary*, not just sufficient.
- The same run **with** `--cascade-search` cascades past `A` and installs `2.0`.
- A second probe installed `Bar` (whose Makefile.PL declares `Foo => '2.0'`) to
  confirm cascade reaches **declared prerequisites** during dependency walking,
  not only top-level argv - the actual merge path. Without cascade:
  `Installing the dependencies failed: Module 'Foo' is not installed` and a bail;
  with cascade: `Foo 2.0` + `Bar 1.0` both install. This is the real merge failure
  reproduced and then fixed by the one flag.
- A third probe confirmed cascade stays **bounded by the listed mirrors** - no
  fallthrough to CPAN. A sentinel module present only in an *unlisted* mirror is
  reported `Couldn't find module or a distribution` after cascade exhausts the
  listed file-mirrors; listing that mirror makes it resolve. Cascade reaches
  exactly the mirrors in the list and stops. Since the merge list omits `cpan.org`
  (`MPAN.pm:54`, added only `unless mirror_only`), there is no CPAN for it to reach.

So the commented-out line was disabled for the *scoping* danger, not because the
mechanism failed. The merge path has two independent guards against CPAN reach -
the list omits cpan.org, and cascade is bounded by the list - and the proposed
coupling adds a third (cascade-search is never emitted without `--mirror-only`).
The probe scripts live at `/tmp/cascade-spike/` and are the seed for the
integration test below.

## Test plan

### 1. Scoping-guard unit test - the regression the comment is begging for

Pure, in-memory, no install (style of `t/build-cpanm-call-stack.t`):

- `MPAN->new( mirror_only => 1, ... )->cpanm_install_options` contains **both**
  `--mirror-only` and `--cascade-search`.
- `MPAN->new( mirror_only => 0, ... )->cpanm_install_options` contains **neither**.

This encodes the reason the line was commented out: cascade-search must never
reach the general, reproducible install path. It is cheap and it is the test that
actually protects the invariant the original author was worried about.

### 2. Merge integration test - mechanism regression

Sandboxed, in the style of `t/mpan-install-activation.t`:

- Set up consumer `C` indexing an old `Foo` and sibling `S` whose cpanfile pins a
  newer `Foo` (carried in `S`'s `mpan-dist`).
- `mist merge S` in `C`. Assert: merge succeeds with **no** manual pre-inject;
  `C/mpan-dist/.../02packages` now indexes the newer `Foo`;
  `rm -rf perl5 && ./mpan-install` builds clean from `C`'s mirrors alone (no
  network).
- Control / no-downgrade: give `C` a *newer* `Foo` than `S`; assert merge does not
  pull it backwards (the indexer's max-wins already guarantees this, but pin it).
- Regression: a normal merge of a drift-free sibling behaves exactly as before.

## Notes

- `mirror_only => 1` already prevents CPAN reach in the merge path; the scoped
  cascade-search cascades only among the curated file-mirrors. The danger is solely
  the leak into the non-`mirror_only` path, which the coupling prevents structurally
  and the scoping-guard test guards.
- The transitive-breakage class (the TimeDate case) is fixed in the sibling's
  cpanfile, not here. Worth a one-line mention in the merge docs so operators reach
  for the `requires` floor instead of asking merge to guess.
- Filename still says "dep-propagation"; the scope is now "honor declared pins."
  Rename to `proposal-merge-honor-declared-pins.md` if/when this is picked up.

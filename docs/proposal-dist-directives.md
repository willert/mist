# Proposal: per-dist build directives - a composition, ordering and build-flag model

> **Status: proposed** (0.45 candidate). Supersedes the parked `ccflags` sketch;
> ccflags lands here as the first new directive on the model, not as a flat add.

## TL;DR

mist's per-dist build handling has grown by accretion: a flat `prepend` list, a
flat `notest` list, version pins from the cpanfile, and now a wish for compiler
flags. Each is a separate structure that `build_cpanm_call_stack` special-cases in
its own branch, and the build phases (prepended -> notest -> prereqs) are hard-coded.

This replaces the parallel structures with one **per-dist directive record**, a
single **composition rule** for folding records across `merge` blocks,
**declaration-order** (FIFO) build ordering with **merged-before-outer** semantics,
and a `build_cpanm_call_stack` reduced to a **compiler** from composed, ordered,
deduped records into cpanm calls. `prepend` becomes the base primitive; `notest`
and `ccflags` become decorators that imply it and compose onto a single call.

## The frictions that motivate it

1. **Merge duplication.** Merged dists contribute overlapping directives that are
   concatenated, not reconciled, so the same dist lands on the call stack several
   times and cpanm re-tries it - mostly harmless noise, but the smell of an
   unreconciled model.
2. **Chained build flags need ordering.** A compiler flag (e.g. `-std=gnu17` for a
   dist that breaks under a C23-default toolchain) only reaches a *named* build, so
   it implies `prepend`; and if two flagged dists sit in a dependency chain, the
   upstream must build flagged before the downstream pulls it. A flat, ad-hoc
   prepend list makes that the author's fragile burden.
3. **The flat arrays are special-casy.** Every new need bolts on another structure
   plus another branch in the call-stack builder.

The tell is that a build-flag directive has to reach back and manipulate an
*ordering* primitive (`prepend`). Two such couplings (notest already does it) is a
pattern, not a coincidence.

## The bound - what this is NOT

mist **composes directives and emits cpanm calls. It does not resolve the
dependency graph or plan a global install order** - cpanm still resolves and
installs the closure. Ordering covers only the directive'd dists, and only by the
author's **declaration order**, never a derived topological sort. Reaching for
graph ordering would be reimplementing cpanm/Carton; the line is "annotated dists,
declared order."

## The per-dist directive record

One record per dist that carries any directive:

    { prepend => 1, notest => 1, ccflags => '-std=gnu17', ... }

`prepend`/`notest` are booleans; `ccflags` is a value. The set is open - a future
directive is a new field, not a new flat structure and a new call-stack branch.
The DSL verbs (`prepend`, `notest`, `ccflags`) write fields on this record in
`Mist::Distribution` instead of appending to separate arrays.

## Composition across merges - one rule

When records from the build-master (outermost) and each merged dist (inner) fold
together:

- **Valued directives - outermost wins.** A build-master `ccflags` for a dist
  overrides a merged dist's. In practice the merged dist's own `ccflags` applies
  unless the build-master deliberately overrides it (the rare "compile this merge's
  dist under different flags" case, which is the author's to write). No string
  union; one winner.
- **No-negation booleans - on if found anywhere (OR).** `notest` has no
  `no-notest`, so it cannot be overridden off; if any level sets it, it is on.
  prepend-membership is the same: prepended if any level prepends it, or `ccflags`
  implies it.

The spec in one line: **if a directive has an "off", outermost wins; if it has
none, it is on-if-anywhere.** A future directive slots into one side or the other.

Dedup is a free consequence: one record per dist means one call-group per dist,
which removes the merge-duplication noise of friction 1.

## Ordering - declaration order, merged-before-outer

Build/prepend order is the order directives are declared, **FIFO** within a level.

**Merged units come before the consumer's own** - because a `merge` vendors a
self-contained, atomic functional unit into the consumer, so the unit must be
fully stood up before the consumer leans on it. This is the existing semantic and
it is correct; it is preserved.

Within the merged set, order is the merge blocks' **declaration order** (which
`mist merge` preserves - it rewrites a block in place via its marker delimiters, or
appends a new one, and never reorders) and statement order within a block. So the
rare chain - a flagged or notest'd dist that depends on another - is handled by the
author declaring the upstream one first, within the merged set.

### The one fold change: de-reversal

Today `store_dist_info` (`Distribution.pm:50-66`) **unshifts** merged entries
per-entry, which reverses them: `prepend P; merge First{F1}; merge Second{S1}`
yields `['S1','F1','P']`, and a block's `M1;M2;M3` yields `['M3','M2','M1']`. That
contradicts FIFO and is surprising. The fix is to insert the merged set ahead of
the outer's own prepends but in **declaration order**: `['F1','S1','P']`, and
`['M1','M2','M3']` within a block. Merged-before-outer is unchanged; only the
reversal goes. This rewrites the pinned assertions in
`t/distribution-verbs.t` (`MERGE_MULTI_PREPEND_ORDER`, `MERGE_TWO_SIBLINGS`) as a
deliberate decision, not a silent break.

### Non-goal: an outer-before-merged override

There is deliberately **no** escape to force a consumer's prepend ahead of a merged
unit. The atomic-unit invariant is exactly why it should not be needed: if a
consumer's prereq must precede a merged unit, that unit is not self-contained, and
the fix belongs at the merge boundary (fold the prereq into the unit), not in an
ordering knob. No such escape existed before; one is not added speculatively. If a
concrete case ever appears it defines its own minimal shape - and it will probably
be the non-atomic-unit smell, which wants a different fix.

## The hierarchy - prepend is the base, notest/ccflags decorate it

- **`prepend` is the base primitive:** "this dist gets its own cpanm call, at its
  declared position, ahead of the bulk prereqs."
- **`notest` and `ccflags` are decorators** that imply `prepend` (both need the
  own-call so their effect can be scoped to the named dist) and **stack onto that
  one call**. A dist with both gets **one** `--installdeps X` plus one `X` call
  carrying *both* `--notest` and the ccflags env - not two splits.
- They are orthogonal axes (position / test-policy / build-flags), so there is no
  precedence conflict - they compose, they do not compete.

This replaces today's three hard-coded phases (prepended -> notest -> prereqs,
`Distribution.pm:269-284`) with a single declaration-ordered pass over the
directive'd records, then the bulk prereqs. It is strictly more general - it also
orders a notest-dep-of-a-*prepend* correctly, which the phase split does not.

## ccflags - the first new directive

- **Implies prepend.** cpanm only customises the *named* build, never a dependency,
  and mist names a dist via `prepend`. An unprepended flagged dist would build
  unflagged as someone's dependency, and its own flagged build would never fire
  (already satisfied) - a silent no-op. So setting `ccflags` adds the dist to the
  prepend set at its declared position.
- **Both builders, no detection.** Around the dist's own cpanm call, set both:
  - `PERL_MM_OPT="CCFLAGS=$Config{ccflags} <flags>"` - ExtUtils::MakeMaker.
    `$Config{ccflags}` is prepended because a `CCFLAGS=` override *replaces* perl's
    default flags rather than appending; `build_cpanm_call_stack` runs under the
    target perl, so `$Config{ccflags}` is in hand.
  - `PERL_MB_OPT="--extra_compiler_flags=<flags>"` - Module::Build, which appends
    natively, so no compose is needed there.

  Each builder reads only its own var, so there is nothing to detect; a dual-life
  dist (ships both Makefile.PL and Build.PL, where cpanm runs Build.PL) correctly
  takes the MB one. No experimental cpanm flag is involved, which suits mist's
  distrust of cpanm flags for anything load-bearing.
- **No leak.** Split the build the way `notest` already does -
  `cpanm --installdeps X` (no flag env) then `cpanm X` (flag env) - so X's deps
  build clean and only X gets the flag. A dep that *also* needs a flag gets its own
  `ccflags`; the model composes.

`ccflags` is EUMM/MB-relevant only because it sets compiler flags; a scan of
exparo-frontend, erb and sig-cms confirms real Build.PL XS dists (Params::Validate,
HTML::Escape, ...) and dists that flip builder across versions (Safe::Hole,
Data::Clone), which is why both builders are handled and why a static EUMM-only
assumption was rejected.

## The compiler

`build_cpanm_call_stack` stops reading N flat structures. It takes the composed,
ordered, deduped records and, per record, emits its cpanm call(s):

- plain `prepend`: `[ $spec ]`;
- any decorator present (notest and/or ccflags): the split `[ '--installdeps',
  $spec ]` then `[ $spec ]` decorated with `--notest` and/or a per-call env marker;
- then the bulk prereqs, unchanged.

One call-group per dist, no duplicates.

## Threading and host change

- DSL verbs write record fields in `Mist::Distribution`; the record, the
  composition rule and the compiler all live there.
- This is fatpacked into `mpan-install` (the call stack is built on the host), so
  the change needs `mist compile` + re-vendor.
- The one host-side addition: `Mist::Script::install::run_cpanm` honors a per-call
  env marker carried on the call entry (for the ccflags env), applied via
  `local %ENV` for that call only.

## Rejected alternatives

- **A `build_order` escape verb / derived topological ordering.** Declaration order
  already expresses what is needed; deriving order from META edges (with cycle
  handling) for an extremely-rare, shallow chain is the planner trap this proposal
  is bounded against.
- **Merge-statement-position ordering.** Tempting, but `mist merge` appends new
  blocks at the *end* of the mistfile, so position order would put merged prepends
  *last* - a flip of today's merged-first behavior and a migration hazard for every
  project that relies on a merged unit standing up first.
- **Additive `ccflags` union across merges.** Outermost-wins is simpler and gives
  the build-master clear authority; merging flag strings invites conflict with no
  obvious resolution.
- **EUMM-only ccflags with a Build.PL tripwire.** Build.PL XS dists are real and
  common in the actual closures, and builders flip across versions - an EUMM-only
  verb would refuse dists in use and rot on a bump.
- **A global `CFLAGS`/`-std` for the whole install.** Fixes one dist but changes
  every other build; directives are deliberately per-dist.

## Tests

- **Composition:** outermost-wins for `ccflags`, OR for `notest`, across a
  synthetic merge tree; one record per dist; no duplicate call-stack entries.
- **Ordering:** declaration FIFO; merged-before-outer; de-reversal
  (`['F1','S1','P']`, `['M1','M2','M3']`) - rewriting the two pinned assertions in
  `t/distribution-verbs.t`.
- **Hierarchy:** a dist with both `notest` and `ccflags` produces a single
  `--installdeps` + one decorated call (both `--notest` and the env), not two
  splits.
- **ccflags:** both env vars on the module call, `$Config{ccflags}` prepended in
  the MM one; the installdeps-split present; the dist in the prepend set. Extends
  `t/build-cpanm-call-stack.t`.

## Migration

The only behavior change for existing projects is the de-reversal of merged
prepend order; merged-before-outer is preserved, so nothing flips between merged
and consumer. Two tests are rewritten to match. `ccflags` is purely additive.

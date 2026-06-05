# Proposal: `mist merge` should propagate the merged project's dependency closure

## TL;DR

After `mist merge <sibling>`, the consumer's `mpan-dist` should be a per-package
superset of the sibling's `mpan-dist` (every package at >= the sibling's version).
Today it is not, so re-merging a sibling whose pinned deps were bumped fails - or
silently leaves the consumer on stale/broken deps - unless the operator manually
`mist inject`s those deps into the consumer first.

## Where this came from

Found during a cross-repo dependency-currency sweep over the Exparse and WeCARE
mist stacks (bumping XML::LibXML to a security release, retiring an unmaintained
XML::Hash::LX, de-flaking Test::XML::Simple, moving TimeDate to current). Every
consumer of a bumped sibling hit the same friction, dubbed the "propagation tax":
re-merging the bumped sibling does not bring the sibling's new deps along, so the
merge install fails or the later from-scratch build fails.

## The problem, concretely

Two distinct failure modes were observed re-merging a freshly-bumped `core` into
its consumers (`dbic`, `oodoc`, `hfh`, `tools`):

1. **Version-pinned bump - merge install fails outright.**
   `core`'s cpanfile now pins `Test::XML::Simple => '1.06'` and
   `XML::LibXML => '2.0213'`. The consumer's `mpan-dist` still indexes `1.05` /
   `2.0208`. `mist merge ../core` dies with:
   `Installing the dependencies failed: Installed version (1.05) of Test::XML::Simple is not in range '1.06'`
   and bails before refreshing the consumer's mistfile block. Workaround today:
   `mist inject 'Test::XML::Simple@1.06' 'XML::LibXML@2.0213'` into the consumer,
   then re-merge.

2. **Transitive bump - merge "succeeds", from-scratch build fails later.**
   `core` pulls `TimeDate` transitively (via `Email::Valid` etc.) with no version
   pin. The consumer had `TimeDate 2.30` (whose `t/getdate.t` fails against current
   system tzdata); the bare requirement is satisfied by 2.30, so the merge does not
   upgrade it. The breakage only surfaces on the next `rm -rf perl5 && ./mpan-install`,
   where 2.30's tests fail and cascade through `MailTools -> Email::Valid -> core`.
   Workaround today: `mist inject 'TimeDate@2.35'` into the consumer, then rebuild.

Both are the same root issue: the consumer's vendored dep set is not reconciled
with the sibling's at merge time.

## Root cause (grounded in the code)

`lib/App/Mist/Command/merge.pm` `execute()`:

- builds the sibling's dist (`work_dir->dist()`, ~L49);
- creates the package manager with `mirror_only => 1` (L68) - so resolution is
  **strictly from the pinned file-mirrors, never CPAN**;
- adds the sibling's own `mpan-dist` as a mirror (L79-81);
- installs the sibling's mistfile call stack, then the dist itself (L87-92);
- `commit`s the consumer's `mpan-dist` (L97).

`lib/Mist/PackageManager/MPAN.pm` `install()`:

- already passes `--save-dists => mpan_dist` (so anything cpanm resolves *is*
  vendored into the consumer);
- passes `--mirror-only` when `mirror_only` is set;
- has `# '--cascade-search'` **commented out**;
- `_build_mirror_list` prepends the consumer's own `file://.../mpan-dist/` first.

When the dist install resolves the sibling's prerequisites, cpanm walks the mirror
list **in order and stops at the first mirror that *has* each module** - the
consumer's own `mpan-dist`. If that mirror's version does not *satisfy* the
requirement (consumer has 1.05, sibling requires 1.06), cpanm errors instead of
cascading to the sibling's mirror (which has 1.06). That is failure mode 1.
Failure mode 2 is the dual: a bare requirement is satisfied by the consumer's
stale version, so no upgrade happens at all.

Note `--save-dists` means **fixing resolution fixes both symptoms at once**: once
cpanm resolves the sibling's versions, they auto-vendor into the consumer's
`mpan-dist`, making it self-contained and the next from-scratch reproducible.

## Desired invariant

> After `mist merge S` into consumer `C`, for every package `P`, `C/mpan-dist`
> indexes a version of `P` that is `>= ` the version `S/mpan-dist` indexes.

i.e. `C`'s mirror becomes a per-package max-version superset of `S`'s. Then `S`'s
closure is always satisfiable from `C`'s own `mpan-dist`, reproducibly, with no
CPAN reach and no manual pre-inject.

## Options

### Option A (recommended, complete): vendor the sibling's dep closure into the consumer

As part of merge, copy the sibling's vendored dep tarballs into the consumer's
`mpan-dist` (**max-version-wins** - never downgrade a package the consumer already
has newer), then re-index, *before* the dist install. This makes `C/mpan-dist`
satisfy the invariant directly.

- Fixes **both** failure modes (version-pinned and transitive), because the
  consumer ends up with the sibling's exact (or newer) versions, including
  transitive ones like TimeDate.
- Simplest form: copy all of `S/mpan-dist/{authors,vendor}` into `C` with a
  per-package version-compare + re-index. Over-vendoring (a sibling test-dep the
  consumer does not need) is harmless - `mpan-dist` is a mirror.
- More precise form: copy only `S`'s declared dependency closure. More code, not
  obviously worth it.

### Option B (partial, cheap): enable `--cascade-search` for the merge install

Because merge already sets `mirror_only => 1`, cascade-search would cascade only
among the **file-mirrors** (consumer's + the sibling's `mpan-dist`) - it would
**not** reach CPAN, so it does not break mpan-dist's "use exactly what's vendored"
guarantee *in the merge path*. `--save-dists` then vendors the resolved versions
into the consumer.

- Fixes failure mode 1 (version-pinned) only.
- Does **not** fix failure mode 2: a bare requirement is satisfied by the
  consumer's stale version, so cascade-search never triggers.
- Do **not** enable cascade-search globally in `MPAN::install` - the general
  install path (e.g. `mpan-install`) is not `mirror_only` and would then be free
  to pull newer-than-vendored releases from CPAN, defeating reproducibility. That
  is almost certainly why the line is commented out. Any cascade-search must be
  scoped to the merge / `mirror_only` case.

**Recommendation:** Option A. It satisfies the invariant and fixes both modes. B
is a reasonable stepping stone but leaves transitive drift unaddressed.

## Test plan

Set up a consumer `C` pinned to old deps and a sibling `S` whose deps were bumped:

1. **Version-pinned:** bump `S`'s cpanfile to require a newer version of a dep
   that `C` has at an older version. `mist merge S` into `C`. Assert: merge
   succeeds with **no** manual pre-inject; `C/mpan-dist/.../02packages` now indexes
   the bumped version; `rm -rf perl5 && ./mpan-install` in `C` builds clean using
   only `C`'s mirrors (no network).
2. **Transitive:** give `C` an older, test-failing version of a transitive dep
   (e.g. `TimeDate 2.30`) that `S` carries newer (`2.35`). `mist merge S`. Assert:
   `C` now indexes 2.35; from-scratch build does not hit the old version's test
   failure.
3. **No downgrade:** give `C` a *newer* version of some dep than `S`. Assert merge
   does not downgrade it.
4. **Regression:** a normal merge of a sibling with no dep drift behaves as before.

## Caveats / notes

- `mirror_only => 1` already prevents CPAN reach in the merge path - lean on it;
  the danger is only if cascade-search leaks into the general install path.
- `--save-dists` already vendors resolved deps; the gap is purely *resolution* /
  *pre-population*, not saving.
- Keep "max-version-wins" semantics so a consumer ahead of a sibling is never
  pulled backwards.
- This touches the shared toolchain; every project's merge flow is affected, so it
  warrants the regression case above before shipping.

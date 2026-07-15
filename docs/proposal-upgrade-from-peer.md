# Proposal: peer mirror fast-forward (`upgrade --from`) and the bundle-producer direction

Status: EXPERIMENTAL, shelved ~1 month (as of 2026-06). The `upgrade --from`
implementation is committed and working; the design below is unresolved. This
document records what exists, why it looks the way it does, the tensions found
while building it, and the leading (but not adopted) redesign, so the reasoning
is not lost over the shelving period.

## Problem

There was no command that takes a source distribution and updates every package
in a target distribution to the latest versions found in the source. The pieces
that overlapped were all wrong in some dimension:

- `inject --from <peer> Module` - right version-selection (raise to the peer's
  vetted version), wrong granularity (one named module at a time).
- `inject --from <peer> --full-dependency-tree Module` - one named module's
  whole dependency tree, written as a deferred bundle. Wrong shape for a
  whole-base sync.
- `merge <peer>` - bulk and peer-sourced, but records a permanent `merge` block
  in the `mistfile` (a consumer relationship that need not exist).
- `upgrade` - bulk, but the wrong axis: it only catches `./perl5/` up to the
  project's own `mpan-dist/`.

## Motivating case

`exparo-frontend` and `sig-ng` share almost the same toolchain, but exparo
stopped being maintained ~14 years ago while sig was continuously updated. The
need is to fast-forward exparo's frozen `mpan-dist/` to sig's current versions of
the shared toolchain - a time-divergence fast-forward of a twin, not adoption of
a foreign toolchain. A real run diffed exparo against sig: 1623 package entries
across 193 tarballs.

## What was built

`mist upgrade --from <peer>`:

1. Reads both `mpan-dist/modules/02packages.details.txt.gz` indexes (mine and the
   peer's) and computes the raise set as an **index-to-index diff**:
   `_read_index` + `_raise_plan` (pure), raise-only and intersection-only. Every
   package present in both indexes where the peer's version is strictly higher is
   raised; the peer's extras are not adopted, and packages the peer is behind on
   are left alone.
2. Copies the peer's higher-versioned tarballs into `mpan-dist/authors/id/` and
   rebuilds the index from disk (`_vendor_raise` -> `reindex_distributions`, the
   hand-dropped-tarball path, as `mist index`).
3. Unless `--vendor-only`, realises the raised `mpan-dist/` into `./perl5/` via
   the ordinary catch-up (`_catch_up_local_lib`, the original `upgrade` body).

Flags: `--vendor-only` (stop after the mirror change), `--dry-run` (plan only),
`--verbose` (per-package listing; summary-only by default).

### Why the index diff, not `cpan-outdated`

The obvious implementation - point `cpan-outdated` at the peer mirror - is wrong.
`cpan-outdated` measures lag against the **installed `./perl5/`**, which is
mutable: a `mist local` or ad-hoc `cpanm` test install can leave a module newer
than both mirrors, which would silently drop it from the raise set and leave the
committed `mpan-dist/` stale. The vendoring decision must be made from the
persistent mirrors, so it is an index-to-index diff. `cpan-outdated` is confined
to the realise step (own mirror vs `./perl5/`), where a `./perl5/`-ahead is
benign (left alone, never downgraded).

## Tensions found (the reasons this is experimental)

1. **The verb conflates two targets - it does not rhyme.** Plain `upgrade` moves
   `mpan-dist -> perl5` (my mirror is the source). `upgrade --from` moves
   `peer -> mpan-dist -> perl5` (my mirror is the destination). The `--from` flag
   does not only change what is read (own mirror -> peer mirror), it changes what
   is written (`perl5` -> `mpan-dist`). One flag, two axes. And the two cannot be
   unified: making plain `upgrade` target `mpan-dist` is a no-op (own-to-own),
   and making `--from` target only `perl5` is the transient, unreproducible path
   we reject. They have genuinely different targets, so they do not belong under
   one verb. Organising by granularity (one dist vs the whole base) was the wrong
   axis; a verb's contract is what it mutates.

2. **The live realise is the weak half, and it is the default.** After vendoring,
   `_catch_up_local_lib` reinstalls the laggards in-place into the live `./perl5/`
   - non-atomic, no generation, no rollback. That is a worse version of what
   `./mpan-install` (seed + delta, generation flip) and `--rebuild` (whole
   closure, flip) already do better. For a 14-year fast-forward, `--rebuild` is
   not merely cleaner but arguably the only correct realise (XS/ABI drift, build
   order, and app-code breakage that only a full closure build + test surfaces).

3. **Comparator brittleness at scale.** `_version_cmp` has documented edge cases
   (`0.05` vs `0.5` collapse, TRIAL above stable) that "never bite real mpan-dist
   tarballs" at a handful of comparisons but are likelier across 1623. Mitigated,
   not eliminated: strings-differ-but-compare-equal is surfaced as a warning
   rather than silently skipped.

4. **The dry-run firehose.** A full sibling fast-forward printed 1623 per-package
   lines (~162KB). Mitigated: summary-by-default, per-package behind `--verbose`.

## Leading direction (NOT adopted - open)

Reframe **bundles as the first-class citizen**. A bundle (a named set of
`Module~version` floor specs, backed by tarballs in the mirror that travels with
it) is the serialized interchange unit across mist's build-master/host split:
producers run build-master-side, `./mpan-install --bundle` applies host-side.
`inject --full-dependency-tree` is not the owner of bundles - it is just the
first *producer* that happened to get written.

Under this reframe:

- Producers differ only in floor **selection**:
  - `inject --full-dependency-tree <target>` - one target's clean-room-resolved
    dependency tree.
  - fast-forward `--from <peer>` - the whole shared-base index diff (the engine
    built here).
- The apply is universal and owns every hard guarantee: `./mpan-install --bundle`
  is a CoW-seeded generation, mirror-only, built and activated atomically, only
  the bundle's dists rebuild, and `>=` floors make it `max(local, bundle)` -
  never a downgrade. That is exactly the "atomic incremental raise-only realise"
  the live path fails to be.
- Consequences: `upgrade --from` is retired; the peer-raise becomes a bundle
  producer (e.g. `mist bundle from <peer> --all`, or an `inject --from --all`),
  sibling to `--full-dependency-tree`. `inject` sheds its one non-inject behavior
  (`--full-dependency-tree`, which writes a bundle and does not install), so it
  means exactly one thing again. Producer contract: vendor the tarballs AND write
  the floors, as one unit, or the bundle is dangling.

This resolves tensions 1, 2, and 4 at once: no verb straddling two targets (it is
a mirror-side producer, silent about `perl5`); no bespoke live realise (the
`--bundle` apply owns atomicity and raise-only); the output is a named, auditable,
fleet-portable erratum rather than a firehose.

## Open questions

- Is the bundle-producer reshape worth it, or is `upgrade --from` (index diff +
  `--vendor-only` + `./mpan-install --rebuild`) enough in practice? (Unconvinced.)
- Naming/home for the producer: `mist bundle from`, `mist fast-forward`,
  `inject --from --all`?
- Does plain `mist upgrade` (mirror -> env) still earn its place now that atomic
  `--rebuild` exists?
- Is raise-only/intersection-only the right semantics, or does a true wholesale
  toolchain adoption want full match (including the peer's extras, and its
  deliberate downgrades)? For the twin fast-forward case it fits; in general it
  may be a half-measure.

## Meanwhile

Dogfood `upgrade --from` on the exparo <- sig fast-forward. Real usage there is
the signal that should decide whether the bundle-producer reshape earns its keep.
The index-diff / `_raise_plan` / `_vendor_raise` engine stands regardless of where
it eventually lives.

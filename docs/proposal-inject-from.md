# Proposal: `mist inject --from <peer>` - source a target and its dependencies from a peer's golden mirror

## TL;DR

Two independent projects, A and B, are pure peers - no dependency relationship.
A hit a CVE whose fix required upgrading a constellation of CPAN modules to a set
of versions that actually co-install and pass tests: real dependency-hell
spelunking. A's `mpan-dist` is now the durable artifact of that work - a resolved,
test-passed version set. Months later B needs the same fix. Today B must either
redo the spelunking against live CPAN (current tips, never tested together) or
`mist merge A` (wrong - it folds A's whole set and records a false "B depends on
A" contract). `mist inject --from ../A Foo::Bar` would let B reuse A's *solution*:
pull the target and its dependencies from A's mirror, mirror-only and fail-loud,
recording nothing about A - because there is no A->B relationship to record. B's
own `cpanfile` pin (with the CVE reason) is the only durable record, and the
correct one. It ships and is useful on its own; the same `--from` flag later
composes onto `inject-deps` (proposal-inject-deps.md) for the bulk case.

## Where this came from

A concrete war story, not a hypothetical. Peer A resolved a CVE by working out
which versions of a dependency cluster install and test together - the expensive,
error-prone part. The valuable thing that work produced is not a tarball, it is
A's *solution to a constraint-satisfaction problem*, frozen in A's `mpan-dist`.
Peer B, developed independently, later needs the same currency fix. Re-deriving it
against live CPAN means re-doing the spelunking against moving tips that A never
validated as a set. Borrowing A's already-resolved versions is strictly better -
if there were a verb for it.

## The gap, precisely

- **`inject` resolves against CPAN.** Its cpanm list ends in
  `--mirror http://www.cpan.org/` with `mirror_only` off
  (`Mist::PackageManager::MPAN::cpanm_install_options`). You get current tips and
  cannot point it at a peer's vetted set.
- **`merge` can add a peer mirror, but only wholesale.** `merge.pm:79` does
  `add_mirror( file://<peer>/mpan-dist )` with `mirror_only => 1` and
  `--cascade-search` - exactly the offline-peer-mirror mechanism this needs - but
  it resolves the peer's *entire declared set* and splices a `merge` block into
  B's `mistfile`, asserting an ongoing "B is downstream of A" contract. For pure
  peers sharing a one-time CVE fix, that contract is a lie and the whole-set pull
  is unwanted.
- So there is no operation for "source *this* target and its dependencies from *that*
  peer's mirror, as a one-time currency pull, recording no relationship."

## The command

`mist inject --from <path> <target>`, run from B's project root:

1. Build the package manager as `inject` does, but with `mirror_only` on and
   `add_mirror( file://<path>/mpan-dist )` - the two calls `merge` already makes.
2. `install( <target> )` - `inject` already forwards positional args straight to
   cpanm's install, so no new target handling is needed.
3. `commit()` `--save-dists` the resolved tarballs into B's `mpan-dist` and
   reindex - identical to `inject`.

It does **not** touch the `cpanfile` (same as `inject`: you add the `requires`
pin, with the CVE reason - that pin is the only durable, correct record). It does
**not** touch the `mistfile` (the difference from `merge`: there is no peer
relationship to record). `--from` takes a peer *project root* (it uses
`<path>/mpan-dist`, like `merge`) and is repeatable, layering peer mirrors in
order. `Context` is not path-parameterizable, so the mirror path is constructed
directly, again as `merge` does.

### Target is any cpanm spec - name or tarball

`<target>` is whatever cpanm install accepts: `Foo::Bar`, `Foo::Bar@2.0`,
`Foo::Bar~">=2.0"`, `AUTHOR/Foo-Bar-2.0.tar.gz`, a local tarball, a URL. `--from`
is orthogonal to the form; what it *does* differs slightly:

- **Module-name target:** `--from` resolves the target (name -> tarball via the
  peer's `02packages`) and its transitive deps. This is the ergonomic win: name
  the module, don't hand-type the AUTHOR path.
- **Tarball target:** cpanm installs that exact file as the target; `--from` then
  only resolves its transitive deps.

### Sourcing: mirror-only is the contract, not a style choice

The guarantee is "you get A's vetted versions, or an error." A silent live-CPAN
fallback for a dep missing from A's mirror would smuggle an untested version into
B's dependency tree - exactly the franken-set B is trying to avoid. So `mirror_only` stays
on and the mirror list is B's mirror plus the peer(s) only, with **no** live-CPAN
entry; a gap is a loud failure. B is borrowing A's solution and must get it intact
or not at all. (This is the deliberate inverse of `inject-deps`, which *should*
reach CPAN, because it reconciles a project to its own declared contract.)

### Currency by highest-version-wins (exact alignment is a non-goal)

B's own mirror is listed first, the peer's second; the indexer's
highest-version-wins (`Mist::Role::CPAN::PackageIndex`) means `--from` raises B to
at least A's golden versions across the overlap, and never downgrades what B
already vendors. This is not an approximation of "reproduce A's set" - it is the
intended result. Exact alignment to A is deliberately *not* the goal, for two
reasons:

- B may already carry a higher version for its own good reasons; nothing should
  pull it back.
- B may depend on something *not in A at all* that requires an even newer version
  of a shared dep than A's golden mirror holds. Forcing A's exact (lower) version
  would make B's graph unsatisfiable. Taking the max of B's own constraints and
  A's vetted floors is the only resolution that keeps B's graph buildable.

So `--from` is a constraint *merge* - max(B's needs, A's vetted floors) - not a
snapshot overwrite. A version A deliberately held *down* is honoured only while
nothing in B's own graph needs it higher; if B does, B's need wins, which is
correct - B's graph is the one that must build and test, not A's.

## How it relates to `inject-deps` and `merge`

`--from` is "where do tarballs come from" (override the upstream); the command is
"what to resolve." That factoring gives a clean family:

- **`inject --from <peer>` (this proposal)** - consumer-side, surgical,
  peer-sourced, mirror-only. The common CVE/currency pull. **Ships standalone.**
- **`inject-deps --from <peer>` (future, additive)** - the bulk form: B bumps its
  cpanfile pins for a sweep, then reconciles the whole declared dependency tree against
  A's golden mirror in one idempotent pass. Pure reuse of the same `--from`
  mechanism on `inject-deps` if/when it lands (proposal-inject-deps.md).
  `inject --from` does **not** depend on it.
- **`inject-deps` (no `--from`)** - owner-side: reconcile a project to its own
  cpanfile, reaching CPAN for genuinely new tarballs.
- **`merge` / merge-cascade** (proposal-merge-dep-propagation.md) - for *actual*
  downstream relationships between related dists, where recording the contract is
  the point. Not for pure peers.

The `merge` contrast is the one that bites: `merge` and `inject --from` both add a
peer's mirror (`merge.pm:79`), but `merge` is for a real downstream relationship
(it folds A's whole set and records a `merge` block - the contract), whereas
`inject --from` is for pure peers and records nothing about A.

## Rejected alternatives

- **A subset mode of `merge`.** `merge`'s identity is fold-the-whole-set and
  record-the-merge-block. For pure peers that block is a false contract and the
  whole set is unwanted. Keep `merge` for real downstream relationships; put the
  surgical peer pull on `inject`.
- **A brand-new command (`graft` / `adopt`).** Unnecessary surface: this is
  `inject` with the upstream swapped. `add_mirror` and `mirror_only` already
  exist; the flag is the whole feature.
- **Gating delivery on `inject-deps`.** The surgical pull is independently the
  common case; shipping `inject --from` first, with `inject-deps --from` as a
  later bonus, is the right order.

## Speculative extension: `--full-dependency-tree`

A later, opt-in mode that changes *how much of the target's dependency tree* `--from`
raises. Plain `inject --from` respects declared requirements: it pulls a dependency
up only when the target's metadata forces it, so a dep B already satisfies at an
older version stays put. `--full-dependency-tree` instead raises *every* module in
the target's dependency tree to at least the peer's version.

Why it is worth having: A's mirror is not just somewhere to fetch a tarball, it is
the record of a *solved problem*. A discovered, through the spelunking, the set of
versions that make the fix actually install and pass tests - knowledge that lives
nowhere in the dependency metadata, which is deliberately loose (`>= 1.0`) because
authors cannot predict the future. Respecting only those loose declarations can
hand B a combination that satisfies the metadata yet reproduces none of A's
discovery, re-shipping the very breakage A already fought through.
`--full-dependency-tree` chooses to trust A's empirically-resolved set over the
optimistic declarations.

It inherits A's versions as *floors*, not as a clone. B's own graph still wins
wherever it needs more: B may depend on something A never had that requires a newer
version of a shared module than the golden mirror holds, and forcing A's lower
version would make B's graph unsatisfiable. So this is `max(B's needs, A's vetted
floors)` across the dependency tree - raise-only, never downgrade. Exact reproduction of
A's set is explicitly a non-goal, not a deferred feature: A's resolution is
knowledge to raise *toward*, not a cage to lock into.

It is a deliberate, rarely-reached-for rebaseline, which is why the flag name is
long and fully spelled: it should read unmistakably at the call site and never fire
by reflex. The everyday move is the surgical single-target `inject --from`.

`--full-dependency-tree` does not apply the raise to the live environment itself; it
is the first **bundle** producer. Its clean-room vendor pass resolves the tree at
the peer's floors, vendors the tarballs into `mpan-dist`, and emits the floor set as
an ephemeral bundle. Producing, publishing and applying that bundle - including the
incremental, atomic `./mpan-install --bundle <id>` apply that avoids a full
rebuild - are described in proposal-bundles.md.

## Notes

- Implementation is small: a `--from=s@` option on `inject.pm`, and in `execute`
  set `mirror_only` and call `add_mirror` for each `--from` before `install`.
  Everything downstream (dependency-tree walk via `--save-dists`, reindex via `commit`) is
  reused unchanged. Verify the mirror_only path produces a cpan.org-free mirror
  list (as `merge` already does) so fail-loud actually holds.
- A `--dry-run` (print the would-be-vendored delta without `--save-dists`) is a
  cheap pre-flight: "what would I pull from A."
- Worth a test: B already holding a *higher* version of a shared dep than the peer
  (confirms highest-wins: B keeps its newer version, no downgrade); a B-only dep
  that requires a shared dep newer than the peer's golden version (confirms the
  constraint merge resolves to B's need, not A's floor); and a dep genuinely
  missing from the peer mirror (confirms fail-loud, no CPAN fallback).

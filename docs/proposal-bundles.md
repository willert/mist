# Proposal: bundles - portable, named dependency errata

## TL;DR

A *bundle* is a small set of pinned dist specs - "these versions, applied as a
unit" - mist's equivalent of a distro security erratum (RHSA-2026-xxxx: "these
package versions fix these CVEs, apply across your fleet"). A producer (today
`inject --full-dependency-tree`) drops an ephemeral, UUID-named bundle under
`~/.mist/<project>/bundles/`. When one is worth keeping, `mist bundle publish`
copies it into the committed `mpan-dist` mirror under a chosen name, where it
travels with the project and applies on any machine - including production boxes
that have only `./mpan-install` and no `mist` - via `./mpan-install --bundle <id>`.
The motivating line is "bundle `cve-2026-xx` fixed CVE-2026-xx": a named,
reproducible, auditable dependency change you carry to every machine.

## Where this came from

It started smaller. `--full-dependency-tree` (proposal-inject-from.md) needed an
*apply* step that did not force a full `./mpan-install --rebuild`, so it would emit
the resolved floor set to a file and hand it to a targeted install. Deciding where
that file lived surfaced the real insight: the file is not scratch. "The set of
versions that fixed CVE-2026-xx" is valuable on its own - across machines, across
time, as an audit record. The moment a bundle is a thing you cite and re-apply, it
stops being an ephemeral handoff and becomes a first-class, portable artifact. This
proposal is that artifact; `--full-dependency-tree` is demoted to one *producer* of
it.

## What a bundle is

A bundle is a set of dist specs expressed as **floors** (`Module~">= 2.0"`), so
applying it never downgrades a machine that is already ahead - the result is
`max(local, bundle)` per dist (the same no-downgrade semantics
`--full-dependency-tree` relies on). It is *not* a full lockfile: Carton's
`cpanfile.snapshot` pins the whole closure; a bundle is the *named partial change* -
the erratum, not the whole world. Whole-closure reproducibility stays the committed
`mpan-dist` mirror's job.

A bundle exists in one of two states, and those states are the whole lifecycle.

## Lifecycle: produce, publish, apply

**Produce (ephemeral).** A producer writes the resolved floor set to
`~/.mist/<project>/bundles/<uuid>`: a pure spec list, identified by an opaque UUID,
with **no metadata**. It is automatic, throwaway, and never travels. Metadata at
produce time is no better than metadata at publish time, so the ephemeral form
carries none; the UUID is collision-free across peers, runs and perls, and a fix is
always a new bundle, never an edit of an old one. Producers today:
`inject --full-dependency-tree`. A manual "freeze these dists" is a plausible
second, and the format is trivial enough that any process can emit one.

**Publish (durable).**
`mist bundle publish <uuid> --as "cve-2026-xx" [--description "..."]` copies the
spec list into the committed mirror at `mpan-dist/bundles/<name>` and attaches the
human metadata *here* - the name, an optional description, the publish timestamp.
This is the deliberate "this set is worth keeping" act, and the only point at which
a bundle gains a name or any meaning. Name collisions are left to git: publish just
writes the file, so an overwrite is a tracked modification you review before
committing and can revert from history - no `--force` ceremony, and re-defining a
published bundle is simply a reviewed commit.

**Apply (host-side).** `./mpan-install --bundle <id>` is the single apply
primitive. It resolves `<id>` against `mpan-dist/bundles/<id>` first (a published
*name*, committed, found on any box) and then `~/.mist/<project>/bundles/<id>` (an
ephemeral *UUID*, found on the box that produced it). The two are distinct
namespaces, so one flag covers both. It installs the floors mirror-only into a
fresh CoW-seeded generation: incremental (only the bundle's dists rebuild), atomic,
no full closure rebuild, never reaching live CPAN. `inject` prints the ready line
(`apply with: ./mpan-install --bundle <uuid>`); `./mpan-install $(cat …)` remains
the fallback for an installer too old to carry `--bundle`.

## A bundle is coupled to its mirror

A bundle names versions; those tarballs must be in the `mpan-dist` that travels
with it, or it is a lockfile pointing at tarballs nobody has - exactly like a
`cpanfile` pin is only buildable once its tarball is vendored. The convenient part:
the `--full-dependency-tree` producer's clean-room vendor pass already vendors
those tarballs into `mpan-dist` as a side effect, so producing the bundle and the
mirror state that makes it reproducible is one operation.

Two properties keep a published bundle from rotting:

- Because the specs are **floors**, apply resolves `>= floor` against whatever
  currently satisfies it in `mpan-dist`, not the exact tarball the bundle was born
  with. A later supersession - and a `mist clean` of the old tarball - still leaves
  a satisfying version, so the erratum stays applicable as the mirror moves forward.
- `mist clean` never touches the bundle files: it GCs only `authors/` and
  `vendor/`, so `mpan-dist/bundles/` is outside its reach.

## It does not replace the `cpanfile`

The `cpanfile` stays the declared contract - "we require Foo >= 2.0, because
CVE-2026-xx". A fresh clone still builds correctly from `cpanfile` + the committed
`mpan-dist` with no bundle in sight. A bundle is the *transport and incremental
apply* of an already-resolved set: it is what lets an already-built box, or a whole
fleet, take the fix without a full rebuild, and what makes the change a named,
auditable unit. Bundle and `cpanfile` answer different questions - "apply this
resolved set now, here" versus "what do we declare we depend on" - so a bundle is
complementary, never a second source of truth.

## How it relates to the other proposals

- **proposal-inject-from.md** - `--full-dependency-tree` is the first bundle
  *producer*; its extension section points here for the apply and transport story
  rather than carrying its own.
- **proposal-inject-deps.md / proposal-merge-dep-propagation.md** - the declared-pin
  workflow (cpanfile -> reconcile -> release -> merge cascade) is unchanged; bundles
  sit downstream of it as a fleet-apply and audit layer, not a replacement.
- **proposal-atomic-perl-env-activation.md** - apply rides the generations
  machinery already in place: a bundle install is a targeted generation build,
  atomic and rollback-able like any other.

## Rejected alternatives

- **Semantic filenames for the ephemeral form.** They collide, imply
  one-per-something, and go stale. Opaque UUID for the transient; a chosen name
  only at publish.
- **`~/.mist`-only storage.** Fine for the ephemeral handoff, useless on a prod box
  that has neither `~/.mist` nor `mist`. A durable bundle must be published into the
  committed mirror to travel.
- **A bundle as a full lockfile.** Whole-closure reproducibility is the committed
  `mpan-dist`'s job; a bundle is the named partial change, the erratum.
- **A bundle as a `cpanfile` replacement.** It transports and applies a resolved
  set; it does not declare dependencies. The `cpanfile` remains the contract.

## Notes / open questions

- **File format.** A self-describing single file (a metadata header plus floor-spec
  lines) keeps the erratum together, but then the raw `$(cat …)` fallback must strip
  the header (`grep -v '^#'`) while the `--bundle` reader owns the parse. A
  spec-file plus sidecar-metadata split keeps `$(cat …)` trivial but separates the
  two. Decide alongside the `--bundle` reader. (Ephemeral bundles carry no metadata,
  so the question only bites for published ones.)
- **Host-side resolution.** `--bundle` must compute `~/.mist/<project>/` itself -
  the same `lc(project_root)`, `\W -> _` derivation Context uses, off
  `$Bin` / `$MIST_APP_ROOT` plus `$HOME` - and sanitize `<id>` as a path component
  against traversal, the guard `release` already applies to its candidate ids. It is
  host-side, so `--bundle` is fatpacked and needs `compile` + re-vendor.
- **UUID source.** Needs a UUID dep if one is not already vendored (Data::UUID /
  UUID::Tiny), or reuse whatever `release` uses for candidate ids, for consistency.
- **The `mist bundle` verbs.** `publish` is the first. `list` / `show` / `prune`
  follow if a second producer or fleet ergonomics warrant them; start minimal.
- **GC.** Ephemeral bundles under `~/.mist` prune freely; published ones are
  committed history, permanent like any committed artifact.

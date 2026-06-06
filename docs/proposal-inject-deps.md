# Proposal: `mist inject-deps` - reconcile a mirror to its declared cpanfile closure

## TL;DR

There is no single command that makes a project's `mpan-dist` satisfy its own
`cpanfile`. Adding or bumping a `requires` pin and then expecting `./mpan-install`
to work assumes the pin's tarball *and its full install closure* are already
vendored - but nothing put them there. Today you reach for a per-module
`mist inject 'Module@version'`, once per pin, and hope you caught every new
transitive dep the bump dragged in. `mist inject-deps` would do it declaratively:
read the cpanfile, resolve the full install closure, and `--save-dists` whatever
the mirror is missing. One idempotent command, no per-module bookkeeping, no
hand-reconstructing closures.

## Where this came from

A cross-repo currency sweep (the WeCARE / Exparse de-hack). The intended-correct
workflow for modernizing a transitive dep is the one the merge-cascade proposal
assumes: pin the dep in the dist that owns it, vendor it, release, and let
consumers pick it up on merge (see proposal-merge-dep-propagation.md, the "Not our
bug" section - "bump its mirror and add `requires ...`"). The "bump its mirror"
half of that is the manual, error-prone step. During the sweep it failed
concretely: bumping `Sub::Attribute` 0.05 -> 0.07 silently introduced a new
runtime dep on `Class::Trigger`; a per-module tarball copy did not bring it; the
from-scratch build broke; and recovery degenerated into hand-parsing `META.json`
to reconstruct the closure. A reconcile-to-cpanfile command removes that entire
failure class - and removes the temptation to go below mist (see the "stay above
mist" guardrail in SKILL.md, which this proposal is the missing-feature answer to).

## The gap, precisely

`mist inject 'Module@version'` is *imperative and per-module*: it stages one dist
plus its deps. There is no *declarative, whole-cpanfile* operation: "given my
current cpanfile (every `requires` across every phase), ensure my `mpan-dist`
holds the complete install closure, pulling only the missing tarballs." So:

- Editing a cpanfile to add a pin does not update the mirror; the two are kept in
  sync by hand. `mist compile` + `./mpan-install` then *fails* if the mirror is
  short - the mirror is the only install source, and mpan-install does not vendor.
- A bump that drags in a new transitive dep (Class::Trigger) needs that dep
  injected too - but you only learn which from a failed from-scratch build, one
  missing dep per round.
- Re-vendoring a hand-edited multi-pin cpanfile means N manual injects, and any
  one forgotten leaves an unbuildable mirror that still passes a warm/incremental
  run.

## The command

`mist inject-deps`, run from a project root:

1. Parse `cpanfile` - every `requires` (and configured `recommends`), all phases.
2. Resolve the full *recursive* install dependency closure for those requirements.
3. Diff the closure against what `mpan-dist`'s `02packages` already indexes
   (treating a cpanfile floor like `>= 2.35` the same way `./mpan-install` does,
   so "satisfied" means the same thing in both).
4. `--save-dists` the missing / under-version tarballs into
   `mpan-dist/authors/...` and re-index, exactly as `mist inject` does per dist.

Idempotent: a second run is a no-op. Resolution should reuse `mist inject`'s
existing cpanm plumbing and mirror configuration - this is `inject` lifted from
"one module argument" to "the cpanfile is the argument".

### Sourcing - mirror-first, CPAN for genuinely new tarballs

Like `mist inject`, resolution may reach live CPAN for a tarball no mirror holds
yet - that is how a brand-new pin gets vendored the first time. This is distinct
from the `mist merge` cascade, which is deliberately mirror-only (it must never
invent a cross-repo dependency from live CPAN). `inject-deps` operates on the
project's *own declared* contract, so pulling a declared dep from CPAN is correct,
not contract invention.

## How it relates to the merge-cascade proposal

Complementary, not overlapping:

- **proposal-merge-dep-propagation** - the *consumer* side: on `mist merge S`,
  honor `S`'s declared pins by cascading resolution among the curated mirrors.
  Cross-repo, mirror-only.
- **inject-deps** - the *owning-dist* side: make a dist's own mirror satisfy its
  own cpanfile. In-repo, on demand.

Together they make the declarative-pin workflow seamless end to end: pin in the
owner's cpanfile -> `mist inject-deps` (owner's mirror follows) -> release ->
`mist merge` cascade (every consumer follows). No tarball is ever touched by hand;
the cpanfile is the single source of truth at each hop.

## Rejected alternative: fold it into `mist compile`

Tempting to have `mist compile` reconcile the mirror as a side effect. Rejected:
`compile` is a pure `cpanfile` + `mistfile` -> `mpan-install` transform with no
network and no mirror mutation; people run it constantly and must be able to trust
it not to reach out or change vendored state. Keep mirror mutation in an explicit,
separately-invoked verb (`inject`, `inject-deps`, `merge`).

## Notes

- Scope check before building: confirm whether `mist inject` already vendors the
  *full recursive* closure of a single dist or only its direct deps. inject-deps'
  resolver must be recursive regardless; if `inject` is already recursive, this is
  largely a front-end that feeds it the cpanfile's requirement set.
- A `--dry-run` (print the missing-tarball delta without vendoring) would make it
  safe to run as a pre-release check: "is my mirror complete for what I declare?"

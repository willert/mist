# Proposal: growing the release-candidate mechanism

Status: SKETCH, parked 2026-08-07. Nothing here is designed, let alone
committed; this records the directions so they are not re-derived. Origin:
the erb 0.0300 release, where the dry-run -> candidate -> promote flow
worked well enough that the wish "skip clean-room work for minor releases
in exchange for a promise the build environment didn't change" turned out
to be already implemented - with the promise upgraded to a proof. The
sketch below asks what else that proof could carry.

## The load-bearing idea

A candidate is a validated build plus a fingerprint (cpanfile, mistfile,
mirror index, perl version, archname) that refuses reuse when the world
changed. That is the general shape of "trust an earlier expensive step":
never a promise, always a verified fingerprint. Everything below is that
one idea pointed at a different expensive step.

## Directions

1. **Fingerprint-keyed candidate cache.** Today each dry-run deletes every
   prior candidate; reuse is dry-run -> promote, once. Keyed by
   fingerprint instead, any later release whose environment matches an
   existing green candidate reuses its closure - the "minor releases skip
   the install" wish, generalized across releases, with staleness decided
   by the fingerprint rather than by anyone's memory. Open question:
   eviction (candidates hold a full contained lib each).

2. **Candidates as CI currency.** A dry-run per push turns the release
   queue into a shelf of validated builds; releasing becomes promoting a
   green candidate. The gate stays where it is - promotion is still the
   release-gated act - but the expensive validation has already happened,
   asynchronously, before anyone asks.

3. **Multi-perl candidates.** The dual-perl validation pattern (pinned
   prod perl beside the next target) as first-class candidates: one
   dry-run per perl, promotion available only when every fingerprinted
   build is green. The fingerprint already carries perl version and
   archname, so the identity model needs nothing new.

4. **Candidate as deploy artifact.** The validated contained lib is a
   built environment; a generation is a built environment; the distance
   between "validated at release" and "activated on the host" is smaller
   than the current tooling admits. A promoted candidate that could ship
   as (or become) a host generation would close the loop from clean-room
   to production with one identity throughout. This one is the largest
   and vaguest - it touches bundles, generations and the host installer -
   and is listed so the shape is on record, not because it is next.

## What stays out

Skipping the clean-room DistTest itself (the suite against the extracted
tarball) was considered at the origin and argued down: its unique catch is
the missing-file class - a new template or revved asset absent from the
dist - which environment sameness cannot vouch for, and which minor
releases produce as readily as major ones. The install is the expensive
part and is already skippable; the tarball check earns its keep.

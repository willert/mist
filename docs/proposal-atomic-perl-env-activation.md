# Proposal: symlink-based perl env activation, switch-guard, and atomic installs

## TL;DR

mist already stores multiple perls side by side (`perl5/perl-<ver>-<arch>/`,
`--perlbrew=X`, `mist run --perlbrew`). What is single-valued and fragile is the
*activation layer*: the generated `mist-run` wrapper and `mist.mistrc` are global
files, rewritten in place to whichever perl last ran `mpan-install`. Three pains
follow - building an alternate perl hijacks the live runtime, a bare install can
silently switch the active perl, and an install bricks the env for the whole
build (truncate-to-stub up front, real wrapper only at the very end).

Fix it in a three-step ladder:

1. **Symlink activation + switch ergonomics.** `perl5/bin/mist-run` becomes a
   symlink to per-perl bodies; each body sources its own per-perl rc. Add a
   switch-guard on *implicit* perl changes, a `--build-only` flag, and delete
   `--all-available-versions`. Cross-perl switches become atomic for free (different
   perls already live in different dirs); same-perl in-place refresh keeps the honest
   loud-fail.
2. **Harden the CoW primitive + build a test harness.** The `--branch`/`--parent`
   copy-on-write path exists but is virtually untested. Prove it in isolation -
   atomicity, rollback, the perllocal append leak - before trusting it.
3. **Promote generations to the default install path.** The active lib dir becomes a
   symlink to a CoW generation; every install builds a new generation and swaps
   atomically on success. This is where same-perl atomicity lands and the step-1 loud
   stub becomes unnecessary.

The organizing idea throughout: **separate Build from Activate**, and make Activate a
single atomic symlink repoint.

## Where this came from

A design session on "how should mist support multi-perl installs." The conclusion
was that the storage layer is already multi-perl; the real, felt problems are in
*activation* and *install atomicity*. The bigger "build a declared matrix / run tests
across perls" ideas were explored and deliberately dropped (see Rejected
alternatives) - the work that earns its keep is the activation rework below.

## Current state: storage is multi-perl, activation is not

Already multi-perl, no change needed:

- Lib dirs are per-perl: `perl5/perl-<ver>-<arch>/` (install.pm:74-78). This repo's
  own `perl5/` holds 5.20.3, 5.38.2 and 5.42.2 concurrently.
- `Context::_build_local_lib` resolves the lib dir through a symlink if it is one
  (Context.pm:170-177, `readlink` at :174) - so the infrastructure for "active lib
  dir is a symlink" already exists.
- `./mpan-install --perlbrew=X` builds a per-version env; `mist run --perlbrew=X`
  runs a command under a side-built env, bypassing the wrapper (run.pm:38-68).

Single-valued and the source of the pain:

- The generated wrapper `perl5/bin/mist-run` and `perl5/etc/mist.mistrc` are global
  files. `$p5_dir` is `realpath($local_lib/..)` = `perl5/` (install.pm:210), so both
  hang off the shared root, not the per-version dir. Every install overwrites them,
  baked to the *running* perl (wrapper `VERSION_ARCH_PATH` at install.pm:333; rc
  `PERLBREW_DEFAULT_VERSION` at perlbrew.pm:172). Last-writer-wins.
- The mistfile `perl` line is the only declared perl; everything else falls out of
  "whichever perl last ran `mpan-install`."

## The three pains, concretely

1. **Building an alternate perl hijacks the live runtime.** `./mpan-install
   --perlbrew=5.42.2` while you work on 5.20.3 rewrites the global wrapper/rc to
   5.42.2. Bare `./mist-run` now silently runs 5.42.2, and a still-active 5.20.3 shell
   that shells out to the new wrapper mixes `@INC` across perls (the
   `Sub::Identify.so: undefined symbol` class of XS failure). Recovery is a full bare
   reinstall.

2. **Bare install can silently switch the active perl.** Bare `./mpan-install`
   re-execs under the embedded mistfile default. On a host deployed on a non-default
   perl, that silently reverts the active perl with no warning.

3. **Installs are not atomic - the env is bricked for the whole build.** The very
   first steps truncate `mist.mistrc` (install.pm:214) and `mist-run`, writing a stub
   (install.pm:218, 226-231: `echo "FATAL: Mist environment not fully installed"; exit
   1`). The real wrapper/rc are written only at the end (install.pm:285-342), after the
   entire cpanm closure builds (where failures actually happen). Any mid-build failure
   leaves the stub - bricked until a fully successful reinstall. The final swap itself
   is `unlink` then `symlink` (install.pm:346-349), a non-atomic window.

## Core design: Build vs Activate, one symlink pivot

- **Build(X)** = populate `perl5/perl-X-arch/`, write the per-perl wrapper body
  `perl5/bin/mist-run-perl-X-arch`, and write the per-perl rc
  `perl5/etc/mist.mistrc-perl-X-arch`. Additive, idempotent, touches no other perl and
  no active selection.
- **Activate(X)** = atomically repoint the single selector `perl5/bin/mist-run` at
  X's body (symlink-to-temp then `rename`).

The wrapper body sources its *own* per-perl rc by baked path (today the body already
bakes `MIST_ENV` and runs `source $MIST_ENV`, install.pm:315/331 - just bake the
per-perl rc path instead of the shared one). So the rc rides through the body, and the
*single* wrapper-symlink repoint is the atomic switch for the entire executed
environment. The stable `perl5/etc/mist.mistrc` stays a symlink to the active per-perl
rc, but only as a convenience alias for the manual `source perl5/etc/mist.mistrc`
surface - never as an independent second selector (that would open a mid-switch window
where the wrapper resolves X but the rc still resolves Y).

The root `./mist-run` symlink and the `perl5/{bin,sbin,script}/<name>` shims are
unchanged: they already funnel through the `perl5/bin/mist-run` name, which now happens
to be a symlink they follow transparently. The bodies use the baked absolute
`MIST_ROOT`, not `$0`, so following a symlink does not disturb root resolution.

`readlink perl5/bin/mist-run` is then the robust, inspectable answer to "which perl is
active" - which the switch-guard reads, and which `ls -l` shows at a glance.

## The ladder

### Step 1 - symlink activation + switch ergonomics

Delivers multi-perl coexistence, safe and inspectable switching, the Build/Activate
split, and atomic *cross-perl* switching. Makes no atomicity claim for the same-perl
case. Touches none of the risky CoW path.

- `perl5/bin/mist-run` becomes a symlink to per-perl bodies; bodies source their own
  per-perl rc (above).
- **Switch-guard.** Resolve the target perl (precedence: `--perlbrew` flag > current
  active read via `readlink` > embedded mistfile default). If a *bare* install would
  change the active perl (target differs from the current symlink target), it is an
  *implicit* switch: on a tty, prompt `This workdir runs on <cur>, switch to <new>?
  [y/N]`; non-interactively, die loudly. Explicit `--perlbrew=X` is itself the
  confirmation - no `--force`/`--yes` flag. Check *before* the perlbrew re-exec
  (perlbrew.pm:118-137 / Context.pm:289-306), or a rejected switch wastes a full
  closure build. Compare at version level (arch is not resolved until after the
  re-exec). A fresh workdir has no symlink, so first install is never guarded.
- **`--build-only`.** Do Build(target), skip Activate. The per-perl body is still
  written (it is a build artifact); only the symlink repoint and rc alias are skipped.
  Bypasses the guard by construction (nothing switches). This is the "build beside,
  never disturb the active perl, never prompt" mode for dev and CI.
- **Delete `--all-available-versions`** (install.pm:22-27, 51-65) and its doc
  (usage.pm:27, 29-30). Keep `list_available_perl_versions` - it looks dead but is
  still used by `assert_availability_of_requested_perl_version` (perlbrew.pm:97). This
  also removes the only internal caller that does a bare `system $0 => @ARGV` reset
  pass, so the guard needs zero internal exemptions.
- **Cross-perl switching is atomic here, for free.** `--perlbrew=xxx` where xxx is not
  the active perl builds into xxx's own dir, body and rc - the active env's lib dir,
  body and rc are never touched - and repoints the symlink only on success. Different
  perls already live in different dirs, so this is *complete* atomicity, not the
  vetoed half-measure: there is no shared state to leave inconsistent. On failure the
  symlink never moves and the active env is exactly as it was.
- **Same-perl in-place refresh keeps the loud stub.** Re-installing the *currently
  active* perl still mutates its one lib dir live, so it retains the honest
  FATAL-stub-during-build behaviour. Only re-install of the active perl needs it; all
  alternate-perl builds are isolated. This is the case step 3 makes atomic.

Net failure story after step 1: "every install can brick the env" becomes "only an
in-place re-install of the active perl can, and it fails loudly when it does."

### Step 2 - harden the CoW primitive + test harness

The `--branch`/`--parent` copy-on-write machinery (install.pm:80-92, `cp --link
--no-clobber --archive` from a parent dir) is the feasibility sketch for generations,
but it is extremely underused and virtually untested - treat it as a sketch in the
tree, not proven infrastructure. The same discount applies to the symlink resolution
in `_build_local_lib` (Context.pm:174) and the generic-symlink relink
(install.pm:418-428): both fire only in the branch case.

- Build the install-time failure-injection / atomicity / rollback / append-leak harness
  the project lacks. The unit suite is healthy and already reaches the install/Script
  layer (`t/script-perlbrew-stdin.t`, `t/build-cpanm-call-stack.t`, plus the parse-layer
  tests); what is missing is exercising a real `./mpan-install` against a sandbox -
  killing it mid-build and asserting generation immutability and rollback.
- Audit and fix the seed+swap primitive against the immutability invariant - or
  rewrite it to that invariant, since branch was written for dev experimentation where
  immutability was never required. The code is cheap either way (the seed is one `cp
  --link`, the swap a few lines); the cost is correctness work and tests, paid
  regardless of reuse vs rewrite.
- The first bug the harness should catch is the perllocal append leak (see Caveats).

Outcome: a CoW-generation primitive proven in isolation, not yet on the default path.

### Step 3 - promote generations to the default install path

- The active lib dir becomes a symlink: `perl5/perl-X-arch` -> generation dir
  `perl5/perl-X-arch--<id>`. `_build_local_lib` already resolves it.
- Every install is implicitly `--branch=<new generation> --parent=<current active>`:
  build a fresh generation, CoW-seeded (hard-linked) from the current one, cpanm into
  *it*, swap the lib symlink atomically on success.
- Same-perl in-place mutation disappears - whole-environment atomicity. A mid-build
  failure discards the staging generation; the active symlink never moved; the old env
  is fully intact and consistent. The step-1 loud stub for the same-perl case is no
  longer needed.
- **No GC.** Generations are immutable and permanent. CoW makes each cheap (hard links
  share unchanged files; only dists cpanm replaces cost real disk), so ~100 cycles
  over a machine lifetime cost a few hundred MB to a couple GB - noise on a server.
  Keeping every generation gives **free rollback to any prior state** by repointing the
  symlink; the symlink is the only bookkeeping. Cleanup, if ever wanted, is a manual
  `rm` of old generation dirs, never an automated GC the installer reasons about.

The two symlink layers compose and stay orthogonal: `perl5/bin/mist-run` selects which
*perl*; `perl5/perl-X-arch` selects which *generation* of that perl.

## Invariants and decisions

- **Build never activates; Activate is a single atomic symlink repoint.** Build =
  (lib dir + per-perl body + per-perl rc). Activate = (repoint `perl5/bin/mist-run`).
- **`--perlbrew=X` relinks.** On a deployed host there is no `mist`, so `./mpan-install
  --perlbrew=X` is the only lever that can switch the active perl. Explicit `--perlbrew`
  is intentional and never guarded.
- **The atomicity boundary is different-dir vs same-dir.** Switching to a *different*
  perl is atomic in step 1 (dir isolation gives it free). Rebuilding the *same* perl
  needs step 3 (CoW generations). Never ship partial atomicity that leaves a valid
  wrapper pointing at half-mutated active libs - a wrapper that "runs and lies" is
  worse than an honest loud failure.
- **One activation pivot.** The wrapper symlink is the single source of truth; the rc
  is bound through the body, and `perl5/etc/mist.mistrc` is only a convenience alias.
  No independent parallel rc symlink.
- **Multi-perl runtime stays in `mist run --perlbrew`,** not in the wrapper. Deployed
  hosts are single-perl; the host wrapper needs no dispatcher or runtime `MIST_PERL`
  selection.

## Rejected alternatives, and why

- **`mist run --all` / matrix testing via an in-tree `prove` loop.** Test suites
  assume exclusive ownership of the tree and write fixed in-tree scratch paths
  (`t/tmp/test.out`) plus host-global resources (ports, sockets). An in-tree loop
  cross-contaminates serially and races in parallel, and it cannot be fixed in-tree
  because the scratch paths live under `t/`. The only safe matrix test is hermetic,
  per-perl, DistTest-style (extract + contained lib), and even that is parallel-safe
  only for in-tree state, not host-global resources. Matrix testing, if ever built, is
  hermetic - never a run-loop.
- **`alt_perls` declared set + `--all` build.** Deferred. It is mostly informative;
  its one consumer is a reproducible set-build, with no concrete use yet. If added
  later, keep the verb neutral - do not bake test-only / merge-ignored semantics into
  the storage or the name, so a future deployment-range reading stays open.
- **`--all-available-versions`.** Removed. Over-engineered, ambient (every perlbrew
  perl on the box, not project-scoped), no users. Its legitimate kernel - build several
  perls - is recovered cleanly by a caller loop over `--perlbrew=$v --build-only`.
- **GC / retention policy for generations.** Unnecessary; CoW deltas are tiny and
  keeping all generations buys free rollback history.
- **Wrapper atomicity without lib atomicity (the half-measure).** Rejected: a valid
  wrapper over half-mutated libs runs in an unspecified environment. Loud-fail is more
  honest. All same-perl atomicity lands in step 3; only the free cross-perl case is
  atomic earlier.
- **A wrapper dispatcher / runtime `MIST_PERL` selection.** Not needed once deployed is
  single-perl and dev alternates go through `mist run --perlbrew`. Keep the host simple.
- **An independent parallel rc symlink.** Rejected: switching would be two repoints
  with a window where the wrapper resolves X but the rc resolves Y. Bind the rc through
  the wrapper body instead.

## Test plan

Step 1:

- Build an alternate perl (`--perlbrew=xxx`, xxx != active) and assert the active
  `./mist-run` still resolves the old perl throughout, then flips only on success;
  kill the build mid-way and assert the active env is untouched.
- `--build-only` writes the body and lib but does not repoint the symlink and does not
  prompt.
- Bare install that would switch the active perl prompts on a tty and dies
  non-interactively; explicit `--perlbrew` never prompts; a fresh workdir is never
  guarded.
- `--all-available-versions` is gone; `list_available_perl_versions` still resolves
  (perlbrew.pm:97 path still works).

Step 2:

- Inject a failure mid-build and assert the previous generation is byte-identical
  afterwards (immutability).
- Roll back by repointing the symlink and assert the prior env is restored.
- Assert installing into a new generation does not mutate the previous generation's
  `perllocal.pod` (the append leak).

Step 3:

- A same-perl delta-upgrade is atomic: mid-build failure leaves the old generation
  active and consistent; success swaps in one step.
- A long-running process started before a swap keeps running the old generation
  (inode pinning) and picks up the new one only on restart.

## Caveats and notes

- **The hard-link append trap.** `cp --link` shares inodes; files the installer
  *replaces* (cpanm's `.pm`/`.so`) get new inodes and are safe, but files it *appends
  to in place* - chiefly `perllocal.pod` - write through the shared inode and mutate
  the previous generation too. Break the link for append-targets before building
  (delete and let it regenerate, or copy without `--link`). Load code is replace-safe;
  this is metadata only, but it violates the immutability invariant generations rest
  on. The risk already exists latently in the `--branch` path; promoting CoW to default
  makes handling it mandatory.
- **Running-process pinning** is the good kind of side effect: a live app holds the old
  generation's inodes, so a swap does not disturb it until it restarts. GC (if ever
  added) must respect this - another reason no-GC is simplest.
- **Downstream migration.** Generated `mpan-install` is vendored downstream; the new
  behaviour reaches a project only when it regenerates. Old vendored installers keep
  the old single-wrapper behaviour. New filename schemes (`mist-run-perl-*`, generation
  dirs) do not collide with old layouts, and `perl5/` is regenerated, so a recompile
  flips a project cleanly. Mixed across projects during rollout, never within one.
- **Arch resolution by on-disk body.** Per-perl bodies are named with the full
  `perl-<ver>-<arch>` (arch baked when `$Config` is in hand at install). The active
  perl is then discoverable by listing/`readlink`, not by reconstructing arch in bash -
  which is why this design avoids the runtime `perl -MConfig` that an env-var-driven
  single wrapper would have needed.
- **`MIST_PERLBREW_VERSION` is overloaded** - it is both the re-exec guard and a
  selection carrier (perlbrew.pm:118 / Context.pm:289). If a user-facing selection var
  is ever wanted, introduce a separate `MIST_PERL` deriving the internal one rather
  than overloading the guard.

## Open sub-decisions

- The generation `<id>` scheme (counter, timestamp, content hash) and how the
  Build/Activate split threads the build-target dir vs the active symlink through the
  installer.
- Whether `--branch` is retired once generations exist, or reimplemented on top of the
  generation primitive (it should not survive as a second unproven CoW path).
- Whether to expose a no-rebuild re-activate (`--activate=X`, or a documented hand `ln
  -sf`) for switching back to an already-built perl on a deployed host without `mist`.

## Code map

- `lib/Mist/Script/install.pm` - install body. Early truncate+stub (:214, :218,
  :226-231); real wrapper/rc written late (:285-342); non-atomic swap (:346-349);
  branch/parent CoW (:80-92); generic-symlink relink (:418-428);
  `--all-available-versions` loop (:51-65); arch/lib-dir derivation (:74-78); rc/bin
  paths off the shared `perl5/` root (:210-218).
- `lib/Mist/Script/perlbrew.pm` - host re-exec (:118-137); version precedence (:37-38);
  `write_env`/rc generation (:170-198), baked `PERLBREW_DEFAULT_VERSION` (:172),
  rc env fallback (:183-187); `list_available_perl_versions` (:76, caller :97).
- `lib/App/Mist/Context.pm` - `_build_local_lib` with symlink resolution (:170-177,
  :174); `ensure_correct_perlbrew_context` + re-exec (:239-320, :289-306).
- `lib/App/Mist/Command/run.pm` - `--perlbrew` opt (:12); env clear before wrapper exec
  (:29); `run_under_perlbrew` (:38-68).
- `lib/App/Mist.pm` - BEGIN single-perl bootstrap/die (:23-32).
- `lib/Mist/Script/usage.pm` - `--prove` pairing note and `--all-available-versions`
  doc to remove (:25-30).

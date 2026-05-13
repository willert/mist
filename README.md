# App::Mist

A per-project Perl environment manager: pin a Perl version, declare your
prereqs, and ship a single self-contained installer that boots a complete
`./perl5/` from scratch on any target host.

Think of it as Carton with two extra things baked in:

1. **Perl version pinning via perlbrew** — your `mistfile` declares
   `perl '5.20.3'`; the installer ensures that exact Perl is available before
   touching any modules.
2. **A fatpacked, self-contained installer.** `mist compile` produces
   `mpan-install` — a single Perl script that embeds `cpanm`, the prereq list,
   and (optionally) a bundled CPAN mirror in `./mpan-dist/`. The target host
   needs only Perl and a C toolchain; no network access to CPAN is required
   when the bundle is used as a mirror.

The combination is what makes mist useful where Carton alone falls short:
reproducible builds on hosts that may not match your dev box's Perl, and
deployments that survive CPAN outages or removed module versions.

## The two entry points

There are exactly two commands you usually run:

- **`mist compile`** — reads `mistfile` + `cpanfile`, regenerates
  `./mpan-install`. Run this whenever you edit the mistfile or change prereqs.
- **`./mpan-install`** — the generated installer. Run this on any host (dev or
  prod) to populate `./perl5/` with the right Perl and all dependencies.
  Re-run it after `mist compile` to pick up changes.

Then, to run code under the project's Perl:

- **`./mist-run <cmd…>`** — a thin wrapper that activates `./perl5/` and execs
  the given command. Use it for `prove`, `perl`, scripts, one-offs:
  `./mist-run -- perl -Ilib -MMy::Module -e '...'`.

### Trap: never run `mist` itself through `./mist-run`

`./mist-run mist compile` looks reasonable. It is not.

`mist-run` exports the project's pinned-Perl `PERL5LIB` / `local::lib` env and
then execs its argv. The system `mist` binary has a shebang pointing at
whatever Perl is current on the box (often 5.38+), so it ends up trying to
load XS modules built for the project's 5.20. First failure is usually
`Sub::Identify.so: undefined symbol: PL_sv_no`, followed by a cascade of
`B::Hooks::EndOfScope` explosions.

**Rule:** invoke `mist` directly (it manages the project's Perl; it doesn't
run under it). Reserve `mist-run` for tools that *should* run under the
project's Perl.

## The mistfile DSL

A `mistfile` is Perl code, not data. It's eval'd in a sandbox that exposes
seven directives — these are the complete set, from
`lib/Mist/Environment.pm:8`:

### `perl '5.20.3'`

Pin the Perl version. The installer will refuse to proceed unless perlbrew has
that version available (it will tell you how to install it).

### `prepend 'Module::Name'` / `prepend 'Module::Name' => '1.23'`

Install this module *before* the cpanfile prereqs, in the order listed.
Use for modules that must be present before normal dependency resolution
(toolchain-ish things: `ExtUtils::MakeMaker`, `Module::Build`, certain
`List::Util` versions). The optional second argument is a version spec
(`'1.23'`, `'>= 1.23'`, etc.); if omitted, mist will pick up any version
requirement from `cpanfile`.

### `notest 'Module::Name'`

Install this module with `--notest`. Use sparingly — the usual reason is a
module whose test suite is broken on your target Perl or in CI environments
without a display/network/etc.

### `assert { … }`

A block of Perl that runs at install time, **before any modules are
installed**. Use it to fail fast on missing system dependencies instead of
letting `cpanm` chew through CPAN for an hour and then bomb on a missing
`mysql_config`.

The block runs in an environment where three helpers are pre-imported (no
`use` needed):

- **`check_bin("name")`** — from `Devel::CheckBin`. Truthy if the binary is
  on `$PATH`. Use for required external programs (`mysql_config`, `pg_config`,
  `pdftotext`, `qpdf`, …).
- **`assert_lib(lib => 'name', header => '...')`** — from `Devel::CheckLib`.
  Dies on failure. Wrap in `eval { } ; die "$@\n…hint…\n" if $@;` if you want
  to add a helpful "On Debian, install `foo-dev`" message.
- **`check_c99()`** — from `Devel::CheckCompiler`. Truthy if a C99 compiler is
  available. (There's no `assert_compile`; chain it with `or die` yourself.)

`Probe::Perl` is also imported into the sandbox if you need to query the
running Perl's `Config` without `use`ing anything.

Idiomatic example (adapted from `examples/mistfile.with-assertions`):

```perl
assert {
  check_c99() or die "No C compiler found";

  eval { assert_lib( lib => 'z', header => '' ) };
  die "$@\nOn Debian, try installing zlib1g-dev\n" if $@;

  assert_lib( lib => [qw/ ssl xml2 expat Imlib2 /] );

  check_bin( "mysql_config" ) or die
    "mysql_config not found — install default-libmysqlclient-dev\n";
};
```

### `merge 'Other::Dist' => sub { … }`

Pull in another mist-managed project's mistfile as a sub-distribution. Inside
the block, the same DSL applies (`perl`, `prepend`, `notest`, `assert`, plus
`dist_path`). This is how shared dependency sets between sibling repos work:
project A's mistfile `merge`s project B's, picking up B's prereqs and
asserts.

**Marker convention:** when a merge block is managed by external tooling
(e.g. generated/refreshed by a script), wrap it in marker comments so humans
and tools know not to hand-edit:

```perl
### <<<[Other::Dist] - keep this line intact
merge 'Other::Dist' => sub {
  perl '5.20.3';
  prepend 'Another::Module';
};
### [Other::Dist]>>> - keep this line intact
```

Anything between the `<<<[Name]` and `[Name]>>>` markers is a managed block.

### `dist_path 'path/to/dist'`

Only valid inside a `merge` block. Tells mist where to find the merged
project's source on disk. Resolution order (see
`App::Mist::Context::get_merge_path_for`):

1. `dist_path` relative to project root, if that exists and is readable;
2. `dist_path` relative to `$HOME`, same check;
3. Fallback: sibling-directory convention — CWD + `../` + lowercased dist
   name (`Other::Dist` → `../other-dist`).

### `script prepare => 'path/to/script', @args` / `script finalize => …`

Register a script to run before (`prepare`) or after (`finalize`) module
installation. Phases other than `prepare` / `finalize` raise an error at
parse time.

## Layout

The code is split along the build-master / host divide:

- **`lib/App/Mist/`** — the `mist` CLI itself (App::Cmd-based). Each
  subcommand is a file under `lib/App/Mist/Command/`. Start here for anything
  you'd invoke as `mist <subcommand>`.
  - `lib/App/Mist/Context.pm` is the shared object that holds project state
    (`project_root`, `cpanfile`, parsed `mistfile`, perlbrew root, …).
- **`lib/Mist/`** — the model and the host-side runtime.
  - `lib/Mist/Environment.pm` and `lib/Mist/Distribution.pm` are the
    mistfile parser and parse result.
  - `lib/Mist/Script/{perlbrew,install,usage}.pm` are the modules that get
    fatpacked into `mpan-install` and run on the *target* host. They never
    run as part of the `mist` CLI.
- **`script/mist`** — the CLI entry point (a four-line shim into
  `App::Mist->run`).
- **`mpan-install`** — the generated installer artifact. **Do not hand-edit.**
  Regenerate with `mist compile`.
- **`mpan-dist/`** — the bundled CPAN-shaped mirror of pinned tarballs.
  `mist inject`, `mist upgrade`, and `mist index` curate it.
- **`examples/`**, **`t/share/`** — sample mistfiles worth reading for the
  shape of real-world usage.

## Further reading

- `docs/workflow.txt` — the original build-master vs. host mental model.
- `docs/bootstrap.sh` and `rebuild-5.20.3.sh` — how to rebuild mist's *own*
  bundled `mpan-dist/` when the chicken-and-egg installer itself is broken.

## Authors

Sebastian Willert &lt;s.willert@wecare.de&gt;

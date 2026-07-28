#!/bin/sh
#
# Regenerate share/cpan-outdated - the self-contained cpan-outdated that
# `mist upgrade` runs to decide which installed modules lag behind mpan-dist.
#
# THE TRACE MUST EXERCISE A file:// MIRROR. `fatpack trace` records only what the
# script actually loads on the run it observes, and mist always passes a file://
# mirror. Tracing against the default http mirror is what shipped a broken script
# for years: LWP::Protocol::file rode into the bundle on LWP::Protocol's packlist,
# but its own load-time requires (LWP::MediaTypes, HTTP::Request/Response/Status/
# Date) were never traced, so `require LWP::Protocol::file` died with "Can't
# locate" - which LWP::Protocol::implementor silently reads as "no handler for this
# scheme" and reports as "501 Protocol scheme 'file' is not supported".
#
# cpan-outdated 0.32 no longer uses LWP at all (it reads a file:// index straight
# off disk), but the rule is what keeps this honest for whatever gets loaded
# dynamically next: URI loads its scheme classes exactly the same way, hence the
# explicit --use=URI::file too.
#
# Needs App::FatPacker, a build-master-only tool that is deliberately not a mist
# dependency. Install it into a throwaway lib rather than the project env:
#
#   cpanm -L /tmp/fatpack-lib App::FatPacker
#   PERL5LIB=/tmp/fatpack-lib/lib/perl5 PATH=/tmp/fatpack-lib/bin:$PATH ./pack.sh
#
# MIST_ROOT must name a project whose mpan-dist and perl5 the trace can read.
set -e
cd "$(dirname "$0")"

MIST_ROOT="${MIST_ROOT:-$HOME/Devel/mist}"
ARCH_PATH="${ARCH_PATH:-perl-5.20.3-x86_64-linux}"

rm -rf fatlib fatpacker.trace packlists cpan-outdated

fatpack trace --to=fatpacker.trace --use=URI::file \
  cpan-outdated.PL \
  --mirror "file://${MIST_ROOT}/mpan-dist/" \
  --local-lib-contained "${MIST_ROOT}/perl5/${ARCH_PATH}"

# Core modules that must come from the target perl rather than be inlined.
grep -v -E 'Cwd\.pm|File/Spec.*pm|Scalar/Util\.pm|List/Util\.pm' \
  fatpacker.trace > fatpacker.trace.keep
mv fatpacker.trace.keep fatpacker.trace

fatpack packlists-for `cat fatpacker.trace` > packlists

# ExtUtils::Installed drags in ExtUtils::MakeMaker's entire packlist - some 14k
# lines of build toolchain a version scanner never runs, and core on every perl
# mist supports. Leave it to the target perl.
grep -v 'ExtUtils/MakeMaker' packlists > packlists.keep
mv packlists.keep packlists

fatpack tree `cat packlists`
fatpack file cpan-outdated.PL > cpan-outdated
chmod a+x cpan-outdated

# Prove the thing this exists for, rather than trusting that it packed.
./cpan-outdated --mirror "file://${MIST_ROOT}/mpan-dist/" \
  --local-lib-contained "${MIST_ROOT}/perl5/${ARCH_PATH}" >/dev/null \
  || { echo "FAIL: packed cpan-outdated cannot read a file:// mirror" >&2; exit 1; }

echo "packed $(wc -l < cpan-outdated) lines; install with:"
echo "  cp cpan-outdated ${MIST_ROOT}/share/cpan-outdated"

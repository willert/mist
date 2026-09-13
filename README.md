# GLOBAL OPTIONS

## -C &lt;path>

Run as if `mist` had been started in `<path>` instead of the current
directory. It is parsed before the subcommand, so the project root (located by
walking up for `mistfile` / `cpanfile`) and everything derived from it
resolve from `<path>`.

May be given more than once; as with `git -C`, a non-absolute `<path>` is
taken relative to the preceding one, and an empty `-C ''` leaves the
directory unchanged. The forms `-C path`, `-C=path` and `-Cpath` are all
accepted.

## --force-system-perl

Run the subcommand under the perl on `PATH` instead of re-executing under the
perl the mistfile pins. For a host that cannot provide a perlbrew context and
needs one command to go through anyway.

This is an escape, not a mode. `./mpan-install --system-perl` is the supported
way for a machine to build against its own perl, and it records that choice;
this flag records nothing, must be typed on every invocation, cannot be set
from the environment, and warns each time it is used.

It is refused for `compile`, `build_dist`, `release` and `prerelease`.
Those emit artifacts that other checkouts and other people consume, and nothing
in the result records which perl resolved it - so an unpinned one is a mistake
that is invisible afterwards and reaches every consumer.

Contradictory with `--perlbrew`, which names an interpreter to use.

# AUTHORS

Sebastian Willert <s.willert@wecare.de>

# LICENSE

Copyright (C) 2013 Sebastian Willert.

This library is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

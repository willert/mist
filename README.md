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

# AUTHORS

Sebastian Willert <s.willert@wecare.de>

# LICENSE

Copyright (C) 2013 Sebastian Willert.

This library is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

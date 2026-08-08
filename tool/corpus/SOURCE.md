# The grammar corpus

Every `.ned` and `.ini` file of the INET C++ tree, copied byte for byte.

| | |
|---|---|
| source | `inet-cpp`, commit `b52bc21a34`, 2026-07-17 |
| copied with | `find . \( -name '*.ned' -o -name '*.ini' \)`, paths preserved |
| contents | 1672 NED files, 329 INI files, 3.3 MB |

**Do not edit a file here.** It is a copy, and an edit makes it a different
thing from what it is a copy of. To refresh the corpus, copy the tree again
from a newer `inet-cpp` and record the commit above.

## What it is for

`tool/binary_precompile.jl` parses all of it while `create_app` builds the
executable. That is the whole purpose: it is a compiler warm-up, not a test
corpus and not a fixture.

The reason is measured. A run of the built binary costs what it costs because
each Lerche transformer callback compiles the first time a grammar production
reaches it — not because of file size, and not because of the parse tables:

| input to the built binary | time |
|---|---|
| `--version`, no parse | 0.29 s |
| an 11-line NED file | 0.30 s |
| 660 lines using only that file's productions | 0.32 s |
| the tutorial's ~1000-line NED file | 5.09 s |

Sixty times the bytes cost nothing. Different productions cost five seconds. So
the build has to reach the productions a user's file will, and the surest way
to reach them is to parse everything INET has.

## What it does not have to parse cleanly

One NED file fails, and that is expected: a malformed documentation snippet
missing its opening brace. The parser's own coverage note records it. The
precompile script counts failures and does not stop on one — a file that
cannot be parsed still compiled everything the attempt reached.

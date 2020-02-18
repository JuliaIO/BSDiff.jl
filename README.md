# BSDiff

[![Build Status](https://travis-ci.org/JuliaIO/BSDiff.jl.svg?branch=master)](https://travis-ci.org/JuliaIO/BSDiff.jl)
[![Codecov](https://codecov.io/gh/JuliaIO/BSDiff.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/JuliaIO/BSDiff.jl)

The BSDiff package is a pure Julia implementation of Matthew
Endsley's [version](https://github.com/mendsley/bsdiff) of the `bsdiff` tool,
based on (but incompatible with) Colin Percival's original program. It provides
two Julia commands with the same API as the command-line tools:

```jl
bsdiff(old, new, [patch])
bspatch(old, [new], patch)
```

The `bsdiff` command computes a patch file given `old` and `new` files while the
`bspatch` command applies a patch file to an `old` file to produce a `new` file.

## API

The public API for the `BSDiff` package consists of the following two functions:

<!-- BEGIN: copied from inline doc strings -->

### bsdiff

	bsdiff(old, new, [ patch ]) -> patch

Compute a binary patch that will transform the file `old` into the file `new`.
All arguments are strings. If no path is passed for `patch` the patch data is
written to a temporary file whose path is returned.

### bspatch

    bspatch(old, [ new, ] patch) -> new

Apply a binary patch in file `patch` to the file `old` producing file `new`.
All arguments are strings. If no path is passed for `new` the new data is
written to a temporary file whose path is returned.

Note that the optional argument is the middle argument, which is a bit unusual
in a Julia API, but which allows the argument order when passing all three paths
to be the same as the `bspatch` command.

<!-- END: copied from inline doc strings -->

## Compatiblity

This package produces and consumes patches that are compatible with Matthew
Endsley's [version](https://github.com/mendsley/bsdiff) of the `bsdiff` tool,
which uses a different format from Colin Percival's original `bsdiff` tool.
Patch files for this version of `bsdiff` start with the magic string
`ENDSLEY/BSDIFF43`. It may, in the future, be possible to add support for other
`bsdiff` formats if someone needs it. Even though the format is compatible,
patch files produced by this package will not be identical to the `bsdiff`
program for two reasons:

1. The bzip2 compression used by package and by the commands may have different
   settings and produce different results—in general compression libraries like
   bzip2 don't guarantee perfect reproducibility.

2. The uncompressed patch produced by this package is sometimes better than the
   one produced by the command line tool due to a bug in the way the command uses
   `memcmp` to do string comparison. See [this pull
   request](https://github.com/JuliaIO/BSDiff.jl/pull/8) for details.

The exact output produced by this library will not necessarily remain identical
in the future—there are many valid patches for the same `old` and `new` data.
Improvements to the speed and quality of the patch generation algorithm may lead
to different outputs in the future. However, the patch format is simple and
stable: it is guaranteed that newer versions of the package will be able to
apply patches produced by older versions and vice versa.

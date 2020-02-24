module BSDiff

export bsdiff, bspatch, suffixsort

import SuffixArrays
using TranscodingStreams, CodecBzip2

## high-level API (similar to the C tool) ##

const AbstractStrings = Union{AbstractString,NTuple{2,AbstractString}}

"""
    bsdiff(old, new, [ patch ]) -> patch

Compute a binary patch that will transform the file `old` into the file `new`.
All arguments are strings. If no path is passed for `patch` the patch data is
written to a temporary file whose path is returned.

The `old` argument can also be a tuple of two strings, in which case the first
is used as the path to the old data and the second is used as the path to a file
containing the sorted suffix array for the old data. Since sorting the suffix
array is the slowest part of generating a diff, pre-computing this and reusing
it can significantly speed up generting diffs from the same old file to multiple
different new files.
"""
function bsdiff(old::AbstractStrings, new::AbstractString, patch::AbstractString)
    bsdiff_core(data_and_suffixes(old)..., read(new), patch, open(patch, write=true))
end

function bsdiff(old::AbstractStrings, new::AbstractString)
    bsdiff_core(data_and_suffixes(old)..., read(new), mktemp()...)
end

"""
    bspatch(old, [ new, ] patch) -> new

Apply a binary patch in file `patch` to the file `old` producing file `new`.
All arguments are strings. If no path is passed for `new` the new data is
written to a temporary file whose path is returned.

Note that the optional argument is the middle argument, which is a bit unusual
in a Julia API, but which allows the argument order when passing all three paths
to be the same as the `bspatch` command.
"""
function bspatch(old::AbstractString, new::AbstractString, patch::AbstractString)
    open(patch) do patch_io
        bspatch_core(read(old), new, open(new, write=true), patch_io)
    end
end

function bspatch(old::AbstractString, patch::AbstractString)
    open(patch) do patch_io
        bspatch_core(read(old), mktemp()..., patch_io)
    end
end

"""
    suffixsort(old, [ suffix_file ]) -> suffix_file

Save the suffix array for the file `old` into the file `suffix_file`. All
arguments are strings. If no `suffix_file` argument is given, the suffix array
is saved to a temporary file and its path is returned.

The path of the suffix file can be passed to `bsdiff` to speed up the diff
computation (by loading the sorted suffix array rather than computing it), by
passing `(old, suffix_file)` as the first argument instead of just `old`.
"""
function suffixsort(old::AbstractString, suffix_file::AbstractString)
    suffixsort_core(read(old), suffix_file, open(suffix_file, write=true))
end

function suffixsort(old::AbstractString)
    suffixsort_core(read(old), mktemp()...)
end

# common code for API entry points

const HEADER = "ENDSLEY/BSDIFF43"

function bsdiff_core(
    old_data::AbstractVector{UInt8},
    suffixes::Vector{<:Integer},
    new_data::AbstractVector{UInt8},
    patch::AbstractString,
    patch_io::IO,
)
    try
        write(patch_io, HEADER)
        write(patch_io, int_io(Int64(length(new_data))))
        io = TranscodingStream(Bzip2Compressor(), patch_io)
        write_diff(io, old_data, new_data, suffixes)
        close(io)
    catch
        close(patch_io)
        rm(patch, force=true)
        rethrow()
    end
    close(patch_io)
    return patch
end

function bspatch_core(
    old_data::AbstractVector{UInt8},
    new::AbstractString,
    new_io::IO,
    patch_io::IO,
)
    try
        hdr = String(read(patch_io, ncodeunits(HEADER)))
        hdr == HEADER || error("corrupt bsdiff patch")
        new_size = Int(int_io(read(patch_io, Int64)))
        io = TranscodingStream(Bzip2Decompressor(), patch_io)
        apply_patch(old_data, io, new_io, new_size)
        close(io)
    catch
        close(new_io)
        rm(new, force=true)
        rethrow()
    end
    close(new_io)
    return new
end

function suffixsort_core(
    old_data::AbstractVector{UInt8},
    suffix_file::AbstractString,
    suffix_io::IO,
)
    try
        suffixes = SuffixArrays.suffixsort(old_data, 0)
        write(suffix_io, suffixes)
    catch
        close(suffix_io)
        rm(suffix_file, force=true)
        rethrow()
    end
    close(suffix_io)
    return suffix_file
end

## loading data and suffixes ##

function data_and_suffixes(data_path::AbstractString)
    data = read(data_path)
    data, SuffixArrays.suffixsort(data, 0)
end

function data_and_suffixes((data_path, suffix_path)::NTuple{2,AbstractString})
    data = read(data_path)
    size = filesize(suffix_path)
    unit = size/length(data)
    T = unit == 1 ? UInt8 :
        unit == 2 ? UInt16 :
        unit == 4 ? UInt32 :
        unit == 8 ? UInt64 :
        error("invalid index type size for suffix file: $unit")
    return data, read!(suffix_path, Vector{T}(undef, round(Int, size/unit)))
end

## internal implementation logic ##

# transform used to serialize integers to avoid lots of
# high bytes being emitted for small negative values
int_io(x::Signed) = ifelse(x == abs(x), x, typemin(x) - x)

"""
How much of old[i:end] and new[j:end] are the same?
"""
function match_length(
    old::AbstractVector{UInt8}, i::Integer,
    new::AbstractVector{UInt8}, j::Integer,
)
    l = 0
    while i ≤ length(old) && j ≤ length(new)
        old[i] ≠ new[j] && break
        i += 1; j += 1; l += 1
    end
    return l
end

@inline function strcmp(p::Ptr{UInt8}, m::Int, q::Ptr{UInt8}, n::Int)
    x = Base._memcmp(p, q, min(m, n))
    x == 0 ? cmp(m, n) : sign(x)
end

"""
Search for the longest prefix of new[ind:end] in old.
Uses the suffix array of old to search efficiently.
"""
function prefix_search(
    suffixes::Vector{<:Integer}, # suffix array of old data (0-based)
    old::AbstractVector{UInt8}, # old data to search in
    new::AbstractVector{UInt8}, # new data to search for
    ind::Int, # search for longest match of new[ind:end]
)
    old_n = length(old)
    new_n = length(new) - ind + 1
    old_p = pointer(old)
    new_p = pointer(new, ind)
    # invariant: longest match is in suffixes[lo:hi]
    lo, hi = 1, old_n
    while hi - lo ≥ 2
        m = (lo + hi) >>> 1
        s = suffixes[m]
        if 0 < strcmp(new_p, new_n, old_p + s, old_n - s)
            lo = m
        else
            hi = m
        end
    end
    i = suffixes[lo]+1
    m = match_length(old, i, new, ind)
    lo == hi && return (i, m)
    j = suffixes[hi]+1
    n = match_length(old, j, new, ind)
    m > n ? (i, m) : (j, n)
end

"""
Computes and emits the diff of the byte vectors `new` versus `old`.
The `suffixes` array is a zero-based suffix array of `old`.
"""
function write_diff(
    io::IO,
    old::AbstractVector{UInt8},
    new::AbstractVector{UInt8},
    suffixes::Vector{<:Integer} = SuffixArrays.suffixsort(old, 0),
)
    oldsize, newsize = length(old), length(new)
    scan = len = pos = lastscan = lastpos = lastoffset = 0

    while scan < newsize
        oldscore = 0
        scsc = scan += len
        while scan < newsize
            pos, len = prefix_search(suffixes, old, new, scan+1)
            pos -= 1 # zero-based
            while scsc < scan + len
                oldscore += scsc + lastoffset < oldsize &&
                    old[scsc + lastoffset + 1] == new[scsc + 1]
                scsc += 1
            end
            if len == oldscore && len ≠ 0 || len > oldscore + 8
                break
            end
            oldscore -= scan + lastoffset < oldsize &&
                old[scan + lastoffset + 1] == new[scan + 1]
            scan += 1
        end
        if len ≠ oldscore || scan == newsize
            i = s = Sf = lenf = 0
            while lastscan + i < scan && lastpos + i < oldsize
                s += old[lastpos + i + 1] == new[lastscan + i + 1]
                i += 1
                if 2s - i > 2Sf - lenf
                    Sf = s
                    lenf = i
                end
            end
            lenb = 0
            if scan < newsize
                s = Sb = 0
                i = 1
                while scan ≥ lastscan + i && pos ≥ i
                    s += old[pos - i + 1] == new[scan - i + 1]
                    if 2s - i > 2Sb - lenb
                        Sb = s
                        lenb = i
                    end
                    i += 1
                end
            end
            if lastscan + lenf > scan - lenb
                overlap = (lastscan + lenf) - (scan - lenb)
                i = s = Ss = lens = 0
                while i < overlap
                    s += new[lastscan + lenf - overlap + i + 1] ==
                         old[lastpos + lenf - overlap + i + 1]
                    s -= new[scan - lenb + i + 1] ==
                         old[pos - lenb + i + 1]
                    if s > Ss
                        Ss = s
                        lens = i + 1;
                    end
                    i += 1
                end
                lenf += lens - overlap
                lenb -= lens
            end

            diff_size = lenf
            copy_size = (scan - lenb) - (lastscan + lenf)
            skip_size = (pos - lenb) - (lastpos + lenf)

            # skip if both blocks are empty
            diff_size == copy_size == 0 && continue

            # write control data
            write(io, int_io(Int64(diff_size)))
            write(io, int_io(Int64(copy_size)))
            write(io, int_io(Int64(skip_size)))

            # write diff data
            for i = 1:diff_size # `i` is one-based here
                write(io, new[lastscan + i] - old[lastpos + i])
            end

            # write extra data
            for i = 1:copy_size
                write(io, new[lastscan + lenf + i])
            end

            lastscan = scan - lenb
            lastpos = pos - lenb
            lastoffset = pos - scan
        end
    end
end

"""
Apply a patch stream to the `old` data buffer, emitting a `new` data stream.
"""
function apply_patch(
    old::AbstractVector{UInt8},
    patch::IO,
    new::IO,
    new_size::Int = typemax(Int),
)
    old_size = length(old)
    n = pos = 0
    while !eof(patch)
        # read control data
        diff_size = Int(int_io(read(patch, Int64)))
        copy_size = Int(int_io(read(patch, Int64)))
        skip_size = Int(int_io(read(patch, Int64)))

        # sanity checks
        0 ≤ diff_size && 0 ≤ copy_size &&        # block sizes are non-negative
        n + diff_size + copy_size ≤ new_size &&  # don't write > new_size bytes
        0 ≤ pos && pos + diff_size ≤ old_size || # bounds check for old data
            error("corrupt bsdiff patch")

        # copy data from old to new, applying diff
        @inbounds for i = 1:diff_size
            n += write(new, old[pos + i] + read(patch, UInt8))
        end
        pos += diff_size

        # copy fresh data from patch to new
        for i = 1:copy_size
            n += write(new, read(patch, UInt8))
        end
        pos += skip_size
    end
    return n
end

end # module

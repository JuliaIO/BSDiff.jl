module BSDiff

export bsdiff, bspatch, bsindex

using SuffixArrays
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
    bsdiff_core(data_and_index(old)..., read(new), patch, open(patch, write=true))
end

function bsdiff(old::AbstractStrings, new::AbstractString)
    bsdiff_core(data_and_index(old)..., read(new), mktemp()...)
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
    bsindex(old, [ index ]) -> index

Save index data (currently a suffix array & lcp data) for the file `old` into the
file `index`. All arguments are strings. If no `index` argument is given, the
index data is saved to a temporary file whose path is returned. The path of the
index file can be passed to `bsdiff` to speed up the diff computation by passing
`(old, index)` as the first argument instead of just `old`.
"""
function bsindex(old::AbstractString, index::AbstractString)
    bsindex_core(read(old), index, open(index, write=true))
end

function bsindex(old::AbstractString)
    bsindex_core(read(old), mktemp()...)
end

# common code for API entry points

const PATCH_HEADER = "ENDSLEY/BSDIFF43"
const INDEX_HEADER = "SUFFIXES,LCP\0"

IndexType{T<:Integer} = Matrix{T}

function bsdiff_core(
    old_data::AbstractVector{UInt8},
    index::IndexType,
    new_data::AbstractVector{UInt8},
    patch::AbstractString,
    patch_io::IO,
)
    try
        write(patch_io, PATCH_HEADER)
        write(patch_io, int_io(Int64(length(new_data))))
        io = TranscodingStream(Bzip2Compressor(), patch_io)
        write_diff(io, old_data, new_data, index)
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
        hdr = String(read(patch_io, ncodeunits(PATCH_HEADER)))
        hdr == PATCH_HEADER || error("corrupt bsdiff patch")
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

function bsindex_core(
    old_data::AbstractVector{UInt8},
    index_path::AbstractString,
    index_io::IO,
)
    try
        write(index_io, INDEX_HEADER)
        index = generate_index(old_data)
        write(index_io, UInt8(sizeof(eltype(index))))
        write(index_io, index)
    catch
        close(index_io)
        rm(index_path, force=true)
        rethrow()
    end
    close(index_io)
    return index_path
end

## loading data and index ##

function data_and_index(data_path::AbstractString)
    data = read(data_path)
    data, generate_index(data)
end

function data_and_index((data_path, index_path)::NTuple{2,AbstractString})
    data = read(data_path)
    index = open(index_path) do index_io
        hdr = String(read(index_io, ncodeunits(INDEX_HEADER)))
        hdr == INDEX_HEADER || error("corrupt bsdiff index")
        unit = Int(read(index_io, UInt8))
        T = unit == 1 ? UInt8 :
            unit == 2 ? UInt16 :
            unit == 4 ? UInt32 :
            unit == 8 ? UInt64 :
            error("invalid unit size for index file: $unit")
        read!(index_io, Matrix{T}(undef, 3, length(data)))
    end
    return data, index
end

## internal implementation logic ##

const SUFFIX = 2

function generate_index(data::AbstractVector{<:UInt8})
    n = length(data)
    suffixes = suffixsort(data, 0)
    index = zeros(eltype(suffixes), 3, n)
    index[SUFFIX, :] .= suffixes
    fill_lcp!(pointer(data), n, index, 1, n)
    return index
end

function fill_lcp!(p::Ptr{UInt8}, n::Int, index::IndexType, lo::Int, hi::Int)
    hi - lo ≥ 2 || return
    mid = (lo + hi) >>> 1
    index[SUFFIX-1, mid] = strlcp(p, n, index[SUFFIX, lo], index[SUFFIX, mid])
    index[SUFFIX+1, mid] = strlcp(p, n, index[SUFFIX, mid], index[SUFFIX, hi])
    fill_lcp!(p, n, index, lo, mid)
    fill_lcp!(p, n, index, mid, hi)
end

strlcp(p::Ptr{UInt8}, n::Int, i::Integer, j::Integer) = strcmplen(p+i, n-i, p+j, n-j)[2]

# transform used to serialize integers to avoid lots of
# high bytes being emitted for small negative values
int_io(x::Signed) = ifelse(x == abs(x), x, typemin(x) - x)

"""
Return lexicographic order and length of common prefix.
"""
function strcmplen(p::Ptr{UInt8}, m::Int, q::Ptr{UInt8}, n::Int)
    i = j = l = x = 0
    while i < m && j < n
        x = cmp(unsafe_load(p+i), unsafe_load(q+j))
        x ≠ 0 && break
        i += 1; j += 1; l += 1
    end
    return ifelse(x == 0, cmp(m, n), x), l
end

"""
Search for the longest prefix of new[t:end] in old.
Uses the index to search efficiently.
"""
function prefix_search(
    index::IndexType, # suffix & lcp data
    old::AbstractVector{UInt8}, # old data to search in
    new::AbstractVector{UInt8}, # new data to search for
    t::Int, # search for longest match of new[t:end]
)
    old_n = length(old)
    new_n = length(new) - t + 1
    old_p = pointer(old)
    new_p = pointer(new, t)
    # dir < 0: searching left, lcp is on the right
    # dir > 0: searching right, lcp is on the left
    lo, hi = 1, old_n
    lcp_lo = strcmplen(new_p, new_n, old_p+index[SUFFIX, lo], old_n-index[SUFFIX, lo])[2]
    lcp_hi = strcmplen(new_p, new_n, old_p+index[SUFFIX, hi], old_n-index[SUFFIX, hi])[2]
    lcp, dir = lcp_lo > lcp_hi ? (lcp_lo, 1) : (lcp_hi, -1)
    while hi - lo ≥ 2
        mid = (lo + hi) >>> 1
        s = index[SUFFIX, mid] # suffix index (0-based)
        c = index[SUFFIX-dir, mid] # lcp(new mid, old mid)
        x = cmp(c, lcp)
        if dir == 0 || x == 0
            # need to look at more of the needle
            dir, l = strcmplen(new_p+c, new_n-c, old_p+s+c, old_n-s-c)
            lcp += l
            dir == 0 && return (s+1, lcp)
        end
        if (dir < 0) ⊻ (x < 0)
            hi = mid
        else
            lo = mid
        end
    end
    i = index[SUFFIX, lo]
    m = strcmplen(new_p, new_n, old_p+i, old_n-i)[2]
    lo == hi && return (i+1, m)
    j = index[SUFFIX, hi]
    n = strcmplen(new_p, new_n, old_p+j, old_n-j)[2]
    m > n ? (i+1, m) : (j+1, n)
end

"""
Computes and emits the diff of the byte vectors `new` versus `old`.
The `index` array contains suffix array and lcp data for `old`.
"""
function write_diff(
    io::IO,
    old::AbstractVector{UInt8},
    new::AbstractVector{UInt8},
    index::IndexType = generate_index(old),
)
    oldsize, newsize = length(old), length(new)
    scan = len = pos = lastscan = lastpos = lastoffset = 0

    while scan < newsize
        oldscore = 0
        scsc = scan += len
        while scan < newsize
            pos, len = prefix_search(index, old, new, scan+1)
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

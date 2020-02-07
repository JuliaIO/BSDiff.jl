module BSDiff

import SuffixArrays: suffixsort

const ByteVector = AbstractVector{UInt8}

"""
How much of old[i:end] and new[j:end] are the same?
"""
function match_length(
    old::ByteVector, i::Integer,
    new::ByteVector, j::Integer,
)
    l = 0
    while i ≤ length(old) && j ≤ length(new)
        old[i] ≠ new[j] && break
        i += 1; j += 1; l += 1
    end
    return l
end

"""
Search for the longest prefix of new[ind:end] in old.
Uses the suffix array of old to search efficiently.
"""
function prefix_search(
    suffixes::Vector{<:Integer}, # suffix array of old data (0-based)
    old::ByteVector, # old data to search in
    new::ByteVector, # new data to search for
    ind::Int, # search for longest match of new[ind:end]
)
    old_n = length(old)
    new_n = length(new) - ind + 1
    old_p = pointer(old)
    new_p = pointer(new, ind)
    # invariant: longest match is in suffixes[lo:hi]
    lo, hi = 1, length(suffixes)
    while hi - lo ≥ 2
        m = (lo + hi) >>> 1
        s = suffixes[m]
        if 0 < Base._memcmp(new_p, old_p + s, min(new_n, old_n - s))
            lo = m
        else
            hi = m
        end
    end
    i = suffixes[lo]+1
    m = match_length(old, i, new, ind)
    lo == hi && return i, m
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
    suffixes::Vector{<:Integer} = suffixsort(old, 0),
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

            # don't emit lots of high bytes for negative values
            n_out(x::Int64) = ifelse(x == abs(x), x, typemin(x) - x)

            # write control data
            write(io, n_out(Int64(lenf)))
            write(io, n_out(Int64((scan - lenb) - (lastscan + lenf))))
            write(io, n_out(Int64((pos - lenb) - (lastpos + lenf))))

            # write diff data
            for i = 1:lenf # `i` is one-based here
                write(io, new[lastscan + i] - old[lastpos + i])
            end

            # write extra data
            for i = 1:((scan - lenb) - (lastscan + lenf))
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
function apply_patch(old::ByteVector, patch::IO, new::IO, new_size::Int = typemax(Int))
    old_size = length(old)
    n = pos = 0
    while !eof(patch)
        # inverse of n_out above
        n_in(x::Int64) = Int(ifelse(x == abs(x), x, typemin(x) + abs(x)))

        # read control data
        diff_size = n_in(read(patch, Int64))
        copy_size = n_in(read(patch, Int64))
        skip_size = n_in(read(patch, Int64))

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

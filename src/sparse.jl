include("leb128.jl")

struct SparsePatch{T<:IO} <: Patch
    io::T
    new_size::Int64
end
SparsePatch(io::IO) = SparsePatch(io, typemax(Int64))

format_magic(::Type{SparsePatch}) = "BSDiff.jl/Sparse\0"

function write_start(
    ::Type{SparsePatch},
    patch_io::IO,
    old_data::AbstractVector{UInt8},
    new_data::AbstractVector{UInt8};
    codec::Codec = Bzip2Compressor(),
)
    new_size = length(new_data)
    write_leb128(patch_io, UInt64(new_size))
    SparsePatch(patch_io, new_size)
end

function read_start(
    ::Type{SparsePatch},
    patch_io::IO;
)
    new_size = Int(read_leb128(patch_io, UInt64))
    SparsePatch(patch_io, new_size)
end

Base.close(patch::SparsePatch) = close(patch.io)

function encode_control(
    patch::SparsePatch,
    diff_size::Int,
    copy_size::Int,
    skip_size::Int,
)
    write_leb128(patch.io, UInt64(diff_size))
    write_leb128(patch.io, UInt64(copy_size))
    skip_size = (abs(skip_size) << 1) | (skip_size < 0)
    write_leb128(patch.io, UInt64(skip_size))
end

function decode_control(patch::SparsePatch)
    eof(patch.io) && return nothing
    diff_size = Int(read_leb128(patch.io, UInt64))
    copy_size = Int(read_leb128(patch.io, UInt64))
    skip_size = read_leb128(patch.io, UInt64)
    neg = isodd(skip_size)
    skip_size = (neg ? -1 : 1)*Int(skip_size >>> 1)
    return diff_size, copy_size, skip_size
end

function encode_diff(
    patch::SparsePatch,
    diff_size::Int,
    new::AbstractVector{UInt8}, new_pos::Int,
    old::AbstractVector{UInt8}, old_pos::Int,
)
    for i = 1:diff_size
        d = new[new_pos + i] - old[old_pos + i]
        d == 0 && continue
        write(patch.io, d)
        write_leb128(patch.io, UInt64(i-1))
    end
    write(patch.io, 0x0)
end

function decode_diff(
    patch::SparsePatch,
    diff_size::Int,
    new::IO,
    old::AbstractVector{UInt8},
    old_pos::Int,
)
    i = 1
    while true
        d = read(patch.io, UInt8)
        d == 0 && break
        j = Int(read_leb128(patch.io, UInt64)+1)
        while i < j
            i += write(new, old[old_pos + i])
        end
        i += write(new, old[old_pos + i] + d)
    end
    while i ≤ diff_size
        i += write(new, old[old_pos + i])
    end
end

function encode_data(
    patch::SparsePatch,
    copy_size::Int,
    new::AbstractVector{UInt8}, pos::Int,
)
    for i = 1:copy_size
        write(patch.io, new[pos + i])
    end
end

function decode_data(
    patch::SparsePatch,
    copy_size::Int,
    new::IO,
)
    for i = 1:copy_size
        write(new, read(patch.io, UInt8))
    end
end

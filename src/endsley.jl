struct EndsleyPatch{T<:IO} <: Patch
    io::T
    new_size::Int64
end
EndsleyPatch(io::IO) = EndsleyPatch(io, typemax(Int64))

header(::Type{EndsleyPatch}) = "ENDSLEY/BSDIFF43"

function write_open(
    ::Type{EndsleyPatch},
    patch_io::IO,
    old_data::AbstractVector{UInt8},
    new_data::AbstractVector{UInt8};
    codec::Codec = Bzip2Compressor(),
)
    new_size = length(new_data)
    write(patch_io, header(EndsleyPatch))
    write(patch_io, int_io(Int64(new_size)))
    EndsleyPatch(TranscodingStream(codec, patch_io), new_size)
end

function read_open(
    ::Type{EndsleyPatch},
    patch_io::IO;
    codec::Codec = Bzip2Decompressor(),
)
    HDR = header(EndsleyPatch)
    hdr = String(read(patch_io, ncodeunits(HDR)))
    hdr == HDR || error("corrupt bsdiff (endsley) patch")
    new_size = int_io(read(patch_io, Int64))
    EndsleyPatch(TranscodingStream(codec, patch_io), new_size)
end

Base.close(patch::EndsleyPatch) = close(patch.io)

function encode_control(
    patch::EndsleyPatch,
    diff_size::Int,
    copy_size::Int,
    skip_size::Int,
)
    write(patch.io, int_io(Int64(diff_size)))
    write(patch.io, int_io(Int64(copy_size)))
    write(patch.io, int_io(Int64(skip_size)))
end

function decode_control(patch::EndsleyPatch)
    eof(patch.io) && return nothing
    diff_size = Int(int_io(read(patch.io, Int64)))
    copy_size = Int(int_io(read(patch.io, Int64)))
    skip_size = Int(int_io(read(patch.io, Int64)))
    return diff_size, copy_size, skip_size
end

function encode_diff(
    patch::EndsleyPatch,
    diff_size::Int,
    new::AbstractVector{UInt8}, new_pos::Int,
    old::AbstractVector{UInt8}, old_pos::Int,
)
    for i = 1:diff_size
        write(patch.io, new[new_pos + i] - old[old_pos + i])
    end
end

function decode_diff(
    patch::EndsleyPatch,
    diff_size::Int,
    new::IO,
    old::AbstractVector{UInt8},
    old_pos::Int,
)
    for i = 1:diff_size
        write(new, old[old_pos + i] + read(patch.io, UInt8))
    end
end

function encode_data(
    patch::EndsleyPatch,
    copy_size::Int,
    new::AbstractVector{UInt8}, pos::Int,
)
    for i = 1:copy_size
        write(patch.io, new[pos + i])
    end
end

function decode_data(
    patch::EndsleyPatch,
    copy_size::Int,
    new::IO,
)
    for i = 1:copy_size
        write(new, read(patch.io, UInt8))
    end
end

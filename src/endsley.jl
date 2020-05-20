struct EndsleyPatch{T<:IO} <: Patch
    io::T
    new_size::Int64
end
EndsleyPatch(io::IO) = EndsleyPatch(io, typemax(Int64))

format_magic(::Type{EndsleyPatch}) = "ENDSLEY/BSDIFF43"

function write_start(
    ::Type{EndsleyPatch},
    patch_io::IO,
    old_data::AbstractVector{UInt8},
    new_data::AbstractVector{UInt8};
    codec::Codec = Bzip2Compressor(),
)
    new_size = length(new_data)
    write_int(patch_io, new_size)
    EndsleyPatch(TranscodingStream(codec, patch_io), new_size)
end

function read_start(
    ::Type{EndsleyPatch},
    patch_io::IO;
    codec::Codec = Bzip2Decompressor(),
)
    new_size = read_int(patch_io)
    EndsleyPatch(TranscodingStream(codec, patch_io), new_size)
end

function write_finish(patch::EndsleyPatch)
    write(patch.io, TranscodingStreams.TOKEN_END)
    flush(patch.io)
end

function encode_control(
    patch::EndsleyPatch,
    diff_size::Int,
    copy_size::Int,
    skip_size::Int,
)
    write_int(patch.io, diff_size)
    write_int(patch.io, copy_size)
    write_int(patch.io, skip_size)
end

function decode_control(patch::EndsleyPatch)
    eof(patch.io) && return nothing
    diff_size = read_int(patch.io)
    copy_size = read_int(patch.io)
    skip_size = read_int(patch.io)
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

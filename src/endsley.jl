mutable struct EndsleyPatch{T<:IO} <: Patch
    io::T
    new_size::Int64
end
EndsleyPatch(io::IO) = EndsleyPatch(io, typemax(Int64))

format_magic(::Type{EndsleyPatch}) = "ENDSLEY/BSDIFF43"

function write_start(
    ::Type{EndsleyPatch},
    patch_io::IO,
    old_data::AbstractVector{UInt8},
    new_data::AbstractVector{UInt8},
)
    new_size = Int64(length(new_data))
    write_int(patch_io, new_size)
    stream = TranscodingStream(compressor(), patch_io)
    patch = EndsleyPatch(stream, new_size)
    finalizer(finalize_patch, patch)
    return patch
end

function read_start(::Type{EndsleyPatch}, patch_io::IO)
    new_size = read_int(patch_io)
    EndsleyPatch(TranscodingStream(decompressor(), patch_io), new_size)
end

function finalize_patch(patch::EndsleyPatch)
    if patch.io isa TranscodingStream
        # must be called to avoid leaking memory
        TranscodingStreams.changemode!(patch.io, :close)
    end
end

function write_finish(patch::EndsleyPatch)
    if patch.io isa TranscodingStream
        write(patch.io, TranscodingStreams.TOKEN_END)
    end
    flush(patch.io)
    finalize(patch)
end

function encode_control(
    patch::EndsleyPatch,
    diff_size::Int64,
    copy_size::Int64,
    skip_size::Int64,
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
    diff_size::Int64,
    new::AbstractVector{UInt8}, new_pos::Int64,
    old::AbstractVector{UInt8}, old_pos::Int64,
)
    for i = 1:diff_size
        write(patch.io, new[new_pos + i] - old[old_pos + i])
    end
end

function decode_diff(
    patch::EndsleyPatch,
    diff_size::Int64,
    new::IO,
    old::AbstractVector{UInt8},
    old_pos::Int64,
)
    for i = 1:diff_size
        write(new, old[old_pos + i] + read(patch.io, UInt8))
    end
end

function encode_data(
    patch::EndsleyPatch,
    copy_size::Int64,
    new::AbstractVector{UInt8}, pos::Int64,
)
    for i = 1:copy_size
        write(patch.io, new[pos + i])
    end
end

function decode_data(
    patch::EndsleyPatch,
    copy_size::Int64,
    new::IO,
)
    for i = 1:copy_size
        write(new, read(patch.io, UInt8))
    end
end

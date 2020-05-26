mutable struct ClassicPatch{T<:IO,C<:Codec} <: Patch
    io::T
    new_size::Int64
    ctrl::TranscodingStream{C,IOBuffer}
    diff::TranscodingStream{C,IOBuffer}
    data::TranscodingStream{C,IOBuffer}
end
function ClassicPatch(patch_io::IO, new_size::Int64 = typemax(Int64))
    ctrl = TranscodingStream(compressor(), IOBuffer())
    diff = TranscodingStream(compressor(), IOBuffer())
    data = TranscodingStream(compressor(), IOBuffer())
    patch = ClassicPatch(patch_io, new_size, ctrl, diff, data)
    finalizer(finalize_patch, patch)
    return patch
end

format_magic(::Type{ClassicPatch}) = "BSDIFF40"

function write_start(
    ::Type{ClassicPatch},
    patch_io::IO,
    old_data::AbstractVector{UInt8},
    new_data::AbstractVector{UInt8},
)
    ClassicPatch(patch_io, length(new_data))
end

function read_start(::Type{ClassicPatch}, patch_io::IO)
    ctrl_size = read_int(patch_io)
    diff_size = read_int(patch_io)
    new_size  = read_int(patch_io)
    ctrl_io = IOBuffer(read(patch_io, ctrl_size))
    diff_io = IOBuffer(read(patch_io, diff_size))
    data_io = IOBuffer(read(patch_io))
    ctrl = TranscodingStream(decompressor(), ctrl_io)
    diff = TranscodingStream(decompressor(), diff_io)
    data = TranscodingStream(decompressor(), data_io)
    patch = ClassicPatch(patch_io, new_size, ctrl, diff, data)
    finalizer(finalize_patch, patch)
    return patch
end

function finalize_patch(patch::ClassicPatch)
    for stream in (patch.ctrl, patch.diff, patch.data)
        # must be called to avoid leaking memory
        TranscodingStreams.changemode!(stream, :close)
    end
end

function write_finish(patch::ClassicPatch)
    for stream in (patch.ctrl, patch.diff, patch.data)
        write(stream, TranscodingStreams.TOKEN_END)
    end
    write_int(patch.io, patch.ctrl.stream.size)
    write_int(patch.io, patch.diff.stream.size)
    write_int(patch.io, patch.new_size)
    for stream in (patch.ctrl, patch.diff, patch.data)
        write(patch.io, resize!(stream.stream.data, stream.stream.size))
    end
    flush(patch.io)
    finalize(patch)
end

function encode_control(
    patch::ClassicPatch,
    diff_size::Int,
    copy_size::Int,
    skip_size::Int,
)
    write_int(patch.ctrl, diff_size)
    write_int(patch.ctrl, copy_size)
    write_int(patch.ctrl, skip_size)
end

function decode_control(patch::ClassicPatch)
    eof(patch.ctrl) && return nothing
    diff_size = read_int(patch.ctrl)
    copy_size = read_int(patch.ctrl)
    skip_size = read_int(patch.ctrl)
    return diff_size, copy_size, skip_size
end

function encode_diff(
    patch::ClassicPatch,
    diff_size::Int,
    new::AbstractVector{UInt8}, new_pos::Int,
    old::AbstractVector{UInt8}, old_pos::Int,
)
    for i = 1:diff_size
        write(patch.diff, new[new_pos + i] - old[old_pos + i])
    end
end

function decode_diff(
    patch::ClassicPatch,
    diff_size::Int,
    new::IO,
    old::AbstractVector{UInt8},
    old_pos::Int,
)
    for i = 1:diff_size
        write(new, old[old_pos + i] + read(patch.diff, UInt8))
    end
end

function encode_data(
    patch::ClassicPatch,
    copy_size::Int,
    new::AbstractVector{UInt8}, pos::Int,
)
    for i = 1:copy_size
        write(patch.data, new[pos + i])
    end
end

function decode_data(
    patch::ClassicPatch,
    copy_size::Int,
    new::IO,
)
    for i = 1:copy_size
        write(new, read(patch.data, UInt8))
    end
end

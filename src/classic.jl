struct ClassicPatch{T<:IO,C<:Codec} <: Patch
    io::T
    ctrl::TranscodingStream{C,IOBuffer}
    diff::TranscodingStream{C,IOBuffer}
    data::TranscodingStream{C,IOBuffer}
    new_size::Int64
end

header(::Type{ClassicPatch}) = "BSDIFF40"

function write_open(
    ::Type{ClassicPatch},
    patch_io::IO,
    old_data::AbstractVector{UInt8},
    new_data::AbstractVector{UInt8};
    codec::Codec = Bzip2Compressor(),
)
    new_size = length(new_data)
    write(patch_io, header(ClassicPatch))
    ctrl = TranscodingStream(deepcopy(codec), IOBuffer())
    diff = TranscodingStream(deepcopy(codec), IOBuffer())
    data = TranscodingStream(identity(codec), IOBuffer())
    ClassicPatch(patch_io, ctrl, diff, data, new_size)
end

function read_open(
    ::Type{ClassicPatch},
    patch_io::IO;
    codec::Codec = Bzip2Decompressor(),
)
    HDR = header(ClassicPatch)
    hdr = String(read(patch_io, ncodeunits(HDR)))
    hdr == HDR || error("corrupt bsdiff (classic) patch")
    ctrl_size = int_io(read(patch_io, Int64))
    diff_size = int_io(read(patch_io, Int64))
    new_size  = int_io(read(patch_io, Int64))
    ctrl_io = IOBuffer(read(patch_io, ctrl_size))
    diff_io = IOBuffer(read(patch_io, diff_size))
    data_io = IOBuffer(read(patch_io))
    ctrl = TranscodingStream(deepcopy(codec), ctrl_io)
    diff = TranscodingStream(deepcopy(codec), diff_io)
    data = TranscodingStream(identity(codec), data_io)
    ClassicPatch(patch_io, ctrl, diff, data, new_size)
end

function Base.close(patch::ClassicPatch)
    if iswritable(patch.ctrl.stream)
        for stream in (patch.ctrl, patch.diff, patch.data)
            write(stream, TranscodingStreams.TOKEN_END)
        end
        write(patch.io, int_io(Int64(patch.ctrl.stream.size)))
        write(patch.io, int_io(Int64(patch.diff.stream.size)))
        write(patch.io, int_io(Int64(patch.new_size)))
        for stream in (patch.ctrl, patch.diff, patch.data)
            write(patch.io, resize!(stream.stream.data, stream.stream.size))
        end
    end
    close(patch.io)
end

function encode_control(
    patch::ClassicPatch,
    diff_size::Int,
    copy_size::Int,
    skip_size::Int,
)
    write(patch.ctrl, int_io(Int64(diff_size)))
    write(patch.ctrl, int_io(Int64(copy_size)))
    write(patch.ctrl, int_io(Int64(skip_size)))
end

function decode_control(patch::ClassicPatch)
    eof(patch.ctrl) && return nothing
    diff_size = Int(int_io(read(patch.ctrl, Int64)))
    copy_size = Int(int_io(read(patch.ctrl, Int64)))
    skip_size = Int(int_io(read(patch.ctrl, Int64)))
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

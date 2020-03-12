## IO type that run-length encodes zero bytes ##

mutable struct ZRLE{T<:IO} <: IO
    stream::T
    zeros::UInt64
end
ZRLE(io::IO) = ZRLE{typeof(io)}(io, 0)

Base.eof(io::ZRLE) = io.zeros == 0 && eof(io.stream)
Base.isopen(io::ZRLE) = isopen(io.stream)

function flush_zeros(io::ZRLE)
    if io.zeros > 0
        write(io.stream, 0x0)
        write_leb128(io.stream, io.zeros-1)
        io.zeros = 0
    end
end

function Base.flush(io::ZRLE)
    flush_zeros(io)
    flush(io.stream)
end

function Base.close(io::ZRLE)
    isreadonly(io.stream) || flush_zeros(io)
    close(io.stream)
end

function Base.write(io::ZRLE, byte::UInt8)
    if byte == 0
        io.zeros += 1
    else
        flush_zeros(io)
        write(io.stream, byte)
    end
    return 1
end

function Base.read(io::ZRLE, ::Type{UInt8})
    if io.zeros > 0
        io.zeros -= 1
        return 0x0
    end
    byte = read(io.stream, UInt8)
    if byte == 0
        io.zeros = read_leb128(io.stream, typeof(io.zeros))
    end
    return byte
end

read_zrle(path::AbstractString) = open(read_zrle, path)
read_zrle(io::IO) = read(ZRLE(io))

function zrle(data::AbstractVector{UInt8})
    buffer = IOBuffer()
    io = ZRLE(buffer)
    write(io, data)
    flush(io)
    take!(buffer)
end

zrld(data::AbstractVector{UInt8}) = read(ZRLE(IOBuffer(data)))

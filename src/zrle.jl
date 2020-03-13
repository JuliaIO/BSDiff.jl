## IO type that run-length encodes zero bytes ##

mutable struct ZRLE{T<:IO} <: IO
    stream::T
    zeros::UInt64
end
ZRLE(io::IO) = ZRLE{typeof(io)}(io, 0)

Base.eof(io::ZRLE) = io.zeros == 0 && eof(io.stream)
Base.close(io::ZRLE) = close(io.stream)

function Base.read(io::ZRLE, ::Type{UInt8})
    zeros = io.zeros
    if zeros == 0
        byte = read(io.stream, UInt8)
        byte ≠ 0 && return byte
        zeros += 1
        while !eof(io.stream) && Base.peek(io.stream) == 0
            byte = read(io.stream, UInt8)
            @assert byte == 0
            zeros += 1
        end
        io.zeros = zeros
        return 0x0
    end
    n = zeros - 1
    byte = (n % UInt8) & 0x7f
    n >>= 7
    byte |= UInt8(n > 0) << 7
    io.zeros = n + (n > 0)
    return byte
end

read_zrle(io::IO) = read(ZRLE(io))
read_zrle(path::AbstractString) = open(read_zrle, path)

zrle(data::AbstractVector{UInt8}) = read(ZRLE(IOBuffer(data)))

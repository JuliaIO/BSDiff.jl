## IO type that run-length encodes zero bytes ##

mutable struct ZRLE{T<:IO} <: IO
    stream::T
    zeros::UInt64
end
ZRLE(io::IO) = ZRLE{typeof(io)}(io, 0)

Base.eof(io::ZRLE) = io.zeros == 0 && eof(io.stream)

function emit_leb128_byte(io::IO, zeros::UInt64)
    byte = (zeros % UInt8) & 0x7f
    zeros >>= 7
    byte |= UInt8(zeros > 0) << 7
    io.zeros = zeros
    return byte
end

function Base.read(io::ZRLE, ::Type{UInt8})
    zeros = io.zeros
    zeros > 0 && return emit_leb128_byte(io, zeros)
    while true
        byte = read(io.stream, UInt8)
        if byte ≠ 0
            zeros == 0 && return byte
            io.zeros = zeros
            return 0x0
        end
        zeros += 1
        if eof(io.stream) && 

        end
    end
end

read_zrle(io::IO) = read(ZRLE(io))
read_zrle(path::AbstractString) = open(read_zrle, path)

zrle(data::AbstractVector{UInt8}) = read(ZRLE(IOBuffer(data)))

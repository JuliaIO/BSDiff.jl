## IO type that run-length encodes zero bytes ##

mutable struct ZRLE{T<:IO} <: IO
    stream::T
    zeros::UInt64
end
ZRLE(io::IO) = ZRLE{typeof(io)}(io, 0)

Base.eof(io::ZRLE) = io.zeros == 0 && eof(io.stream)

function Base.read(io::ZRLE, ::Type{UInt8})
    zeros = io.zeros
    if zeros > 0
        byte = (zeros % UInt8) & 0x7f
        zeros >>= 7
        byte |= UInt8(zeros > 0) << 7
        io.zeros = zeros
        return byte
    end
    while !eof(io.stream)
        byte = read(io.stream, UInt8)
        if byte == 0
            zeros += 1
        elseif zeros == 0
            return byte
        else
            io.zeros = zeros
            return 0x0
        end
    end
    if zeros > 0
        byte = (zeros % UInt8) & 0x7f
        zeros >>= 7
        byte |= UInt8(zeros > 0) << 7
        io.zeros = zeros
        return byte
    end
    read(io.stream, UInt8) # error
end

read_zrle(io::IO) = read(ZRLE(io))
read_zrle(path::AbstractString) = open(read_zrle, path)

zrle(data::AbstractVector{UInt8}) = read(ZRLE(IOBuffer(data)))

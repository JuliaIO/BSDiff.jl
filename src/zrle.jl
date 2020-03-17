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
            read(io.stream, UInt8)
            zeros += 1
        end
        io.zeros = zeros
        return 0x0
    end
    n = zeros - 1
    # compute one LEB128 byte
    byte = (n % UInt8) & 0x7f
    n >>= 7
    byte |= UInt8(n > 0) << 7
    io.zeros = n + (n > 0)
    return byte
end

function Base.write(io::ZRLE, byte::UInt8)
    zeros = io.zeros
    if zeros == 0
        write(io.stream, byte)
        io.zeros = byte == 0
    else
        # decode LEB128 one byte at a time
        # leading bit indicates shift position
        # trailing bits are the value so far
        shift = 63 - leading_zeros(zeros)
        zeros &= ((1 << shift) - 1)
        zeros |= UInt64(byte) << shift
        if byte & 0x80 > 0
            io.zeros = zeros
        else
            for _ = 1:zeros
                write(io.stream, 0x0)
            end
            io.zeros = 0
        end
    end
    return 1
end

function read_zrle(path::AbstractString)
    data = read(path)
    file = IOBuffer(data)
    buf = IOBuffer(sizehint = length(data))
    while !eof(file)
        byte = read(file, UInt8)
        write(buf, byte)
        if byte == 0
            n = UInt64(0)
            while byte == 0 && !eof(file)
                byte = read(file, UInt8)
                n += byte == 0
            end
            write_leb128(buf, n)
            byte ≠ 0 && write(buf, byte)
        end
    end
    return take!(buf)
end

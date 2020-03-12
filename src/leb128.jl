## variable-length integer I/O ##

function write_leb128(io::IO, n::Unsigned)
    while true
        byte::UInt8 = n & 0x7f
        more = (n >>= 7) != 0
        byte |= UInt8(more) << 7
        write(io, byte)
        more || break
    end
end

function read_leb128(io::IO, ::Type{T}) where {T<:Unsigned}
    n::T = zero(T)
    shift = 0
    while true
       byte = read(io, UInt8)
       n |= T(byte & 0x7f) << shift
       (byte & 0x80) == 0 && break
       shift += 7
    end
    return n
end

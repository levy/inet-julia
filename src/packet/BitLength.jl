# ============================================================================
# BitLength — a bit-granular length that cannot be confused with a plain Int.
#
# INET keeps `b` and `B` as distinct types so `bits + bytes` cannot compile
# without a coercion. Here a bare `Int` simply is not a `BitLength`, so the
# same confusion is caught at the construction site — `Bits(n)` vs `Bytes(n)`
# — with none of the machinery. Two constructors, one representation.
#
# Semantics: "unspecified" is `nothing`; "at most" travels as a separate
# keyword rather than as a signed length. This kills the sign-overloaded
# length representation (INET defect 8) at the type level.
# ============================================================================

struct BitLength
    bits::Int64
end

Bits(n::Integer)  = BitLength(Int64(n))
Bytes(n::Integer) = BitLength(Int64(n) * 8)

const ZERO_LENGTH = BitLength(0)

# --- accessors ---------------------------------------------------------------
bits(l::BitLength)  = l.bits
bytes(l::BitLength) = l.bits >> 3                # exact only when isbyte(l)
isbyte(l::BitLength) = (l.bits & 7) == 0

# --- arithmetic --------------------------------------------------------------
Base.:+(a::BitLength, b::BitLength) = BitLength(a.bits + b.bits)
Base.:-(a::BitLength, b::BitLength) = BitLength(a.bits - b.bits)
Base.:*(a::BitLength, k::Integer)   = BitLength(a.bits * k)
Base.:*(k::Integer, a::BitLength)   = a * k

# --- comparison --------------------------------------------------------------
Base.:(==)(a::BitLength, b::BitLength) = a.bits == b.bits
Base.isless(a::BitLength, b::BitLength) = a.bits < b.bits
Base.hash(l::BitLength, h::UInt) = hash(l.bits, hash(:BitLength, h))
Base.zero(::Type{BitLength}) = ZERO_LENGTH
Base.zero(::BitLength) = ZERO_LENGTH
Base.iszero(l::BitLength) = l.bits == 0

Base.min(a::BitLength, b::BitLength) = BitLength(min(a.bits, b.bits))
Base.max(a::BitLength, b::BitLength) = BitLength(max(a.bits, b.bits))

function Base.show(io::IO, l::BitLength)
    if isbyte(l)
        print(io, bytes(l), "B")
    else
        print(io, l.bits, "b")
    end
end

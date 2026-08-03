# ============================================================================
# Quality — three monotone flags stated as a join-semilattice.
#
# INET carries `incomplete / incorrect / improperlyRepresented` as three bits
# with per-composite `isIncomplete()` overrides that OR the children by hand.
# There is no `markComplete/Correct/ProperlyRepresented`, which is what makes
# these monotone. Once monotone, they compose automatically via ⊔.
#
# Immutability is deliberately absent — Julia `struct`s are immutable and
# safe to share, so INET's fourth flag has no residue here (see plan §2.1).
# ============================================================================

struct Quality
    bits::UInt8
end

const Q_COMPLETE       = Quality(0x00)
const Q_INCOMPLETE     = Quality(0x01)
const Q_INCORRECT      = Quality(0x02)
const Q_MISREPRESENTED = Quality(0x04)

# The lattice: bitwise OR is the join.
⊔(a::Quality, b::Quality) = Quality(a.bits | b.bits)

Base.:(==)(a::Quality, b::Quality) = a.bits == b.bits
Base.hash(q::Quality, h::UInt) = hash(q.bits, hash(:Quality, h))

is_complete(q::Quality)        = (q.bits & Q_INCOMPLETE.bits) == 0
is_incomplete(q::Quality)      = !is_complete(q)
is_correct(q::Quality)         = (q.bits & Q_INCORRECT.bits) == 0
is_incorrect(q::Quality)       = !is_correct(q)
is_properly_represented(q::Quality)   = (q.bits & Q_MISREPRESENTED.bits) == 0
is_improperly_represented(q::Quality) = !is_properly_represented(q)

function Base.show(io::IO, q::Quality)
    if q == Q_COMPLETE
        print(io, "Q_COMPLETE")
    else
        parts = String[]
        is_incomplete(q)             && push!(parts, "incomplete")
        is_incorrect(q)              && push!(parts, "incorrect")
        is_improperly_represented(q) && push!(parts, "misrepresented")
        print(io, "Quality(", join(parts, "|"), ")")
    end
end

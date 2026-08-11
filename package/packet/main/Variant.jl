# ============================================================================
# A variant — one wire format, many concrete types.
#
# 158 of INET's 206 coded formats are served by a codec that reads a
# discriminator and then casts to a concrete type. `IcmpHeaderSerializer` reads
# three fields, switches on the type, and then copies those three fields into
# the concrete header by hand, once for each case — seven lines per case, and
# the branch had to fix a case that forgot them (`28a8970d9d`, "copy the
# action-frame fields when deserializing a DELBA").
#
# Here the base is an embedded field, so nothing is copied and nothing can be
# forgotten:
#
#     abstract type IcmpMessage <: Fields end
#
#     @header IcmpHeader <: IcmpMessage begin      # the base, and the fallback
#         type     :: IcmpType
#         code     :: U8
#         checksum :: Checksum16
#     end
#
#     @header IcmpEchoRequest <: IcmpMessage begin
#         base            :: IcmpHeader
#         identifier      :: U16
#         sequence_number :: U16
#     end
#
#     list_variants(::Type{IcmpMessage}) = (IcmpEchoRequest, IcmpEchoReply)
#     variant_base(::Type{IcmpMessage})  = IcmpHeader
#     matches_variant(::Type{IcmpEchoRequest}, base) = base.type == ICMP_ECHO_REQUEST
#
# A variant is a family, like an option family: an abstract type and three
# methods. It differs in how a member is chosen — an option family reads a code
# and looks it up, a variant reads the whole base and asks each member.
#
# The base is also the fallback. With no match it comes back marked
# misrepresented, which is what INET's `markImproperlyRepresented` means and
# what lets an unknown subtype still re-serialize byte for byte.
#
# Julia has no struct inheritance, and this needs none: the five-level 802.11
# chain is four levels of embedding.
# ============================================================================

"""
    list_variants(::Type{FAMILY})::Tuple

Every concrete member of a variant family. Empty for a header that is not one,
which is what makes the variant path cost nothing for every other header.
"""
list_variants(::Type{<:Fields}) = ()

"""
    variant_base(::Type{FAMILY})::Type

The member that carries the discriminator — the one a reader reads first, and
the one that comes back when no member claims what arrived.
"""
function variant_base end

"""
    variant_fallback(::Type{FAMILY})::Type

The member a message comes back as when no member claims it. It is usually the
base, and it is not always: ICMP's discriminator is four bytes and every
message is eight, so what a reader looks at and what it falls back to are two
different types.
"""
variant_fallback(::Type{FAMILY}) where {FAMILY} = variant_base(FAMILY)

"""
    matches_variant(::Type{MEMBER}, base)::Bool

Whether this member is what the base says arrived. The first member that says
yes is the one the reader builds.
"""
matches_variant(::Type, base) = false

"""
    select_variant(::Type{FAMILY}, base)::Type

The member the base selects, or `variant_base(FAMILY)` when none does.
"""
function select_variant(::Type{FAMILY}, base) where {FAMILY}
    for member in list_variants(FAMILY)
        matches_variant(member, base) && return member
    end
    return variant_fallback(FAMILY)
end

# The read path. It reads the base, rewinds, and reads again as the member the
# base chose — so a member's own declaration writes every field once, including
# the base's, and no case can forget to copy them.
function deserialize_variant(::Type{FAMILY}, io::BitReader) where {FAMILY}
    base_type = variant_base(FAMILY)
    at = io.bit_pos
    base = deserialize(base_type, io)
    header = base isa MarkedFields ? base.header : base
    member = select_variant(FAMILY, header)
    if member === variant_fallback(FAMILY)
        # Nothing claimed it, so read again as the fallback — which may be
        # wider than the part the reader looked at.
        io.bit_pos = at
        fallback = deserialize(variant_fallback(FAMILY), io)
        return mark_misrepresented(fallback isa MarkedFields ? fallback.header : fallback)
    end
    if member === base_type
        # Nothing claimed it. The base comes back, marked misrepresented: the
        # bytes are intact and the model does not describe them.
        return mark_misrepresented(header)
    end
    io.bit_pos = at
    return deserialize(member, io)
end

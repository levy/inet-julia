# ============================================================================
# Checksums — the mode, the algorithm, and the way a header computes its own.
#
# INET carries a `ChecksumMode` on every chunk that has a checksum, and the
# serializer reads it: `CHECKSUM_DECLARED` writes the stored value as it is,
# `CHECKSUM_COMPUTED` requires a value the model already computed, and
# `CHECKSUM_DISABLED` writes zero. The default is `declared`, which is why
# INET can round-trip a capture it cannot verify.
#
# `@header` needs no `checksum` clause for this. A mode is a model-only field
# (width 0) and the value is a `derive` that reads it:
#
#     checksum      :: UInt16 | 16 | hex |
#                      derive(checksum_mode == CHECKSUM_COMPUTED ?
#                             internet_checksum(h, :checksum) : checksum) = 0x0000
#     checksum_mode :: ChecksumMode | 0 = CHECKSUM_DECLARED
#
# The recursion that would otherwise bite — computing the checksum needs the
# bytes, and the bytes need the checksum — is broken by `internet_checksum`:
# it serialises a COPY whose mode is `declared` and whose checksum field is
# zero, so the derive above takes its other branch and stops.
# ============================================================================

"""
    ChecksumMode

What a header does with its checksum field when it is serialised.
`CHECKSUM_DECLARED` writes the stored value unchanged, which is what lets a
capture round-trip byte for byte without the reader verifying anything.
"""
@enum ChecksumMode CHECKSUM_DECLARED = 0 CHECKSUM_COMPUTED = 1 CHECKSUM_DISABLED = 2

"""
    ones_complement_checksum(bytes)::UInt16

The internet checksum of RFC 1071: the one's complement of the one's
complement sum of the bytes taken as 16-bit big-endian words. An odd number of
bytes is padded with a zero on the right.
"""
function ones_complement_checksum(bytes::AbstractVector{UInt8})
    total = UInt32(0)
    index = firstindex(bytes)
    last = lastindex(bytes)
    while index <= last
        high = UInt32(bytes[index])
        low = index < last ? UInt32(bytes[index + 1]) : UInt32(0)
        total += (high << 8) | low
        index += 2
    end
    while total > 0xffff
        total = (total & 0xffff) + (total >> 16)
    end
    return UInt16(~total & 0xffff)
end

"""
    with_field(h::Fields, field::Symbol, value)

A copy of `h` whose `field` is `value`. A header is immutable, so this rebuilds
it through its positional constructor.
"""
function with_field(h::H, field::Symbol, value) where {H <: Fields}
    field in fieldnames(H) ||
        error("with_field: $(H) has no field `$(field)`")
    return H((name === field ? value : getfield(h, name) for name in fieldnames(H))...)
end

"""
    internet_checksum(h::Fields, field = :checksum; mode_field = :checksum_mode)

The RFC 1071 checksum of `h`, computed over the header's own bytes with
`field` set to zero.

This is what a `derive` clause calls. It breaks the recursion by serialising a
copy whose `mode_field` says `CHECKSUM_DECLARED`, so the derive that called it
takes its other branch and reads the zero this function just wrote.
"""
function internet_checksum(h::Fields, field::Symbol = :checksum;
                           mode_field::Symbol = :checksum_mode)
    zeroed = with_field(h, field, zero(fieldtype(typeof(h), field)))
    if mode_field in fieldnames(typeof(h))
        zeroed = with_field(zeroed, mode_field, CHECKSUM_DECLARED)
    end
    return ones_complement_checksum(to_bytes(zeroed))
end

"""
    internet_checksum(h::Fields, field, pseudo_header::AbstractVector{UInt8})

The same checksum, taken over `pseudo_header` and then the header's own bytes.
TCP and UDP need this: their checksum covers addresses that live in the IP
header above them, not in their own.
"""
function internet_checksum(h::Fields, field::Symbol,
                           pseudo_header::AbstractVector{UInt8};
                           mode_field::Symbol = :checksum_mode)
    zeroed = with_field(h, field, zero(fieldtype(typeof(h), field)))
    if mode_field in fieldnames(typeof(h))
        zeroed = with_field(zeroed, mode_field, CHECKSUM_DECLARED)
    end
    return ones_complement_checksum(vcat(pseudo_header, to_bytes(zeroed)))
end

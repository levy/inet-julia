# ============================================================================
# The protocol elements — INET's one-purpose headers.
#
# Each carries one fact and nothing else, so a model can compose a protocol out
# of them rather than declaring a whole format. Only the three below have a
# serializer; the rest of `protocolelement/` states a field model that no code
# turns into bytes, so there is nothing to port.
# ============================================================================

"""
    SequenceNumberHeader(; sequence_number)

Two bytes of sequence number, for a protocol that needs ordering and nothing
else.
"""
@header SequenceNumberHeader begin
    sequence_number :: U16
end

"""
    FragmentNumberHeader(; fragment_number, last_fragment)

One byte: seven bits of fragment number and the bit that says this is the last
one.
"""
@header FragmentNumberHeader begin
    fragment_number :: U7
    last_fragment   :: Bool = false
end

"""
    ChecksumHeader(; checksum, checksum_mode)

A checksum on its own. INET sets its width programmatically — one, two, four or
eight bytes — and this declares the two-byte form, which is the one its
serializer registers.
"""
@header ChecksumHeader begin
    checksum      :: Checksum16 = 0
    checksum_mode :: Model{ChecksumMode} = CHECKSUM_DECLARED
end

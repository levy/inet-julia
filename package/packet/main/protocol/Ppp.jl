# ============================================================================
# PPP — RFC 1662, in the shape INET serializes.
#
# The header is the flag, the all-stations address, the unnumbered-information
# control field and the protocol; the trailer is the frame check sequence.
#
# INET's trailer is two bytes and not three: it does not carry the closing
# flag, and its own source says so. This follows INET rather than the RFC,
# because a frame it wrote must read back.
# ============================================================================

const PPP_FLAG    = 0x7E      # the frame delimiter
const PPP_ADDRESS = 0xFF      # all stations
const PPP_CONTROL = 0x03      # unnumbered information

const PPP_PROTOCOL_IPV4 = 0x0021
const PPP_PROTOCOL_IPV6 = 0x0057

"""
    PppHeader(; protocol, flag, address, control)

The PPP header, 5 bytes. The first three fields are what RFC 1662 fixes for a
frame with no address or control compression.
"""
@header PppHeader begin
    flag     :: U8  = PPP_FLAG
    address  :: U8  = PPP_ADDRESS
    control  :: U8  = PPP_CONTROL
    protocol :: U16
end

"""
    PppTrailer(; fcs)

The PPP frame check sequence, 2 bytes. Declared, never computed — the same
choice every other frame check in this library makes.
"""
@header PppTrailer begin
    fcs :: U16 = 0
end

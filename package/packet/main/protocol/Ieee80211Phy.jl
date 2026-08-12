# ============================================================================
# The IEEE 802.11 physical-layer headers.
#
# Six headers, one per modulation, and they have almost nothing in common: each
# physical layer was specified on its own and they do not share a base. What
# they share is that the MAC frame follows them, and that each one states the
# length of that frame in units of its own choosing.
#
# Two things separate them from every other header in the inventory.
#
#   * **Every field after the first is little-endian.** The DSSS and HR/DSSS
#     headers write their length and their checksum least significant octet
#     first — IEEE 802.11-2016 clause 16.2.3 — where every other header here is
#     network order. That is a property of the header, so `byte_order` says it
#     once for the whole header.
#   * **The OFDM SIGNAL field is transmitted least significant BIT first.** No
#     `byte_order` can express that, because the field is twenty-four bits and
#     its parts are not octet-aligned. It is `Ieee80211OfdmSignal`, a value type
#     that carries its own order, which is the same answer the 802.11 duration
#     and sequence-control fields got.
#
# INET declares an HT and a VHT header and its serializer writes nothing for
# either — both `serialize` bodies are empty. They are not declared here: a
# header with no fields is not a wire format, and inventing one would be worse
# than saying it is missing.
# ============================================================================

"The widths the standard gives each physical-layer header, in octets."
const IEEE80211_FHSS_PHY_HEADER_BYTES     = 4
const IEEE80211_IR_PHY_HEADER_BYTES       = 2
const IEEE80211_DSSS_PHY_HEADER_BYTES     = 6
const IEEE80211_HR_DSSS_PHY_HEADER_BYTES  = 6
const IEEE80211_OFDM_PHY_HEADER_BYTES     = 5

"""
    Ieee80211FhssPhyHeader(; psdu_length, signalling, header_error_check)

The frequency-hopping spread spectrum header — IEEE 802.11-2016 clause 18.2.3.

`psdu_length` is the PLW, twelve bits of octet count. `signalling` is the PSF,
four bits that name the data rate. `header_error_check` is a CRC over the two
fields above it, and INET calls it the FCS.

Every field is network order, which makes this the only physical-layer header
here that is.
"""
@header Ieee80211FhssPhyHeader begin
    psdu_length              :: U12 = 0
    signalling               :: U4  = 0
    header_error_check       :: Checksum16 = 0
    header_error_check_mode  :: Model{ChecksumMode} = CHECKSUM_DECLARED
end

"""
    Ieee80211IrPhyHeader(; crc)

The infrared header — IEEE 802.11-1997 clause 16.2.3.

INET writes two octets of CRC and nothing else, and this follows it. The 1997
standard puts a data rate and a length field in front of the CRC; INET's model
has neither, and declaring a layout that was not read from the standard would be
worse than declaring the two octets INET does write. The infrared physical layer
was withdrawn in 802.11-2012.
"""
@header Ieee80211IrPhyHeader begin
    crc      :: Checksum16 = 0
    crc_mode :: Model{ChecksumMode} = CHECKSUM_DECLARED
end

"""
    Ieee80211DsssPhyHeader(; signal, service, length_field, crc)

The direct sequence spread spectrum header — IEEE 802.11-2016 clause 16.2.3.
Six octets, and the last four are little-endian.

`signal` is the data rate in units of 100 kbit/s, so eleven means 1.1 Mbit/s.
Clause 16.2.3.4 says `length_field` counts the MICROSECONDS the frame that
follows will take; INET writes octets there, which is its own model and not the
standard's.
"""
@header Ieee80211DsssPhyHeader begin
    signal       :: U8  = 10
    service      :: U8  = 0
    length_field :: U16 = 0
    crc          :: Checksum16 = 0
    crc_mode     :: Model{ChecksumMode} = CHECKSUM_DECLARED
end

byte_order(::Type{Ieee80211DsssPhyHeader}) = :le

"""
    Ieee80211HrDsssPhyHeader(; signal, service, length_field, crc)

The high rate direct sequence spread spectrum header — IEEE 802.11-2016 clause
17.2.3. It is the DSSS header again, with rates up to 11 Mbit/s.
"""
@header Ieee80211HrDsssPhyHeader begin
    signal       :: U8  = 10
    service      :: U8  = 0
    length_field :: U16 = 0
    crc          :: Checksum16 = 0
    crc_mode     :: Model{ChecksumMode} = CHECKSUM_DECLARED
end

byte_order(::Type{Ieee80211HrDsssPhyHeader}) = :le

"""
    Ieee80211OfdmPhyHeader(; signal, service)

The orthogonal frequency division multiplexing header — IEEE 802.11-2016 clause
17.3. Five octets: three of SIGNAL and two of SERVICE.

The SIGNAL field goes out least significant bit first, so it is one value and
not five fields. `Ieee80211OfdmSignal` reads its parts back.
"""
@header Ieee80211OfdmPhyHeader begin
    signal  :: Ieee80211OfdmSignal = Ieee80211OfdmSignal()
    service :: U16 = 0
end

byte_order(::Type{Ieee80211OfdmPhyHeader}) = :le

"""
    Ieee80211ErpOfdmPhyHeader(; signal, service)

The extended rate OFDM header — IEEE 802.11-2016 clause 18.3. It is the OFDM
header on the 2.4 GHz band, and the octets are the same.
"""
@header Ieee80211ErpOfdmPhyHeader begin
    signal  :: Ieee80211OfdmSignal = Ieee80211OfdmSignal()
    service :: U16 = 0
end

byte_order(::Type{Ieee80211ErpOfdmPhyHeader}) = :le

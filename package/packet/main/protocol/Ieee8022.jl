# ============================================================================
# IEEE 802.2 — logical link control, and the SNAP extension.
#
# Clause 3.2 gives the LLC PDU three fields: the destination service access
# point, the source service access point, and a control field of one or two
# octets. The control field is two octets unless its low two bits are both set,
# which is what `when` says here and what INET's `(control & 3) != 3` says
# there.
#
# ONE DIFFERENCE FROM INET, and it is deliberate. `Ieee8022LlcHeaderSerializer`
# writes the SSAP before the DSAP. IEEE 802.2 clause 3.2 puts the DSAP first,
# and this follows the standard. A frame this library writes therefore does not
# match one INET writes, and the two disagree about which byte is which.
# ============================================================================

const LLC_SAP_SNAP = 0xAA
const LLC_SAP_IP   = 0x06
const LLC_CONTROL_UNNUMBERED_INFORMATION = 0x03

"""
    Ieee8022LlcHeader(; dsap, ssap, control, control_high)

The LLC PDU header, 3 bytes, or 4 when the control field takes two octets.
Leave `control_high` at `nothing` for the one-octet form.
"""
@header Ieee8022LlcHeader begin
    dsap         :: U8
    ssap         :: U8
    control      :: U8 = LLC_CONTROL_UNNUMBERED_INFORMATION
    control_high :: Optional{U8} = nothing
        when(control & 0x03 != 0x03)
end

"""
    Ieee8022SnapHeader(; oui, protocol_id)

The SNAP extension on its own, 5 bytes: a 24-bit organizationally unique
identifier and a 16-bit protocol identifier. An OUI of zero means the protocol
identifier is an EtherType.
"""
@header Ieee8022SnapHeader begin
    oui         :: U24 = 0
    protocol_id :: U16
end

"""
    Ieee8022LlcSnapHeader(; llc, oui, protocol_id)

An LLC header followed by the SNAP extension, 8 bytes. The LLC part is an
embedded header rather than a repeated declaration, so the two cannot drift.
"""
@header Ieee8022LlcSnapHeader begin
    llc         :: Ieee8022LlcHeader =
                   Ieee8022LlcHeader(dsap = LLC_SAP_SNAP, ssap = LLC_SAP_SNAP)
    oui         :: U24 = 0
    protocol_id :: U16
end

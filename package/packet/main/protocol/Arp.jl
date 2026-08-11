# ============================================================================
# ARP — RFC 826, over Ethernet and IPv4.
#
# The first four fields say what kind of addresses the rest carries, and for
# Ethernet over IPv4 all four are fixed: hardware type 1, protocol type 0x0800,
# a six-byte hardware address and a four-byte protocol address. INET writes
# them as literals, and here they are constants — on the wire, not in the
# struct, because a model that could change them would describe a packet this
# declaration cannot carry.
# ============================================================================

const ARP_REQUEST      = 1
const ARP_REPLY        = 2
const ARP_RARP_REQUEST = 3
const ARP_RARP_REPLY   = 4

const ARP_HARDWARE_ETHERNET = 1

"""
    ArpPacket(; opcode, source_mac, source_ip, destination_mac, destination_ip)

An ARP packet for Ethernet and IPv4, 28 bytes.
"""
@header ArpPacket begin
    hardware_type        :: Constant{U16, ARP_HARDWARE_ETHERNET}
    protocol_type        :: Constant{U16, 0x0800}
    hardware_address_size :: Constant{U8, 6}
    protocol_address_size :: Constant{U8, 4}
    opcode               :: U16
    source_mac           :: MacAddress
    source_ip            :: Ipv4Address
    destination_mac      :: MacAddress
    destination_ip       :: Ipv4Address
end

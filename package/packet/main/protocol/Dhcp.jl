# ============================================================================
# The dynamic host configuration protocol — RFC 2131.
#
# A message is two hundred and forty octets of fixed fields, a four-octet magic
# cookie, and then options until the End option. Most of those fixed octets are
# the three name fields — the client hardware address, the server name and the
# boot file — which is what `FixedOctets` is for.
#
# **A fault in INET, and this one changes the octets.** `DhcpMessageSerializer`
# writes the flags field as a single bit:
#
#     stream.writeBit(dhcpMessage->getBroadcast());
#     stream.writeIpv4Address(dhcpMessage->getCiaddr());
#
# RFC 2131 clause 2 gives `flags` two octets — the broadcast bit and fifteen
# reserved bits. Writing one bit leaves every field after it misaligned by
# fifteen bits, so INET's message is not a DHCP message from `ciaddr` onward.
# The standard's two octets are declared here.
# ============================================================================

const DHCP_BOOT_REQUEST = 1
const DHCP_BOOT_REPLY   = 2

"The hardware type, from the ARP table — RFC 2131 clause 2."
const DHCP_HARDWARE_ETHERNET = 1
const DHCP_ETHERNET_ADDRESS_BYTES = 6

"The magic cookie that starts the options — RFC 2132 clause 2."
const DHCP_MAGIC_COOKIE = UInt8[99, 130, 83, 99]

"The option codes — RFC 2132."
const DHCP_OPTION_PAD            = 0
const DHCP_OPTION_SUBNET_MASK    = 1
const DHCP_OPTION_ROUTER         = 3
const DHCP_OPTION_HOST_NAME      = 12
const DHCP_OPTION_REQUESTED_IP   = 50
const DHCP_OPTION_LEASE_TIME     = 51
const DHCP_OPTION_MESSAGE_TYPE   = 53
const DHCP_OPTION_SERVER_ID      = 54
const DHCP_OPTION_PARAMETER_LIST = 55
const DHCP_OPTION_CLIENT_ID      = 61
const DHCP_OPTION_END            = 255

"The message types an option 53 carries — RFC 2132 clause 9.6."
const DHCP_DISCOVER = 1
const DHCP_OFFER    = 2
const DHCP_REQUEST  = 3
const DHCP_DECLINE  = 4
const DHCP_ACK      = 5
const DHCP_NAK      = 6
const DHCP_RELEASE  = 7
const DHCP_INFORM   = 8

"The fixed part of a message, the magic cookie included — RFC 2131 clause 2."
const DHCP_MESSAGE_BYTES = 240

"The DHCP options — one shape, and the code octet says which."
abstract type DhcpOption <: Fields end

"""
    DhcpPad()

The Pad option, one octet — RFC 2132 clause 3.1. It has no length and no value.
"""
@header DhcpPad <: DhcpOption begin
    code :: Constant{U8, DHCP_OPTION_PAD}
end

"""
    DhcpEnd()

The End option, one octet — RFC 2132 clause 3.2. Everything after it is
padding.
"""
@header DhcpEnd <: DhcpOption begin
    code :: Constant{U8, DHCP_OPTION_END}
end

"""
    DhcpMessageType(; message_type)

The DHCP Message Type option, three octets — RFC 2132 clause 9.6. Every message
carries one, and it is what makes a message a DISCOVER or an ACK.
"""
@header DhcpMessageType <: DhcpOption begin
    code         :: Constant{U8, DHCP_OPTION_MESSAGE_TYPE}
    length       :: Constant{U8, 1}
    message_type :: U8 = DHCP_DISCOVER
end

"""
    DhcpAddressOption(; code, address)

An option whose value is one IPv4 address, six octets. The subnet mask, the
requested address and the server identifier all have this shape, and the code
says which one this is.
"""
@header DhcpAddressOption <: DhcpOption begin
    code    :: U8 = DHCP_OPTION_REQUESTED_IP
    length  :: Constant{U8, 4}
    address :: Ipv4Address
end

"""
    DhcpOptionRaw(; code, value)

An option this library does not model. It keeps its code and its octets, so a
message round-trips where the model stops.
"""
@header DhcpOptionRaw <: DhcpOption begin
    code   :: U8
    length :: U8 = 0
        derive(Base.length(value))
    value  :: Octets = UInt8[]
        length(Bytes(length))
end

list_options(::Type{DhcpOption}) = (DhcpPad, DhcpEnd, DhcpMessageType)
find_raw_option(::Type{DhcpOption}) = DhcpOptionRaw
ends_option_list(::Type{DhcpOption}, code) = code == DHCP_OPTION_END

"""
    DhcpMessage(; op, transaction_id, client_address, your_address, options, …)

A DHCP message — RFC 2131 clause 2. Two hundred and forty octets and then the
options.

`client_hardware_address` is sixteen octets whatever the hardware is, so an
Ethernet address takes the first six and the other ten are zero. `server_name`
and `boot_file` are the two long name fields, and both are zero-terminated.
"""
@header DhcpMessage begin
    op                      :: U8 = DHCP_BOOT_REQUEST
    hardware_type           :: U8 = DHCP_HARDWARE_ETHERNET
    hardware_length         :: U8 = DHCP_ETHERNET_ADDRESS_BYTES
    hops                    :: U8 = 0
    transaction_id          :: U32 = 0
    seconds                 :: U16 = 0
    broadcast               :: Bool = false
    reserved                :: U15 = 0
    client_address          :: Ipv4Address
    your_address            :: Ipv4Address
    server_address          :: Ipv4Address
    gateway_address         :: Ipv4Address
    client_hardware_address :: FixedOctets{16} = zeros(UInt8, 16)
    server_name             :: FixedOctets{64} = zeros(UInt8, 64)
    boot_file               :: FixedOctets{128} = zeros(UInt8, 128)
    magic_cookie            :: FixedOctets{4} = copy(DHCP_MAGIC_COOKIE)
    options                 :: Options{DhcpOption} = DhcpOption[]
end

"The Ethernet address a message carries — the first six of its sixteen octets."
read_client_mac(message::DhcpMessage) =
    MacAddress(sum(UInt64(message.client_hardware_address[index]) << (8 * (6 - index))
                   for index in 1:6))

"The sixteen-octet client hardware address an Ethernet address makes."
build_client_hardware_address(address::MacAddress) =
    FixedOctets{16}(vcat(collect(UInt8, list_mac_octets(address)), zeros(UInt8, 10)))

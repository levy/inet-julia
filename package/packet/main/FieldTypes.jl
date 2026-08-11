# ============================================================================
# The named field types — the values the standards give names to.
#
# A protocol field is rarely "a 16-bit number". RFC 768 calls it a Source Port,
# RFC 791 calls it a Protocol, IEEE 802.3 calls it a MAC address. Each of those
# is a type here, for three reasons:
#
#   * a header cannot take a port where it wants a length;
#   * the value prints itself, so one text form serves the REPL, the tests, the
#     packet diagram and the editor, and no declaration states a display base;
#   * the width comes from the type, so a declaration states a width only where
#     the standard gives a bare N-bit number.
#
# `FieldValue.jl` holds the protocol these answer, and the numbers `U4`, `I12`,
# `Bool`, `Constant` and `Model`.
# ============================================================================

# ---------- MacAddress ------------------------------------------------------

"""
    MacAddress(value)
    MacAddress(o1, o2, o3, o4, o5, o6)
    MacAddress(text)

A 48-bit IEEE 802 address. It prints and parses as `0a:00:00:00:00:01`.
"""
struct MacAddress
    value::UInt64
    MacAddress(value::Integer) = new(UInt64(value) & 0x0000_ffff_ffff_ffff)
end

MacAddress(o1::Integer, o2::Integer, o3::Integer, o4::Integer, o5::Integer, o6::Integer) =
    MacAddress((UInt64(o1) << 40) | (UInt64(o2) << 32) | (UInt64(o3) << 24) |
               (UInt64(o4) << 16) | (UInt64(o5) << 8) | UInt64(o6))

function MacAddress(text::AbstractString)
    parts = split(text, ':')
    Base.length(parts) == 6 || error("MacAddress: expected six octets, got $(repr(text))")
    MacAddress((parse(UInt8, p, base = 16) for p in parts)...)
end

MacAddress(v::MacAddress) = v

"The six octets of an address, most significant first."
list_mac_octets(m::MacAddress) = ntuple(i -> UInt8((m.value >> (8 * (6 - i))) & 0xff), 6)

Base.show(io::IO, m::MacAddress) =
    print(io, join((string(o, base = 16, pad = 2) for o in list_mac_octets(m)), ":"))

Base.convert(::Type{MacAddress}, value::Integer) = MacAddress(value)
Base.convert(::Type{MacAddress}, text::AbstractString) = MacAddress(text)

measure_field(::Type{MacAddress}) = 48
encode_field(::Type{MacAddress}, m::MacAddress) = m.value
decode_field(::Type{MacAddress}, bits::UInt64) = MacAddress(bits)
classify_display(::Type{MacAddress}) = :openable
literal_field(m::MacAddress) = string("MacAddress(", repr(string(m)), ")")

"The broadcast address, `ff:ff:ff:ff:ff:ff`."
const MAC_BROADCAST = MacAddress(0x0000_ffff_ffff_ffff)

is_multicast(m::MacAddress) = !iszero(m.value & (UInt64(1) << 40))
is_broadcast(m::MacAddress) = m == MAC_BROADCAST

# ---------- Ipv4Address -----------------------------------------------------

"""
    Ipv4Address(value)
    Ipv4Address(a, b, c, d)
    Ipv4Address(text)

A 32-bit IPv4 address. It prints and parses as `10.0.0.1`.
"""
struct Ipv4Address
    value::UInt32
    Ipv4Address(value::Integer) = new(UInt32(value))
end

Ipv4Address(a::Integer, b::Integer, c::Integer, d::Integer) =
    Ipv4Address((UInt32(a) << 24) | (UInt32(b) << 16) | (UInt32(c) << 8) | UInt32(d))

function Ipv4Address(text::AbstractString)
    parts = split(text, '.')
    Base.length(parts) == 4 || error("Ipv4Address: expected four octets, got $(repr(text))")
    Ipv4Address((parse(UInt8, p) for p in parts)...)
end

Ipv4Address(v::Ipv4Address) = v

"The four octets of an address, most significant first."
list_ipv4_octets(a::Ipv4Address) = ntuple(i -> UInt8((a.value >> (8 * (4 - i))) & 0xff), 4)

Base.show(io::IO, a::Ipv4Address) = print(io, join(list_ipv4_octets(a), "."))

Base.convert(::Type{Ipv4Address}, value::Integer) = Ipv4Address(value)
Base.convert(::Type{Ipv4Address}, text::AbstractString) = Ipv4Address(text)

measure_field(::Type{Ipv4Address}) = 32
encode_field(::Type{Ipv4Address}, a::Ipv4Address) = UInt64(a.value)
decode_field(::Type{Ipv4Address}, bits::UInt64) = Ipv4Address(UInt32(bits))
classify_display(::Type{Ipv4Address}) = :openable
literal_field(a::Ipv4Address) = string("Ipv4Address(", repr(string(a)), ")")

# ---------- Ipv6Address -----------------------------------------------------

"""
    Ipv6Address(high, low)
    Ipv6Address(text)

A 128-bit IPv6 address, as two 64-bit halves. It prints in the form RFC 5952
asks for: lower-case hex, no leading zero in a group, and `::` over the longest
run of zero groups.

This is the type that a `UInt64` cannot carry, so it defines `write_field` and
`read_field` rather than `encode_field` and `decode_field`.
"""
struct Ipv6Address
    high::UInt64
    low::UInt64
end

Ipv6Address(groups::NTuple{8, <:Integer}) =
    Ipv6Address(foldl((a, g) -> (a << 16) | UInt64(g), groups[1:4]; init = UInt64(0)),
                foldl((a, g) -> (a << 16) | UInt64(g), groups[5:8]; init = UInt64(0)))

Ipv6Address(v::Ipv6Address) = v

"The eight 16-bit groups of an address, most significant first."
list_ipv6_groups(a::Ipv6Address) =
    ntuple(i -> UInt16(((i <= 4 ? a.high : a.low) >> (16 * (4 - mod1(i, 4)))) & 0xffff), 8)

function Ipv6Address(text::AbstractString)
    left, _, right = split_once(text, "::")
    head = isempty(left) ? UInt16[] : [parse(UInt16, p, base = 16) for p in split(left, ':')]
    tail = isempty(right) ? UInt16[] : [parse(UInt16, p, base = 16) for p in split(right, ':')]
    if occursin("::", text)
        Base.length(head) + Base.length(tail) <= 7 ||
            error("Ipv6Address: `::` needs a run of at least one zero group in $(repr(text))")
        groups = vcat(head, zeros(UInt16, 8 - Base.length(head) - Base.length(tail)), tail)
    else
        groups = head
        Base.length(groups) == 8 ||
            error("Ipv6Address: expected eight groups, got $(repr(text))")
    end
    return Ipv6Address(NTuple{8, UInt16}(groups))
end

"Split `text` at the first `separator`, into the part before, the separator and the part after."
function split_once(text::AbstractString, separator::AbstractString)
    at = findfirst(separator, text)
    at === nothing && return (text, "", "")
    return (text[begin:prevind(text, first(at))], separator, text[nextind(text, last(at)):end])
end

# RFC 5952 shortens only a run of two or more zero groups, and takes the
# leftmost longest run.
function find_zero_run(groups::NTuple{8, UInt16})
    best = nothing
    start = nothing
    for i in 1:9
        zero = i <= 8 && iszero(groups[i])
        if zero && start === nothing
            start = i
        elseif !zero && start !== nothing
            run = start:(i - 1)
            if Base.length(run) >= 2 && (best === nothing || Base.length(run) > Base.length(best))
                best = run
            end
            start = nothing
        end
    end
    return best
end

function Base.show(io::IO, a::Ipv6Address)
    groups = list_ipv6_groups(a)
    text(i) = string(groups[i], base = 16)
    run = find_zero_run(groups)
    if run === nothing
        print(io, join((text(i) for i in 1:8), ":"))
    else
        print(io, join((text(i) for i in 1:(first(run) - 1)), ":"), "::",
                  join((text(i) for i in (last(run) + 1):8), ":"))
    end
end

Base.convert(::Type{Ipv6Address}, text::AbstractString) = Ipv6Address(text)

const IPV6_UNSPECIFIED = Ipv6Address(0, 0)
const IPV6_LOOPBACK    = Ipv6Address(0, 1)

measure_field(::Type{Ipv6Address}) = 128
classify_display(::Type{Ipv6Address}) = :openable
literal_field(a::Ipv6Address) = string("Ipv6Address(", repr(string(a)), ")")

function write_field(io::BitWriter, ::Type{Ipv6Address}, a::Ipv6Address,
                     width::Int, order::Symbol)
    width == 128 || error("Ipv6Address: expected a 128-bit field, got $width")
    order === :be || error("Ipv6Address: an address travels in network order")
    write_bits!(io, a.high, 64)
    write_bits!(io, a.low, 64)
end

function read_field(io::BitReader, ::Type{Ipv6Address}, width::Int, order::Symbol)
    width == 128 || error("Ipv6Address: expected a 128-bit field, got $width")
    order === :be || error("Ipv6Address: an address travels in network order")
    high = read_bits!(io, 64)
    return Ipv6Address(high, read_bits!(io, 64))
end

# ---------- EtherTypeOrLength -----------------------------------------------

"""
    EtherTypeOrLength(value)

The third field of an IEEE 802.3 MAC header, which is one field with two
readings: clause 3.2.6 makes a value up to 1500 a length, and 1536 or above an
EtherType. INET splits it into two chunk classes; the standard does not, so
neither does this.

A value the table names prints as `IPv4 (0x0800)`, a length prints as `1500 B`,
and anything else prints as its number — a foreign implementation may send a
type this library does not know.
"""
struct EtherTypeOrLength
    value::UInt16
    EtherTypeOrLength(value::Integer) = new(UInt16(value))
end

EtherTypeOrLength(v::EtherTypeOrLength) = v

const MAX_ETHERNET_LENGTH_FIELD = 1500
const MIN_ETHERNET_TYPE_FIELD   = 1536

const ETHER_TYPE_NAMES = Dict{UInt16, String}(
    0x0800 => "IPv4",
    0x0806 => "ARP",
    0x8100 => "VLAN",
    0x86dd => "IPv6",
    0x88a8 => "QinQ",
    0x88cc => "LLDP",
    0x88f7 => "PTP")

is_length(t::EtherTypeOrLength) = t.value <= MAX_ETHERNET_LENGTH_FIELD
is_type(t::EtherTypeOrLength)   = t.value >= MIN_ETHERNET_TYPE_FIELD

"The name of an EtherType, or `nothing` when the table does not know it."
find_ether_type_name(t::EtherTypeOrLength) = get(ETHER_TYPE_NAMES, t.value, nothing)

function Base.show(io::IO, t::EtherTypeOrLength)
    if is_length(t)
        print(io, Int(t.value), " B")
    else
        name = find_ether_type_name(t)
        hex = "0x" * string(t.value, base = 16, pad = 4)
        name === nothing ? print(io, hex) : print(io, name, " (", hex, ")")
    end
end

Base.convert(::Type{EtherTypeOrLength}, value::Integer) = EtherTypeOrLength(value)

measure_field(::Type{EtherTypeOrLength}) = 16
encode_field(::Type{EtherTypeOrLength}, t::EtherTypeOrLength) = UInt64(t.value)
decode_field(::Type{EtherTypeOrLength}, bits::UInt64) = EtherTypeOrLength(UInt16(bits))
classify_display(::Type{EtherTypeOrLength}) = :openable
# The text form is `IPv4 (0x0800)` or `1500 B`, neither of which is an
# expression, so the number comes back as the hex a standard quotes.
literal_field(t::EtherTypeOrLength) =
    string("EtherTypeOrLength(0x", string(t.value, base = 16, pad = 4), ")")

# ---------- IpProtocol ------------------------------------------------------

"""
    IpProtocol(value)

The 8-bit Protocol field of an IPv4 header, and the Next Header field of an
IPv6 one. It prints as `UDP (17)` when the table names it, and as its number
alone when it does not.
"""
struct IpProtocol
    value::UInt8
    IpProtocol(value::Integer) = new(UInt8(value))
end

IpProtocol(v::IpProtocol) = v

const IP_PROTOCOL_NAMES = Dict{UInt8, String}(
    0x01 => "ICMP",
    0x02 => "IGMP",
    0x06 => "TCP",
    0x11 => "UDP",
    0x29 => "IPv6",
    0x2b => "IPv6-Route",
    0x2c => "IPv6-Frag",
    0x3a => "ICMPv6",
    0x3b => "IPv6-NoNxt",
    0x59 => "OSPF",
    0x84 => "SCTP")

"The name of a protocol number, or `nothing` when the table does not know it."
find_ip_protocol_name(p::IpProtocol) = get(IP_PROTOCOL_NAMES, p.value, nothing)

function Base.show(io::IO, p::IpProtocol)
    name = find_ip_protocol_name(p)
    name === nothing ? print(io, Int(p.value)) : print(io, name, " (", Int(p.value), ")")
end

Base.convert(::Type{IpProtocol}, value::Integer) = IpProtocol(value)

measure_field(::Type{IpProtocol}) = 8
encode_field(::Type{IpProtocol}, p::IpProtocol) = UInt64(p.value)
decode_field(::Type{IpProtocol}, bits::UInt64) = IpProtocol(UInt8(bits))
classify_display(::Type{IpProtocol}) = :openable
literal_field(p::IpProtocol) = string("IpProtocol(", Int(p.value), ")")

# ---------- Port ------------------------------------------------------------

"""
    Port(value)

A 16-bit transport port. It is a type of its own so that a header cannot take a
port where it wants a length, and so that a view knows to print it as a decimal
number.
"""
struct Port
    value::UInt16
    Port(value::Integer) = new(UInt16(value))
end

Port(v::Port) = v

Base.show(io::IO, p::Port) = print(io, Int(p.value))
Base.convert(::Type{Port}, value::Integer) = Port(value)
Base.:(==)(a::Port, b::Integer) = a.value == b
Base.:(==)(a::Integer, b::Port) = a == b.value

measure_field(::Type{Port}) = 16
encode_field(::Type{Port}, p::Port) = UInt64(p.value)
decode_field(::Type{Port}, bits::UInt64) = Port(UInt16(bits))
classify_display(::Type{Port}) = :scalar
literal_field(p::Port) = string("Port(", Int(p.value), ")")

# ---------- Checksum16 ------------------------------------------------------

"""
    Checksum16(value)

A 16-bit internet checksum, as RFC 1071 defines it. It is a type of its own so
that it prints as hex without any declaration saying so, and so that a header
cannot take a checksum where it wants a length.

RFC 768 gives zero a second meaning in UDP: the sender did not compute one.
`is_absent` asks that question.
"""
struct Checksum16
    value::UInt16
    Checksum16(value::Integer) = new(UInt16(value))
end

Checksum16(v::Checksum16) = v

is_absent(c::Checksum16) = iszero(c.value)

Base.show(io::IO, c::Checksum16) = print(io, "0x", string(c.value, base = 16, pad = 4))
Base.convert(::Type{Checksum16}, value::Integer) = Checksum16(value)

measure_field(::Type{Checksum16}) = 16
encode_field(::Type{Checksum16}, c::Checksum16) = UInt64(c.value)
decode_field(::Type{Checksum16}, bits::UInt64) = Checksum16(UInt16(bits))
classify_display(::Type{Checksum16}) = :scalar
literal_field(c::Checksum16) =
    string("Checksum16(0x", string(c.value, base = 16, pad = 4), ")")

# ---------- reading a named value as a number --------------------------------

# A named value type is not an `Integer` — a `Port` is a port, and arithmetic on
# one is rarely what a caller means. But reading its number is, so each of the
# types above converts to one on request: `Int(h.source_port)`.
for named in (:Port, :Checksum16, :EtherTypeOrLength, :IpProtocol, :Ipv4Address, :MacAddress)
    @eval (::Type{S})(value::$named) where {S <: Integer} = S(value.value)
    @eval Base.convert(::Type{S}, value::$named) where {S <: Integer} = S(value.value)
end

# ---------- the two IEEE 802.11 fields that are not in network order ---------
#
# Byte order is a property of the protocol, and a header declares one. IEEE
# 802.11 is the exception that proves it is not the whole rule: its MAC header
# writes the duration and the sequence control little-endian and its addresses
# and block acknowledgement fields big-endian, in the same header.
#
# So the order belongs to these two fields, and a field's own type is where
# what-a-value-is lives. Neither becomes a clause: byte order is not an
# expression over sibling fields, so it stays out of the macro.

"""
    Ieee80211Duration(value)

The Duration/ID field of an IEEE 802.11 MAC header, sixteen bits and
little-endian — IEEE 802.11 clause 9.2.4.2.

It is one field with two readings, as an EtherType field is. In a PS-Poll frame
the top two bits are set and the rest is an association identifier; in every
other frame the value is a duration in microseconds.
"""
struct Ieee80211Duration
    value::UInt16
    Ieee80211Duration(value::Integer) = new(UInt16(value))
end

Ieee80211Duration(v::Ieee80211Duration) = v

"The bit pattern that makes the field an association identifier — clause 9.2.4.2."
const IEEE80211_AID_MARK = 0xc000

is_association_id(d::Ieee80211Duration) = (d.value & IEEE80211_AID_MARK) == IEEE80211_AID_MARK
is_duration(d::Ieee80211Duration) = !is_association_id(d)

"The association identifier a PS-Poll frame carries — the low fourteen bits."
read_association_id(d::Ieee80211Duration) = d.value & 0x3fff

"The duration in microseconds, or `nothing` when the field is an identifier."
read_microseconds(d::Ieee80211Duration) = is_duration(d) ? Int(d.value) : nothing

function Base.show(io::IO, d::Ieee80211Duration)
    is_association_id(d) ? print(io, "AID ", Int(read_association_id(d))) :
                           print(io, Int(d.value), " us")
end

Base.convert(::Type{Ieee80211Duration}, value::Integer) = Ieee80211Duration(value)
Base.:(==)(a::Ieee80211Duration, b::Ieee80211Duration) = a.value == b.value
Base.hash(d::Ieee80211Duration, seed::UInt) = hash(d.value, seed)

measure_field(::Type{Ieee80211Duration}) = 16
encode_field(::Type{Ieee80211Duration}, d::Ieee80211Duration) = UInt64(d.value)
decode_field(::Type{Ieee80211Duration}, bits::UInt64) = Ieee80211Duration(UInt16(bits))
classify_display(::Type{Ieee80211Duration}) = :openable

# The header's declared order is refused: this field has one of its own.
write_field(io::BitWriter, ::Type{Ieee80211Duration}, d::Ieee80211Duration,
            width::Int, ::Symbol) = write_bits!(io, UInt64(d.value), 16, :le)
read_field(io::BitReader, ::Type{Ieee80211Duration}, width::Int, ::Symbol) =
    Ieee80211Duration(UInt16(read_bits!(io, 16, :le)))

"""
    Ieee80211SequenceControl(; fragment_number, sequence_number)

The Sequence Control field, sixteen bits and little-endian — IEEE 802.11 clause
9.2.4.4. The low four bits are the fragment number and the high twelve are the
sequence number.

It is one type rather than two bit-fields because the packing and the byte
order have to happen together: two big-endian bit-fields would put the octets
the other way round.
"""
struct Ieee80211SequenceControl
    value::UInt16
    Ieee80211SequenceControl(value::Integer) = new(UInt16(value))
end

Ieee80211SequenceControl(v::Ieee80211SequenceControl) = v

Ieee80211SequenceControl(; fragment_number::Integer = 0, sequence_number::Integer = 0) =
    Ieee80211SequenceControl((UInt16(fragment_number) & 0x000f) |
                             ((UInt16(sequence_number) & 0x0fff) << 4))

read_fragment_number(s::Ieee80211SequenceControl) = Int(s.value & 0x000f)
read_sequence_number(s::Ieee80211SequenceControl) = Int((s.value >> 4) & 0x0fff)

Base.show(io::IO, s::Ieee80211SequenceControl) =
    print(io, "seq ", read_sequence_number(s), " frag ", read_fragment_number(s))

Base.convert(::Type{Ieee80211SequenceControl}, value::Integer) =
    Ieee80211SequenceControl(value)
Base.:(==)(a::Ieee80211SequenceControl, b::Ieee80211SequenceControl) = a.value == b.value
Base.hash(s::Ieee80211SequenceControl, seed::UInt) = hash(s.value, seed)

measure_field(::Type{Ieee80211SequenceControl}) = 16
encode_field(::Type{Ieee80211SequenceControl}, s::Ieee80211SequenceControl) = UInt64(s.value)
decode_field(::Type{Ieee80211SequenceControl}, bits::UInt64) =
    Ieee80211SequenceControl(UInt16(bits))
classify_display(::Type{Ieee80211SequenceControl}) = :openable

write_field(io::BitWriter, ::Type{Ieee80211SequenceControl}, s::Ieee80211SequenceControl,
            width::Int, ::Symbol) = write_bits!(io, UInt64(s.value), 16, :le)
read_field(io::BitReader, ::Type{Ieee80211SequenceControl}, width::Int, ::Symbol) =
    Ieee80211SequenceControl(UInt16(read_bits!(io, 16, :le)))

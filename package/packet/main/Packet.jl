# ============================================================================
# The `Packet` module — a Julia-native packet & chunk API.
# Design: plan/done/packet-chunk-api.md.
#
# Loaded from `InetPacket.jl`. Structure:
#
#   BitLength.jl    bit-granular length that isn't an Int
#   Quality.jl      the incomplete/incorrect/misrepresented lattice
#   Chunk.jl        Filler / Raw / Slice / Sequence + smart constructors
#   Peek.jl         type-directed peek
#   BitIO.jl        bit-granular reader and writer
#   FieldValue.jl   what a field may be: the protocol, U{N}, I{N}, Constant, Model
#   FieldTypes.jl   the values the standards name: MacAddress, Port, …
#   HeaderCodec.jl  the codec, written once over `fieldtypes`
#   protocol/       the wire formats, one file per protocol
#
# A wire format is an ordinary Julia struct. `fieldnames` and `fieldtypes` are
# its layout, so the codec is generic and nothing is generated per header.
# ============================================================================

module PacketModule

export BitLength, Bits, Bytes, bits, bytes, isbyte, ZERO_LENGTH,
       Quality, Q_COMPLETE, Q_INCOMPLETE, Q_INCORRECT, Q_MISREPRESENTED, ⊔,
       is_complete, is_incomplete, is_correct, is_incorrect,
       is_properly_represented, is_improperly_represented,
       Chunk, Filler, Raw, Slice, Sequence, Fields,
       slice, sequence, quality, peek, chunk_length,
       Packet, dup, trim!, data_length, front_length, back_length,
       content_length, data_chunk,
       BitWriter, BitReader, write_bits!, read_bits!, bit_count,
       write_bytes!, read_bytes!, write_byte_repeatedly!, skip_bits!, measure_padding,
       measure_field, encode_field, decode_field, write_field, read_field,
       format_field, classify_display, has_field_bits, extend_sign,
       U, I, Constant, Model, store_unsigned, store_signed,
       MacAddress, list_mac_octets, MAC_BROADCAST, is_multicast, is_broadcast,
       Ipv4Address, list_ipv4_octets, Ipv6Address, list_ipv6_groups,
       IPV6_UNSPECIFIED, IPV6_LOOPBACK,
       EtherTypeOrLength, find_ether_type_name, is_type, is_length,
       MAX_ETHERNET_LENGTH_FIELD, MIN_ETHERNET_TYPE_FIELD,
       IpProtocol, find_ip_protocol_name, Port, Checksum16, is_absent,
       FieldSpec, HeaderLayout, describe_layout, get_field, is_constant, has_bits,
       byte_order, default_field, measure_header, unwrap_field,
       serialize, deserialize, encode_header, decode_header, has,
       @header, derive_field, check_field, list_derived, list_checked,
       minimum_chunk_length, is_fixed_length,
       ChecksumMode, CHECKSUM_DECLARED, CHECKSUM_COMPUTED, CHECKSUM_DISABLED,
       compute_ones_complement, compute_internet_checksum, set_field,
       EthernetPhyHeader, EthernetMacHeader, Ieee8021qTag, EthernetFcs,
       MIN_ETHERNET_FRAME_BYTES, MAX_ETHERNET_FRAME_BYTES, INTERFRAME_GAP_BITS,
       JAM_SIGNAL_BYTES, ETHERNET_PHY_HEADER_LEN_BYTES, ETHERNET_PHY_ESD_LEN_BYTES,
       ETHERNET_TXRATE_10MB, ETHERNET_PREAMBLE, ETHERNET_SFD,
       ETHERTYPE_IPV4, ETHERTYPE_ARP, ETHERTYPE_VLAN, ETHERTYPE_IPV6,
       Ipv4Header, IPV4_VERSION, IPV4_MIN_IHL, IPV4_HEADER_BYTES, IPV4_DEFAULT_TTL,
       IP_PROTOCOL_ICMP, IP_PROTOCOL_IGMP, IP_PROTOCOL_TCP, IP_PROTOCOL_UDP,
       Ipv6Header, IPV6_VERSION, IPV6_HEADER_BYTES, IPV6_DEFAULT_HOP_LIMIT,
       IP_PROTOCOL_NONE, IP_PROTOCOL_IPV6_ROUTING, IP_PROTOCOL_IPV6_FRAGMENT,
       IP_PROTOCOL_ICMPV6, split_dscp, split_ecn, join_traffic_class,
       UdpHeader, UDP_HEADER_BYTES,
       TcpHeader, list_tcp_flags, TCP_MIN_DATA_OFFSET, TCP_HEADER_BYTES,
       mark_quality, mark_incomplete, mark_incorrect, mark_misrepresented,
       MarkedFields,
       TagSet, RegionTagSet, RegionTag, tryget, add_region_tag!, region_tags,
       set_tag!, get_tag, has_tag, del_tag!, try_tag,
       ChunkQueue, ChunkBuffer, OverlapPolicy, OVERWRITE, KEEP_EXISTING, REFUSE,
       total_length, peekfirst, write!, region_at, gaps,
       is_complete_range, assembled_chunk,
       Dissection, dissect, describe

include("BitLength.jl")
include("Quality.jl")
include("Chunk.jl")
include("Peek.jl")
include("BitIO.jl")
include("FieldValue.jl")
include("FieldTypes.jl")
include("HeaderCodec.jl")
include("Header.jl")
include("Checksum.jl")
# The wire formats. One file per protocol, each written from the standard.
include("protocol/Ethernet.jl")
include("protocol/Ipv4.jl")
include("protocol/Ipv6.jl")
include("protocol/Udp.jl")
include("protocol/Tcp.jl")
include("PeekFields.jl")
include("QualityOps.jl")
include("Tags.jl")
include("PacketEnvelope.jl")
include("Buffers.jl")
include("Inspect.jl")

end # module

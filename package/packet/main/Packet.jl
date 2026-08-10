# ============================================================================
# The `Packet` module — a Julia-native packet & chunk API.
# Design: plan/done/packet-chunk-api.md.
#
# Loaded from `InetPacket.jl`. Structure:
#
#   BitLength.jl    bit-granular length that isn't an Int
#   Quality.jl      the incomplete/incorrect/misrepresented lattice
#   Chunk.jl        Filler / Raw / Slice / Sequence + smart constructors
#   Peek.jl         type-directed peek (Phase 1 core; Phase 3 extends)
#
# Later phases add PacketEnvelope.jl (Phase 2), Header.jl (@header, Phase 3),
# Tags.jl (Phase 5), Buffers.jl (Phase 6), Inspect.jl (Phase 7).
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
       field_width, field_encode, field_decode, field_base,
       field_write, field_read, sign_extend,
       MacAddress, mac_octets, MAC_BROADCAST, is_multicast, is_broadcast,
       Ipv4Address, ipv4_octets, EtherType, ethertype_name,
       Ipv6Address, ipv6_groups, IPV6_UNSPECIFIED, IPV6_LOOPBACK,
       IpProtocol, ip_protocol_name, PortNumber,
       FieldSpec, HeaderLayout, header_layout, build_header_layout,
       field_bits, field_text, field_value, is_constant, has_bits,
       EthernetPhyHeader, EthernetMacHeader, Ieee8021qTag, EthernetFcs,
       MIN_ETHERNET_FRAME_BYTES, MAX_ETHERNET_FRAME_BYTES, INTERFRAME_GAP_BITS,
       JAM_SIGNAL_BYTES, ETHERNET_PHY_HEADER_LEN_BYTES, ETHERNET_PHY_ESD_LEN_BYTES,
       ETHERNET_TXRATE_10MB, ETHERNET_PREAMBLE, ETHERNET_SFD,
       ETHERTYPE_IPV4, ETHERTYPE_ARP, ETHERTYPE_VLAN, ETHERTYPE_IPV6,
       Ipv4Header, IPV4_VERSION, IPV4_MIN_IHL, IPV4_HEADER_BYTES,
       IPV4_DEFAULT_TTL, IPV4_FLAG_RESERVED, IPV4_FLAG_DF, IPV4_FLAG_MF,
       IP_PROTOCOL_ICMP, IP_PROTOCOL_IGMP, IP_PROTOCOL_TCP, IP_PROTOCOL_UDP,
       Ipv6Header, IPV6_VERSION, IPV6_HEADER_BYTES, IPV6_DEFAULT_HOP_LIMIT,
       IP_PROTOCOL_NONE, IP_PROTOCOL_IPV6_ROUTING, IP_PROTOCOL_IPV6_FRAGMENT,
       IP_PROTOCOL_ICMPV6,
       ipv6_dscp, ipv6_ecn, ipv6_traffic_class,
       UdpHeader, UDP_HEADER_BYTES,
       TcpHeader, tcp_flags, TCP_MIN_DATA_OFFSET, TCP_HEADER_BYTES,
       @header, serialize, deserialize, to_bytes, from_bytes, has,
       ChecksumMode, CHECKSUM_DECLARED, CHECKSUM_COMPUTED, CHECKSUM_DISABLED,
       ones_complement_checksum, internet_checksum, with_field,
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
include("FieldTypes.jl")
include("HeaderLayout.jl")
include("Header.jl")
include("Checksum.jl")
# The wire formats, declared with the macro above. One file per protocol.
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

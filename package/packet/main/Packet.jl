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
#   HeaderFacts.jl  what a header knows about itself beyond its layout
#   protocol/       the wire formats, one file per protocol
#
# A wire format is an ordinary Julia struct. `fieldnames` and `fieldtypes` are
# its layout, so the codec is generic and nothing is generated per header.
# ============================================================================

module PacketModule

# The data model is a document, so its values are navigable, selectable and
# reactive without a mirror of them existing somewhere else. `@document` needs
# three names besides itself: `Document`, the supertype every document gets,
# `Reference`, which types the `selection` field, and the cell types a field is
# wrapped in.
#
# Every type here declares `selection::Nothing` and an immutable field kind. A
# chunk is on the simulation's hot path, and the injected selection is a union
# over heap types that would stop it being isbits — a `Filler` would go from 16
# bytes inline to 24 on the heap. Nothing a simulation touches is reactive.
using ProjecturedKernel.DocumentModule: Document, @document, @document_preset,
                                        copy_document, sync_document!
using ProjecturedKernel.ReferenceModule: Reference
using ProjecturedKernel.CellModule: AbstractCell, ImmutableCell

# The envelope is the one packet type that mutates, and it is the one a
# simulation touches on every hop. Its bare name is the plain `mutable struct` it
# has always been; `ACPacket` is the cell layout an editor holds a copy in.
@document_preset native_document [M, C]

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
       format_field, literal_field, literal_bytes, literal_list,
       classify_display, has_field_bits, extend_sign,
       U, I, Constant, Model, Octets, Rest, Pad, Repeated, Options, Optional,
       is_present, optional_type,
       list_options, find_raw_option, option_code, ends_option_list,
       measure_option_code, find_option_type,
       list_variants, variant_base, variant_fallback, matches_variant, select_variant,
       list_headers, register_header, fill_field, fill_asymmetric, check_round_trip,
       find_declaration, declaration_path, package_source_directory,
       example_header,
       HeaderArgument, HeaderConstruction, describe_construction, construction_text,
       is_named, list_named, list_omitted, has_keyword_constructor,
       HeaderUpdate, describe_update, find_updatable_field,
       store_unsigned, store_signed,
       is_variable_field, measure_value, measure_read, measure_default, format_octets,
       MacAddress, list_mac_octets, MAC_BROADCAST, is_multicast, is_broadcast,
       Ipv4Address, list_ipv4_octets, Ipv6Address, list_ipv6_groups,
       IPV6_UNSPECIFIED, IPV6_LOOPBACK,
       EtherTypeOrLength, find_ether_type_name, is_type, is_length,
       MAX_ETHERNET_LENGTH_FIELD, MIN_ETHERNET_TYPE_FIELD,
       IpProtocol, find_ip_protocol_name, Port, Checksum16, is_absent,
       FieldSpec, HeaderLayout, describe_layout, get_field, is_constant, has_bits,
       byte_order, default_field, measure_header, unwrap_field, measure_write,
       serialize, deserialize, encode_header, decode_header, has,
       @header, derive_field, check_field, list_derived, list_checked, find_default,
       Draft, start_draft, build_header, is_set, list_unset, set_field!, unset_field!,
       header_type,
       minimum_chunk_length, is_fixed_length,
       ChecksumMode, CHECKSUM_DECLARED, CHECKSUM_COMPUTED, CHECKSUM_DISABLED,
       compute_ones_complement, compute_internet_checksum, set_field,
       AckingMacHeader, ShortcutMacHeader, GenericPhyHeader, ShortcutPhyHeader,
       ApskPhyHeader, build_filler, SIMULATION_FILLER, ACKING_MAC_HEADER_BYTES,
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
       Ipv6Option, Ipv6OptionPad1, Ipv6OptionPadN, Ipv6OptionRaw,
       IPV6_TLVOPTION_PAD1, IPV6_TLVOPTION_PADN,
       Ipv6HopByHopOptionsHeader, Ipv6DestinationOptionsHeader,
       Ipv6RoutingHeader, Ipv6FragmentHeader, Ipv6AuthenticationHeader,
       Ipv6EncapsulatingSecurityPayloadHeader, measure_fragment_offset,
       IP_PROTOCOL_IPV6_HOP_BY_HOP, IP_PROTOCOL_IPV6_DESTINATION,
       IP_PROTOCOL_IPV6_AUTHENTICATION, IP_PROTOCOL_IPV6_ESP,
       IPV6_ROUTING_TYPE_SEGMENT,
       Ipv6NdOption, Ipv6NdSourceLinkLayerAddress, Ipv6NdTargetLinkLayerAddress,
       Ipv6NdPrefixInformation, Ipv6NdMtu, Ipv6NdOptionRaw,
       IPV6ND_SOURCE_LINK_LAYER_ADDRESS, IPV6ND_TARGET_LINK_LAYER_ADDRESS,
       IPV6ND_PREFIX_INFORMATION, IPV6ND_REDIRECTED_HEADER, IPV6ND_MTU,
       Icmpv6Message, Icmpv6Common, Icmpv6Header,
       Icmpv6DestinationUnreachable, Icmpv6PacketTooBig, Icmpv6TimeExceeded,
       Icmpv6ParameterProblem, Icmpv6EchoRequest, Icmpv6EchoReply,
       Ipv6RouterSolicitation, Ipv6RouterAdvertisement,
       Ipv6NeighborSolicitation, Ipv6NeighborAdvertisement, Ipv6Redirect,
       MldQuery, MldReport, MldDone, Mldv2Query, Mldv2Report,
       Mldv2MulticastAddressRecord, MLD_MESSAGE_BYTES,
       ICMPV6_DESTINATION_UNREACHABLE, ICMPV6_PACKET_TOO_BIG,
       ICMPV6_TIME_EXCEEDED, ICMPV6_PARAMETER_PROBLEM,
       ICMPV6_ECHO_REQUEST, ICMPV6_ECHO_REPLY,
       ICMPV6_MLD_QUERY, ICMPV6_MLD_REPORT, ICMPV6_MLD_DONE,
       ICMPV6_ROUTER_SOLICITATION, ICMPV6_ROUTER_ADVERTISEMENT,
       ICMPV6_NEIGHBOR_SOLICITATION, ICMPV6_NEIGHBOR_ADVERTISEMENT,
       ICMPV6_REDIRECT, ICMPV6_MLDV2_REPORT,
       IgmpMessage, IgmpCommon, IgmpHeader,
       Igmpv1Query, Igmpv2Query, Igmpv3Query, Igmpv1Report, Igmpv2Report,
       Igmpv2Leave, Igmpv3Report, Igmpv3GroupRecord, RgmpHello,
       IGMP_MEMBERSHIP_QUERY, IGMPV1_MEMBERSHIP_REPORT, IGMPV2_MEMBERSHIP_REPORT,
       IGMPV2_LEAVE_GROUP, IGMPV3_MEMBERSHIP_REPORT, RGMP_HELLO,
       IGMP_MESSAGE_BYTES, IGMP_MODE_IS_INCLUDE, IGMP_MODE_IS_EXCLUDE,
       IGMP_CHANGE_TO_INCLUDE_MODE, IGMP_CHANGE_TO_EXCLUDE_MODE,
       IGMP_ALLOW_NEW_SOURCES, IGMP_BLOCK_OLD_SOURCES,
       EthernetMacAddressFields, EthernetTypeOrLengthField,
       EthernetControlMessage, EthernetControlFrame, EthernetPauseFrame,
       ETHERNET_CONTROL_PAUSE,
       Ieee8021qTagTpidHeader, Ieee8021qTagEpdHeader,
       Ieee8021aeTagTpidHeader, Ieee8021aeTagEpdHeader,
       Ieee8021rTagTpidHeader, Ieee8021rTagEpdHeader, Ieee802EpdHeader,
       ETHERTYPE_MACSEC, ETHERTYPE_RTAG,
       Bpdu, BpduCommon, BpduConfiguration, BpduTopologyChangeNotification,
       BPDU_PROTOCOL_SPANNING_TREE, BPDU_VERSION_SPANNING_TREE,
       BPDU_VERSION_RAPID_SPANNING_TREE, BPDU_VERSION_MULTIPLE_SPANNING_TREE,
       BPDU_CONFIGURATION, BPDU_TOPOLOGY_CHANGE_NOTIFICATION,
       BPDU_PORT_ROLE_UNKNOWN, BPDU_PORT_ROLE_ALTERNATE, BPDU_PORT_ROLE_ROOT,
       BPDU_PORT_ROLE_DESIGNATED, measure_bpdu_seconds, build_bpdu_ticks,
       Ieee802154MacHeader, IEEE802154_FRAME_CONTROL, IEEE802154_BROADCAST_PAN,
       BMacHeader, BMacCommon, BMacControlFrame, BMacDataFrameHeader,
       BMacUnknownFrame, BMAC_PREAMBLE, BMAC_DATA, BMAC_ACK,
       XMacHeader, XMacCommon, XMacControlFrame, XMacDataFrameHeader,
       XMacUnknownFrame, XMAC_PREAMBLE, XMAC_DATA, XMAC_ACK,
       CsmaCaMacHeader, CsmaCaMacCommon, CsmaCaMacAckHeader, CsmaCaMacDataHeader,
       CsmaCaMacTrailer, CSMA_DATA, CSMA_ACK,
       GptpMessage, GptpCommon, GptpTimestamp, GptpPortIdentity,
       GptpScaledNanoseconds, GptpFollowUpInformationTlv,
       GptpSync, GptpFollowUp, GptpPdelayReq, GptpPdelayResp,
       GptpPdelayRespFollowUp, GptpAnnounce,
       GPTP_TYPE_SYNC, GPTP_TYPE_PDELAY_REQUEST, GPTP_TYPE_PDELAY_RESPONSE,
       GPTP_TYPE_FOLLOW_UP, GPTP_TYPE_PDELAY_RESPONSE_FOLLOW_UP, GPTP_TYPE_ANNOUNCE,
       GPTP_FLAG_ALTERNATE_MASTER, GPTP_FLAG_TWO_STEP,
       GPTP_FOLLOW_UP_INFORMATION_TLV, GPTP_ORGANIZATION_ID, GPTP_ORGANIZATION_SUBTYPE,
       GPTP_HEADER_BYTES, GPTP_SYNC_BYTES, GPTP_FOLLOW_UP_BYTES,
       GPTP_PDELAY_REQUEST_BYTES, GPTP_PDELAY_RESPONSE_BYTES,
       GPTP_PDELAY_RESPONSE_FOLLOW_UP_BYTES, GPTP_ANNOUNCE_BYTES,
       MrpVersion, MrpTlv, MrpEnd, MrpCommon, MrpTest, MrpTopologyChange,
       MrpLinkDown, MrpLinkUp, MrpInTest, MrpInTopologyChange, MrpInLinkDown,
       MrpInLinkUp, MrpInLinkStatusPoll, MrpOption,
       MrpSubTlv, MrpAutoManager, MrpManufacturerFunction,
       MrpSubTlvTestPropagate, MrpSubTlvTestManagerNack,
       MRP_TLV_END, MRP_TLV_COMMON, MRP_TLV_TEST, MRP_TLV_TOPOLOGY_CHANGE,
       MRP_TLV_LINK_DOWN, MRP_TLV_LINK_UP, MRP_TLV_IN_TEST,
       MRP_TLV_IN_TOPOLOGY_CHANGE, MRP_TLV_IN_LINK_DOWN, MRP_TLV_IN_LINK_UP,
       MRP_TLV_IN_LINK_STATUS_POLL, MRP_TLV_OPTION,
       MRP_SUBTLV_RESERVED, MRP_SUBTLV_TEST_MANAGER_NACK,
       MRP_SUBTLV_TEST_PROPAGATE, MRP_SUBTLV_AUTO_MANAGER,
       MRP_OUI_DEFAULT, MRP_OUI_IEC, MRP_PRIORITY_DEFAULT,
       Ieee8022LlcHeader, Ieee8022SnapHeader, Ieee8022LlcSnapHeader,
       LLC_SAP_SNAP, LLC_SAP_IP, LLC_CONTROL_UNNUMBERED_INFORMATION,
       PppHeader, PppTrailer, PPP_FLAG, PPP_ADDRESS, PPP_CONTROL,
       PPP_PROTOCOL_IPV4, PPP_PROTOCOL_IPV6,
       MplsHeader, MPLS_LABEL_IPV4_EXPLICIT_NULL, MPLS_LABEL_ROUTER_ALERT,
       MPLS_LABEL_IPV6_EXPLICIT_NULL, MPLS_LABEL_IMPLICIT_NULL,
       SequenceNumberHeader, FragmentNumberHeader, ChecksumHeader,
       ArpPacket, ARP_REQUEST, ARP_REPLY, ARP_RARP_REQUEST, ARP_RARP_REPLY,
       ARP_HARDWARE_ETHERNET,
       IcmpMessage, IcmpCommon, IcmpHeader, IcmpEchoRequest, IcmpEchoReply, IcmpPtb,
       ICMP_ECHO_REPLY, ICMP_DESTINATION_UNREACHABLE, ICMP_ECHO_REQUEST,
       ICMP_TIME_EXCEEDED, ICMP_PARAMETER_PROBLEM, ICMP_DU_FRAGMENTATION_NEEDED,
       Ipv4Option, Ipv4OptionEnd, Ipv4OptionNop, Ipv4OptionStreamId,
       Ipv4OptionRouterAlert, Ipv4OptionRecordRoute, Ipv4OptionRaw,
       IPOPTION_END_OF_OPTIONS, IPOPTION_NO_OPTION, IPOPTION_RECORD_ROUTE,
       IPOPTION_TIMESTAMP, IPOPTION_SECURITY, IPOPTION_LOOSE_SOURCE_ROUTING,
       IPOPTION_STREAM_ID, IPOPTION_STRICT_SOURCE_ROUTING, IPOPTION_ROUTER_ALERT,
       TcpOption, TcpOptionEnd, TcpOptionNop, TcpOptionMaxSegmentSize,
       TcpOptionWindowScale, TcpOptionSackPermitted, TcpOptionTimestamp,
       TcpOptionRaw,
       TCPOPTION_END_OF_OPTION_LIST, TCPOPTION_NO_OPERATION,
       TCPOPTION_MAXIMUM_SEGMENT_SIZE, TCPOPTION_WINDOW_SCALE,
       TCPOPTION_SACK_PERMITTED, TCPOPTION_SACK, TCPOPTION_TIMESTAMP,
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
include("Draft.jl")
include("Options.jl")
include("Variant.jl")
include("RoundTrip.jl")
include("Checksum.jl")
# What a header knows about itself: where it is declared, how one is built,
# and what a field update does. It reads the clause methods `Header.jl` emits
# and the corpus `RoundTrip.jl` keeps, so it comes after both.
include("HeaderFacts.jl")
# The wire formats. One file per protocol, each written from the standard.
include("protocol/SimulationHeader.jl")
include("protocol/Ethernet.jl")
include("protocol/Ieee8021.jl")
include("protocol/Ieee8021d.jl")
include("protocol/Ieee8022.jl")
include("protocol/Ieee802154.jl")
include("protocol/WirelessMac.jl")
include("protocol/Gptp.jl")
include("protocol/Mrp.jl")
include("protocol/ProtocolElement.jl")
include("protocol/Ppp.jl")
include("protocol/Mpls.jl")
include("protocol/Ipv4Option.jl")
include("protocol/Ipv4.jl")
include("protocol/Arp.jl")
include("protocol/Icmp.jl")
include("protocol/Igmp.jl")
include("protocol/Ipv6.jl")
include("protocol/Ipv6Option.jl")
include("protocol/Ipv6Extension.jl")
include("protocol/Ipv6NdOption.jl")
include("protocol/Icmpv6.jl")
include("protocol/Udp.jl")
include("protocol/TcpOption.jl")
include("protocol/Tcp.jl")
include("PeekFields.jl")
include("QualityOps.jl")
include("Tags.jl")
include("PacketEnvelope.jl")
include("Buffers.jl")
include("Inspect.jl")

end # module

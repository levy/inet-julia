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
                                        copy_document, sync_document!,
                                        document_schema_name
import ProjecturedKernel.DocumentModule: should_descend_sync, unsynced_placeholder
using ProjecturedKernel.ReferenceModule: Reference
using ProjecturedKernel.CellModule: AbstractCell, ImmutableCell, ReactiveCell

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
       Packet, APacket, live_packet, dup, trim!, data_length, front_length, back_length,
       content_length, data_chunk,
       BitWriter, BitReader, write_bits!, read_bits!, bit_count,
       write_bytes!, read_bytes!, write_byte_repeatedly!, skip_bits!, measure_padding,
       measure_field, encode_field, decode_field, write_field, read_field,
       format_field, literal_field, literal_bytes, literal_list,
       classify_display, has_field_bits, extend_sign,
       U, I, Constant, Model, Octets, FixedOctets, Rest, Pad, Repeated, Options, Optional,
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
       is_variable_field, measure_value, measure_read, measure_default,
       MacAddress, list_mac_octets, MAC_BROADCAST, is_multicast, is_broadcast,
       Ipv4Address, list_ipv4_octets, Ipv6Address, list_ipv6_groups,
       IPV6_UNSPECIFIED, IPV6_LOOPBACK,
       EtherTypeOrLength, find_ether_type_name, is_type, is_length,
       MAX_ETHERNET_LENGTH_FIELD, MIN_ETHERNET_TYPE_FIELD,
       IpProtocol, find_ip_protocol_name, Port, Checksum16, is_absent,
       Ieee80211Duration, is_association_id, is_duration, read_association_id,
       read_microseconds, IEEE80211_AID_MARK,
       Ieee80211SequenceControl, read_fragment_number, read_sequence_number,
       header_fields, header_types, header_count, has_selection_field,
       document_schema_name,
       Ieee80211OfdmSignal, read_ofdm_rate, read_ofdm_reserved, read_ofdm_length,
       read_ofdm_parity, read_ofdm_tail,
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
       ApplicationPacket, EtherAppRequest, EtherAppResponse,
       APPLICATION_PACKET_BYTES, ETHER_APP_PACKET_BYTES,
       VoipStreamPacket, VOIP_STREAM_VOICE, VOIP_STREAM_SILENCE,
       VOIP_STREAM_PACKET_BYTES,
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
       Ieee80211MacHeader, Ieee80211FrameControl, Ieee80211Common,
       Ieee80211Ack, Ieee80211Cts, Ieee80211Rts, Ieee80211PsPoll,
       Ieee80211BlockAckRequest, Ieee80211BasicBlockAck, Ieee80211CompressedBlockAck,
       Ieee80211DataHeader, Ieee80211MgmtHeader, Ieee80211MacTrailer,
       Ieee80211AddbaRequest, Ieee80211AddbaResponse, Ieee80211Delba,
       Ieee80211ActionOther, has_qos_control, has_fourth_address,
       IEEE80211_TYPE_MANAGEMENT, IEEE80211_TYPE_CONTROL, IEEE80211_TYPE_DATA,
       IEEE80211_SUBTYPE_BLOCK_ACK_REQUEST, IEEE80211_SUBTYPE_BLOCK_ACK,
       IEEE80211_SUBTYPE_PS_POLL, IEEE80211_SUBTYPE_RTS, IEEE80211_SUBTYPE_CTS,
       IEEE80211_SUBTYPE_ACK, IEEE80211_SUBTYPE_BEACON, IEEE80211_SUBTYPE_ACTION,
       IEEE80211_SUBTYPE_DATA, IEEE80211_SUBTYPE_QOS_DATA, IEEE80211_QOS_SUBTYPE_BIT,
       IEEE80211_SUBTYPE_ASSOCIATION_REQUEST, IEEE80211_SUBTYPE_ASSOCIATION_RESPONSE,
       IEEE80211_SUBTYPE_REASSOCIATION_REQUEST, IEEE80211_SUBTYPE_REASSOCIATION_RESPONSE,
       IEEE80211_SUBTYPE_PROBE_REQUEST, IEEE80211_SUBTYPE_PROBE_RESPONSE,
       IEEE80211_SUBTYPE_ATIM, IEEE80211_SUBTYPE_DISASSOCIATION,
       IEEE80211_SUBTYPE_AUTHENTICATION, IEEE80211_SUBTYPE_DEAUTHENTICATION,
       IEEE80211_SUBTYPE_ACTION_NO_ACK,
       IEEE80211_ACK_NORMAL, IEEE80211_ACK_NONE, IEEE80211_ACK_NO_EXPLICIT,
       IEEE80211_ACK_BLOCK, IEEE80211_CATEGORY_BLOCK_ACK,
       IEEE80211_ACTION_ADDBA_REQUEST, IEEE80211_ACTION_ADDBA_RESPONSE,
       IEEE80211_ACTION_DELBA,
       Ieee80211FhssPhyHeader, Ieee80211IrPhyHeader, Ieee80211DsssPhyHeader,
       Ieee80211HrDsssPhyHeader, Ieee80211OfdmPhyHeader, Ieee80211ErpOfdmPhyHeader,
       IEEE80211_FHSS_PHY_HEADER_BYTES, IEEE80211_IR_PHY_HEADER_BYTES,
       IEEE80211_DSSS_PHY_HEADER_BYTES, IEEE80211_HR_DSSS_PHY_HEADER_BYTES,
       IEEE80211_OFDM_PHY_HEADER_BYTES,
       Ieee80211InformationElement, Ieee80211ElementSsid,
       Ieee80211ElementSupportedRates, Ieee80211ElementExtendedRates,
       Ieee80211ElementDsParameterSet, Ieee80211ElementIbssParameterSet,
       Ieee80211ElementRaw,
       Ieee80211AssociationRequest, Ieee80211AssociationResponse,
       Ieee80211ReassociationRequest, Ieee80211ReassociationResponse,
       Ieee80211ProbeRequest, Ieee80211ProbeResponse, Ieee80211Beacon,
       Ieee80211Disassociation, Ieee80211Deauthentication, Ieee80211Authentication,
       build_supported_rate, measure_supported_rate, is_basic_rate,
       measure_beacon_interval, build_beacon_interval,
       IEEE80211_ELEMENT_SSID, IEEE80211_ELEMENT_SUPPORTED_RATES,
       IEEE80211_ELEMENT_DSSS_PARAMETER_SET, IEEE80211_ELEMENT_TRAFFIC_INDICATION_MAP,
       IEEE80211_ELEMENT_IBSS_PARAMETER_SET, IEEE80211_ELEMENT_COUNTRY,
       IEEE80211_ELEMENT_EXTENDED_RATES, IEEE80211_ELEMENT_HEADER_BYTES,
       IEEE80211_AUTHENTICATION_OPEN_SYSTEM, IEEE80211_AUTHENTICATION_SHARED_KEY,
       IEEE80211_STATUS_SUCCESS, IEEE80211_STATUS_UNSPECIFIED,
       IEEE80211_STATUS_CAPABILITY_UNSUPPORTED, IEEE80211_STATUS_ASSOCIATION_DENIED,
       IEEE80211_REASON_UNSPECIFIED, IEEE80211_REASON_LEAVING,
       IEEE80211_REASON_INACTIVITY, IEEE80211_REASON_NOT_AUTHENTICATED,
       IEEE80211_TIME_UNIT_MICROSECONDS,
       IEEE80211_ACK_BYTES, IEEE80211_CTS_BYTES, IEEE80211_RTS_BYTES,
       IEEE80211_PS_POLL_BYTES, IEEE80211_MANAGEMENT_BYTES,
       IEEE80211_BLOCK_ACK_REQUEST_BYTES,
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
       RipPacket, RipEntry, RIP_REQUEST, RIP_RESPONSE, RIP_ENTRY_BYTES,
       RIP_ADDRESS_FAMILY_NONE, RIP_ADDRESS_FAMILY_INET,
       RIP_ADDRESS_FAMILY_AUTHENTICATION,
       AodvControlPacket, AodvCommon, AodvRreq, AodvRrep, AodvRerr, AodvRrepAck,
       AodvRreqIpv6, AodvRrepIpv6, AodvRerrIpv6, AodvRrepAckIpv6,
       AodvUnreachableNode, AodvUnreachableNodeIpv6, DsdvHello,
       AODV_RREQ, AODV_RREP, AODV_RERR, AODV_RREP_ACK,
       AODV_RREQ_IPV6, AODV_RREP_IPV6, AODV_RERR_IPV6, AODV_RREP_ACK_IPV6,
       PimPacket, PimCommon, PimHello, PimRegister, PimRegisterStop,
       PimJoinPrune, PimJoinPruneGroup, PimGraft, PimGraftAck, PimAssert,
       PimStateRefresh, PimUnicastAddress, PimGroupAddress, PimSourceAddress,
       PimOption, PimHoldTime, PimLanPruneDelay, PimDrPriority, PimGenerationId,
       PimOptionRaw,
       PIM_HELLO, PIM_REGISTER, PIM_REGISTER_STOP, PIM_JOIN_PRUNE, PIM_BOOTSTRAP,
       PIM_ASSERT, PIM_GRAFT, PIM_GRAFT_ACK, PIM_CANDIDATE_RP, PIM_STATE_REFRESH,
       PIM_OPTION_HOLD_TIME, PIM_OPTION_LAN_PRUNE_DELAY, PIM_OPTION_DR_PRIORITY,
       PIM_OPTION_GENERATION_ID, PIM_ADDRESS_FAMILY_INET, PIM_ENCODING_NATIVE,
       BgpMessage, BgpCommon, BgpKeepAlive, BgpOpen, BgpNotification,
       BgpParameter, BgpParameterCapabilities, BgpParameterRaw,
       BgpCapabilityMultiprotocol,
       BGP_OPEN, BGP_UPDATE, BGP_NOTIFICATION, BGP_KEEPALIVE, BGP_VERSION,
       BGP_HEADER_BYTES, BGP_OPEN_BYTES, BGP_MAX_MESSAGE_BYTES, BGP_MARKER,
       BGP_PARAMETER_CAPABILITIES, BGP_CAPABILITY_MULTIPROTOCOL,
       BGP_ERROR_MESSAGE_HEADER, BGP_ERROR_OPEN_MESSAGE, BGP_ERROR_UPDATE_MESSAGE,
       BGP_ERROR_HOLD_TIMER, BGP_ERROR_FINITE_STATE, BGP_ERROR_CEASE,
       BgpUpdate, BgpPrefix, BgpAttribute, BgpAttributeHeader,
       BgpAttributeOrigin, BgpAttributeAsPath, BgpAsPathSegment,
       BgpAttributeNextHop, BgpAttributeMultiExitDiscriminator,
       BgpAttributeLocalPreference, BgpAttributeAtomicAggregate,
       BgpAttributeAggregator, BgpAttributeMpReachNlri, BgpAttributeMpUnreachNlri,
       BgpAttributeRaw,
       measure_prefix_octets, measure_attribute_length, measure_attribute_end,
       measure_attribute_header_bytes, set_attribute_length, measure_list_bytes,
       BGP_UPDATE_BYTES, BGP_ATTRIBUTE_ORIGIN, BGP_ATTRIBUTE_AS_PATH,
       BGP_ATTRIBUTE_NEXT_HOP, BGP_ATTRIBUTE_MULTI_EXIT_DISC,
       BGP_ATTRIBUTE_LOCAL_PREFERENCE, BGP_ATTRIBUTE_ATOMIC_AGGREGATE,
       BGP_ATTRIBUTE_AGGREGATOR, BGP_ATTRIBUTE_MP_REACH_NLRI,
       BGP_ATTRIBUTE_MP_UNREACH_NLRI,
       BGP_ORIGIN_IGP, BGP_ORIGIN_EGP, BGP_ORIGIN_INCOMPLETE,
       BGP_AS_SET, BGP_AS_SEQUENCE,
       RtpHeader, RtpMpegHeader, RTP_VERSION, RTP_HEADER_BYTES,
       RtcpPacket, RtcpCommon, RtcpReceptionReport, RtcpSenderReport,
       RtcpReceiverReport, RtcpSourceDescription, RtcpBye,
       RtcpSdesItem, RtcpSdesCname, RtcpSdesItemRaw,
       RTCP_SENDER_REPORT, RTCP_RECEIVER_REPORT, RTCP_SOURCE_DESCRIPTION,
       RTCP_BYE, RTCP_APPLICATION,
       RTCP_SDES_END, RTCP_SDES_CNAME, RTCP_SDES_NAME, RTCP_SDES_EMAIL,
       RTCP_SDES_PHONE, RTCP_SDES_LOCATION, RTCP_SDES_TOOL, RTCP_SDES_NOTE,
       RTCP_SDES_PRIVATE,
       DhcpMessage, DhcpOption, DhcpPad, DhcpEnd, DhcpMessageType,
       DhcpAddressOption, DhcpOptionRaw, read_client_mac,
       build_client_hardware_address,
       DHCP_BOOT_REQUEST, DHCP_BOOT_REPLY, DHCP_HARDWARE_ETHERNET,
       DHCP_ETHERNET_ADDRESS_BYTES, DHCP_MAGIC_COOKIE, DHCP_MESSAGE_BYTES,
       DHCP_OPTION_PAD, DHCP_OPTION_SUBNET_MASK, DHCP_OPTION_ROUTER,
       DHCP_OPTION_HOST_NAME, DHCP_OPTION_REQUESTED_IP, DHCP_OPTION_LEASE_TIME,
       DHCP_OPTION_MESSAGE_TYPE, DHCP_OPTION_SERVER_ID, DHCP_OPTION_PARAMETER_LIST,
       DHCP_OPTION_CLIENT_ID, DHCP_OPTION_END,
       DHCP_DISCOVER, DHCP_OFFER, DHCP_REQUEST, DHCP_DECLINE, DHCP_ACK,
       DHCP_NAK, DHCP_RELEASE, DHCP_INFORM,
       MobilityHeader, MobilityCommon, Mipv6BindingRefreshRequest,
       Mipv6HomeTestInit, Mipv6CareOfTestInit, Mipv6HomeTest, Mipv6CareOfTest,
       Mipv6BindingUpdate, Mipv6BindingAcknowledgement, Mipv6BindingError,
       measure_binding_seconds, build_binding_lifetime,
       MIPV6_BINDING_REFRESH_REQUEST, MIPV6_HOME_TEST_INIT, MIPV6_CARE_OF_TEST_INIT,
       MIPV6_HOME_TEST, MIPV6_CARE_OF_TEST, MIPV6_BINDING_UPDATE,
       MIPV6_BINDING_ACKNOWLEDGEMENT, MIPV6_BINDING_ERROR,
       MIPV6_LIFETIME_UNIT, MIPV6_NO_NEXT_HEADER,
       Ospfv2Packet, Ospfv2Common, Ospfv2Header, Ospfv2Options,
       Ospfv2Hello, Ospfv2DatabaseDescription, Ospfv2LinkStateRequest,
       Ospfv2LinkStateUpdate, Ospfv2LinkStateAcknowledgement, Ospfv2LsaRequest,
       Ospfv2Lsa, Ospfv2LsaHeader, Ospfv2RouterLsa, Ospfv2NetworkLsa,
       Ospfv2SummaryLsa, Ospfv2AsExternalLsa, Ospfv2RawLsa,
       Ospfv2Link, Ospfv2RouterTos, Ospfv2SummaryTos, Ospfv2ExternalTos,
       measure_lsa_length, measure_packet_length,
       OSPF_VERSION_2, OSPF_HELLO_PACKET, OSPF_DATABASE_DESCRIPTION_PACKET,
       OSPF_LINK_STATE_REQUEST_PACKET, OSPF_LINK_STATE_UPDATE_PACKET,
       OSPF_LINK_STATE_ACKNOWLEDGEMENT_PACKET,
       OSPF_AUTHENTICATION_NULL, OSPF_AUTHENTICATION_SIMPLE,
       OSPF_AUTHENTICATION_CRYPTOGRAPHIC,
       OSPF_ROUTER_LSA, OSPF_NETWORK_LSA, OSPF_SUMMARY_LSA,
       OSPF_ASBR_SUMMARY_LSA, OSPF_AS_EXTERNAL_LSA, OSPF_NSSA_EXTERNAL_LSA,
       OSPF_LINK_POINT_TO_POINT, OSPF_LINK_TRANSIT, OSPF_LINK_STUB,
       OSPF_LINK_VIRTUAL,
       OSPFV2_HEADER_BYTES, OSPFV2_HELLO_BODY_BYTES,
       OSPFV2_DATABASE_DESCRIPTION_BYTES, OSPFV2_LSA_HEADER_BYTES,
       OSPFV2_REQUEST_BYTES,
       Ospfv3Packet, Ospfv3Common, Ospfv3Header, Ospfv3Options,
       Ospfv3Hello, Ospfv3DatabaseDescription, Ospfv3LinkStateRequest,
       Ospfv3LinkStateUpdate, Ospfv3LinkStateAcknowledgement, Ospfv3LsaRequest,
       Ospfv3Lsa, Ospfv3LsaHeader, Ospfv3RouterLsa, Ospfv3NetworkLsa,
       Ospfv3InterAreaPrefixLsa, Ospfv3InterAreaRouterLsa, Ospfv3AsExternalLsa,
       Ospfv3LinkLsa, Ospfv3IntraAreaPrefixLsa, Ospfv3RawLsa,
       Ospfv3RouterLink, Ospfv3Prefix, Ospfv3PrefixMetric, Ospfv3PrefixOptions,
       measure_v3_lsa_length, measure_v3_packet_length, measure_prefix_bytes,
       OSPF_VERSION_3, OSPFV3_ROUTER_LSA, OSPFV3_NETWORK_LSA,
       OSPFV3_INTER_AREA_PREFIX_LSA, OSPFV3_INTER_AREA_ROUTER_LSA,
       OSPFV3_AS_EXTERNAL_LSA, OSPFV3_NSSA_LSA, OSPFV3_LINK_LSA,
       OSPFV3_INTRA_AREA_PREFIX_LSA,
       OSPFV3_SCOPE_LINK_LOCAL, OSPFV3_SCOPE_AREA, OSPFV3_SCOPE_AS,
       OSPFV3_SCOPE_RESERVED,
       OSPFV3_LINK_POINT_TO_POINT, OSPFV3_LINK_TRANSIT, OSPFV3_LINK_VIRTUAL,
       OSPFV3_HEADER_BYTES, OSPFV3_HELLO_BODY_BYTES,
       OSPFV3_DATABASE_DESCRIPTION_BYTES, OSPFV3_LSA_HEADER_BYTES,
       OSPFV3_REQUEST_BYTES, OSPFV3_ROUTER_LINK_BYTES,
       SctpHeader, SctpChunk, SctpChunkHeader, SctpChunkRaw,
       SctpData, SctpInit, SctpInitAck, SctpSack, SctpGapAckBlock,
       SctpHeartbeat, SctpHeartbeatAck, SctpAbort, SctpShutdown, SctpShutdownAck,
       SctpError, SctpCookieEcho, SctpCookieAck, SctpShutdownComplete,
       SctpForwardTsn, SctpForwardTsnStream,
       SctpParameter, SctpParameterIpv4Address, SctpParameterIpv6Address,
       SctpParameterCookiePreservative, SctpParameterSupportedAddresses,
       SctpParameterStateCookie, SctpParameterHeartbeatInfo,
       SctpParameterForwardTsn, SctpParameterSupportedExtensions,
       SctpParameterRaw,
       SctpCause, SctpCauseInvalidStream, SctpCauseStaleCookie,
       SctpCauseOutOfResource, SctpCauseNoUserData, SctpCauseCookieWhileShutdown,
       SctpCauseRaw, measure_chunk_value_bytes,
       SCTP_COMMON_HEADER_BYTES, SCTP_CHUNK_HEADER_BYTES,
       SCTP_PARAMETER_HEADER_BYTES,
       SCTP_DATA, SCTP_INIT, SCTP_INIT_ACK, SCTP_SACK, SCTP_HEARTBEAT,
       SCTP_HEARTBEAT_ACK, SCTP_ABORT, SCTP_SHUTDOWN, SCTP_SHUTDOWN_ACK,
       SCTP_ERROR, SCTP_COOKIE_ECHO, SCTP_COOKIE_ACK, SCTP_SHUTDOWN_COMPLETE,
       SCTP_AUTH, SCTP_NR_SACK, SCTP_FORWARD_TSN,
       SCTP_PARAMETER_HEARTBEAT_INFO, SCTP_PARAMETER_IPV4_ADDRESS,
       SCTP_PARAMETER_IPV6_ADDRESS, SCTP_PARAMETER_STATE_COOKIE,
       SCTP_PARAMETER_UNRECOGNIZED, SCTP_PARAMETER_COOKIE_PRESERVATIVE,
       SCTP_PARAMETER_HOST_NAME, SCTP_PARAMETER_SUPPORTED_ADDRESSES,
       SCTP_PARAMETER_RANDOM, SCTP_PARAMETER_CHUNK_LIST,
       SCTP_PARAMETER_HMAC_ALGORITHM, SCTP_PARAMETER_SUPPORTED_EXTENSIONS,
       SCTP_PARAMETER_FORWARD_TSN,
       SCTP_CAUSE_INVALID_STREAM, SCTP_CAUSE_MISSING_PARAMETER,
       SCTP_CAUSE_STALE_COOKIE, SCTP_CAUSE_OUT_OF_RESOURCE,
       SCTP_CAUSE_UNRESOLVABLE_ADDRESS, SCTP_CAUSE_UNRECOGNIZED_CHUNK,
       SCTP_CAUSE_INVALID_PARAMETER, SCTP_CAUSE_UNRECOGNIZED_PARAMETER,
       SCTP_CAUSE_NO_USER_DATA, SCTP_CAUSE_COOKIE_WHILE_SHUTDOWN,
       SCTP_ADDRESS_IPV4, SCTP_ADDRESS_IPV6,
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
include("protocol/Ieee80211.jl")
include("protocol/Ieee80211Phy.jl")
include("protocol/Ieee80211Mgmt.jl")
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
include("protocol/Sctp.jl")
include("protocol/Rip.jl")
include("protocol/Aodv.jl")
include("protocol/Pim.jl")
include("protocol/Bgp.jl")
include("protocol/Rtp.jl")
include("protocol/Dhcp.jl")
include("protocol/Mipv6.jl")
include("protocol/Ospfv2.jl")
include("protocol/Ospfv3.jl")
include("PeekFields.jl")
include("QualityOps.jl")
include("Tags.jl")
include("PacketEnvelope.jl")
include("Buffers.jl")
include("Inspect.jl")

end # module

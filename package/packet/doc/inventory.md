# The INET wire-format inventory

⚙️ **Generated.** Do not edit by hand. Regenerate with
`julia --project=tool tool/inventory_headers.jl`; the generator is
[`tool/inventory_headers.jl`](../../../tool/inventory_headers.jl) and the plan
behind it is `plan/*/protocol-header-inventory.md`.

Source: `remotes/origin/topic/bz/serializertest` in the `inet-cpp` checkout.

Every class below derives from INET's `FieldsChunk`, which means it is a
wire format that `inet-julia` declares with `@header`. A class with no
serializer states a field model that no C++ code turns into bytes.

## The size of it

| fact | count |
| --- | --- |
| `.msg` files read | 229 |
| `*Serializer.cc` files read | 69 |
| classes that derive from `FieldsChunk` | 301 |
| … with a registered serializer | 206 |
| … with no wire format at all | 95 |
| serializer classes that carry them | 95 |

## The tiers

The tier is a property of the codec, so a family that shares one codec
shares one tier.

| tier | what the codec needs | formats |
| --- | --- | --- |
| T0 | fixed widths, big-endian, nothing else | 16 |
| T1 | plus padding, byte order or validation | 14 |
| T2 | plus a length that depends on the data | 10 |
| T3 | plus repetition: arrays or option lists | 89 |
| T4 | plus a variant: one format, many types | 77 |

## Capability demand

How many formats need each construct, counted over the 206
formats that have a codec.

| construct | formats | plan section |
| --- | --- | --- |
| repetition | 85 | D1, D2 |
| helper | 41 | D2, F1 |
| variant | 158 | E2 |
| cursor | 105 | C1, C4 |
| rawbytes | 15 | C2 |
| padding | 51 | C3 |
| quality | 116 | B3 |
| littleendian | 23 | A2 |
| subbyte | 86 | A1 |
| branch | 140 | B3, E3 |

## The families

| family | formats | with a codec | tiers |
| --- | --- | --- | --- |
| `linklayer/ieee80211` | 36 | 31 | T3:28, T4:3 |
| `transportlayer/quic` | 23 | 0 |  |
| `physicallayer/wireless` | 21 | 11 | T2:3, T4:8 |
| `networklayer/icmpv6` | 19 | 18 | T3:6, T4:12 |
| `linklayer/mrp` | 17 | 16 | T0:1, T2:1, T4:14 |
| `networklayer/ipv4` | 15 | 15 | T3:11, T4:4 |
| `routing/eigrp` | 13 | 0 |  |
| `networklayer/mipv6` | 9 | 9 | T4:9 |
| `networklayer/rsvpte` | 9 | 0 |  |
| `linklayer/ethernet` | 8 | 8 | T0:3, T1:3, T4:2 |
| `networklayer/ipv6` | 8 | 7 | T0:1, T1:3, T3:3 |
| `routing/pim` | 8 | 8 | T3:8 |
| `linklayer/ieee8021as` | 7 | 7 | T4:7 |
| `networklayer/ldp` | 7 | 0 |  |
| `transportlayer/rtp` | 7 | 7 | T0:1, T3:6 |
| `routing/ospfv2` | 6 | 6 | T3:6 |
| `routing/ospfv3` | 6 | 6 | T3:6 |
| `routing/aodv` | 5 | 5 | T3:5 |
| `routing/bgpv4` | 4 | 4 | T3:4 |
| `linklayer/csmaca` | 4 | 4 | T4:4 |
| `linklayer/bmac` | 3 | 3 | T4:3 |
| `linklayer/ieee8021d` | 3 | 3 | T4:3 |
| `protocolelement/selectivity` | 3 | 0 |  |
| `physicallayer/wired` | 3 | 3 | T1:1, T3:1, T4:1 |
| `networklayer/ipsec` | 3 | 0 |  |
| `linklayer/ieee8022` | 3 | 2 | T4:2 |
| `linklayer/lmac` | 3 | 0 |  |
| `linklayer/xmac` | 3 | 3 | T4:3 |
| `routing/dymo` | 2 | 0 |  |
| `applications/ethernet` | 2 | 2 | T2:2 |
| `linklayer/ieee8021ae` | 2 | 2 | T0:1, T1:1 |
| `linklayer/ieee8021q` | 2 | 2 | T0:2 |
| `linklayer/ieee8021r` | 2 | 2 | T1:2 |
| `linklayer/ppp` | 2 | 2 | T0:2 |
| `linklayer/acking` | 1 | 1 | T2:1 |
| `protocolelement/acknowledgement` | 1 | 0 |  |
| `applications/base` | 1 | 1 | T2:1 |
| `networklayer/arp` | 1 | 1 | T1:1 |
| `protocolelement/checksum` | 1 | 1 | T4:1 |
| `applications/dhcp` | 1 | 1 | T3:1 |
| `routing/dsdv` | 1 | 1 | T0:1 |
| `networklayer/common` | 1 | 1 | T0:1 |
| `networklayer/flooding` | 1 | 0 |  |
| `protocolelement/fragmentation` | 1 | 1 | T0:1 |
| `routing/gpsr` | 1 | 0 |  |
| `protocolelement/forwarding` | 1 | 0 |  |
| `linklayer/ieee802154` | 1 | 1 | T1:1 |
| `linklayer/ieee802` | 1 | 1 | T4:1 |
| `networklayer/ted` | 1 | 0 |  |
| `networklayer/mpls` | 1 | 1 | T0:1 |
| `networklayer/contract` | 1 | 0 |  |
| `networklayer/nexthop` | 1 | 0 |  |
| `routing/ospf_common` | 1 | 1 | T3:1 |
| `networklayer/probabilistic` | 1 | 0 |  |
| `protocolelement/dispatching` | 1 | 0 |  |
| `routing/rip` | 1 | 1 | T3:1 |
| `transportlayer/sctp` | 1 | 1 | T3:1 |
| `protocolelement/ordering` | 1 | 1 | T0:1 |
| `linklayer/shortcut` | 1 | 1 | T2:1 |
| `applications/voip` | 1 | 0 |  |
| `protocolelement/aggregation` | 1 | 0 |  |
| `transportlayer/tcp_common` | 1 | 1 | T3:1 |
| `transportlayer/contract` | 1 | 0 |  |
| `transportlayer/common` | 1 | 1 | T1:1 |
| `transportlayer/udp` | 1 | 1 | T1:1 |
| `applications/voipstream` | 1 | 1 | T2:1 |
| `networklayer/wiseroute` | 1 | 0 |  |

## Every format

| format | family | tier | serializer | needs |
| --- | --- | --- | --- | --- |
| `ApplicationPacket` | `applications/base` | T2 | `ApplicationPacketSerializer` | `cursor` `padding` `branch` |
| `DhcpMessage` | `applications/dhcp` | T3 | `DhcpMessageSerializer` | `repetition` `variant` `cursor` `rawbytes` `padding` `quality` `subbyte` `branch` |
| `EtherAppReq` | `applications/ethernet` | T2 | `EtherAppReqSerializer` | `cursor` `padding` `branch` |
| `EtherAppResp` | `applications/ethernet` | T2 | `EtherAppRespSerializer` | `cursor` `padding` `branch` |
| `SimpleVoipPacket` | `applications/voip` | — | — model only |  |
| `VoipStreamPacket` | `applications/voipstream` | T2 | `VoipStreamPacketSerializer` | `cursor` `padding` `quality` `branch` |
| `AckingMacHeader` | `linklayer/acking` | T2 | `AckingMacHeaderSerializer` | `cursor` `padding` `branch` |
| `BMacControlFrame` | `linklayer/bmac` | T4 | `BMacHeaderSerializer` | `variant` `cursor` `padding` `quality` `branch` |
| `BMacDataFrameHeader` | `linklayer/bmac` | T4 | `BMacHeaderSerializer` | `variant` `cursor` `padding` `quality` `branch` |
| `BMacHeaderBase` | `linklayer/bmac` | T4 | `BMacHeaderSerializer` | `variant` `cursor` `padding` `quality` `branch` |
| `CsmaCaMacAckHeader` | `linklayer/csmaca` | T4 | `CsmaCaMacHeaderSerializer` | `variant` `cursor` `padding` `branch` |
| `CsmaCaMacDataHeader` | `linklayer/csmaca` | T4 | `CsmaCaMacHeaderSerializer` | `variant` `cursor` `padding` `branch` |
| `CsmaCaMacHeader` | `linklayer/csmaca` | T4 | `CsmaCaMacHeaderSerializer` | `variant` `cursor` `padding` `branch` |
| `CsmaCaMacTrailer` | `linklayer/csmaca` | T4 | `CsmaCaMacTrailerSerializer` | `variant` `branch` |
| `EthernetControlFrameBase` | `linklayer/ethernet` | T4 | `EthernetControlFrameSerializer` | `variant` `quality` `branch` |
| `EthernetFcs` | `linklayer/ethernet` | T1 | `EthernetFcsSerializer` | `branch` |
| `EthernetFragmentFcs` | `linklayer/ethernet` | T1 | `EthernetFcsSerializer` | `branch` |
| `EthernetMacAddressFields` | `linklayer/ethernet` | T0 | `EthernetMacAddressFieldsSerializer` |  |
| `EthernetMacHeader` | `linklayer/ethernet` | T0 | `EthernetMacHeaderSerializer` |  |
| `EthernetPadding` | `linklayer/ethernet` | T1 | `EthernetPaddingSerializer` | `padding` |
| `EthernetPauseFrame` | `linklayer/ethernet` | T4 | `EthernetControlFrameSerializer` | `variant` `quality` `branch` |
| `EthernetTypeOrLengthField` | `linklayer/ethernet` | T0 | `EthernetTypeOrLengthFieldSerializer` |  |
| `Ieee802EpdHeader` | `linklayer/ieee802` | T4 | `Ieee802EpdHeaderSerializer` | `variant` |
| `Ieee80211AckFrame` | `linklayer/ieee80211` | T3 | `Ieee80211MacHeaderSerializer` | `repetition` `variant` `cursor` `quality` `littleendian` `subbyte` `branch` |
| `Ieee80211ActionFrame` | `linklayer/ieee80211` | T3 | `Ieee80211MacHeaderSerializer` | `repetition` `variant` `cursor` `quality` `littleendian` `subbyte` `branch` |
| `Ieee80211ActionFrameOther` | `linklayer/ieee80211` | T3 | `Ieee80211MacHeaderSerializer` | `repetition` `variant` `cursor` `quality` `littleendian` `subbyte` `branch` |
| `Ieee80211AddbaRequest` | `linklayer/ieee80211` | T3 | `Ieee80211MacHeaderSerializer` | `repetition` `variant` `cursor` `quality` `littleendian` `subbyte` `branch` |
| `Ieee80211AddbaResponse` | `linklayer/ieee80211` | T3 | `Ieee80211MacHeaderSerializer` | `repetition` `variant` `cursor` `quality` `littleendian` `subbyte` `branch` |
| `Ieee80211AssociationRequestFrame` | `linklayer/ieee80211` | T3 | `Ieee80211MgmtFrameSerializer` | `repetition` `helper` `variant` `rawbytes` `branch` |
| `Ieee80211AssociationResponseFrame` | `linklayer/ieee80211` | T3 | `Ieee80211MgmtFrameSerializer` | `repetition` `helper` `variant` `rawbytes` `branch` |
| `Ieee80211AuthenticationFrame` | `linklayer/ieee80211` | T3 | `Ieee80211MgmtFrameSerializer` | `repetition` `helper` `variant` `rawbytes` `branch` |
| `Ieee80211BasicBlockAck` | `linklayer/ieee80211` | T3 | `Ieee80211MacHeaderSerializer` | `repetition` `variant` `cursor` `quality` `littleendian` `subbyte` `branch` |
| `Ieee80211BasicBlockAckReq` | `linklayer/ieee80211` | T3 | `Ieee80211MacHeaderSerializer` | `repetition` `variant` `cursor` `quality` `littleendian` `subbyte` `branch` |
| `Ieee80211BeaconFrame` | `linklayer/ieee80211` | T3 | `Ieee80211MgmtFrameSerializer` | `repetition` `helper` `variant` `rawbytes` `branch` |
| `Ieee80211BlockAck` | `linklayer/ieee80211` | — | — model only |  |
| `Ieee80211BlockAckReq` | `linklayer/ieee80211` | — | — model only |  |
| `Ieee80211CompressedBlockAck` | `linklayer/ieee80211` | T3 | `Ieee80211MacHeaderSerializer` | `repetition` `variant` `cursor` `quality` `littleendian` `subbyte` `branch` |
| `Ieee80211CompressedBlockAckReq` | `linklayer/ieee80211` | T3 | `Ieee80211MacHeaderSerializer` | `repetition` `variant` `cursor` `quality` `littleendian` `subbyte` `branch` |
| `Ieee80211CtsFrame` | `linklayer/ieee80211` | T3 | `Ieee80211MacHeaderSerializer` | `repetition` `variant` `cursor` `quality` `littleendian` `subbyte` `branch` |
| `Ieee80211DataHeader` | `linklayer/ieee80211` | T3 | `Ieee80211MacHeaderSerializer` | `repetition` `variant` `cursor` `quality` `littleendian` `subbyte` `branch` |
| `Ieee80211DataOrMgmtHeader` | `linklayer/ieee80211` | T3 | `Ieee80211MacHeaderSerializer` | `repetition` `variant` `cursor` `quality` `littleendian` `subbyte` `branch` |
| `Ieee80211DeauthenticationFrame` | `linklayer/ieee80211` | T3 | `Ieee80211MgmtFrameSerializer` | `repetition` `helper` `variant` `rawbytes` `branch` |
| `Ieee80211Delba` | `linklayer/ieee80211` | T3 | `Ieee80211MacHeaderSerializer` | `repetition` `variant` `cursor` `quality` `littleendian` `subbyte` `branch` |
| `Ieee80211DisassociationFrame` | `linklayer/ieee80211` | T3 | `Ieee80211MgmtFrameSerializer` | `repetition` `helper` `variant` `rawbytes` `branch` |
| `Ieee80211MacHeader` | `linklayer/ieee80211` | T3 | `Ieee80211MacHeaderSerializer` | `repetition` `variant` `cursor` `quality` `littleendian` `subbyte` `branch` |
| `Ieee80211MacTrailer` | `linklayer/ieee80211` | T4 | `Ieee80211MacTrailerSerializer` | `variant` `branch` |
| `Ieee80211MgmtFrame` | `linklayer/ieee80211` | — | — model only |  |
| `Ieee80211MgmtHeader` | `linklayer/ieee80211` | T3 | `Ieee80211MacHeaderSerializer` | `repetition` `variant` `cursor` `quality` `littleendian` `subbyte` `branch` |
| `Ieee80211MpduSubframeHeader` | `linklayer/ieee80211` | T4 | `Ieee80211MpduSubframeHeaderSerializer` | `variant` `cursor` `subbyte` |
| `Ieee80211MsduSubframeHeader` | `linklayer/ieee80211` | T4 | `Ieee80211MsduSubframeHeaderSerializer` | `variant` `cursor` |
| `Ieee80211MultiTidBlockAck` | `linklayer/ieee80211` | T3 | `Ieee80211MacHeaderSerializer` | `repetition` `variant` `cursor` `quality` `littleendian` `subbyte` `branch` |
| `Ieee80211MultiTidBlockAckReq` | `linklayer/ieee80211` | T3 | `Ieee80211MacHeaderSerializer` | `repetition` `variant` `cursor` `quality` `littleendian` `subbyte` `branch` |
| `Ieee80211OneAddressHeader` | `linklayer/ieee80211` | — | — model only |  |
| `Ieee80211ProbeRequestFrame` | `linklayer/ieee80211` | T3 | `Ieee80211MgmtFrameSerializer` | `repetition` `helper` `variant` `rawbytes` `branch` |
| `Ieee80211ProbeResponseFrame` | `linklayer/ieee80211` | T3 | `Ieee80211MgmtFrameSerializer` | `repetition` `helper` `variant` `rawbytes` `branch` |
| `Ieee80211ReassociationRequestFrame` | `linklayer/ieee80211` | T3 | `Ieee80211MgmtFrameSerializer` | `repetition` `helper` `variant` `rawbytes` `branch` |
| `Ieee80211ReassociationResponseFrame` | `linklayer/ieee80211` | T3 | `Ieee80211MgmtFrameSerializer` | `repetition` `helper` `variant` `rawbytes` `branch` |
| `Ieee80211RtsFrame` | `linklayer/ieee80211` | T3 | `Ieee80211MacHeaderSerializer` | `repetition` `variant` `cursor` `quality` `littleendian` `subbyte` `branch` |
| `Ieee80211TwoAddressHeader` | `linklayer/ieee80211` | — | — model only |  |
| `Ieee802154MacHeader` | `linklayer/ieee802154` | T1 | `Ieee802154MacHeaderSerializer` | `littleendian` |
| `Ieee8021aeTagEpdHeader` | `linklayer/ieee8021ae` | T0 | `Ieee8021aeTagEpdHeaderSerializer` |  |
| `Ieee8021aeTagTpidHeader` | `linklayer/ieee8021ae` | T1 | `Ieee8021aeTagTpidHeaderSerializer` | `quality` `branch` |
| `GptpAnnounce` | `linklayer/ieee8021as` | T4 | `GptpPacketSerializer` | `variant` `cursor` `subbyte` |
| `GptpBase` | `linklayer/ieee8021as` | T4 | `GptpPacketSerializer` | `variant` `cursor` `subbyte` |
| `GptpFollowUp` | `linklayer/ieee8021as` | T4 | `GptpPacketSerializer` | `variant` `cursor` `subbyte` |
| `GptpPdelayReq` | `linklayer/ieee8021as` | T4 | `GptpPacketSerializer` | `variant` `cursor` `subbyte` |
| `GptpPdelayResp` | `linklayer/ieee8021as` | T4 | `GptpPacketSerializer` | `variant` `cursor` `subbyte` |
| `GptpPdelayRespFollowUp` | `linklayer/ieee8021as` | T4 | `GptpPacketSerializer` | `variant` `cursor` `subbyte` |
| `GptpSync` | `linklayer/ieee8021as` | T4 | `GptpPacketSerializer` | `variant` `cursor` `subbyte` |
| `BpduBase` | `linklayer/ieee8021d` | T4 | `Ieee8021dBpduSerializer` | `variant` `subbyte` |
| `BpduCfg` | `linklayer/ieee8021d` | T4 | `Ieee8021dBpduSerializer` | `variant` `subbyte` |
| `BpduTcn` | `linklayer/ieee8021d` | T4 | `Ieee8021dBpduSerializer` | `variant` `subbyte` |
| `Ieee8021qTagEpdHeader` | `linklayer/ieee8021q` | T0 | `Ieee8021qTagEpdHeaderSerializer` |  |
| `Ieee8021qTagTpidHeader` | `linklayer/ieee8021q` | T0 | `Ieee8021qTagTpidHeaderSerializer` |  |
| `Ieee8021rTagEpdHeader` | `linklayer/ieee8021r` | T1 | `Ieee8021rTagEpdHeaderSerializer` | `quality` `branch` |
| `Ieee8021rTagTpidHeader` | `linklayer/ieee8021r` | T1 | `Ieee8021rTagTpidHeaderSerializer` | `quality` `branch` |
| `Ieee8022LlcHeader` | `linklayer/ieee8022` | T4 | `Ieee8022LlcHeaderSerializer` | `variant` `branch` |
| `Ieee8022LlcSnapHeader` | `linklayer/ieee8022` | T4 | `Ieee8022LlcHeaderSerializer` | `variant` `branch` |
| `Ieee8022SnapHeader` | `linklayer/ieee8022` | — | — model only |  |
| `LMacControlFrame` | `linklayer/lmac` | — | — model only |  |
| `LMacDataFrameHeader` | `linklayer/lmac` | — | — model only |  |
| `LMacHeaderBase` | `linklayer/lmac` | — | — model only |  |
| `CfmContinuityCheckMessage` | `linklayer/mrp` | T2 | `CfmContinuityCheckMessageSerializer` | `rawbytes` `padding` |
| `CfmMessage` | `linklayer/mrp` | — | — model only |  |
| `MrpCommon` | `linklayer/mrp` | T4 | `MrpTlvSerializer` | `variant` `cursor` `padding` `branch` |
| `MrpEnd` | `linklayer/mrp` | T4 | `MrpTlvSerializer` | `variant` `cursor` `padding` `branch` |
| `MrpInLinkChange` | `linklayer/mrp` | T4 | `MrpTlvSerializer` | `variant` `cursor` `padding` `branch` |
| `MrpInLinkStatusPoll` | `linklayer/mrp` | T4 | `MrpTlvSerializer` | `variant` `cursor` `padding` `branch` |
| `MrpInTest` | `linklayer/mrp` | T4 | `MrpTlvSerializer` | `variant` `cursor` `padding` `branch` |
| `MrpInTopologyChange` | `linklayer/mrp` | T4 | `MrpTlvSerializer` | `variant` `cursor` `padding` `branch` |
| `MrpLinkChange` | `linklayer/mrp` | T4 | `MrpTlvSerializer` | `variant` `cursor` `padding` `branch` |
| `MrpManufacturerFkt` | `linklayer/mrp` | T4 | `MrpSubTlvSerializer` | `variant` |
| `MrpOption` | `linklayer/mrp` | T4 | `MrpTlvSerializer` | `variant` `cursor` `padding` `branch` |
| `MrpSubTlvHeader` | `linklayer/mrp` | T4 | `MrpSubTlvSerializer` | `variant` |
| `MrpSubTlvTest` | `linklayer/mrp` | T4 | `MrpSubTlvSerializer` | `variant` |
| `MrpTest` | `linklayer/mrp` | T4 | `MrpTlvSerializer` | `variant` `cursor` `padding` `branch` |
| `MrpTlvHeader` | `linklayer/mrp` | T4 | `MrpTlvSerializer` | `variant` `cursor` `padding` `branch` |
| `MrpTopologyChange` | `linklayer/mrp` | T4 | `MrpTlvSerializer` | `variant` `cursor` `padding` `branch` |
| `MrpVersion` | `linklayer/mrp` | T0 | `MrpVersionFieldSerializer` |  |
| `PppHeader` | `linklayer/ppp` | T0 | `PppHeaderSerializer` |  |
| `PppTrailer` | `linklayer/ppp` | T0 | `PppTrailerSerializer` |  |
| `ShortcutMacHeader` | `linklayer/shortcut` | T2 | `ShortcutMacHeaderSerializer` | `cursor` `padding` `quality` `branch` |
| `XMacControlFrame` | `linklayer/xmac` | T4 | `XMacHeaderSerializer` | `variant` `cursor` `padding` `quality` `branch` |
| `XMacDataFrameHeader` | `linklayer/xmac` | T4 | `XMacHeaderSerializer` | `variant` `cursor` `padding` `quality` `branch` |
| `XMacHeaderBase` | `linklayer/xmac` | T4 | `XMacHeaderSerializer` | `variant` `cursor` `padding` `quality` `branch` |
| `ArpPacket` | `networklayer/arp` | T1 | `ArpPacketSerializer` | `quality` `branch` |
| `EchoPacket` | `networklayer/common` | T0 | `EchoPacketSerializer` |  |
| `NetworkHeaderBase` | `networklayer/contract` | — | — model only |  |
| `FloodingHeader` | `networklayer/flooding` | — | — model only |  |
| `Icmpv6DestUnreachableMsg` | `networklayer/icmpv6` | T4 | `Icmpv6HeaderSerializer` | `variant` `quality` |
| `Icmpv6EchoReplyMsg` | `networklayer/icmpv6` | T4 | `Icmpv6HeaderSerializer` | `variant` `quality` |
| `Icmpv6EchoRequestMsg` | `networklayer/icmpv6` | T4 | `Icmpv6HeaderSerializer` | `variant` `quality` |
| `Icmpv6Header` | `networklayer/icmpv6` | T4 | `Icmpv6HeaderSerializer` | `variant` `quality` |
| `Icmpv6PacketTooBigMsg` | `networklayer/icmpv6` | T4 | `Icmpv6HeaderSerializer` | `variant` `quality` |
| `Icmpv6ParamProblemMsg` | `networklayer/icmpv6` | T4 | `Icmpv6HeaderSerializer` | `variant` `quality` |
| `Icmpv6TimeExceededMsg` | `networklayer/icmpv6` | T4 | `Icmpv6HeaderSerializer` | `variant` `quality` |
| `Ipv6NdMessage` | `networklayer/icmpv6` | — | — model only |  |
| `Ipv6NeighbourAdvertisement` | `networklayer/icmpv6` | T4 | `Icmpv6HeaderSerializer` | `variant` `quality` |
| `Ipv6NeighbourSolicitation` | `networklayer/icmpv6` | T4 | `Icmpv6HeaderSerializer` | `variant` `quality` |
| `Ipv6Redirect` | `networklayer/icmpv6` | T4 | `Icmpv6HeaderSerializer` | `variant` `quality` |
| `Ipv6RouterAdvertisement` | `networklayer/icmpv6` | T4 | `Icmpv6HeaderSerializer` | `variant` `quality` |
| `Ipv6RouterSolicitation` | `networklayer/icmpv6` | T4 | `Icmpv6HeaderSerializer` | `variant` `quality` |
| `MldDone` | `networklayer/icmpv6` | T3 | `MldHeaderSerializer` | `repetition` `variant` `cursor` `quality` `subbyte` `branch` |
| `MldMessage` | `networklayer/icmpv6` | T3 | `MldHeaderSerializer` | `repetition` `variant` `cursor` `quality` `subbyte` `branch` |
| `MldQuery` | `networklayer/icmpv6` | T3 | `MldHeaderSerializer` | `repetition` `variant` `cursor` `quality` `subbyte` `branch` |
| `MldReport` | `networklayer/icmpv6` | T3 | `MldHeaderSerializer` | `repetition` `variant` `cursor` `quality` `subbyte` `branch` |
| `Mldv2Query` | `networklayer/icmpv6` | T3 | `MldHeaderSerializer` | `repetition` `variant` `cursor` `quality` `subbyte` `branch` |
| `Mldv2Report` | `networklayer/icmpv6` | T3 | `MldHeaderSerializer` | `repetition` `variant` `cursor` `quality` `subbyte` `branch` |
| `IPsecAuthenticationHeader` | `networklayer/ipsec` | — | — model only |  |
| `IPsecEspHeader` | `networklayer/ipsec` | — | — model only |  |
| `IPsecEspTrailer` | `networklayer/ipsec` | — | — model only |  |
| `IcmpEchoReply` | `networklayer/ipv4` | T4 | `IcmpHeaderSerializer` | `variant` `quality` `branch` |
| `IcmpEchoRequest` | `networklayer/ipv4` | T4 | `IcmpHeaderSerializer` | `variant` `quality` `branch` |
| `IcmpHeader` | `networklayer/ipv4` | T4 | `IcmpHeaderSerializer` | `variant` `quality` `branch` |
| `IcmpPtb` | `networklayer/ipv4` | T4 | `IcmpHeaderSerializer` | `variant` `quality` `branch` |
| `IgmpMessage` | `networklayer/ipv4` | T3 | `IgmpHeaderSerializer` | `repetition` `variant` `cursor` `quality` `subbyte` `branch` |
| `IgmpQuery` | `networklayer/ipv4` | T3 | `IgmpHeaderSerializer` | `repetition` `variant` `cursor` `quality` `subbyte` `branch` |
| `Igmpv1Query` | `networklayer/ipv4` | T3 | `IgmpHeaderSerializer` | `repetition` `variant` `cursor` `quality` `subbyte` `branch` |
| `Igmpv1Report` | `networklayer/ipv4` | T3 | `IgmpHeaderSerializer` | `repetition` `variant` `cursor` `quality` `subbyte` `branch` |
| `Igmpv2Leave` | `networklayer/ipv4` | T3 | `IgmpHeaderSerializer` | `repetition` `variant` `cursor` `quality` `subbyte` `branch` |
| `Igmpv2Query` | `networklayer/ipv4` | T3 | `IgmpHeaderSerializer` | `repetition` `variant` `cursor` `quality` `subbyte` `branch` |
| `Igmpv2Report` | `networklayer/ipv4` | T3 | `IgmpHeaderSerializer` | `repetition` `variant` `cursor` `quality` `subbyte` `branch` |
| `Igmpv3Query` | `networklayer/ipv4` | T3 | `IgmpHeaderSerializer` | `repetition` `variant` `cursor` `quality` `subbyte` `branch` |
| `Igmpv3Report` | `networklayer/ipv4` | T3 | `IgmpHeaderSerializer` | `repetition` `variant` `cursor` `quality` `subbyte` `branch` |
| `Ipv4Header` | `networklayer/ipv4` | T3 | `Ipv4HeaderSerializer` | `repetition` `helper` `cursor` `rawbytes` `quality` `branch` |
| `RgmpHello` | `networklayer/ipv4` | T3 | `IgmpHeaderSerializer` | `repetition` `variant` `cursor` `quality` `subbyte` `branch` |
| `Ipv6AuthenticationHeader` | `networklayer/ipv6` | T1 | `Ipv6AuthenticationHeaderSerializer` | `padding` |
| `Ipv6DestinationOptionsHeader` | `networklayer/ipv6` | T3 | `Ipv6DestinationOptionsHeaderSerializer` | `helper` |
| `Ipv6EncapsulatingSecurityPayloadHeader` | `networklayer/ipv6` | T1 | `Ipv6EncapsulatingSecurityPayloadHeaderSerializer` | `padding` |
| `Ipv6ExtensionHeader` | `networklayer/ipv6` | — | — model only |  |
| `Ipv6FragmentHeader` | `networklayer/ipv6` | T0 | `Ipv6FragmentHeaderSerializer` | `subbyte` |
| `Ipv6Header` | `networklayer/ipv6` | T1 | `Ipv6HeaderSerializer` | `quality` `subbyte` `branch` |
| `Ipv6HopByHopOptionsHeader` | `networklayer/ipv6` | T3 | `Ipv6HopByHopOptionsHeaderSerializer` | `helper` |
| `Ipv6RoutingHeader` | `networklayer/ipv6` | T3 | `Ipv6RoutingHeaderSerializer` | `repetition` |
| `LdpAddress` | `networklayer/ldp` | — | — model only |  |
| `LdpHello` | `networklayer/ldp` | — | — model only |  |
| `LdpIni` | `networklayer/ldp` | — | — model only |  |
| `LdpLabelMapping` | `networklayer/ldp` | — | — model only |  |
| `LdpLabelRequest` | `networklayer/ldp` | — | — model only |  |
| `LdpNotify` | `networklayer/ldp` | — | — model only |  |
| `LdpPacket` | `networklayer/ldp` | — | — model only |  |
| `BindingAcknowledgement` | `networklayer/mipv6` | T4 | `MobilityHeaderSerializer` | `variant` `cursor` `padding` `quality` `branch` |
| `BindingError` | `networklayer/mipv6` | T4 | `MobilityHeaderSerializer` | `variant` `cursor` `padding` `quality` `branch` |
| `BindingRefreshRequest` | `networklayer/mipv6` | T4 | `MobilityHeaderSerializer` | `variant` `cursor` `padding` `quality` `branch` |
| `BindingUpdate` | `networklayer/mipv6` | T4 | `MobilityHeaderSerializer` | `variant` `cursor` `padding` `quality` `branch` |
| `CareOfTest` | `networklayer/mipv6` | T4 | `MobilityHeaderSerializer` | `variant` `cursor` `padding` `quality` `branch` |
| `CareOfTestInit` | `networklayer/mipv6` | T4 | `MobilityHeaderSerializer` | `variant` `cursor` `padding` `quality` `branch` |
| `HomeTest` | `networklayer/mipv6` | T4 | `MobilityHeaderSerializer` | `variant` `cursor` `padding` `quality` `branch` |
| `HomeTestInit` | `networklayer/mipv6` | T4 | `MobilityHeaderSerializer` | `variant` `cursor` `padding` `quality` `branch` |
| `MobilityHeader` | `networklayer/mipv6` | T4 | `MobilityHeaderSerializer` | `variant` `cursor` `padding` `quality` `branch` |
| `MplsHeader` | `networklayer/mpls` | T0 | `MplsPacketSerializer` | `subbyte` |
| `NextHopForwardingHeader` | `networklayer/nexthop` | — | — model only |  |
| `ProbabilisticBroadcastHeader` | `networklayer/probabilistic` | — | — model only |  |
| `RsvpHelloMsg` | `networklayer/rsvpte` | — | — model only |  |
| `RsvpMessage` | `networklayer/rsvpte` | — | — model only |  |
| `RsvpPacket` | `networklayer/rsvpte` | — | — model only |  |
| `RsvpPathError` | `networklayer/rsvpte` | — | — model only |  |
| `RsvpPathMsg` | `networklayer/rsvpte` | — | — model only |  |
| `RsvpPathTear` | `networklayer/rsvpte` | — | — model only |  |
| `RsvpResvError` | `networklayer/rsvpte` | — | — model only |  |
| `RsvpResvMsg` | `networklayer/rsvpte` | — | — model only |  |
| `RsvpResvTear` | `networklayer/rsvpte` | — | — model only |  |
| `LinkStateMsg` | `networklayer/ted` | — | — model only |  |
| `WiseRouteHeader` | `networklayer/wiseroute` | — | — model only |  |
| `EthernetFragmentPhyHeader` | `physicallayer/wired` | T4 | `EthernetFragmentPhyHeaderSerializer` | `variant` `padding` `quality` `branch` |
| `EthernetPhyHeader` | `physicallayer/wired` | T1 | `EthernetPhyHeaderSerializer` | `padding` `quality` `branch` |
| `EthernetPhyHeaderBase` | `physicallayer/wired` | T3 | `EthernetPhyHeaderBaseSerializer` | `helper` `branch` |
| `ApskPhyHeader` | `physicallayer/wireless` | T2 | `ApskPhyHeaderSerializer` | `cursor` `padding` `quality` `branch` |
| `GenericPhyHeader` | `physicallayer/wireless` | T2 | `GenericPhyHeaderSerializer` | `cursor` `padding` `branch` |
| `Ieee80211DsssPhyHeader` | `physicallayer/wireless` | T4 | `Ieee80211DsssPhyHeaderSerializer` | `variant` `littleendian` |
| `Ieee80211DsssPhyPreamble` | `physicallayer/wireless` | — | — model only |  |
| `Ieee80211ErpOfdmPhyHeader` | `physicallayer/wireless` | T4 | `Ieee80211ErpOfdmPhyHeaderSerializer` | `variant` `littleendian` |
| `Ieee80211ErpOfdmPhyPreamble` | `physicallayer/wireless` | — | — model only |  |
| `Ieee80211FhssPhyHeader` | `physicallayer/wireless` | T4 | `Ieee80211FhssPhyHeaderSerializer` | `variant` `subbyte` |
| `Ieee80211FhssPhyPreamble` | `physicallayer/wireless` | — | — model only |  |
| `Ieee80211HrDsssPhyHeader` | `physicallayer/wireless` | T4 | `Ieee80211HrDsssPhyHeaderSerializer` | `variant` `littleendian` |
| `Ieee80211HrDsssPhyPreamble` | `physicallayer/wireless` | — | — model only |  |
| `Ieee80211HtPhyHeader` | `physicallayer/wireless` | T4 | `Ieee80211HtPhyHeaderSerializer` | `variant` |
| `Ieee80211HtPhyPreamble` | `physicallayer/wireless` | — | — model only |  |
| `Ieee80211IrPhyHeader` | `physicallayer/wireless` | T4 | `Ieee80211IrPhyHeaderSerializer` | `variant` |
| `Ieee80211IrPhyPreamble` | `physicallayer/wireless` | — | — model only |  |
| `Ieee80211OfdmPhyHeader` | `physicallayer/wireless` | T4 | `Ieee80211OfdmPhyHeaderSerializer` | `variant` `littleendian` |
| `Ieee80211OfdmPhyPreamble` | `physicallayer/wireless` | — | — model only |  |
| `Ieee80211PhyHeader` | `physicallayer/wireless` | — | — model only |  |
| `Ieee80211PhyPreamble` | `physicallayer/wireless` | — | — model only |  |
| `Ieee80211VhtPhyHeader` | `physicallayer/wireless` | T4 | `Ieee80211VhtPhyHeaderSerializer` | `variant` |
| `Ieee80211VhtPhyPreamble` | `physicallayer/wireless` | — | — model only |  |
| `ShortcutPhyHeader` | `physicallayer/wireless` | T2 | `ShortcutPhyHeaderSerializer` | `cursor` `padding` `quality` `branch` |
| `AcknowledgeHeader` | `protocolelement/acknowledgement` | — | — model only |  |
| `SubpacketLengthHeader` | `protocolelement/aggregation` | — | — model only |  |
| `ChecksumHeader` | `protocolelement/checksum` | T4 | `ChecksumHeaderSerializer` | `variant` `cursor` `branch` |
| `ProtocolHeader` | `protocolelement/dispatching` | — | — model only |  |
| `HopLimitHeader` | `protocolelement/forwarding` | — | — model only |  |
| `FragmentNumberHeader` | `protocolelement/fragmentation` | T0 | `FragmentNumberHeaderSerializer` |  |
| `SequenceNumberHeader` | `protocolelement/ordering` | T0 | `SequenceNumberHeaderSerializer` |  |
| `DestinationL3AddressHeader` | `protocolelement/selectivity` | — | — model only |  |
| `DestinationMacAddressHeader` | `protocolelement/selectivity` | — | — model only |  |
| `DestinationPortHeader` | `protocolelement/selectivity` | — | — model only |  |
| `AodvControlPacket` | `routing/aodv` | T3 | `AodvControlPacketsSerializer` | `repetition` `variant` `quality` `subbyte` `branch` |
| `Rerr` | `routing/aodv` | T3 | `AodvControlPacketsSerializer` | `repetition` `variant` `quality` `subbyte` `branch` |
| `Rrep` | `routing/aodv` | T3 | `AodvControlPacketsSerializer` | `repetition` `variant` `quality` `subbyte` `branch` |
| `RrepAck` | `routing/aodv` | T3 | `AodvControlPacketsSerializer` | `repetition` `variant` `quality` `subbyte` `branch` |
| `Rreq` | `routing/aodv` | T3 | `AodvControlPacketsSerializer` | `repetition` `variant` `quality` `subbyte` `branch` |
| `BgpHeader` | `routing/bgpv4` | T3 | `BgpHeaderSerializer` | `repetition` `variant` `cursor` `padding` `quality` `subbyte` `branch` |
| `BgpKeepAliveMessage` | `routing/bgpv4` | T3 | `BgpHeaderSerializer` | `repetition` `variant` `cursor` `padding` `quality` `subbyte` `branch` |
| `BgpOpenMessage` | `routing/bgpv4` | T3 | `BgpHeaderSerializer` | `repetition` `variant` `cursor` `padding` `quality` `subbyte` `branch` |
| `BgpUpdateMessage` | `routing/bgpv4` | T3 | `BgpHeaderSerializer` | `repetition` `variant` `cursor` `padding` `quality` `subbyte` `branch` |
| `DsdvHello` | `routing/dsdv` | T0 | `DsdvHelloSerializer` |  |
| `DymoPacket` | `routing/dymo` | — | — model only |  |
| `RteMsg` | `routing/dymo` | — | — model only |  |
| `EigrpIpv4Ack` | `routing/eigrp` | — | — model only |  |
| `EigrpIpv4Hello` | `routing/eigrp` | — | — model only |  |
| `EigrpIpv4Message` | `routing/eigrp` | — | — model only |  |
| `EigrpIpv4Query` | `routing/eigrp` | — | — model only |  |
| `EigrpIpv4Reply` | `routing/eigrp` | — | — model only |  |
| `EigrpIpv4Update` | `routing/eigrp` | — | — model only |  |
| `EigrpIpv6Ack` | `routing/eigrp` | — | — model only |  |
| `EigrpIpv6Hello` | `routing/eigrp` | — | — model only |  |
| `EigrpIpv6Message` | `routing/eigrp` | — | — model only |  |
| `EigrpIpv6Query` | `routing/eigrp` | — | — model only |  |
| `EigrpIpv6Reply` | `routing/eigrp` | — | — model only |  |
| `EigrpIpv6Update` | `routing/eigrp` | — | — model only |  |
| `EigrpMessage` | `routing/eigrp` | — | — model only |  |
| `GpsrBeacon` | `routing/gpsr` | — | — model only |  |
| `OspfPacketBase` | `routing/ospf_common` | T3 | `OspfPacketSerializer` | `helper` `variant` `cursor` `padding` `quality` `branch` |
| `Ospfv2DatabaseDescriptionPacket` | `routing/ospfv2` | T3 | `Ospfv2PacketSerializer` | `repetition` `helper` `variant` `quality` `subbyte` `branch` |
| `Ospfv2HelloPacket` | `routing/ospfv2` | T3 | `Ospfv2PacketSerializer` | `repetition` `helper` `variant` `quality` `subbyte` `branch` |
| `Ospfv2LinkStateAcknowledgementPacket` | `routing/ospfv2` | T3 | `Ospfv2PacketSerializer` | `repetition` `helper` `variant` `quality` `subbyte` `branch` |
| `Ospfv2LinkStateRequestPacket` | `routing/ospfv2` | T3 | `Ospfv2PacketSerializer` | `repetition` `helper` `variant` `quality` `subbyte` `branch` |
| `Ospfv2LinkStateUpdatePacket` | `routing/ospfv2` | T3 | `Ospfv2PacketSerializer` | `repetition` `helper` `variant` `quality` `subbyte` `branch` |
| `Ospfv2Packet` | `routing/ospfv2` | T3 | `Ospfv2PacketSerializer` | `repetition` `helper` `variant` `quality` `subbyte` `branch` |
| `Ospfv3DatabaseDescriptionPacket` | `routing/ospfv3` | T3 | `Ospfv3PacketSerializer` | `repetition` `helper` `variant` `quality` `subbyte` `branch` |
| `Ospfv3HelloPacket` | `routing/ospfv3` | T3 | `Ospfv3PacketSerializer` | `repetition` `helper` `variant` `quality` `subbyte` `branch` |
| `Ospfv3LinkStateAcknowledgementPacket` | `routing/ospfv3` | T3 | `Ospfv3PacketSerializer` | `repetition` `helper` `variant` `quality` `subbyte` `branch` |
| `Ospfv3LinkStateRequestPacket` | `routing/ospfv3` | T3 | `Ospfv3PacketSerializer` | `repetition` `helper` `variant` `quality` `subbyte` `branch` |
| `Ospfv3LinkStateUpdatePacket` | `routing/ospfv3` | T3 | `Ospfv3PacketSerializer` | `repetition` `helper` `variant` `quality` `subbyte` `branch` |
| `Ospfv3Packet` | `routing/ospfv3` | T3 | `Ospfv3PacketSerializer` | `repetition` `helper` `variant` `quality` `subbyte` `branch` |
| `PimAssert` | `routing/pim` | T3 | `PimPacketSerializer` | `repetition` `helper` `variant` `cursor` `quality` `subbyte` `branch` |
| `PimGraft` | `routing/pim` | T3 | `PimPacketSerializer` | `repetition` `helper` `variant` `cursor` `quality` `subbyte` `branch` |
| `PimHello` | `routing/pim` | T3 | `PimPacketSerializer` | `repetition` `helper` `variant` `cursor` `quality` `subbyte` `branch` |
| `PimJoinPrune` | `routing/pim` | T3 | `PimPacketSerializer` | `repetition` `helper` `variant` `cursor` `quality` `subbyte` `branch` |
| `PimPacket` | `routing/pim` | T3 | `PimPacketSerializer` | `repetition` `helper` `variant` `cursor` `quality` `subbyte` `branch` |
| `PimRegister` | `routing/pim` | T3 | `PimPacketSerializer` | `repetition` `helper` `variant` `cursor` `quality` `subbyte` `branch` |
| `PimRegisterStop` | `routing/pim` | T3 | `PimPacketSerializer` | `repetition` `helper` `variant` `cursor` `quality` `subbyte` `branch` |
| `PimStateRefresh` | `routing/pim` | T3 | `PimPacketSerializer` | `repetition` `helper` `variant` `cursor` `quality` `subbyte` `branch` |
| `RipPacket` | `routing/rip` | T3 | `RipPacketSerializer` | `repetition` `cursor` `quality` `branch` |
| `TransportPseudoHeader` | `transportlayer/common` | T1 | `TransportPseudoHeaderSerializer` | `branch` |
| `TransportHeaderBase` | `transportlayer/contract` | — | — model only |  |
| `AckFrameHeader` | `transportlayer/quic` | — | — model only |  |
| `ConnectionCloseFrameHeader` | `transportlayer/quic` | — | — model only |  |
| `CryptoFrameHeader` | `transportlayer/quic` | — | — model only |  |
| `DataBlockedFrameHeader` | `transportlayer/quic` | — | — model only |  |
| `FrameHeader` | `transportlayer/quic` | — | — model only |  |
| `HandshakeDoneFrameHeader` | `transportlayer/quic` | — | — model only |  |
| `HandshakePacketHeader` | `transportlayer/quic` | — | — model only |  |
| `InitialPacketHeader` | `transportlayer/quic` | — | — model only |  |
| `LongPacketHeader` | `transportlayer/quic` | — | — model only |  |
| `MaxDataFrameHeader` | `transportlayer/quic` | — | — model only |  |
| `MaxStreamDataFrameHeader` | `transportlayer/quic` | — | — model only |  |
| `NewTokenFrameHeader` | `transportlayer/quic` | — | — model only |  |
| `OneRttPacketHeader` | `transportlayer/quic` | — | — model only |  |
| `PacketHeader` | `transportlayer/quic` | — | — model only |  |
| `PaddingFrameHeader` | `transportlayer/quic` | — | — model only |  |
| `PingFrameHeader` | `transportlayer/quic` | — | — model only |  |
| `RetryPacketHeader` | `transportlayer/quic` | — | — model only |  |
| `ShortPacketHeader` | `transportlayer/quic` | — | — model only |  |
| `StreamDataBlockedFrameHeader` | `transportlayer/quic` | — | — model only |  |
| `StreamFrameHeader` | `transportlayer/quic` | — | — model only |  |
| `TransportParametersExtension` | `transportlayer/quic` | — | — model only |  |
| `VersionNegotiationPacketHeader` | `transportlayer/quic` | — | — model only |  |
| `ZeroRttPacketHeader` | `transportlayer/quic` | — | — model only |  |
| `RtcpByePacket` | `transportlayer/rtp` | T3 | `RtcpPacketSerializer` | `repetition` `helper` `variant` `cursor` `quality` `subbyte` |
| `RtcpPacket` | `transportlayer/rtp` | T3 | `RtcpPacketSerializer` | `repetition` `helper` `variant` `cursor` `quality` `subbyte` |
| `RtcpReceiverReportPacket` | `transportlayer/rtp` | T3 | `RtcpPacketSerializer` | `repetition` `helper` `variant` `cursor` `quality` `subbyte` |
| `RtcpSdesPacket` | `transportlayer/rtp` | T3 | `RtcpPacketSerializer` | `repetition` `helper` `variant` `cursor` `quality` `subbyte` |
| `RtcpSenderReportPacket` | `transportlayer/rtp` | T3 | `RtcpPacketSerializer` | `repetition` `helper` `variant` `cursor` `quality` `subbyte` |
| `RtpHeader` | `transportlayer/rtp` | T3 | `RtpPacketSerializer` | `repetition` `subbyte` |
| `RtpMpegHeader` | `transportlayer/rtp` | T0 | `RtpMpegPacketSerializer` | `subbyte` |
| `SctpHeader` | `transportlayer/sctp` | T3 | `SctpHeaderSerializer` | `repetition` `variant` `cursor` `rawbytes` `branch` |
| `TcpHeader` | `transportlayer/tcp_common` | T3 | `TcpHeaderSerializer` | `repetition` `helper` `cursor` `rawbytes` `padding` `branch` |
| `UdpHeader` | `transportlayer/udp` | T1 | `UdpHeaderSerializer` | `branch` |

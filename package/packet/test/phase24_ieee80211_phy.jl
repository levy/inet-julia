# ============================================================================
# Phase 24 — the IEEE 802.11 physical-layer headers.
# ============================================================================
using Test
using InetPacket.PacketModule

hex24(bytes) = join((string(b, base = 16, pad = 2) for b in bytes), " ")

@testset "802.11 PHY — one header per modulation, and three orders between them" begin
    for (T, octets) in ((Ieee80211FhssPhyHeader, IEEE80211_FHSS_PHY_HEADER_BYTES),
                        (Ieee80211IrPhyHeader, IEEE80211_IR_PHY_HEADER_BYTES),
                        (Ieee80211DsssPhyHeader, IEEE80211_DSSS_PHY_HEADER_BYTES),
                        (Ieee80211HrDsssPhyHeader, IEEE80211_HR_DSSS_PHY_HEADER_BYTES),
                        (Ieee80211OfdmPhyHeader, IEEE80211_OFDM_PHY_HEADER_BYTES),
                        (Ieee80211ErpOfdmPhyHeader, IEEE80211_OFDM_PHY_HEADER_BYTES))
        @test chunk_length(T) == Bytes(octets)
        @test check_round_trip(T)
    end

    # ---------- FHSS is the only one in network order, clause 18.2.3 --------
    fhss = Ieee80211FhssPhyHeader(psdu_length = UInt16(0x123), signalling = 0x4,
                                  header_error_check = 0xabcd)
    @test hex24(encode_header(fhss)) == "12 34 ab cd"
    fhss_back = decode_header(Ieee80211FhssPhyHeader, encode_header(fhss))
    @test fhss_back.psdu_length == 0x123
    @test fhss_back.signalling == 0x4

    # ---------- DSSS puts its length and CRC low octet first, clause 16.2.3 -
    dsss = Ieee80211DsssPhyHeader(signal = 10, length_field = UInt16(0x1234),
                                  crc = 0xabcd)
    @test byte_order(Ieee80211DsssPhyHeader) == :le
    @test hex24(encode_header(dsss)) == "0a 00 34 12 cd ab"
    dsss_back = decode_header(Ieee80211DsssPhyHeader, encode_header(dsss))
    @test dsss_back.length_field == 0x1234
    @test dsss_back.crc == Checksum16(0xabcd)

    # HR/DSSS is the same six octets.
    hr = Ieee80211HrDsssPhyHeader(signal = 110, length_field = UInt16(0x1234),
                                  crc = 0xabcd)
    @test hex24(encode_header(hr)) == "6e 00 34 12 cd ab"

    # ---------- the OFDM SIGNAL goes out low BIT first, clause 17.3.4 -------
    # The rate is the lowest four bits, the length is bits five to sixteen and
    # the parity is bit seventeen, so the three octets come out reversed. A
    # reader that took twenty-four bits high bit first would find the rate in
    # the tail.
    signal = Ieee80211OfdmSignal(rate = 0xb, length = 100, parity = true)
    @test read_ofdm_rate(signal) == 11
    @test read_ofdm_length(signal) == 100
    @test read_ofdm_parity(signal)
    @test read_ofdm_tail(signal) == 0
    @test !read_ofdm_reserved(signal)

    ofdm = Ieee80211OfdmPhyHeader(signal = signal, service = UInt16(0))
    @test hex24(encode_header(ofdm)) == "8b 0c 02 00 00"
    ofdm_back = decode_header(Ieee80211OfdmPhyHeader, encode_header(ofdm))
    @test read_ofdm_rate(ofdm_back.signal) == 11
    @test read_ofdm_length(ofdm_back.signal) == 100
    @test read_ofdm_parity(ofdm_back.signal)
    @test ofdm_back.signal == signal

    # Extended rate OFDM writes the same five octets.
    erp = Ieee80211ErpOfdmPhyHeader(signal = signal, service = UInt16(0))
    @test encode_header(erp) == encode_header(ofdm)
    @test decode_header(Ieee80211ErpOfdmPhyHeader,
                        encode_header(erp)).signal == signal

    # A signal of every rate survives, which is what a wrong bit order breaks.
    for rate in 0:15, length_field in (0, 1, 100, 4095)
        one = Ieee80211OfdmSignal(rate = rate, length = length_field)
        back = decode_header(Ieee80211OfdmPhyHeader,
                             encode_header(Ieee80211OfdmPhyHeader(signal = one)))
        @test read_ofdm_rate(back.signal) == rate
        @test read_ofdm_length(back.signal) == length_field
    end
end

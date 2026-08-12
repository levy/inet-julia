# ============================================================================
# The IEEE 802.11 management frame bodies — IEEE 802.11-2016 clause 9.3.3.
#
# A management frame is the MAC header of `Ieee80211.jl` and then one of the ten
# bodies here. The bodies are not a variant family: nothing in a body says which
# body it is. The subtype in the frame control field says it, and that lives in
# the header, so a reader picks the body from the header it already has.
#
# Every body ends with a list of information elements — clause 9.4.2. An element
# is a one-octet identifier, a one-octet length and that many octets, which is
# the shape `Options` was written for.
#
# **INET writes two elements inline and in a fixed order.** Its serializer emits
# the SSID and then the supported rates, both by hand, and its reader expects
# exactly that. A beacon from real equipment carries a DS parameter set, a
# traffic indication map, a country element and more, in an order the standard
# fixes but INET does not follow — so INET reads its own beacons and nothing
# else. Here the elements are a list, so an element this library does not model
# still keeps its octets and its place.
#
# One more difference, and it loses information rather than octets. INET writes
# a constant zero where clause 9.3.3.12 puts the authentication algorithm
# number, so a Shared Key authentication frame comes back as an Open System one.
# The field is declared.
# ============================================================================

"The information element identifiers — IEEE 802.11-2016 clause 9.4.2.1."
const IEEE80211_ELEMENT_SSID                   = 0
const IEEE80211_ELEMENT_SUPPORTED_RATES        = 1
const IEEE80211_ELEMENT_DSSS_PARAMETER_SET     = 3
const IEEE80211_ELEMENT_TRAFFIC_INDICATION_MAP = 5
const IEEE80211_ELEMENT_IBSS_PARAMETER_SET     = 6
const IEEE80211_ELEMENT_COUNTRY                = 7
const IEEE80211_ELEMENT_EXTENDED_RATES         = 50

"The authentication algorithms — IEEE 802.11-2016 clause 9.4.1.1."
const IEEE80211_AUTHENTICATION_OPEN_SYSTEM = 0
const IEEE80211_AUTHENTICATION_SHARED_KEY  = 1

"The status codes a response carries — IEEE 802.11-2016 clause 9.4.1.9."
const IEEE80211_STATUS_SUCCESS          = 0
const IEEE80211_STATUS_UNSPECIFIED      = 1
const IEEE80211_STATUS_CAPABILITY_UNSUPPORTED = 10
const IEEE80211_STATUS_ASSOCIATION_DENIED     = 12

"The reason codes a disassociation carries — IEEE 802.11-2016 clause 9.4.1.7."
const IEEE80211_REASON_UNSPECIFIED       = 1
const IEEE80211_REASON_LEAVING           = 3
const IEEE80211_REASON_INACTIVITY        = 4
const IEEE80211_REASON_NOT_AUTHENTICATED = 6

"A beacon interval counts time units of 1024 microseconds — clause 9.4.1.3."
const IEEE80211_TIME_UNIT_MICROSECONDS = 1024

"The header of an element is two octets — clause 9.4.2."
const IEEE80211_ELEMENT_HEADER_BYTES = 2

"""
    measure_beacon_interval(units)::Int

How many microseconds a beacon interval of `units` time units is. A time unit is
1024 microseconds — IEEE 802.11-2016 clause 3.1 — so the usual interval of 100
units is 102400 microseconds and not 100000.
"""
measure_beacon_interval(units) = Int(units) * IEEE80211_TIME_UNIT_MICROSECONDS

"""
    build_beacon_interval(microseconds)::Int

The time units that carry `microseconds`.
"""
build_beacon_interval(microseconds) =
    Int(microseconds) ÷ IEEE80211_TIME_UNIT_MICROSECONDS

# ---------- the information elements -----------------------------------------

"The information elements — IEEE 802.11-2016 clause 9.4.2."
abstract type Ieee80211InformationElement <: Fields end

"""
    Ieee80211ElementSsid(; ssid)

An SSID element — IEEE 802.11-2016 clause 9.4.2.2. Nought to thirty-two octets
of network name, and a length of nought means the wildcard SSID.

Its identifier is zero, which is the octet INET's serializer writes with the
comment "dummy, what is it?".
"""
@header Ieee80211ElementSsid <: Ieee80211InformationElement begin
    id     :: Constant{U8, IEEE80211_ELEMENT_SSID}
    length :: U8 = 0
        derive(Base.length(ssid))
    ssid   :: Octets = UInt8[]
        length(Bytes(length))
end

"""
    Ieee80211ElementSupportedRates(; rates)

A Supported Rates element — IEEE 802.11-2016 clause 9.4.2.3. One octet per rate,
and up to eight of them.

Each octet is a rate in units of 500 kbit/s with the top bit set when the rate
belongs to the basic rate set, so 0x82 is a basic 1 Mbit/s rate.
"""
@header Ieee80211ElementSupportedRates <: Ieee80211InformationElement begin
    id     :: Constant{U8, IEEE80211_ELEMENT_SUPPORTED_RATES}
    length :: U8 = 0
        derive(Base.length(rates))
    rates  :: Octets = UInt8[]
        length(Bytes(length))
end

"""
    build_supported_rate(megabits_per_second; basic = false)::UInt8

The octet that carries a rate — IEEE 802.11-2016 clause 9.4.2.3. The unit is
500 kbit/s, and the top bit says the rate is in the basic rate set.
"""
build_supported_rate(megabits_per_second; basic::Bool = false) =
    UInt8(round(Int, megabits_per_second * 2)) | (basic ? 0x80 : 0x00)

"The rate an octet carries, in megabits per second."
measure_supported_rate(octet) = (Int(octet) & 0x7f) / 2

"Whether the rate belongs to the basic rate set."
is_basic_rate(octet) = (Int(octet) & 0x80) != 0

"""
    Ieee80211ElementExtendedRates(; rates)

An Extended Supported Rates element — IEEE 802.11-2016 clause 9.4.2.13. It
carries the rates that do not fit in the eight the Supported Rates element
holds, in the same one-octet form.
"""
@header Ieee80211ElementExtendedRates <: Ieee80211InformationElement begin
    id     :: Constant{U8, IEEE80211_ELEMENT_EXTENDED_RATES}
    length :: U8 = 0
        derive(Base.length(rates))
    rates  :: Octets = UInt8[]
        length(Bytes(length))
end

"""
    Ieee80211ElementDsParameterSet(; channel)

A DSSS Parameter Set element — IEEE 802.11-2016 clause 9.4.2.4. One octet: the
channel the BSS is on. Every beacon from real equipment carries it, and INET
writes none.
"""
@header Ieee80211ElementDsParameterSet <: Ieee80211InformationElement begin
    id      :: Constant{U8, IEEE80211_ELEMENT_DSSS_PARAMETER_SET}
    length  :: Constant{U8, 1}
    channel :: U8 = 1
end

"""
    Ieee80211ElementIbssParameterSet(; atim_window)

An IBSS Parameter Set element — IEEE 802.11-2016 clause 9.4.2.7. Two octets: the
announcement traffic indication window, in time units.
"""
@header Ieee80211ElementIbssParameterSet <: Ieee80211InformationElement begin
    id          :: Constant{U8, IEEE80211_ELEMENT_IBSS_PARAMETER_SET}
    length      :: Constant{U8, 2}
    atim_window :: U16 = 0
end

"""
    Ieee80211ElementRaw(; id, value)

An element this library does not model. It keeps its identifier and its octets,
and it reads exactly as many as its length says — so the element after it still
starts where it should.
"""
@header Ieee80211ElementRaw <: Ieee80211InformationElement begin
    id     :: U8 = 0
    length :: U8 = 0
        derive(Base.length(value))
    value  :: Octets = UInt8[]
        length(Bytes(length))
end

list_options(::Type{Ieee80211InformationElement}) =
    (Ieee80211ElementSsid, Ieee80211ElementSupportedRates,
     Ieee80211ElementDsParameterSet, Ieee80211ElementIbssParameterSet,
     Ieee80211ElementExtendedRates)
find_raw_option(::Type{Ieee80211InformationElement}) = Ieee80211ElementRaw

# ---------- the bodies -------------------------------------------------------
#
# `capability_information` is sixteen bits — clause 9.4.1.4 — that say what the
# sender can do: whether it is an access point or an independent station,
# whether it needs privacy, whether it takes a short preamble, and more. It is
# one field here because the standard's bit order is not checked, and a field
# whose octets are right is better than named bits that might not be.

"""
    Ieee80211AssociationRequest(; capability_information, listen_interval, elements)

An association request body — IEEE 802.11-2016 clause 9.3.3.5.

`listen_interval` counts beacon intervals: it is how long the station may sleep,
and the access point keeps its traffic for at least that long.
"""
@header Ieee80211AssociationRequest begin
    capability_information :: U16 = 0
    listen_interval        :: U16 = 0
    elements               :: Options{Ieee80211InformationElement} =
        Ieee80211InformationElement[]
end

"""
    Ieee80211AssociationResponse(; capability_information, status_code, association_id, elements)

An association response body — IEEE 802.11-2016 clause 9.3.3.6.

`association_id` is fourteen bits of identifier with the top two bits set to
one, so an access point that grants identifier 1 sends 0xc001.
"""
@header Ieee80211AssociationResponse begin
    capability_information :: U16 = 0
    status_code            :: U16 = IEEE80211_STATUS_SUCCESS
    association_id         :: U16 = 0
    elements               :: Options{Ieee80211InformationElement} =
        Ieee80211InformationElement[]
end

"""
    Ieee80211ReassociationRequest(; capability_information, listen_interval, current_access_point, elements)

A reassociation request body — IEEE 802.11-2016 clause 9.3.3.7. It is the
association request with the address of the access point the station is leaving,
so the new one can fetch what the old one still holds.
"""
@header Ieee80211ReassociationRequest begin
    capability_information :: U16 = 0
    listen_interval        :: U16 = 0
    current_access_point   :: MacAddress = MAC_BROADCAST
    elements               :: Options{Ieee80211InformationElement} =
        Ieee80211InformationElement[]
end

"""
    Ieee80211ReassociationResponse(; capability_information, status_code, association_id, elements)

A reassociation response body — IEEE 802.11-2016 clause 9.3.3.8. It has the same
octets as an association response.
"""
@header Ieee80211ReassociationResponse begin
    capability_information :: U16 = 0
    status_code            :: U16 = IEEE80211_STATUS_SUCCESS
    association_id         :: U16 = 0
    elements               :: Options{Ieee80211InformationElement} =
        Ieee80211InformationElement[]
end

"""
    Ieee80211ProbeRequest(; elements)

A probe request body — IEEE 802.11-2016 clause 9.3.3.9. It has no fixed fields
at all: a station asks what is there by sending an SSID element and the rates it
supports.
"""
@header Ieee80211ProbeRequest begin
    elements :: Options{Ieee80211InformationElement} =
        Ieee80211InformationElement[]
end

"""
    Ieee80211ProbeResponse(; timestamp, beacon_interval, capability_information, elements)

A probe response body — IEEE 802.11-2016 clause 9.3.3.10. It answers a probe
request with what a beacon would have said.
"""
@header Ieee80211ProbeResponse begin
    timestamp              :: U64 = 0
    beacon_interval        :: U16 = 100
    capability_information :: U16 = 0
    elements               :: Options{Ieee80211InformationElement} =
        Ieee80211InformationElement[]
end

"""
    Ieee80211Beacon(; timestamp, beacon_interval, capability_information, elements)

A beacon body — IEEE 802.11-2016 clause 9.3.3.3.

`timestamp` is the access point's clock in microseconds, and it is what every
station in the BSS synchronises to. `beacon_interval` counts time units of 1024
microseconds, so the usual 100 is 102400 microseconds and not 100000.
"""
@header Ieee80211Beacon begin
    timestamp              :: U64 = 0
    beacon_interval        :: U16 = 100
    capability_information :: U16 = 0
    elements               :: Options{Ieee80211InformationElement} =
        Ieee80211InformationElement[]
end

"""
    Ieee80211Disassociation(; reason_code)

A disassociation body — IEEE 802.11-2016 clause 9.3.3.4. Two octets, and it
ends the association without ending the authentication.
"""
@header Ieee80211Disassociation begin
    reason_code :: U16 = IEEE80211_REASON_UNSPECIFIED
end

"""
    Ieee80211Deauthentication(; reason_code)

A deauthentication body — IEEE 802.11-2016 clause 9.3.3.13. The same two octets,
and it ends the authentication as well.
"""
@header Ieee80211Deauthentication begin
    reason_code :: U16 = IEEE80211_REASON_UNSPECIFIED
end

"""
    Ieee80211Authentication(; algorithm, sequence_number, status_code, elements)

An authentication body — IEEE 802.11-2016 clause 9.3.3.12.

`algorithm` is Open System or Shared Key, and `sequence_number` counts the steps
of the exchange from one. A Shared Key exchange carries its challenge text as an
element.

INET writes a constant zero here and keeps no algorithm at all, so a Shared Key
frame comes back from its serializer as an Open System one.
"""
@header Ieee80211Authentication begin
    algorithm       :: U16 = IEEE80211_AUTHENTICATION_OPEN_SYSTEM
    sequence_number :: U16 = 1
    status_code     :: U16 = IEEE80211_STATUS_SUCCESS
    elements        :: Options{Ieee80211InformationElement} =
        Ieee80211InformationElement[]
end

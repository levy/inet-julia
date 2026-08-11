# ============================================================================
# The `HeaderView` module — what the editor's reflection asks a field value.
#
# `DocumentReflection` reflects an arbitrary Julia object into a tree the
# inspector draws, and it decides where to stop by asking `is_reflection_leaf`.
# Its default rule is a good one for an engine's internals: a number is a leaf,
# and so is anything with no fields.
#
# A protocol field value is neither. `Ipv4Address` is one `UInt32` in a struct,
# so the default opens it and shows `value = 167772161` — the number the type
# exists to stop anyone from reading. `InetPacket` already says what should
# happen instead: `classify_display` answers `:scalar`, `:openable` or
# `:composite` for every field type, and `format_field` gives the text. This is
# the two-method bridge between them.
#
# It lives in the umbrella because it needs a header AND the editor stack at
# once, which is the reason `packetdiagram/` lives here too. `InetPacket`
# depends on nothing, and a rule about how a value is displayed is not a reason
# to change that.
#
# Design: plan/*/protocol-header-gallery.md.
# ============================================================================

module HeaderViewModule

using InetPacket.PacketModule

import ProjecturedReflection.DocumentReflectionModule: is_reflection_leaf, reflection_value

# The field values a reflection must not open.
#
# The list is exactly the types that carry FIELDS and are still not worth
# opening — a value type whose storage says less than its text does. The others
# need nothing:
#
#   `U`, `I`, `Bool`, `UInt8`   already leaves, being numbers
#   `Constant`, `Pad`           already leaves, being zero-size singletons
#   `Repeated`, `Options`       genuinely composite, and open correctly
#   an embedded header          the same
#
# An `:openable` value — an address, an EtherType — is a leaf here too. The
# parts are real, and a reader who wants the octets has the bit grid beside
# this; a tree that opens every address is a tree nobody can read.
const LEAF_FIELD_VALUES = Union{MacAddress, Ipv4Address, Ipv6Address,
                                EtherTypeOrLength, IpProtocol, Port, Checksum16,
                                Octets, Rest, Model, Optional}

is_reflection_leaf(value::LEAF_FIELD_VALUES) =
    classify_display(typeof(value)) !== :composite

# And a leaf shows what the domain shows: `10.0.0.1`, `UDP (17)`, `0x1234`. The
# reflection's own default would print the struct.
reflection_value(value::LEAF_FIELD_VALUES) = format_field(value)

end # module HeaderViewModule

# ============================================================================
# MPLS — RFC 3032, section 2.1.
#
# One 32-bit label stack entry: a 20-bit label, three traffic-class bits, the
# bottom-of-stack bit and a time to live. A packet carries a stack of them, and
# the bottom-of-stack bit is what says which one is last.
# ============================================================================

const MPLS_LABEL_IPV4_EXPLICIT_NULL = 0
const MPLS_LABEL_ROUTER_ALERT       = 1
const MPLS_LABEL_IPV6_EXPLICIT_NULL = 2
const MPLS_LABEL_IMPLICIT_NULL      = 3

"""
    MplsHeader(; label, tc, bottom_of_stack, time_to_live)

One MPLS label stack entry, 4 bytes.
"""
@header MplsHeader begin
    label           :: U20
    tc              :: U3   = 0
    bottom_of_stack :: Bool = true
    time_to_live    :: U8   = 255
end

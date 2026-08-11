# ────────────────────────────────────────────────────────────────────────────
# A packet, on a page, as the thing itself.
#
# `describe(pk)` renders a packet's dissection as a string, and a page can paste
# that string into a code block — which is what these pages did, and it is a
# quotation: nothing re-checks it, so it lies quietly the day the format
# changes.
#
# `packet("name")` splices in the packet the code above it builds. It is the
# same marker shape as `fsm(…)`: a name resolved from a small table, so the
# marker language still names data rather than calling arbitrary Julia.
# ────────────────────────────────────────────────────────────────────────────

using Inet.PacketModule: dissect, Q_COMPLETE, Fields, Packet
using OmnetppPresentation: evaluate_document_expression

"""
    PACKET_VIEWS :: Dict{String, Function}

Every packet a page may name, and the thunk that builds it. Each is built by
the same functions the page embeds above it, so what is shown is what the shown
code makes.
"""
const PACKET_VIEWS = Dict{String, Function}(
    # The routed IPv4 packet `make_packet` builds: a header over a Filler
    # payload, with the simulator-internal tags beside them.
    "routed_ipv4" => () -> InetPacketExample.make_packet(
        UInt32(0x0a000001), UInt32(0x0a000002), 40, Int64(1000)),
    # The same datagram on the wire: four declared headers and one opaque run,
    # which is what makes it worth drawing as a figure.
    "ethernet_frame" => () -> InetPacketExample.make_frame(),
)

"""
    packet_views() -> Vector{String}

The name of every packet a page may embed.
"""
packet_views() = sort!(collect(keys(PACKET_VIEWS)))

"""
    named_packet(name) -> Packet

The packet a page names, built by the same function the page embeds above it.
"""
function named_packet(name::AbstractString)
    build = get(PACKET_VIEWS, String(name), nothing)
    build === nothing &&
        error("packet(", repr(String(name)), "): no such packet; available: ",
              join(packet_views(), ", "))
    return build()
end

# `<<packet("routed_ipv4")>>` puts the packet on the page as the figure the RFCs
# draw. What it splices is the packet's DIAGRAM DOCUMENT, which holds the live
# packet in its `packet` field — an embed arrives inside a `WidgetCard`, and a
# card renders its content only when the content is a `Document`
# (`w.content isa Document` in `WidgetToGraphics.jl`). A `Packet` is not one and
# never can be: `InetPacket` may not import the kernel that defines documents.
#
# The figure is still drawn from the packet, by the same projection that draws
# one the renderer meets anywhere else — `packet_diagram_entries` registers both
# ends, so a packet in a document field needs no marker at all.
#
# The argument is a name from the table above, or the Julia that builds the
# thing: `<<packet("UdpHeader(source_port = 5000)")>>` states the datagram the
# page means, where the page is. `evaluate_document_expression` runs it — a
# constructor call over literals and nothing else, so a page still cannot call
# a function or reach a binding.
function marker_packet(_ctx, source::AbstractString)
    haskey(PACKET_VIEWS, String(source)) && return packet_diagram(named_packet(source))
    return marker_packet(_ctx, evaluate_document_expression(source))
end

# A header of its own becomes a packet with one chunk, which is what the figure
# draws. A packet says so already.
marker_packet(_ctx, header::Fields) = packet_diagram(Packet(header))
marker_packet(_ctx, packet::Packet) = packet_diagram(packet)

# `<<packet_tree("routed_ipv4")>>` shows the same packet as its chunk tree, with
# a fold marker on every chunk. Two views of one packet, and a page names the
# one its prose is about.
marker_packet_tree(_ctx, name::AbstractString) = packet_syntax(named_packet(name))

"""
    packet_syntax(packet) -> SyntaxNode

A packet's dissection as a **syntax document**, which is what makes it a thing
on the page rather than a picture of one: syntax nodes fold, so every chunk in
the tree has a marker a reader can click, and the fold state lives on the
document.

Not generic reflection. `ObjectToSyntax` would render the struct, and on a real
packet it walks out of the domain and into Julia's own internals — a `Memory`
of types with undefined slots — and dies there. `dissect` is the view the
domain means: chunks, their lengths, their quality, and the fields a header
decodes to.
"""
packet_syntax(packet) = begin
    entries = dissect(packet)
    length(entries) == 1 ? _dissection_syntax(entries[1]) :
        SyntaxNode(CellVector(Any[_dissection_syntax(e) for e in entries]); indentation = 2)
end

# One chunk. A chunk with nothing under it is a leaf and gets no fold marker; a
# chunk with fields or children is a node, and its header line is the `open`
# span — so a folded chunk still shows what it is and how long it is, which is
# the whole reason to fold it.
function _dissection_syntax(dissection)
    header = string(dissection.label, "  [", dissection.length,
                    dissection.quality == Q_COMPLETE ? "" : ", $(dissection.quality)", "]")
    children = Any[]
    for (name, value) in dissection.fields
        push!(children, SyntaxLeaf(TextString(string(name, " = ", value), _PACKET_FIELD)))
    end
    for child in dissection.children
        push!(children, _dissection_syntax(child))
    end
    isempty(children) && return SyntaxLeaf(TextString(header, _PACKET_LABEL))
    SyntaxNode(CellVector(children); open = TextString(header, _PACKET_LABEL),
               indentation = 2)
end

const _PACKET_LABEL = StyleText(font_ubuntu_monospace_bold_20, color_solarized_green)
const _PACKET_FIELD = StyleText(font_ubuntu_monospace_regular_20, color_solarized_blue)

"""
    packet_entry(; measure = truetype_measure_text) -> Pair{Type,Any}

The dispatch entry that renders a spliced-in packet. A syntax document passes
through the to-syntax stage unchanged and then takes the ordinary
syntax → text → graphics route, which is where folding is implemented — so the
markers work for free rather than being re-invented here.
"""
packet_entry(; measure = truetype_measure_text) =
    SyntaxDocument => ChainingProjection(
        RecursiveProjection(SyntaxToText(expanded_marker  = _PACKET_EXPANDED,
                                         collapsed_marker = _PACKET_COLLAPSED)),
        TextToGraphics(measure = measure))

# The fold markers. `SyntaxToText` draws none by default, and a marker that is
# not drawn cannot be clicked — the reader recognises a press on the marker's own
# glyph, so the glyph is the affordance and not decoration.
#
# DejaVu mono, not the Ubuntu mono the rest of the block uses: Ubuntu has no
# chevron, and SDL does not fall back to another face, so the marker would render
# as a tofu box. Gray, like the collapsed-body ellipsis, because a fold marker is
# projection chrome rather than content.
const _PACKET_EXPANDED  = TextString("▾ ", font_dejavu_monospace_regular_20,
                                     color_solarized_gray)
const _PACKET_COLLAPSED = TextString("▸ ", font_dejavu_monospace_regular_20,
                                     color_solarized_gray)

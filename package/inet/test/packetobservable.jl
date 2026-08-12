# ============================================================================
# What a packet can do now that it is a document.
#
# The rest of the suite checks that nothing broke. This file checks what the
# change was for: a live packet is a thing an inspector can open, a reference
# can point into, and a projection watches. Without these three the change is a
# refactor.
#
# Every check uses `live_packet`, the envelope as a reactive document over the
# chunks it already holds. That is what an editor watches; a simulation holds
# the native envelope, which announces nothing on purpose.
# ============================================================================
using Test
using Inet
using Inet.PacketModule
using Inet.PacketDiagramModule
using Projectured.ProjectionApiModule: print_document, map_reference_backward
using Projectured.PrinterContextModule: PrinterContext
using Projectured.IoMapModule: get_iomap_output
using Projectured.ReferenceModule: EmptyReference, ConcreteReference,
    FieldReferenceStep, ElementReferenceStep, evaluate_reference
using Projectured.DocumentReflectionModule: reflect_document
using Projectured.BoundedSyncModule: DepthPolicy
using Projectured.OperationModule: ReplaceReferencedValueOperation, evaluate_operation

# An IPv4 datagram in an Ethernet payload: two declared headers and a filler.
function observable_test_packet()
    pk = Packet(Filler(Bytes(32)))
    pushfirst!(pk, UdpHeader(source_port = 1000, destination_port = 2000,
                             length = UInt16(40)))
    pushfirst!(pk, Ipv4Header(total_length = UInt16(60), protocol = IP_PROTOCOL_UDP,
                              source = Ipv4Address("10.0.0.1"),
                              destination = Ipv4Address("10.0.0.2")))
    return pk
end

# A reference from a plain step list, which is what a backward map returns.
_reference(steps) =
    foldr((step, tail) -> ConcreteReference(step, tail), steps; init = EmptyReference())

# Every label in a reflected subtree, so a walk can be asserted as a set.
function _labels(node, out = String[])
    push!(out, node.label)
    node.children === nothing && return out
    for child in node.children
        _labels(child, out)
    end
    return out
end

@testset "an inspector opens a live packet and walks it" begin
    live = live_packet(observable_test_packet())
    node = reflect_document(live, DepthPolicy(5); label = "Packet")

    # The envelope's own fields, which is what a packet is.
    @test [c.label for c in node.children] ==
          ["content", "front", "back", "packet_tags", "region_tags"]

    # And the walk goes all the way down: through the content, into the
    # sequence, into a chunk, to the fields a header declares. Nothing along
    # the way is a picture of the packet — this is the packet.
    labels = _labels(node)
    @test "chunks" in labels
    @test "time_to_live" in labels        # an IPv4 field
    @test "destination" in labels
    @test "source_port" in labels         # a UDP field
    @test "fill" in labels                # the filler's own

    # A reflection is not a dissection. It shows the storage — `front`, `back`,
    # `offsets` — where `dissect` shows the wire. Both are wanted, and this is
    # why `dissect` did not retire.
    @test "offsets" in labels
    @test [d.label for d in dissect(observable_test_packet())][1] == "Packet(data=60B)"
end

@testset "a reference names a header field and evaluates to its value" begin
    live = live_packet(observable_test_packet())
    projection = PacketToPacketDiagram()
    iomap = print_document(projection, nothing, live, PrinterContext())
    diagram = get_iomap_output(iomap)

    # The reference is not written by hand: it is what a reader's click on the
    # figure produces, mapped back through the stage. So this asserts the loop
    # closes — the value the figure shows is the value the path reaches.
    band = collect(diagram.bands)[1]
    fields = collect(band.fields)
    for name in ("source", "destination", "time_to_live", "protocol")
        index = findfirst(f -> f.name == name, fields)
        @test index !== nothing
        path = map_reference_backward(projection, iomap,
                                      _reference(Any[FieldReferenceStep("bands"),
                                                     ElementReferenceStep(1),
                                                     FieldReferenceStep("fields"),
                                                     ElementReferenceStep(index)]))
        @test path !== nothing
        @test string(evaluate_reference(live, path)) == fields[index].text
    end

    # The second band is the UDP header, and its fields are its own.
    udp = collect(diagram.bands)[2]
    index = findfirst(f -> f.name == "destination_port", collect(udp.fields))
    path = map_reference_backward(projection, iomap,
                                  _reference(Any[FieldReferenceStep("bands"),
                                                 ElementReferenceStep(2),
                                                 FieldReferenceStep("fields"),
                                                 ElementReferenceStep(index)]))
    @test evaluate_reference(live, path) == Port(2000)
end

@testset "writing through a reference changes the packet, and the figure follows" begin
    live = live_packet(observable_test_packet())
    projection = PacketToPacketDiagram()
    diagram = get_iomap_output(print_document(projection, nothing, live,
                                              PrinterContext()))
    @test Base.length(diagram.bands) == 3
    @test occursin("60B", diagram.label)
    before = packet_diagram_string(live)

    # `content` is an envelope field, so a reference names it and the kernel's
    # own operation writes it. Nothing here knows about packets.
    operation = ReplaceReferencedValueOperation(
        live, _reference(Any[FieldReferenceStep("content")]), Filler(Bytes(4)))
    evaluate_operation(nothing, operation)

    @test data_length(live) == Bytes(4)
    # The figure followed with nothing told to refresh: the label and the bands
    # read the packet inside a cell, and the write announced itself.
    @test Base.length(diagram.bands) == 1
    @test occursin("4B", diagram.label)
    @test packet_diagram_string(live) != before
end

@testset "an edit to a header field is a rebuild, and the figure shows it" begin
    # A chunk is immutable, and the codec depends on it: a header's fields are
    # the values they are. So an edit to a field rebuilds the header — which is
    # what `set_field` is — and the write lands on the envelope, the one part of
    # a packet that is not a value.
    live = live_packet(observable_test_packet())
    projection = PacketToPacketDiagram()
    iomap = print_document(projection, nothing, live, PrinterContext())
    diagram = get_iomap_output(iomap)

    chunks = collect(live.content.chunks)
    rebuilt = set_field(chunks[1], :destination, Ipv4Address("10.9.9.9"))
    operation = ReplaceReferencedValueOperation(
        live, _reference(Any[FieldReferenceStep("content")]),
        sequence(Chunk[rebuilt, chunks[2:end]...]))
    evaluate_operation(nothing, operation)

    fields = collect(collect(diagram.bands)[1].fields)
    index = findfirst(f -> f.name == "destination", fields)
    @test fields[index].text == "10.9.9.9"

    # And the wire moved with it, which is the point of editing a header.
    @test peek(live, Ipv4Header).destination == Ipv4Address("10.9.9.9")
end

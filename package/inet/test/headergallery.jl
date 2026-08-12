# One protocol header, as a page: the declaration, the call that builds an
# instance, a field read and written, the instance reflected and the instance
# drawn.
#
# What is asserted here is what the page DRAWS. A page builder that returns a
# tree of the right types and draws none of the header's fields is a page that
# is broken in the one way a reader would notice, and forcing the render is the
# only thing that catches it.
#
# `demo.jl` runs first and defines `_drawn_strings`.

using Test
using Inet
using InetExample
using Inet.PacketModule
using OmnetppPresentation
using Projectured
using Projectured.DocumentReflectionModule: reflect_document
using Projectured.GraphicsModule: GraphicsCanvas
using Projectured.IoMapModule: get_iomap_output
using Projectured.MarkdownModule: MarkdownRoot, MarkdownCodeBlock, MarkdownHeading,
    MarkdownParagraph, MarkdownText
using Projectured.ProjectionApiModule: print_document
using Projectured.TrueTypeModule: truetype_measure_text
using Inet.PacketDiagramModule: PacketDiagram

# One catalog and one projection for the whole file. A shell built per page
# reparses the index and every stub, and a projection built per page rebuilds
# the dispatch table — ten of each turned a ninety-second suite into a
# quarter-hour one. It is also what a reader does: open the catalog once, then
# click.
const _SHELL = Ref{Any}(nothing)
const _PROJECTION = Ref{Any}(nothing)

function _gallery_shell()
    _SHELL[] === nothing && (_SHELL[] = demo_catalog())
    _PROJECTION[] === nothing &&
        (_PROJECTION[] = demo_projection(measure = truetype_measure_text))
    return (_SHELL[], _PROJECTION[])
end

# The page a stub file names, drawn the way `run_demo` draws it.
function _gallery_drawn(path::AbstractString)
    shell, projection = _gallery_shell()
    index = findfirst(e -> e.path == path, collect(shell.entries))
    index === nothing && error("no navigator row for ", path)
    open_page!(shell, index)
    out = get_iomap_output(print_document(projection, shell))
    return (shell, out, _drawn_strings(out))
end

_says(strings, text) = any(s -> occursin(text, s), strings)

@testset "the gallery names ten headers, each for a reason" begin
    @test Base.length(gallery_headers()) == 10
    @test allunique(gallery_headers())
    for H in gallery_headers()
        @test !isempty(header_reason(H))
        # Every one of them is a wire format the library declares, not a probe.
        @test H in list_headers()
    end
    @test find_gallery_header("Ipv4Header") === Ipv4Header
    # A name the gallery does not offer fails with the list, because a marker
    # that resolves to nothing is a page with a hole in it.
    @test_throws ErrorException find_gallery_header("NoSuchHeader")
end

@testset "a header page carries the five views" begin
    page = header_page(Ipv4Header)
    @test page isa MarkdownRoot
    kinds = [document_schema_name(typeof(e)) for e in page.elements]
    # The declaration arrives as the parsed Julia it is — with its docstring,
    # because `definition` yields a documented definition whole.
    @test :JuliaDocstring in kinds || :JuliaMacroCall in kinds
    @test :MarkdownCodeBlock in kinds        # the call, and the bytes
    @test :ReflectedNode in kinds            # the instance, reflected
    @test :Packet in kinds                   # the instance, as the RFC draws it
    # Four headings: declared, built, read and written, reflected, drawn.
    @test Base.length([k for k in kinds if k === :MarkdownHeading]) >= 4
end

@testset "every header in the gallery builds a page" begin
    for H in gallery_headers()
        page = header_page(H)
        @test page isa MarkdownRoot
        @test !isempty(page.elements)
    end
end

@testset "every header in the gallery has a row and a page of its own" begin
    shell, _ = _gallery_shell()
    paths = [e.path for e in collect(shell.entries) if !e.section]
    for H in gallery_headers()
        path = string("pages/header/", document_schema_name(H), ".md")
        @test path in paths
        @test isfile(joinpath(demo_directory(), path))
        # And the stub names the header the row is for, so a page cannot end up
        # showing a different format from the one its title states.
        @test occursin(string("header_view(\"", document_schema_name(H), "\")"),
                       read(joinpath(demo_directory(), path), String))
    end
end

@testset "every header page is about the header it is for" begin
    # Asserted on the DOCUMENT, not on the pixels. `demo.jl`'s walk already
    # opens all ten pages and forces the canvas, and a header page is expensive
    # to draw — a parsed declaration, a reflected instance and a bit grid, some
    # seconds each — so drawing all ten a second time buys nothing. What the
    # walk cannot say is whether a page is about the header its row names, and
    # that is what is checked here.
    #
    # One page IS drawn and read, below. That is where the five views are proved
    # to reach the screen.
    for H in gallery_headers()
        page = header_page(H)
        blocks = collect(page.elements)
        # The call that builds an instance names the type.
        code = [b.code for b in blocks if b isa MarkdownCodeBlock]
        @test any(c -> occursin(string(document_schema_name(H), "("), c), code)
        # The figure is drawn from a packet that holds this header, and not
        # from one built for another page. The page carries the packet itself,
        # so there is nothing between the block and the header it is about.
        @test has(only(b for b in blocks if b isa Packet), H)
        # A page asked for twice is one document, so a fold a reader opened is
        # still open when they come back — and a catalog rebuilt is not ten
        # pages rebuilt.
        @test header_page(H) === page
    end
end

@testset "the IPv4 page draws all five views" begin
    _, out, strings = _gallery_drawn("pages/header/Ipv4Header.md")
    @test out isa GraphicsCanvas
    @test !isempty(strings)

    # 1. the declaration, quoted from the file that declares it
    @test _says(strings, "@header")
    @test _says(strings, "time_to_live")
    @test _says(strings, "IPV4_DEFAULT_TTL")
    # 2. the call that builds an instance, naming what a caller decides
    @test _says(strings, "Ipv4Header(")
    @test _says(strings, "Ipv4Address(")
    # 3. one field read and written
    @test _says(strings, "get_field")
    @test _says(strings, "set_field")
    # 4. the instance by reflection — an address as its text, not its storage
    @test _says(strings, "10.0.0.14")
    # 5. the bit grid the standard draws
    @test _says(strings, "fragment_offset")
    @test any(s -> occursin("+-+-+-+", s), strings)

end

@testset "the prose on a page is prose" begin
    # A paragraph built by hand takes a plain vector of inline nodes. Hand the
    # field a collection instead and it wraps that in a second one, and the
    # inner collection draws as the list it now is — brackets around every
    # sentence the page says.
    #
    # Asserted on the document: the page DOES draw bare brackets, from the
    # `Ipv4Option[]` in the declaration it quotes, so the pixels cannot tell the
    # two apart.
    page = header_page(Ipv4Header)
    paragraphs = [b for b in page.elements if b isa MarkdownParagraph]
    @test !isempty(paragraphs)
    for paragraph in paragraphs
        @test all(node -> node isa MarkdownText, collect(paragraph.content))
    end
    headings = [b for b in page.elements if b isa MarkdownHeading]
    for heading in headings
        @test all(node -> node isa MarkdownText, collect(heading.content))
    end
end

@testset "a field value reflects as what it is" begin
    # `Ipv4Address` is one `UInt32` in a struct, and the reflection's own rule
    # would open it and show the number the type exists to hide.
    node = reflect_document(example_header(Ipv4Header); label = "Ipv4Header")
    fields = Dict(child.label => child for child in node.children)
    @test fields["source"].value == "10.0.0.14"
    @test fields["source"].children === nothing        # a leaf, not a level
    @test fields["header_checksum"].value == "0x100d"
    @test fields["protocol"].value == format_field(get_field(
              example_header(Ipv4Header), :protocol))
    # An option list is genuinely composite and still opens.
    @test fields["options"].value === nothing
end

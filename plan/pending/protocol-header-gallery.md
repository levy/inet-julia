# The protocol header gallery

`run_demo()` opens the demo catalog: the navigator on the left, the open page on
the right. This plan adds one navigator row per protocol header, and one page
behind each row. The page shows five things about that header:

1. how the header is **declared** in Julia,
2. how an instance is **built** in Julia,
3. how a field is **read and written**,
4. the instance in a **reflection widget**,
5. the instance as the **RFC bit grid**.

91 wire formats are declared. This plan covers **ten** of them, chosen so that
each one shows something the others do not. A page is derived from the header
type, so the ten cost one page builder and not ten pages. Every header is a
later stage, and it changes one list.

Status: **PENDING**. No stage has started.

## 1. What the plan delivers

1. Three facts a header can answer about itself, in `InetPacket`: where it is
   declared, how to construct it, and what one field update does to the bytes.
2. A page document built from a header type, in `Inet`.
3. A bridge from `classify_display` to the editor's generic reflection, which
   closes §15 of
   [protocol-header-inventory.md](protocol-header-inventory.md).
4. Ten navigator rows, one per header of the subset.
5. Tests that build all ten pages and render them.

## 2. What exists already

Nothing below is written a second time. The plan is mostly wiring.

| what it gives | where it is |
| --- | --- |
| the catalog, and the projection that draws it | [InetExample.jl:130-209](../../package/inet/example/InetExample.jl#L130) |
| the navigator, derived from the index page's headings and links | [CatalogShell.jl:106-183](../../../omnetpp-julia/package/presentation/main/src/project/CatalogShell.jl#L106) |
| the marker vocabulary, extended at load time | [InetExample.jl:260-268](../../package/inet/example/InetExample.jl#L260) |
| a marker that splices a live object into a page | `marker_packet`, [Packets.jl:53-68](../../package/inet/example/Packets.jl#L53) |
| a source fragment on a page, addressed by the name it carries | [JuliaFile.jl:194-217](../../../projectured-julia/package/julia/main/JuliaFile.jl#L194), [Headers.md:7](../../package/inet/example/demo/pages/Headers.md#L7) |
| every declared header, in declaration order | `list_headers`, [RoundTrip.jl:26-44](../../package/packet/main/RoundTrip.jl#L26) |
| an instance of any header, every field distinct | `fill_asymmetric`, [RoundTrip.jl](../../package/packet/main/RoundTrip.jl) |
| the wire layout: name, type, bit offset, bit width | `describe_layout`, [HeaderCodec.jl:87-125](../../package/packet/main/HeaderCodec.jl#L87) |
| read and write one field | `get_field` [HeaderCodec.jl:137](../../package/packet/main/HeaderCodec.jl#L137), `set_field` [Checksum.jl:62](../../package/packet/main/Checksum.jl#L62) |
| the default of a field, or `nothing` when it is required | `find_default`, [Draft.jl:30-36](../../package/packet/main/Draft.jl#L30) |
| how a value wants to be shown, and its text | `classify_display` and `format_field`, [FieldValue.jl:70-89](../../package/packet/main/FieldValue.jl#L70) |
| the RFC bit grid, from a packet | `packet_diagram`, [PacketToPacketDiagram.jl:43](../../package/inet/main/packetdiagram/PacketToPacketDiagram.jl#L43) |
| a band for one bare header inside that grid | [PacketToPacketDiagram.jl:121](../../package/inet/main/packetdiagram/PacketToPacketDiagram.jl#L121) |
| a bounded reflection of an arbitrary Julia object | `reflect_document`, [DocumentReflection.jl:181](../../../projectured-julia/package/base/main/reflection/DocumentReflection.jl#L181) |
| a reflected tree, drawn as a disclosure tree, **already registered** in the demo projection | `AReflectedNode =>` in [WorkbenchRender.jl:188](../../../omnetpp-julia/package/presentation/main/src/workbench/WorkbenchRender.jl#L188) |

Two of those remove most of the work. `demo_projection` already splices in
`workbench_document_dispatch`
([InetExample.jl:167](../../package/inet/example/InetExample.jl#L167)), and that
table already routes `AReflectedNode`; `packet_diagram_entries` is spliced in the
same way. A reflected header and a packet diagram in a document field therefore
render with **no** new projection.

## 3. The design

### 3.1 A page is derived, never authored

`header_page(H)` builds the page document from the type. The prose at the top is
the header's **own docstring** —
[Ipv4.jl:34-45](../../package/packet/main/protocol/Ipv4.jl#L34) already says what
RFC 791 decides and what the IP module fills in — so the page carries no sentence
that the file could contradict.

The instance the page shows is `example_header(H)`, which is `fill_asymmetric(H)`
by default. That function already builds an instance of any declared header with
every field distinct, generically, for the round-trip corpus. Every field
distinct is also what makes a bit grid readable. Two headers a page already
narrates keep a realistic instance instead, through a small override table beside
`PACKET_VIEWS` ([Packets.jl:23](../../package/inet/example/Packets.jl#L23)).

### 3.2 The five views

**View 1 — the declaration.** The `@header … begin … end` source, read out of the
file that declares it, through the fragment marker a page already uses:

```
<<definition(file("<path>"), "Ipv4Header")>>
```

Two things are missing, and §5 closes both: the marker cannot yet name a macro
call whose first argument is a bare identifier, and nothing tells a page which
file declares a header.

**View 2 — the construction.** `describe_construction(h)` gives the keyword call
that rebuilds `h`: every required field, plus every field whose value differs
from its default, in declaration order. A field is required when
`find_default(H, Val(name))` is `nothing`. The fields left out are listed under
the call with the default each takes, so the page says what the keyword form does
not state, and why it does not.

The call is Julia that runs. `format_field` prints `10.0.0.1`, which is display
text and not an expression, so a second method answers the other question:

```julia
literal_field(value)::String     # the Julia expression that rebuilds the value
```

The default is `repr(value)`; `Ipv4Address` answers `Ipv4Address("10.0.0.1")`,
and `IpProtocol` answers the constant's name where one exists. The gate is that
`eval` of the text gives a header equal to `h`.

**View 3 — read and write.** `describe_update(h)` picks one field and reports what
a read gives, what a write changes it to, and which byte of the encoded header
moves. The field is the first that is not `Constant`, not `Model`, not derived
and not checked — a derived field is overwritten on the way out, a checked field
would fail its own check, and neither demonstrates anything. The page shows

```julia
get_field(h, :time_to_live)      # 64
h2 = set_field(h, :time_to_live, 63)
```

and the two byte strings with the changed byte marked. This is the paragraph
[Headers.md:46](../../package/inet/example/demo/pages/Headers.md#L46) writes by
hand for IPv4, computed instead.

**View 4 — the reflection widget.** `reflect_document(h)` gives the node tree, and
the demo projection already draws it. What it does not know is that `Ipv4Address`
is a value and not a container, so §3.3 supplies that.

**View 5 — the RFC bit grid.** `packet_diagram(Packet(h))` — a packet holding one
header. `_append_band!` already has the method for a bare header
([PacketToPacketDiagram.jl:121](../../package/inet/main/packetdiagram/PacketToPacketDiagram.jl#L121)),
so the grid needs no new code, only a packet to hold the header.

### 3.3 The reflection bridge closes an open question

§10 of [protocol-header-inventory.md](protocol-header-inventory.md) says a
reflective view must ask the value type how deep to go, and declares
`classify_display`. §15 leaves open whether the editor has a rule to hook it
into. It has: `is_reflection_leaf(x)` and `reflection_value(x)` are ordinary
generic functions with defaults
([DocumentReflection.jl:96-118](../../../projectured-julia/package/base/main/reflection/DocumentReflection.jl#L96)).

Two methods bridge them:

```julia
is_reflection_leaf(x::AFieldValue) = classify_display(typeof(x)) === :scalar
reflection_value(x::AFieldValue)   = format_field(x)
```

An `:openable` value stays a node, so its parts are there for a reader who opens
it, and its label is the text `format_field` gives — which is what §10 asks for.
`:composite` needs nothing: it is the default on both sides.

The methods live in `Inet`, not in `InetPacket`. `InetPacket` depends on nothing
and must keep depending on nothing; `Inet` already depends on both it and
`ProjecturedVisual`, and that is what the umbrella is for.

### 3.4 The navigator gets ordinary rows

The navigator is derived from the index page: a `##` heading is a section, and a
link is an entry when its url ends with `.md`
([CatalogShell.jl:170](../../../omnetpp-julia/package/presentation/main/src/project/CatalogShell.jl#L170)).
Ten rows are ten links, which the index can state, so **the navigator needs no
change at all** for this plan.

Each row points at a stub page of three lines:

```markdown
# The IPv4 header

```pred-ref
<<header_view("Ipv4Header")>>
```
```

The stub is an anchor for the navigator, not a copy of a template: the title and
the five views come from the type. Ten stubs are honest; ninety-one are not, and
§6.4 says what replaces them if the gallery ever grows that far.

### 3.5 Where each part lives

| part | package | why there |
| --- | --- | --- |
| `find_declaration`, `describe_construction`, `describe_update`, `literal_field`, `example_header` | `InetPacket` (`package/packet/main/`) | facts about a header, computed from the type. No editor, no simulator — the package depends on nothing |
| `header_page`, the reflection bridge | `Inet` (`package/inet/main/headergallery/`) | needs a header **and** the editor stack, which is what the umbrella already is (`packetdiagram/` is the precedent) |
| the `header_view` marker, the stub pages, the index section | `InetExample` (`package/inet/example/`) | the catalog is the example package's, and a marker registration is runtime state |
| the `definition` fix | `projectured-julia`, `package/julia/main/` | the marker vocabulary lives there |

## 4. The subset

Ten headers. Each one earns its row by a wire-format feature that none of the
others shows, and the ten span nine of the nineteen protocol files.

| header | family | what only this one shows |
| --- | --- | --- |
| `EthernetMacHeader` | Ethernet | a plain struct with no macro at all, and two `:openable` field types |
| `Ieee8022LlcHeader` | IEEE 802.2 | an `Optional` field, present or absent by a `when` clause |
| `ArpPacket` | ARP | `Constant` fields, and two address families in one header |
| `Ipv4Header` | IPv4 | sub-byte widths, a `check`, a `derive`, and an option list |
| `UdpHeader` | UDP | the smallest header there is: two defaults and no expressions |
| `TcpHeader` | TCP | a length derived from the header's own width, over its own option family |
| `Ipv6Header` | IPv6 | a 128-bit field, and a 20-bit flow label |
| `Ipv6FragmentHeader` | IPv6 | an extension header: small, fixed, and mostly reserved |
| `IcmpEchoRequest` | ICMP | a variant, declared over an embedded base header |
| `Igmpv3Report` | IGMP | a repeated list that fills its window and a count that derives from it |

The list lives in one table, `GALLERY_HEADERS`, in `InetExample`, in the shape
`PACKET_VIEWS` already has ([Packets.jl:23](../../package/inet/example/Packets.jl#L23)).
A reason string sits beside each entry and the page prints it, so the answer to
"why this one" is on the page rather than in this plan alone.

To add a header, add a row and a stub page. Nothing else changes.

## 5. The gaps to close

**G1 — a marker cannot name a `@header`.** `julia_definition_name(::JuliaMacroCall)`
asks `julia_definition_name` of the first argument
([JuliaFile.jl:179](../../../projectured-julia/package/julia/main/JuliaFile.jl#L179)),
and that answers `nothing` for a bare identifier. So `@document struct Foo … end`
is found and `@header Ipv4Header begin … end` is not. Ask `_julia_header_name`
instead, which already handles an identifier, a `<:` and a `Foo{T}`. One line,
and it also makes `@header Member <: Family` addressable — which
`IcmpEchoRequest` needs.

This is the plan's only change outside this repository. It must land on `main` in
`projectured-julia` before Stage 1 ends: this repository's `[sources]` reach the
main checkout, so a change that sits in a worktree is invisible here.

**G2 — nothing says where a header is declared.** `@header` already calls
`register_header` ([Header.jl:313](../../package/packet/main/Header.jl#L313)).
Pass `__source__` with it, keep it beside the type, and answer
`find_declaration(H)`. `EthernetMacHeader` registers itself by hand
([Ethernet.jl:63](../../package/packet/main/protocol/Ethernet.jl#L63)) and takes
the same argument.

A recorded path is the path of the machine that precompiled the package, so
`declaration_path(H)` rebases the file name onto the loaded package directory
(`dirname(pathof(InetPacket))`). A relocated checkout and a precompiled image
then both find the file.

## 6. The stages

Three stages. Each one ends green, is committed, and is worth opening on its own.
Stage 3 is optional and is not started until the ten pages have been read.

| stage | delivers | gate |
| --- | --- | --- |
| 1 | the facts, and one page for `Ipv4Header` | the page opens in `run_demo()` and draws all five views |
| 2 | the other nine, and their rows | ten rows, ten pages, all rendered by the test |
| 3 | *optional* — every declared header | 91 rows, without 91 stub files |

### Stage 1 — one header, end to end

The whole mechanism, proved on one header. Six steps, one commit each.

1. **G1, upstream.** Fix `julia_definition_name` in `projectured-julia` and test
   that `definition(file(…), "Ipv4Header")` finds the declaration. Land it on
   `main`.
2. **G2 and the facts.** New file `package/packet/main/HeaderFacts.jl`, beside
   `HeaderCodec.jl`: `find_declaration`, `declaration_path`,
   `describe_construction`, `describe_update`, `example_header`. `literal_field`
   joins `format_field` in `FieldValue.jl`, and its per-type methods sit beside
   the `format_field` methods in `FieldTypes.jl`.

   Return data, not text. `HeaderConstruction` and `HeaderUpdate` are small
   structs in the shape `FieldSpec` and `HeaderLayout` already set
   ([HeaderCodec.jl:49-76](../../package/packet/main/HeaderCodec.jl#L49)), so the
   page decides how to print them and a test asserts them without an editor.

   Gate: new `package/packet/test/phase21_header_facts.jl`, over the ten of §4
   and then over `list_headers()` — the facts are generic, so run them on all 91
   even though only ten get a page. `eval` of the construction text gives a header
   equal to the instance, and exactly the reported bytes change.

   ```
   julia --project=package/packet/test -e 'using InetPacketTest; test_packet()'
   ```
3. **The block spike.** One thing is not known: whether the natural renderer takes
   a live document as a **block** of a page directly, or whether the block must be
   an embed card. Put `packet_diagram(…)` in a `MarkdownRoot` and render it. If it
   draws, the page is a plain AST and nothing else is needed. If it does not, wrap
   each live view in the embed card the presentation package already uses, the way
   `<<realize(…)>>` does. Record the answer in §9 of this plan.
4. **The page.** New slice `package/inet/main/headergallery/`, one module,
   exported from `Inet`: `header_page(H)`, and the five view builders.
5. **The reflection bridge.** The two methods of §3.3. Then update §15 of
   [protocol-header-inventory.md](protocol-header-inventory.md): the question is
   answered, and the hook is `is_reflection_leaf`.
6. **The row.** Register the `header_view` marker in `InetExample.__init__`,
   beside the markers already there
   ([InetExample.jl:260](../../package/inet/example/InetExample.jl#L260)). Add
   `demo/pages/header/Ipv4Header.md` and one link in
   [index.md](../../package/inet/example/demo/index.md).

   Gate: `run_demo()` shows the row; the page draws the declaration, the keyword
   call, the byte diff, the reflection tree and the bit grid. The headless check
   uses `_drawn_strings` from [demo.jl](../../package/inet/test/demo.jl) — it
   forces the tree, which asserting the canvas type does not.

### Stage 2 — the other nine

1. **The table.** `GALLERY_HEADERS` in `InetExample`, with the reason string §4
   asks for. `Ipv4Header` moves into it.
2. **The nine stubs and the index section.** One three-line page each, under a new
   `## Every header declares its own bytes` section in `index.md`, in the order of
   §4 — link layer first, then the internet core, then the message families.
3. **What the nine break.** Expect three kinds of failure, and fix each where it
   belongs rather than on the page:
   * a variant member (`IcmpEchoRequest`) whose declaration is
     `@header Member <: Family` — G1 covers it, so this is the check that it does;
   * a variable-length header (`Ipv4Header`, `TcpHeader`, `Igmpv3Report`) whose
     `describe_layout` needs the instance and not the type
     ([HeaderCodec.jl:118](../../package/packet/main/HeaderCodec.jl#L118));
   * an `Optional` field (`Ieee8022LlcHeader`) that is absent in the instance, and
     must read as absent rather than as a hole.
4. **The tests.** New `package/inet/test/headergallery.jl`: all ten pages build and
   their facts hold, and all ten render through `demo_projection`. State the
   render cost in the file. `demo.jl`'s existing walk picks the ten new rows up on
   its own, because they are ordinary `.md` pages.

   ```
   julia --project=package/inet/test -e 'using InetTest; test_inet()'
   ```
5. **The documentation.** `package/packet/doc/packet.md` gains the three facts and
   `literal_field`. `package/inet/doc/` gains a short guide: what a page is made
   of, how to add a header, and how to add a sixth view.
   [Headers.md](../../package/inet/example/demo/pages/Headers.md) keeps its prose
   and points at the gallery. Add one gallery page to `Precompile.jl` —
   `InetExample` is a leaf, so a workload belongs there.

No new requirement. The gallery is evidence for `IR-DECLARED-HEADERS` and
`IR-ANY-REPRESENTATION`, which
[documentation/requirements.md](../../documentation/requirements.md) already
states.

### Stage 3 — every header (optional)

Do not start this before the ten pages have been read by a person. If ten pages
do not teach the reader what the declaration language does, ninety-one will not
either, and the answer is a better page and not more of them.

At 91 the stub file stops being honest, so the navigator learns to expand one
link into many rows. Generalise the `sim:` special case
([CatalogShell.jl:35-46](../../../omnetpp-julia/package/presentation/main/src/project/CatalogShell.jl#L35),
[CatalogShell.jl:335](../../../omnetpp-julia/package/presentation/main/src/project/CatalogShell.jl#L335))
into a registry in the presentation package:

```julia
register_entry_scheme!(:header, expand, open)
```

* `expand(name) -> Vector{CatalogEntry}` turns one authored link into the rows it
  stands for — 19 section rows, one per protocol file, with their headers under
  each.
* `open(shell, entry, name) -> page` builds the page, and keeps it, the way
  `_SIMULATION_WINDOWS` keeps a window.

The index then carries one link, `[All protocol headers](header:*)`, and
`InetExample.__init__` registers the scheme. The presentation package learns a
mechanism and not a protocol, which is the shape `register_doctype_module!` and
`register_marker_function!` already have. Port `sim:` onto the same path, so one
mechanism replaces two.

Two test assertions then need care, because a page built in memory has no file:
`filename(shell.page) == entry.path` and "every page carries at least one marker"
([demo.jl:112-114](../../package/inet/test/demo.jl#L112)). Exempt a scheme row
from both, and assert instead that its page draws the header's name.

Watch the cost: 91 renders in the acceptance test is far more than the walk costs
today. Render one header per protocol family and build the facts for all 91. If
that is still too slow, cut further and **say so in the test file** — a silent cut
reads as full coverage.

## 7. Decisions

| question | the position |
| --- | --- |
| how many headers | ten, chosen by the feature each one alone shows. The full inventory is a later stage that changes one list |
| authored pages or derived pages | derived. The stub file holds a title and a marker; the five views come from the type |
| how a row reaches a page, at ten | an ordinary `.md` link. The navigator needs no change, and the plan touches one file outside this repository instead of three |
| how a row reaches a page, at ninety-one | a scheme registry, in Stage 3, and only after a person has read the ten |
| which reflection projection | `DocumentReflection`, and the entry already in `workbench_document_dispatch` |
| where the prose comes from | the header's own docstring |
| which instance the page shows | `fill_asymmetric`, with an override for the headers a page already narrates |
| where the facts live | `InetPacket`. They are computed from the type, and the package that owns the type owns them |
| where the bridge lives | `Inet`. `InetPacket` depends on nothing, and that rule is what its separate package is for |

## 8. Rejected

* **`ObjectToWidget`** ([ObjectToWidget.jl](../../../projectured-julia/package/visual/main/widget/ObjectToWidget.jl)).
  It renders a field as a control when a `Cell` backs it, and skips "a plain
  struct without `Cell` fields". A header is an immutable `isbits` struct with no
  cells, so `MacAddress`, `Ipv4Address` and `EtherTypeOrLength` would vanish from
  the view — the fields a reader most wants. `DocumentReflection` reflects an
  arbitrary object, which is what this needs.
* **One page with its own inner list.** The catalog's left side would carry one
  row, and the page would grow a second navigator beside the one the window
  already has. The ask puts the protocol on the left side.
* **The scheme registry in Stage 1.** It is the right answer at 91 and too much
  machinery at 10. Stage 3 holds it, with the trigger written down.
* **A `header:` branch in `open_page!`.** It puts INET protocol vocabulary in the
  presentation package. A registry costs the same and keeps the layering.

## 9. Open

* Whether a live document may be a markdown block directly, or needs the embed
  card. Stage 1 step 3 answers it, and the answer is recorded here.
* Whether a variant family gets a row of its own beside its members.
  `IcmpEchoRequest` is a member and gets one; the family is abstract and has only
  the base's layout, so the first cut lists members only.
* Editing. The reflection tree is read-only here: writing a field would need
  `set_field` and somewhere to write the new header back to, and the gallery's
  instance sits in no packet. Out of scope, and the type already answers what an
  editor would need (§10 of the inventory plan).

## 10. Out of scope

* Wave 3 and Wave 4 of
  [protocol-header-inventory.md](protocol-header-inventory.md). The gallery lists
  what is declared; it declares nothing.
* A pcap reader, and reading a header out of a captured frame.
* Renaming the chunk and packet API.

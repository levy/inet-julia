# The header gallery

One protocol header, as a page: what the declaration says, what a caller writes
to build one, what one field update does to the bytes, what the fields hold, and
what the standard's own figure looks like.

Nothing on such a page is written by hand. That is the point of it — a wire
format is declared once, and a page that is derived from the declaration cannot
drift from it. A reader who doubts that can rename a field and watch the page
follow.

## Where it lives

| part | where |
| --- | --- |
| the facts a header answers about itself | `package/packet/main/HeaderFacts.jl` |
| what the editor's reflection asks a field value | `package/inet/main/headerview/` |
| the page, the table of headers, the marker | `package/inet/example/HeaderPage.jl` |
| the stub page per header | `package/inet/example/demo/pages/header/` |

The facts sit in `InetPacket` because they are computed from the type, and that
package depends on the document substrate alone. The page sits in `InetExample` because it is
markdown, and markdown is a domain the umbrella does not reach — `Inet` depends
on `ProjecturedVisual` alone.

## The five views

```
<<header_view("Ipv4Header")>>
```

| view | what builds it |
| --- | --- |
| the declaration | `definition(file(…), "Ipv4Header")` — the marker any page uses for a source fragment |
| how one is built | `describe_construction`, over `find_default` and `list_derived` |
| a field read and written | `describe_update`, and `encode_header` on both sides |
| the instance, reflected | `reflect_document`, with `classify_display` deciding the leaves |
| the instance, drawn | `packet_diagram` over a packet holding the one header |

The declaration arrives with its docstring, because `definition` yields a
documented definition whole. So the format is described in prose exactly once,
in the file that declares it.

The last two are **live documents sitting in the page as blocks**. A page's
elements each re-enter the renderer in their own domain, and the demo projection
already knows both types — so neither needs an embed card, a marker of its own,
or any conversion first. The figure keeps its colours and its foldable bands
that way.

A note for anyone measuring: a `PacketDiagram` re-derives its span sequence from
inside the text renderer's iteration, which looks alarming in a stack sample and
is worth fixing. It is not, however, expensive here — the suite takes the same
time with the live figure as with a flat string in its place.

## Adding a header

1. Add a row to `GALLERY_HEADERS` in `HeaderPage.jl`, with the one thing this
   header shows that none of the others does. The reason is printed on the page.
2. Add a stub page under `demo/pages/header/`, which is a title, a sentence and
   the marker.
3. Add a link to it in `demo/index.md`, under **One protocol, one page**.

The tests then walk it with the others: `test_inet()` builds every gallery page,
renders it through the projection `run_demo` uses, and asserts what it draws.

## Why ten and not ninety-one

Ninety-one wire formats are declared. Ten are in the gallery, one per feature of
the declaration language — a header written by hand, an optional field,
constants, sub-byte
widths, a derive, a wide field, an extension header, a variant, and a list that
fills its window. A gallery is read; an inventory is searched. The inventory is
`package/packet/doc/inventory.md`, and it is generated.

Scaling to all ninety-one means the navigator expanding one link into many rows
rather than ten stub files becoming ninety-one. That is stage 3 of
`plan/*/protocol-header-gallery.md`, and it is not started.

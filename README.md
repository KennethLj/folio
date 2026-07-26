# Folio

Print-quality PDF from [Typst](https://typst.app), in-process from Elixir via a Rustler NIF.

[![Hex.pm](https://img.shields.io/hexpm/v/folio.svg)](https://hex.pm/packages/folio)
[![Docs](https://img.shields.io/badge/docs-hex.pm-blue)](https://hexdocs.pm/folio)

## What it is

A thin adaptor over Typst's own compiler. You give it Typst source and the files that
source reads; Typst parses, evaluates and lays it out; you get PDF bytes back.

```elixir
{:ok, pdf} = Folio.compile("""
#set page(width: 595pt, height: 842pt)
= Rapport
Innehåll.
""")
```

Everything Typst does works, because none of it is reimplemented here — `#set` and
`#show` rules, `context`, outlines, references, page counters, user-defined functions.

## Data-driven documents

Keep the layout in a template and pass content as data:

```elixir
template = File.read!("priv/report.typ")

{:ok, pdf} =
  Folio.compile(template, %{
    "data.json" => JSON.encode!(%{title: "Q3", rows: rows}),
    "markdown.typ" => File.read!("priv/markdown.typ")
  })
```

```typst
#let data = json("data.json")

= #data.title
#for row in data.rows [ #row.name #row.amount \ ]
```

Files are scoped to the call — concurrent compiles cannot see each other's attachments.

This shape is also the safe one. `#data.title` renders a *value*; it is never parsed as
markup, so no escaping pass is needed and no user-supplied string can change the
document's structure.

> **Typst source is code.** `compile/3` runs the evaluator, so never build source by
> interpolating untrusted input into it. Put untrusted values in the file map instead.

## Reproducibility

The same source and files produce the same bytes on any machine:

- no creation timestamp is written into the PDF,
- typesetting uses only the fonts embedded in the NIF — system fonts are never
  consulted, so an image that happens to ship a different font set cannot change
  the metrics, the pagination or the output,
- `datetime.today()` is unavailable to templates.

That matters if you hash your output. A document that renders differently depending on
where it ran cannot be re-rendered later and compared against the one that was signed.

## Options

```elixir
Folio.compile(source, files, tagged: false)
```

`:tagged` controls whether a tagged (accessible) PDF is written. Defaults to `true`,
matching Typst. Tagging adds a structure element per table cell, so table-heavy
documents get considerably smaller with it off.

## Installation

```elixir
def deps do
  [{:folio, "~> 0.4"}]
end
```

Precompiled NIFs are downloaded for macOS (x86_64/aarch64) and Linux glibc
(x86_64/aarch64) — no Rust toolchain needed. To build from source:

```sh
FOLIO_BUILD=1 mix compile
```

## Errors

`compile/3` returns `{:ok, pdf}` or `{:error, %Folio.CompileError{}}` carrying Typst's
diagnostics. Warnings that don't stop a compile are logged via `Logger.warning/1`.

Failures Typst defers so layout can finish — an unresolved `@reference` is the common
one — are promoted to errors rather than being dropped, so a broken document does not
report success.

## License

MIT

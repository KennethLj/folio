# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Folio is a **thin adaptor** over Typst's compiler, exposed to Elixir through a Rustler NIF.
It hands Typst source and a file map to `typst::compile` and returns PDF bytes.

The load-bearing property is that **nothing Typst does is reimplemented here**. There is no
content-tree builder, no style translation layer, no markdown bridge, no show-rule engine.
Templates get the real evaluator: `#set`/`#show`, `context`, outlines, `@refs`, counters,
user-defined functions. The layout convergence loop, introspection settling and diagnostic
promotion are Typst's own `compile_impl`, not a copy of it.

If you are tempted to add a node type, a style struct, or an Elixir-side transform — don't.
That is the architecture this replaced, and every bug it had was a bug in the copy rather
than in Typst. Add it to the `.typ` template instead.

## Common commands

```sh
mix deps.get
mix test
mix test test/folio_test.exs:42     # single test by line
mix format
mix credo --strict
mix ci                              # compile --warnings-as-errors, format, credo, dialyzer, test, ex_dna
```

### NIF build

Precompiled NIFs are downloaded for macOS x86_64/aarch64 and Linux glibc x86_64/aarch64.
`lib/folio/native.ex` forces a source build when it detects `test/test_helper.exs` + `.git`
(i.e. when working in this repo). Elsewhere: `FOLIO_BUILD=1 mix compile`.

A cold Rust build compiles the whole Typst crate graph and takes minutes; incremental
rebuilds after touching only `src/*.rs` are fast.

## Architecture

```
Elixir                          Rust                            Typst
──────                          ────                            ─────
Folio.compile(source, files)
  └─ Folio.Native.compile_pdf ─► compile_pdf (DirtyCpu)
                                   ├─ FolioWorld::new ──────────► World impl
                                   ├─ typst::compile::<PagedDocument>
                                   └─ typst_pdf::pdf
                                 {pdf, warnings} ◄────────────── Warned<SourceResult<_>>
```

Two Rust files, and that is the whole of it:

- `native/folio_nif/src/world.rs` — the `World` impl. Fonts and `Library` are built once in
  a `LazyLock`; the source and file map live on the instance.
- `native/folio_nif/src/lib.rs` — the NIF entry point, diagnostic formatting, and
  `catch_nif`.

### The World

`source/1` serves the entry point plus any attached `.typ` file, so a template can
`#import` its siblings. `file/1` serves attached bytes, which is how `json("data.json")`
reaches its data.

Files live **on the `FolioWorld` instance**, not in a global or thread-local store. Two
compiles on different dirty schedulers cannot observe each other's attachments. Do not
reintroduce a global file registry.

### Determinism is a feature, not an accident

Three things are deliberate, and changing any of them breaks callers who hash their output:

1. `PdfOptions.timestamp` is `None` — no creation date in the PDF.
2. Only `typst_assets::fonts()` are loaded. **System fonts are deliberately not consulted.**
   Loading them makes output depend on what the host machine happens to have installed;
   the previous architecture did this and silently rendered a different typeface in a slim
   container than on a developer's Mac.
3. `World::today/1` returns `None`.

### Safety model

`catch_nif` wraps the NIF body in `catch_unwind` so Rust panics surface as Rustler errors
rather than crashing the BEAM. **Caveat:** Typst's `comemo` caches are not unwind-safe — a
panic mid-compile may leave them inconsistent, and restarting the VM is the only fully safe
recovery. Don't rely on a panic being recoverable.

The NIF runs on a `DirtyCpu` scheduler. Layout dominates compile time (~88% by Typst's own
trace), so a large document occupies that scheduler for its duration.

`Folio.compile/3` runs the **full evaluator**, so Typst source is code and is not safe to
build from untrusted input. Untrusted values belong in the file map, read via `json()` — a
value rendered by a fixed template cannot alter the document's structure. This distinction
is the one to protect when changing the API.

## Typst dependency

`native/folio_nif/Cargo.toml` pins **upstream** `typst/typst` at rev `5187e083`. All four
crates must move together — mixing revs yields incompatible `typst-utils` copies in the dep
graph.

This rev is a `main` commit, not a release tag: it is the upstream commit that the
`dannote/typst` fork (which this used to track) was branched from, and v0.14.2's `World`
API differs enough that the code does not compile against it. The fork existed only to make
`Bibliography::load` and `FirstLineIndent::new` public for the old struct-building path;
through the evaluator, `#bibliography(..)` and `#set par(first-line-indent: ..)` are
ordinary Typst functions, so no fork is needed. Those `pub` bumps have still not landed
upstream, so do not assume a release tag is a drop-in swap.

## Conventions

- `Folio.compile/3` returns `{:ok, pdf} | {:error, Folio.CompileError.t()}`; `compile!/3` raises.
- Warnings come back from the NIF as the second element of `{pdf, warnings}` and are logged
  by `Folio.compile/3`. Deferred failures are promoted to errors inside Typst's own
  compile, so they are not dropped.
- The Hex package `:files` list must stay in sync with what the Rust build needs.
- Supported Elixir/OTP per CI: 1.16 / OTP 26 and 1.18 / OTP 27.

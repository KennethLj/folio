# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Folio is an Elixir library that produces print-quality PDF / SVG / PNG from Markdown + an Elixir DSL, by driving [Typst](https://typst.app)'s layout engine through a Rustler NIF.

The **primary path bypasses the Typst parser and evaluator** — content trees are constructed directly in Rust from Elixir structs and fed to the layout stage, so the normal pipeline carries no Typst source string. That's what buys the typed DSL: bad input raises `ArgumentError` in Elixir before anything reaches Rust.

The evaluator is still linked and reachable through two deliberate escape hatches:

- `raw_typst/1` → `typst_eval::eval_string` in `SyntaxMode::Markup` (`convert.rs`). This is the *full* evaluator — set rules, show rules, `context` / `here()`, `for` loops, `let` bindings and user-defined functions all work.
- `FolioWorld::eval_math` → `eval_string` in `SyntaxMode::Math` (`world.rs`), used for `$...$` from markdown and `math/2`.

Treat that distinction as load-bearing when changing the architecture: adding a node type belongs on the struct path, not the eval path. And `raw_typst/1` runs arbitrary Typst, so it is **not safe for untrusted input** — Typst caps a single loop at 10,000 iterations (`typst-eval/src/flow.rs`), but nested loops multiply and NIFs run on DirtyCpu schedulers. File access is confined to the session/global file store.

## Common commands

```sh
mix deps.get
mix test                          # run tests
mix test test/dsl_test.exs        # single file
mix test test/dsl_test.exs:42     # single test by line
mix format
mix credo --strict
mix dialyzer
mix ci                            # the full CI bundle: compile --warnings-as-errors, format --check-formatted, credo --strict, dialyzer, test, ex_dna
```

### NIF build

Precompiled NIFs are downloaded for supported targets (macOS x86_64/aarch64, Linux glibc x86_64/aarch64) — no Rust toolchain needed for users.

When working **in this repo** on dev/test, `lib/folio/native.ex` automatically forces a source build (it detects `test/test_helper.exs` + `.git`). To force a source build elsewhere: `FOLIO_BUILD=1 mix compile`.

`native/folio_nif/Cargo.toml` pulls the typst crates from `github.com/dannote/typst` (a fork = upstream typst + 6 lines making `Bibliography::load` and `FirstLineIndent::new` public for embedder use). All eight crates must come from the same source — splitting some from upstream and some from the fork yields incompatible `typst-utils` copies in the dep graph. Once those `pub` bumps land upstream, swap all eight back to `github.com/typst/typst` and bump the rev together.

Releases (precompiled NIF artifacts + `checksum-Elixir.Folio.Native.exs`) are produced by `.github/workflows/release.yml`.

## Architecture

### The pipeline

```
Elixir input ──┐
               │
  Markdown ────┼─► Folio.parse_markdown (NIF, comrak) ─► [Folio.Content.* structs]
  DSL structs ─┤                                                       │
  Document ────┘                                                       ▼
                                                          Folio.Show.apply  (Elixir-side
                                                                            show-rule
                                                                            transforms)
                                                                       │
                                                                       ▼
                                                          Folio.Native.compile_{pdf,svg,png}
                                                                       │
                                                                       ▼ (NIF / DirtyCpu)
                                                          ExContent → typst Content tree
                                                          ExStyle   → typst Styles
                                                          → typst-layout → typst-pdf/svg/render
```

Three top-level inputs flow into the NIF: a list of `%Folio.Content.*{}` nodes, a list of `%Folio.Styles.*{}` rules, and a `%{path => binary}` map of attached files.

### Elixir ↔ Rust struct contract (critical)

Every content node and style rule is an Elixir struct that maps **1:1** to a `#[derive(NifStruct)]` in Rust via Rustler's `NifStruct` + `NifUntaggedEnum`:

| Elixir | Rust | hand-written? |
|---|---|---|
| `lib/folio/content.ex` (`%Folio.Content.Text{}`, `Heading{}`, …) | `src/generated_content_nodes.rs` (`ExText`, `ExHeading`, `ExContent`) | **generated** from `codegen/content_nodes.ex` |
| `lib/folio/styles.ex` (`%Folio.Styles.PageSize{}`, …) | `src/types.rs` (`ExStyle` variants) | hand-written |
| `lib/folio/native.ex` (`@spec`s) | `src/generated_nifs.rs` (`#[rustler::nif]` wrappers) | **generated** from `codegen/native.ex` |

Two Rust files are RustQ output and must never be edited directly — `mix rustq.gen` regenerates them from `rustq.exs`, and `mix ci` runs `rustq.gen --check` to catch drift. Editing the generated file instead of the codegen source produces a confusing compile error where the signature reverts on the next build.

When adding or changing a node/style:

1. Edit the Elixir struct (fields + `@type t`).
2. Content node → add/edit the `node` entry in `codegen/content_nodes.ex` and run `mix rustq.gen`. Style rule → edit the Rust struct in `types.rs` by hand and add the `ExStyle` variant. Either way `#[module = "Folio.Content.Foo"]` must match the Elixir module name **exactly**, and field names + types must match.
3. Handle the new variant in `native/folio_nif/src/convert.rs` (ExContent → `typst::foundations::Content`).
4. If it appears in Markdown, map the corresponding `comrak::NodeValue` in `native/folio_nif/src/mdex_bridge.rs`.
5. Add a builder function in `lib/folio/dsl.ex`.
6. Add a `node_type/1` clause and `child_fields` consideration in `lib/folio/show.ex` if the node should be addressable by show rules or contains nested content.

Changing a NIF's signature means editing `codegen/native.ex`, not `lib/folio/native.ex`'s `@spec` alone — the `@spec` is documentation, the codegen entry is what generates the Rust.

A field-decode mismatch surfaces as `"Could not decode field :X on %ExY{}"` from the NIF; `Folio.format_nif_error/1` rewrites this into a hint about checking the DSL signature.

### Show rules

`Folio.Show.apply/1` runs **in Elixir before the NIF call**. It walks the content tree, extracts every `%Content.ShowRule{}` (regardless of nesting), and applies the transforms bottom-up against `node_type/1`. This emulates Typst's `#show` mechanism without reaching the Typst evaluator. New container nodes that hold child content should expose those children via one of the recognized fields (`:body`, `:children`, `:caption`, `:term`, `:description`, `:supplement`) so the show traversal can reach into them.

### Layout convergence and diagnostics

`FolioWorld::layout` mirrors `compile_impl` in `typst/src/lib.rs`. The body and styles are built **once** against an `EmptyIntrospector`, then layout runs in a loop (up to `MAX_ITERS` = 5), each pass feeding the previous document's introspector into a fresh `Engine`. The loop exits when the `comemo::Constraint` validates against the new document's introspector.

This matters because anything Typst resolves in its second pass — page counters, `ref`s, outline entries — reads as empty on a single pass. A single-pass layout silently produces an empty outline and a page counter stuck at 1.

Diagnostics flow through the `Sink`:

- Each attempt gets its own `subsink`; only the sink of the iteration actually kept is merged into the outer one, so diagnostics from discarded passes don't leak.
- On non-convergence, `typst_library::introspection::analyze` turns the document history into warnings naming *which* introspection failed to settle — hence the history is retained, not just the previous document.
- `sink.delayed()` is drained and promoted to a hard error. Typst defers some failures so layout can finish (an unresolved `ref` is the common one); dropping the sink swallows them.
- Warnings are returned from the NIF as `{payload, warnings}` and logged by `Folio.wrap_call/2` via `Logger.warning`. The public API stays `{:ok, result} | {:error, t}`.

`convert_node` can't return a `Result`, so conversion-time failures (e.g. `raw_typst` that doesn't parse) go through `engine.sink.delay/1` and surface via that same promotion. Prefer this over packing placeholder text into the document — a placeholder renders into the user's PDF *and* reports success.

### File attachment scopes

- `Folio.Document.attach_file/3` — session-scoped. Files live only for that document's compile call; cleared via `clear_session_files()` after the NIF returns. Prefer this for untrusted input.
- `Folio.register_file/2` / `unregister_file/1` — process-global, persists for the BEAM lifetime. Useful for long-lived assets shared across many compiles.

### NIF safety model

`catch_nif` in `native/folio_nif/src/lib.rs` wraps every NIF body in `catch_unwind` so Rust panics surface as Rustler errors instead of crashing the BEAM. **Caveat documented in that file:** Typst's `comemo` caches and the global file store are not unwind-safe — a panic mid-compile may leave them inconsistent, and the only fully safe recovery is restarting the VM. Don't rely on a NIF panic being recoverable in tests or production.

All NIFs run on `DirtyCpu` schedulers; fonts are loaded once via `typst-assets` and shared across compilations (see `world.rs`).

## Conventions worth knowing

- `use Folio` imports `Folio.DSL`, `Folio.Styles`, and `Folio.Sigil`. The `~MD"""..."""` sigil supports `p` (returns `{:ok, pdf}`), `s` (returns `{:ok, [svg]}`), and no modifier (returns content nodes). Interpolation `#{}` is normal Elixir.
- DSL builders (`text/2`, `heading/2`, `table/2`, …) raise `ArgumentError` with descriptive messages on bad input rather than silently producing malformed structs.
- Compile entry points return `{:ok, result} | {:error, Folio.CompileError.t()}`; the parse entry returns `{:ok, nodes} | {:error, Folio.ParseError.t()}`. The bang variants (`parse_markdown!`) raise.
- `mix.exs` includes only the Typst crates needed for layout/render in the Hex package — `vendor/typst/crates/typst-cli` and `typst-ide` are excluded. The `package` `:files` list and `:exclude_patterns` must stay in sync with what the Rust build needs.
- Supported Elixir/OTP per CI: 1.16 / OTP 26 and 1.18 / OTP 27.

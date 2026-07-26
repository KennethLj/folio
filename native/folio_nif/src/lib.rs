mod world;

use std::collections::HashMap;
use std::panic::AssertUnwindSafe;

use rustler::{Env, NifResult, OwnedBinary};
use typst::diag::{SourceDiagnostic, Warned};
use typst::foundations::Smart;
use typst_layout::PagedDocument;
use typst_pdf::{pdf, PdfOptions};

use world::FolioWorld;

/// Wrap a NIF body in `catch_unwind` so Rust panics become structured
/// Rustler errors instead of crashing the BEAM.
///
/// # Safety
///
/// Typst's `comemo` caches are not unwind-safe. A panic during compilation may
/// leave them inconsistent, and restarting the BEAM VM is the only fully safe
/// recovery. Do not rely on a panic here being recoverable.
fn catch_nif<F, T>(label: &str, f: F) -> NifResult<T>
where
    F: FnOnce() -> NifResult<T>,
{
    match std::panic::catch_unwind(AssertUnwindSafe(f)) {
        Ok(result) => result,
        Err(panic) => {
            let msg = match panic.downcast::<String>() {
                Ok(s) => format!("{} panicked: {}", label, *s),
                Err(p) => match p.downcast::<&str>() {
                    Ok(s) => format!("{} panicked: {}", label, *s),
                    Err(_) => format!("{} panicked with unknown value", label),
                },
            };
            Err(rustler::Error::RaiseTerm(Box::new(msg)))
        }
    }
}

/// Compile Typst `source` to PDF.
///
/// `files` maps virtual paths to bytes, and is how a template reaches its
/// data (`json("data.json")`) and its siblings (`#import "markdown.typ"`).
/// Returns the PDF alongside any warnings, which the caller logs.
///
/// The PDF carries no creation timestamp, so the same source and files always
/// produce the same bytes.
#[rustler::nif(schedule = "DirtyCpu")]
fn compile_pdf<'a>(
    env: Env<'a>,
    source: String,
    files: HashMap<String, rustler::Binary<'a>>,
    tagged: bool,
) -> NifResult<(rustler::Binary<'a>, Vec<String>)> {
    catch_nif("compile_pdf", || {
        let files = files
            .into_iter()
            .map(|(path, data)| (path, data.as_slice().to_vec()))
            .collect();

        let world = FolioWorld::new(source, files);
        let Warned { output, warnings } = typst::compile::<PagedDocument>(&world);

        let document = output.map_err(diagnostics_error)?;

        let options = PdfOptions {
            ident: Smart::Auto,
            timestamp: None,
            page_ranges: None,
            standards: Default::default(),
            tagged,
        };

        let bytes = pdf(&document, &options).map_err(diagnostics_error)?;

        Ok((alloc_binary(env, &bytes)?, format_all(&warnings)))
    })
}

fn diagnostics_error(diagnostics: impl IntoIterator<Item = SourceDiagnostic>) -> rustler::Error {
    let messages: Vec<String> = diagnostics
        .into_iter()
        .map(|d| format_diagnostic(&d))
        .collect();

    rustler::Error::RaiseTerm(Box::new(messages.join("\n")))
}

fn format_all(diagnostics: &[SourceDiagnostic]) -> Vec<String> {
    diagnostics.iter().map(format_diagnostic).collect()
}

fn format_diagnostic(diagnostic: &SourceDiagnostic) -> String {
    let mut out = diagnostic.message.to_string();

    for hint in &diagnostic.hints {
        out.push_str("\n  hint: ");
        out.push_str(&hint.v);
    }

    out
}

fn alloc_binary<'a>(env: Env<'a>, bytes: &[u8]) -> NifResult<rustler::Binary<'a>> {
    let mut binary = OwnedBinary::new(bytes.len())
        .ok_or(rustler::Error::Term(Box::new("failed to allocate binary")))?;

    binary.as_mut_slice().copy_from_slice(bytes);

    Ok(binary.release(env))
}

rustler::init!("Elixir.Folio.Native");

use std::collections::HashMap;
use std::sync::LazyLock;

use typst::diag::{FileError, FileResult};
use typst::foundations::{Bytes, Datetime, Duration};
use typst::syntax::{FileId, RootedPath, Source, VirtualPath, VirtualRoot};
use typst::text::{Font, FontBook};
use typst::utils::LazyHash;
use typst::{Features, Library, LibraryExt, World};

struct GlobalState {
    library: LazyHash<Library>,
    fonts: Vec<Font>,
    book: LazyHash<FontBook>,
    main_id: FileId,
}

/// Fonts, library and the main file id, built once and shared across compiles.
///
/// Only the fonts embedded in `typst-assets` are loaded. System fonts are
/// deliberately *not* consulted: whichever fonts a laptop or a container image
/// happens to carry would otherwise change the metrics, the pagination and
/// therefore the bytes of a document, and callers who hash their output need
/// the same input to render the same PDF everywhere. This mirrors the CLI's
/// `--ignore-system-fonts`.
static GLOBAL: LazyLock<GlobalState> = LazyLock::new(|| {
    let fonts: Vec<Font> = typst_assets::fonts()
        .flat_map(|data| Font::iter(Bytes::new(data)))
        .collect();
    let book = LazyHash::new(FontBook::from_fonts(&fonts));
    let library = LazyHash::new(Library::builder().with_features(Features::all()).build());
    let main_id =
        RootedPath::new(VirtualRoot::Project, VirtualPath::new("main.typ").unwrap()).intern();

    GlobalState {
        library,
        fonts,
        book,
        main_id,
    }
});

/// A `World` over an in-memory source and file map.
///
/// Attached files live on the instance rather than in a global or
/// thread-local store, so two compiles running concurrently on different dirty
/// schedulers cannot observe each other's files.
pub struct FolioWorld {
    main: Source,
    files: HashMap<String, Bytes>,
}

impl FolioWorld {
    pub fn new(source: String, files: HashMap<String, Vec<u8>>) -> Self {
        Self {
            main: Source::new(GLOBAL.main_id, source),
            files: files
                .into_iter()
                .map(|(path, data)| (path, Bytes::new(data)))
                .collect(),
        }
    }
}

impl World for FolioWorld {
    fn library(&self) -> &LazyHash<Library> {
        &GLOBAL.library
    }

    fn book(&self) -> &LazyHash<FontBook> {
        &GLOBAL.book
    }

    fn main(&self) -> FileId {
        GLOBAL.main_id
    }

    /// Serves the entry point, plus any attached `.typ` file so a template can
    /// `#import` its siblings.
    fn source(&self, id: FileId) -> FileResult<Source> {
        if id == GLOBAL.main_id {
            return Ok(self.main.clone());
        }

        let path = id.vpath().get_without_slash();
        let bytes = self
            .files
            .get(path)
            .ok_or_else(|| FileError::NotFound(path.into()))?;

        let text = std::str::from_utf8(bytes).map_err(|_| FileError::InvalidUtf8)?;

        Ok(Source::new(id, text.to_string()))
    }

    fn file(&self, id: FileId) -> FileResult<Bytes> {
        let path = id.vpath().get_without_slash();

        self.files
            .get(path)
            .cloned()
            .ok_or_else(|| FileError::NotFound(path.into()))
    }

    fn font(&self, index: usize) -> Option<Font> {
        GLOBAL.fonts.get(index).cloned()
    }

    /// `None` keeps `datetime.today()` unavailable to templates. A document
    /// whose content depends on the day it was rendered cannot be re-rendered
    /// later and compared against the one that was signed.
    fn today(&self, _offset: Option<Duration>) -> Option<Datetime> {
        None
    }
}

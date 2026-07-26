use RustQ.Config

require_file("codegen/content_nodes.ex")
require_file("codegen/native.ex")

generate :nifs, "native/folio_nif/src/generated_nifs.rs" do
  build(&Folio.Codegen.Native.rust_nifs/0)
end

rust "native/folio_nif/src/generated_content_nodes.rs" do
  Folio.Codegen.ContentNodes.rust_items()
end

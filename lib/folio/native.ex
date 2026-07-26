defmodule Folio.Native do
  @moduledoc false

  version = Mix.Project.config()[:version]
  source_root = Path.expand("../..", __DIR__)

  local_test_build =
    Mix.env() in [:dev, :test] and
      File.exists?(Path.join(source_root, "test/test_helper.exs")) and
      File.dir?(Path.join(source_root, ".git"))

  use RustlerPrecompiled,
    otp_app: :folio,
    crate: :folio_nif,
    base_url: "https://github.com/dannote/folio/releases/download/v#{version}",
    force_build:
      local_test_build or System.get_env("FOLIO_BUILD") in ["1", "true"] or
        Application.compile_env(:rustler_precompiled, [:force_build, :folio], false),
    targets: ~w(
      aarch64-apple-darwin
      aarch64-unknown-linux-gnu
      x86_64-apple-darwin
      x86_64-unknown-linux-gnu
    ),
    version: version

  @typedoc "Diagnostics Typst emitted without failing the compile."
  @type warnings :: [String.t()]

  @spec compile_pdf(String.t(), %{optional(String.t()) => binary()}, boolean()) ::
          {binary(), warnings()}
  def compile_pdf(_source, _files, _tagged), do: :erlang.nif_error(:nif_not_loaded)
end

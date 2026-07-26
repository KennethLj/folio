defmodule Folio do
  @moduledoc """
  Print-quality PDF from Typst, in-process via a Rustler NIF.

  Folio is a thin adaptor over Typst's own compiler. You supply Typst source
  and the files it reads; Typst parses, evaluates and lays it out, and you get
  PDF bytes back. Everything Typst can do — `#set` and `#show` rules, `context`,
  outlines, references, page counters — works, because none of it is
  reimplemented here.

      {:ok, pdf} = Folio.compile("#set page(width: 200pt, height: 100pt)\\nHej")

  ## Files

  A template reaches its data and its siblings through the file map:

      Folio.compile(File.read!("report.typ"), %{
        "data.json" => JSON.encode!(payload),
        "markdown.typ" => File.read!("markdown.typ")
      })

  Files are scoped to the call. Nothing is registered globally, so concurrent
  compiles cannot observe each other's attachments.

  ## Reproducibility

  The PDF carries no creation timestamp and typesetting is restricted to the
  fonts embedded in the NIF, so the same source and files produce the same
  bytes on every machine. `datetime.today()` is unavailable to templates for
  the same reason — a document that depends on the day it was rendered cannot
  be re-rendered later and compared against the one that was signed.

  ## Untrusted input

  `compile/3` runs the Typst evaluator, so **Typst source is code**. Do not
  build source from untrusted input. Put untrusted values in the file map as
  data instead: `json("data.json")` in a fixed template renders values, it does
  not evaluate them.
  """

  alias Folio.CompileError

  require Logger

  @typedoc "Virtual path to file contents, readable by the template."
  @type files :: %{optional(String.t()) => binary()}

  @doc """
  Compiles Typst `source` to PDF.

  ## Options

    * `:tagged` — emit a tagged (accessible) PDF. Defaults to `true`, matching
      Typst's own default. Tagging adds a structure element per table cell, so
      table-heavy documents shrink considerably with it off.

  Warnings from the compiler are logged; the return value is the PDF or an
  error carrying the diagnostics.
  """
  @spec compile(String.t(), files(), keyword()) :: {:ok, binary()} | {:error, CompileError.t()}
  def compile(source, files \\ %{}, opts \\ [])
      when is_binary(source) and is_map(files) and is_list(opts) do
    tagged = Keyword.get(opts, :tagged, true)
    {pdf, warnings} = Folio.Native.compile_pdf(source, files, tagged)

    Enum.each(warnings, &Logger.warning("typst: #{&1}"))

    {:ok, pdf}
  rescue
    error in ErlangError -> {:error, CompileError.new(describe(error))}
  end

  @doc """
  Compiles Typst `source` to PDF, raising `Folio.CompileError` on failure.
  """
  @spec compile!(String.t(), files(), keyword()) :: binary()
  def compile!(source, files \\ %{}, opts \\ []) do
    case compile(source, files, opts) do
      {:ok, pdf} -> pdf
      {:error, error} -> raise error
    end
  end

  defp describe(%ErlangError{original: original}) when is_binary(original), do: original
  defp describe(error), do: Exception.message(error)
end

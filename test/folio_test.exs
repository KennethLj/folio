defmodule FolioTest do
  use ExUnit.Case, async: true

  @page "#set page(width: 300pt, height: 200pt)\n"

  describe "compile/3" do
    test "compiles Typst source to a PDF" do
      assert {:ok, pdf} = Folio.compile(@page <> "Hej världen")
      assert <<"%PDF", _rest::binary>> = pdf
    end

    test "reads attached data through json()" do
      source = @page <> ~S|#let d = json("data.json")| <> "\n#d.namn"

      assert {:ok, pdf} = Folio.compile(source, %{"data.json" => ~s({"namn": "Nordvik AB"})})
      assert <<"%PDF", _rest::binary>> = pdf
    end

    test "imports attached siblings" do
      source = @page <> ~S|#import "hjalp.typ": rubrik| <> "\n#rubrik[Titel]"
      files = %{"hjalp.typ" => "#let rubrik(body) = heading(level: 1, body)\n"}

      assert {:ok, pdf} = Folio.compile(source, files)
      assert <<"%PDF", _rest::binary>> = pdf
    end

    # The evaluator is reached in full, which is the point of the adaptor: none
    # of this is reimplemented, so `#set`/`#show`, context and counters work.
    test "runs set and show rules, context and counters" do
      source =
        @page <>
          """
          #set heading(numbering: "1.")
          #show heading: it => emph(it.body)
          = Först
          = Sedan
          #context counter(heading).display()
          """

      assert {:ok, pdf} = Folio.compile(source)
      assert <<"%PDF", _rest::binary>> = pdf
    end

    # Introspection needs more than one layout pass. Typst's own compiler runs
    # the loop; a single pass would leave the outline empty.
    test "resolves introspection-driven content" do
      source = @page <> "#outline()\n= Kapitel ett\n= Kapitel två\n"

      assert {:ok, pdf} = Folio.compile(source)
      assert <<"%PDF", _rest::binary>> = pdf
    end

    test "the same source renders byte-for-byte identically" do
      source = @page <> "Determinism"

      assert {:ok, first} = Folio.compile(source)
      assert {:ok, second} = Folio.compile(source)
      assert first == second
    end

    test "different source renders different bytes" do
      assert {:ok, first} = Folio.compile(@page <> "Ett")
      assert {:ok, second} = Folio.compile(@page <> "Två")
      refute first == second
    end

    test "tagging is on by default and off by request" do
      source = @page <> "#table(columns: 2, [a], [b], [c], [d])"

      assert {:ok, tagged} = Folio.compile(source)
      assert {:ok, untagged} = Folio.compile(source, %{}, tagged: false)
      assert byte_size(tagged) > byte_size(untagged)
    end

    test "a syntax error is returned, not raised" do
      assert {:error, %Folio.CompileError{} = error} = Folio.compile(@page <> "#let = 1")
      assert Exception.message(error) =~ "Folio compile error"
    end

    # Typst defers some failures so layout can finish; an unresolved reference
    # is the usual one. Dropping them would report success on a broken document.
    test "a deferred failure still fails the compile" do
      assert {:error, %Folio.CompileError{}} = Folio.compile(@page <> "@finns-inte")
    end

    test "a missing file is an error naming the path" do
      assert {:error, %Folio.CompileError{} = error} =
               Folio.compile(@page <> ~S|#json("saknas.json")|)

      assert Exception.message(error) =~ "saknas.json"
    end
  end

  describe "compile!/3" do
    test "returns the PDF" do
      assert <<"%PDF", _rest::binary>> = Folio.compile!(@page <> "Hej")
    end

    test "raises on failure" do
      assert_raise Folio.CompileError, fn -> Folio.compile!(@page <> "#let = 1") end
    end
  end
end

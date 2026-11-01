# Copyright 2026 hpack authors
# SPDX-License-Identifier: Apache-2.0
#
# Generate test/fixtures/hpax_vectors.txt: header blocks encoded by the real
# hpax 1.0.4, for the hpax-differential test (HPACKInteropTest). Each sequence
# uses one evolving table, so dynamic indexing carries across blocks.
#
# Usage (hpax checkout at $HPAX_DIR, v1.0.4):
#   elixirc -o /tmp/hpax_ebin $HPAX_DIR/lib/hpax.ex $HPAX_DIR/lib/hpax/*.ex
#   elixir -pa /tmp/hpax_ebin bench/gen_vectors.exs
#
# Format:
#   HPAX-VECTORS 1
#   TABLE <max-size> <never|always>
#   BLOCK <k>
#   <action> <namehex|-> <valuehex|->
#   ...
#   ENCODED <hex>
#   SIZE <table-size>

:rand.seed(:exsss, {4080, 5, 1})

static_names =
  HPAX.Table.__static_table__()
  |> Enum.map(&elem(&1, 0))
  |> Enum.uniq()

random_name = fn ->
  if :rand.uniform(3) == 1 do
    Enum.random(static_names)
  else
    1..:rand.uniform(12) |> Enum.map(fn _ -> ?a + :rand.uniform(26) - 1 end) |> :binary.list_to_bin()
  end
end

random_value = fn ->
  if :rand.uniform(4) == 1 do
    ""
  else
    1..:rand.uniform(40) |> Enum.map(fn _ -> :rand.uniform(256) - 1 end) |> :binary.list_to_bin()
  end
end

hex = fn
  "" -> "-"
  bin -> Base.encode16(bin, case: :lower)
end

lines = ["HPAX-VECTORS 1"]

lines =
  Enum.reduce([:never, :always], lines, fn huffman, lines ->
    lines = lines ++ ["TABLE 4096 #{huffman}"]
    enc = HPAX.new(4096, huffman_encoding: huffman)

    {lines, _enc} =
      Enum.reduce(1..20, {lines, enc}, fn _, {lines, enc} ->
        headers =
          for _ <- 1..:rand.uniform(4) do
            action = Enum.random([:store, :store_name, :no_store, :never_store])
            {action, random_name.(), random_value.()}
          end

        {io, enc} = HPAX.encode(headers, enc)
        lines =
          lines ++
            ["BLOCK #{length(headers)}"] ++
            Enum.map(headers, fn {a, n, v} -> "#{a} #{hex.(n)} #{hex.(v)}" end) ++
            ["ENCODED #{Base.encode16(IO.iodata_to_binary(io), case: :lower)}", "SIZE #{enc.size}"]

        {lines, enc}
      end)

    lines
  end)

File.mkdir_p!("test/fixtures")
File.write!("test/fixtures/hpax_vectors.txt", Enum.join(lines, "\n") <> "\n")
IO.puts("wrote test/fixtures/hpax_vectors.txt (#{length(lines)} lines)")

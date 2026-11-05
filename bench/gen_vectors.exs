# Copyright 2026 hpack authors
# SPDX-License-Identifier: Apache-2.0
#
# Generate test/fixtures/hpax_vectors.txt: header blocks encoded (and bad
# blocks rejected) by the real hpax 1.0.4, for the hpax-differential test
# (HPACKInteropTest). Each sequence uses one evolving table, so dynamic
# indexing carries across blocks.
#
# Usage (hpax checkout or hex tarball contents at $HPAX_DIR, v1.0.4):
#   elixirc -o /tmp/hpax_ebin $HPAX_DIR/lib/hpax.ex $HPAX_DIR/lib/hpax/*.ex
#   HPAX_DIR=$HPAX_DIR elixir -pa /tmp/hpax_ebin bench/gen_vectors.exs
#
# Provenance: the header records the hpax version, a digest of the hpax
# sources, the OTP release and the Elixir version. `:rand` and `Enum.random`
# output can change between OTP/Elixir releases, so a regen under a different
# toolchain or hpax source fails loudly instead of silently reshuffling the
# vectors. Set ACCEPT_PROVENANCE=1 to deliberately rewrite with the new one.
#
# Format:
#   HPAX-VECTORS 2 hpax=<ver> hpax-src=<sha256/16> otp=<release> elixir=<ver>
#   TABLE <max-size> <never|always>    fresh encoder and decoder tables
#   RESIZE <max-size>                  HPAX.resize/2 on both tables
#   BLOCK <k>
#   <action> <namehex|-> <valuehex|->
#   ...
#   ENCODED <hex>
#   SIZE <table-size>
#   ERROR <max-size> <hex> <reason> [<detail>]
#                                      HPAX.decode/2 of <hex> on a fresh table
#                                      returns {:error, reason} (or
#                                      {:error, {reason, detail}})

hpax_dir = System.get_env("HPAX_DIR") || raise "set HPAX_DIR to the hpax 1.0.4 source"

[_, hpax_version] = Regex.run(~r/@version "([^"]+)"/, File.read!(Path.join(hpax_dir, "mix.exs")))
hpax_version == "1.0.4" || raise "expected hpax 1.0.4, found #{hpax_version} in #{hpax_dir}"

hpax_src =
  Path.wildcard(Path.join(hpax_dir, "lib/**/*.ex"))
  |> Enum.sort()
  |> Enum.map(fn p -> [Path.relative_to(p, hpax_dir), 0, File.read!(p)] end)
  |> then(&:crypto.hash(:sha256, &1))
  |> Base.encode16(case: :lower)
  |> binary_part(0, 16)

provenance = %{
  "hpax" => hpax_version,
  "hpax-src" => hpax_src,
  "otp" => to_string(:erlang.system_info(:otp_release)),
  "elixir" => System.version()
}

fixture = "test/fixtures/hpax_vectors.txt"

# Refuse to regenerate under a different toolchain unless told to.
with {:ok, text} <- File.read(fixture),
     ["HPAX-VECTORS", "2" | pairs] <- text |> String.split("\n", parts: 2) |> hd() |> String.split() do
  recorded = Map.new(pairs, fn p -> p |> String.split("=", parts: 2) |> List.to_tuple() end)

  if recorded != provenance and System.get_env("ACCEPT_PROVENANCE") != "1" do
    raise """
    provenance changed since #{fixture} was generated:
      recorded: #{inspect(recorded)}
      current:  #{inspect(provenance)}
    :rand/Enum.random output is OTP/Elixir-sensitive. Regenerate under the
    recorded toolchain, or set ACCEPT_PROVENANCE=1 to accept the new one.
    """
  end
end

header =
  "HPAX-VECTORS 2 " <>
    Enum.map_join(["hpax", "hpax-src", "otp", "elixir"], " ", &"#{&1}=#{provenance[&1]}")

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

all_actions = [:store, :store_name, :no_store, :never_store]

# Encode one random block through `enc` (decoding it through `dec` too, so
# the generator itself checks hpax round-trips), returning the fixture lines.
block = fn enc, dec, actions ->
  headers =
    for _ <- 1..:rand.uniform(4) do
      {Enum.random(actions), random_name.(), random_value.()}
    end

  {io, enc} = HPAX.encode(headers, enc)
  encoded = IO.iodata_to_binary(io)
  {:ok, decoded, dec} = HPAX.decode(encoded, dec)
  decoded == Enum.map(headers, fn {_, n, v} -> {n, v} end) || raise "hpax round-trip mismatch"
  enc.size == dec.size || raise "hpax encoder/decoder table sizes diverged"

  lines =
    ["BLOCK #{length(headers)}"] ++
      Enum.map(headers, fn {a, n, v} -> "#{a} #{hex.(n)} #{hex.(v)}" end) ++
      ["ENCODED #{Base.encode16(encoded, case: :lower)}", "SIZE #{enc.size}"]

  {lines, encoded, enc, dec}
end

# A sequence: a fresh table pair, then a script of `{:block, actions}` and
# `{:resize, n}` steps. Returns the lines, the encoded blocks and final tables.
sequence = fn max, huffman, steps ->
  enc = HPAX.new(max, huffman_encoding: huffman)
  dec = HPAX.new(max, huffman_encoding: huffman)

  {lines, blocks, enc, dec} =
    Enum.reduce(steps, {["TABLE #{max} #{huffman}"], [], enc, dec}, fn
      {:resize, n}, {lines, blocks, enc, dec} ->
        {lines ++ ["RESIZE #{n}"], blocks, HPAX.resize(enc, n), HPAX.resize(dec, n)}

      {:block, actions}, {lines, blocks, enc, dec} ->
        {more, encoded, enc, dec} = block.(enc, dec, actions)
        {lines ++ more, blocks ++ [encoded], enc, dec}
    end)

  {lines, blocks, enc}
end

blocks = fn n, actions -> List.duplicate({:block, actions}, n) end

# 1. The original two 4096-byte sequences. They come first and consume the
#    seeded stream exactly as HPAX-VECTORS 1 did, so those 40 blocks are
#    unchanged by later additions.
{never4096, _, _} = sequence.(4096, :never, blocks.(20, all_actions))
{always4096, _, _} = sequence.(4096, :always, blocks.(20, all_actions))

# 2. Eviction: a 256-byte table holds only a few entries, and a store-heavy
#    mix keeps evicting them.
store_heavy = [:store, :store, :store, :store_name, :no_store]
{evict, _, evict_enc} = sequence.(256, :never, blocks.(20, store_heavy))

stored =
  evict
  |> Enum.filter(&String.starts_with?(&1, "store"))
  |> length()

stored > evict_enc.length || raise "eviction sequence did not evict"

# 3. Resize: shrink, shrink-then-grow (two pending updates, RFC 7541 §4.2),
#    grow past the initial maximum, and two grows in a row.
resize_steps =
  blocks.(3, store_heavy) ++
    [{:resize, 128}] ++
    blocks.(2, store_heavy) ++
    [{:resize, 0}, {:resize, 512}] ++
    blocks.(3, store_heavy) ++
    [{:resize, 8192}] ++
    blocks.(3, store_heavy) ++
    [{:resize, 1024}, {:resize, 2048}] ++
    blocks.(2, store_heavy)

{resize, resize_blocks, _} = sequence.(4096, :always, resize_steps)

# Each block straight after a RESIZE (blocks 3, 5, 8 and 11) must open with
# a dynamic table size update (001xxxxx).
for i <- [3, 5, 8, 11] do
  <<0b001::3, _::bitstring>> = Enum.at(resize_blocks, i)
end

# 4. Known-bad blocks: hpax decides the reason, the fixture records it.
error_cases = [
  # indexed field 0 is never valid
  {4096, "80"},
  # first dynamic index on an empty table
  {4096, "be"},
  # dynamic index one past the only stored entry (62 is foo: bar)
  {4096, "4003666f6f03626172bf"},
  # indexed field whose integer continuation is missing
  {4096, "ff"},
  # literal-without-indexing name index whose continuation is missing
  {4096, "0f"},
  # integer continuation too long for hpax's maximum
  {4096, "ffffffffffffff7f"},
  # literal with indexed name but no value
  {4096, "41"},
  # literal new name whose length runs past the block
  {4096, "4005616263"},
  # size update above the protocol maximum (5000 > 4096)
  {4096, "3fe926"},
  # size update after a header field
  {4096, "8220"},
  # Huffman name "0" (00000) padded with 000 instead of EOS bits
  {4096, "408100"}
]

format_reason = fn
  reason when is_atom(reason) -> "#{reason}"
  {reason, detail} when is_atom(reason) and (is_atom(detail) or is_integer(detail)) -> "#{reason} #{detail}"
  other -> raise "unexpected hpax error shape: #{inspect(other)}"
end

errors =
  Enum.map(error_cases, fn {max, h} ->
    bin = Base.decode16!(h, case: :lower)

    reason =
      try do
        HPAX.decode(bin, HPAX.new(max))
      catch
        :throw, {:hpax, r} -> {:error, r}
      end
      |> case do
        {:error, r} -> r
        other -> raise "expected #{h} to fail in hpax, got #{inspect(other)}"
      end

    "ERROR #{max} #{h} #{format_reason.(reason)}"
  end)

lines = [header] ++ never4096 ++ always4096 ++ evict ++ resize ++ errors

File.mkdir_p!("test/fixtures")
File.write!(fixture, Enum.join(lines, "\n") <> "\n")
IO.puts("wrote #{fixture} (#{length(lines)} lines)")

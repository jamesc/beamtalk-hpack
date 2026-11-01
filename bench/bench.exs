# Copyright 2026 hpack authors
# SPDX-License-Identifier: Apache-2.0
#
# Time hpax 1.0.4 encoding + decoding a typical request header block, for the
# README comparison against beamtalk-hpack.
#
# Usage (hpax checkout at $HPAX_DIR, v1.0.4):
#   elixirc -o /tmp/hpax_ebin $HPAX_DIR/lib/hpax.ex $HPAX_DIR/lib/hpax/*.ex
#   elixir -pa /tmp/hpax_ebin bench/bench.exs [iterations]

n = (System.argv() |> List.first() || "2000") |> String.to_integer()

headers = [
  {:store, ":method", "GET"},
  {:store, ":scheme", "https"},
  {:store, ":path", "/index.html"},
  {:store, ":authority", "www.example.com"},
  {:store, "cache-control", "no-cache"},
  {:store, "custom-key", "custom-value"}
]

# Warm up once (also builds any lazy state), then measure fresh tables per
# iteration, exactly as the Beamtalk bench does.
{io, _} = HPAX.encode(headers, HPAX.new(4096, huffman_encoding: :always))
wire = IO.iodata_to_binary(io)
IO.puts("encoded bytes: #{byte_size(wire)}")

{us, _} =
  :timer.tc(fn ->
    Enum.each(1..n, fn _ ->
      {io, enc} = HPAX.encode(headers, HPAX.new(4096, huffman_encoding: :always))
      {:ok, _, _} = HPAX.decode(IO.iodata_to_binary(io), HPAX.new(4096, huffman_encoding: :always))
      enc
    end)
  end)

IO.puts("hpax encode+decode x#{n}: #{us} us total, #{Float.round(us / n, 2)} us/op")

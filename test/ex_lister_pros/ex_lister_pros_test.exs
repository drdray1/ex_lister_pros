defmodule ExListerProsTest do
  use ExUnit.Case, async: true

  alias ExListerPros.Fixtures

  @stub __MODULE__.Stub

  test "facade delegates list_listings to Listings" do
    Req.Test.stub(@stub, fn conn ->
      Req.Test.json(conn, Fixtures.listings_page(1))
    end)

    assert {:ok, %{listings: listings, pagination: %{total: 92}}} =
             ExListerPros.list_listings(Fixtures.authed_session(@stub))

    assert length(listings) == 2
  end

  test "facade delegates list_all_listings to Listings" do
    Req.Test.stub(@stub, fn conn ->
      page = String.to_integer(URI.decode_query(conn.query_string)["page"])
      Req.Test.json(conn, Fixtures.listings_page(page))
    end)

    assert {:ok, all} =
             ExListerPros.list_all_listings(Fixtures.authed_session(@stub),
               sleep_fn: fn _ -> :ok end
             )

    assert length(all) == 16
  end

  test "facade delegates stream_listings to Listings" do
    Req.Test.stub(@stub, fn conn ->
      page = String.to_integer(URI.decode_query(conn.query_string)["page"])
      Req.Test.json(conn, Fixtures.listings_page(page))
    end)

    listings =
      Fixtures.authed_session(@stub)
      |> ExListerPros.stream_listings(sleep_fn: fn _ -> :ok end)
      |> Enum.take(2)

    assert length(listings) == 2
  end
end

defmodule ExListerPros.ListingsTest do
  use ExUnit.Case, async: true

  alias ExListerPros.{Fixtures, Listings}

  @stub __MODULE__.Stub

  describe "list_listings/2" do
    test "sends the Inertia partial-reload headers and page param" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/listings"
        assert Plug.Conn.get_req_header(conn, "x-inertia") == ["true"]

        assert Plug.Conn.get_req_header(conn, "x-inertia-partial-component") ==
                 ["Customer/Listings/IndexListing"]

        assert Plug.Conn.get_req_header(conn, "x-inertia-partial-data") == ["listings"]
        assert URI.decode_query(conn.query_string)["page"] == "3"

        Req.Test.json(conn, Fixtures.listings_page(3))
      end)

      assert {:ok, %{listings: listings, pagination: pagination}} =
               Listings.list_listings(Fixtures.authed_session(@stub), page: 3)

      assert length(listings) == 2

      assert %{"address" => %{"unparsed_address" => "100 N Cactus Rd, Sampleton, AZ 85001"}} =
               hd(listings)

      assert pagination.current_page == 3
      assert pagination.last_page == 8
      assert pagination.total == 92
      assert pagination.per_page == 12
      assert pagination.next_page == 4
      assert pagination.prev_page == 2
    end

    test "defaults to page 1 and computes prev_page nil" do
      Req.Test.stub(@stub, fn conn ->
        assert URI.decode_query(conn.query_string)["page"] == "1"
        Req.Test.json(conn, Fixtures.listings_page(1))
      end)

      assert {:ok, %{pagination: pagination}} =
               Listings.list_listings(Fixtures.authed_session(@stub))

      assert pagination.current_page == 1
      assert pagination.prev_page == nil
      assert pagination.next_page == 2
    end
  end

  describe "get_listing/3" do
    test "requests /listings/:id/edit with the detail component and merges galleries" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/listings/aryeo-listing-1/edit"
        assert Plug.Conn.get_req_header(conn, "x-inertia") == ["true"]

        assert Plug.Conn.get_req_header(conn, "x-inertia-partial-component") ==
                 ["Customer/Listings/EditListing"]

        assert Plug.Conn.get_req_header(conn, "x-inertia-partial-data") ==
                 ["listing,images,videos,floorplans"]

        Req.Test.json(conn, Fixtures.listing_detail())
      end)

      assert {:ok, listing} =
               Listings.get_listing(Fixtures.authed_session(@stub), "aryeo-listing-1")

      # The listing fields come through...
      assert listing["id"] == "aryeo-listing-1"
      assert listing["description"] == "Charming sample home."

      # ...and the top-level galleries are unwrapped from `%{"data" => [...]}`.
      assert [%{"id" => "img-1"}, %{"id" => "img-2"}] = listing["images"]
      assert [%{"id" => "vid-1"}] = listing["videos"]
      assert [%{"id" => "fp-1"}] = listing["floorplans"]
    end

    test "tolerates a listing with no galleries" do
      Req.Test.stub(@stub, fn conn ->
        Req.Test.json(conn, %{"props" => %{"listing" => %{"id" => "bare"}}})
      end)

      assert {:ok, listing} = Listings.get_listing(Fixtures.authed_session(@stub), "bare")
      assert listing["id"] == "bare"
      assert listing["images"] == []
      assert listing["videos"] == []
      assert listing["floorplans"] == []
    end

    test "propagates an unauthenticated error" do
      Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 419, "") end)

      assert {:error, :unauthenticated} =
               Listings.get_listing(Fixtures.authed_session(@stub), "x")
    end
  end

  describe "anti-detection headers" do
    test "every request looks like the captured browser session" do
      Req.Test.stub(@stub, fn conn ->
        assert [ua] = Plug.Conn.get_req_header(conn, "user-agent")
        assert ua =~ "Chrome/149"
        assert Plug.Conn.get_req_header(conn, "accept-language") == ["en-US,en;q=0.9"]
        assert [sec_ch_ua] = Plug.Conn.get_req_header(conn, "sec-ch-ua")
        assert sec_ch_ua =~ "Chromium"
        assert [referer] = Plug.Conn.get_req_header(conn, "referer")
        assert referer =~ "media.listerpros.com"
        assert [cookie] = Plug.Conn.get_req_header(conn, "cookie")
        assert cookie =~ "XSRF-TOKEN="
        assert Plug.Conn.get_req_header(conn, "x-xsrf-token") == ["encoded=token"]
        Req.Test.json(conn, Fixtures.listings_page(1))
      end)

      assert {:ok, _} = Listings.list_listings(Fixtures.authed_session(@stub))
    end
  end

  describe "list_all_listings/2" do
    test "walks every page and paces between requests" do
      test_pid = self()

      Req.Test.stub(@stub, fn conn ->
        page = String.to_integer(URI.decode_query(conn.query_string)["page"])
        send(test_pid, {:fetched_page, page})
        Req.Test.json(conn, Fixtures.listings_page(page))
      end)

      sleep_fn = fn ms -> send(test_pid, {:slept, ms}) end

      assert {:ok, all} =
               Listings.list_all_listings(Fixtures.authed_session(@stub),
                 sleep_fn: sleep_fn,
                 page_delay_ms: 10,
                 jitter_ms: 0
               )

      # 8 pages × 2 listings each in the fixture.
      assert length(all) == 16
      for page <- 1..8, do: assert_received({:fetched_page, ^page})
      # Paced between pages only: 7 sleeps for 8 pages.
      slept = for _ <- 1..7, do: assert_received({:slept, 10})
      assert length(slept) == 7
      refute_received {:slept, _}
    end
  end

  describe "stream_listings/2" do
    test "lazily yields listings across pages" do
      Req.Test.stub(@stub, fn conn ->
        page = String.to_integer(URI.decode_query(conn.query_string)["page"])
        Req.Test.json(conn, Fixtures.listings_page(page))
      end)

      listings =
        Fixtures.authed_session(@stub)
        |> Listings.stream_listings(sleep_fn: fn _ -> :ok end)
        |> Enum.take(3)

      assert length(listings) == 3
    end
  end

  describe "error handling" do
    test "419 session-expired maps to :unauthenticated" do
      Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 419, "") end)

      assert {:error, :unauthenticated} =
               Listings.list_listings(Fixtures.authed_session(@stub))
    end

    test "409 asset-version mismatch maps to :inertia_version_changed" do
      Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 409, "") end)

      assert {:error, :inertia_version_changed} =
               Listings.list_listings(Fixtures.authed_session(@stub))
    end

    test "429 maps to :rate_limited" do
      Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 429, "") end)

      assert {:error, :rate_limited} =
               Listings.list_listings(Fixtures.authed_session(@stub))
    end

    test "list_all_listings/2 propagates a mid-walk error as a tuple" do
      Req.Test.stub(@stub, fn conn ->
        page = String.to_integer(URI.decode_query(conn.query_string)["page"])

        if page == 2,
          do: Plug.Conn.send_resp(conn, 419, ""),
          else: Req.Test.json(conn, Fixtures.listings_page(page))
      end)

      assert {:error, :unauthenticated} =
               Listings.list_all_listings(Fixtures.authed_session(@stub),
                 sleep_fn: fn _ -> :ok end
               )
    end

    test "stream_listings/2 raises ExListerPros.Error on a mid-stream failure" do
      Req.Test.stub(@stub, fn conn ->
        page = String.to_integer(URI.decode_query(conn.query_string)["page"])

        if page == 2,
          do: Plug.Conn.send_resp(conn, 419, ""),
          else: Req.Test.json(conn, Fixtures.listings_page(page))
      end)

      assert_raise ExListerPros.Error, ~r/page 2.*unauthenticated/, fn ->
        Fixtures.authed_session(@stub)
        |> Listings.stream_listings(sleep_fn: fn _ -> :ok end)
        |> Enum.to_list()
      end
    end
  end

  describe "envelope normalization" do
    test "falls back gracefully when meta is missing" do
      Req.Test.stub(@stub, fn conn ->
        Req.Test.json(conn, %{"props" => %{"listings" => %{"data" => [%{"id" => "x"}]}}})
      end)

      assert {:ok, %{listings: [%{"id" => "x"}], pagination: pagination}} =
               Listings.list_listings(Fixtures.authed_session(@stub))

      assert pagination.current_page == 1
      assert pagination.last_page == 1
      assert pagination.next_page == nil
    end
  end
end

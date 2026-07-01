defmodule ExListerPros.Listings do
  @moduledoc """
  Read listings from an authenticated `ExListerPros.Session`.

  Listings come back as raw maps (no typed structs) alongside normalized
  pagination. The default sort is *Date Created DESC*, so page 1 is the newest —
  for a "grab new listings as they arrive" poller, fetch page 1 only and diff
  against what you've already seen.

      {:ok, %{listings: listings, pagination: page}} =
        ExListerPros.Listings.list_listings(session)

  ## Anti-bot pacing

  `stream_listings/2` and `list_all_listings/2` walk every page. To avoid
  hammering the server (and looking like a scraper) they sleep a randomized
  `page_delay_ms + rand(jitter_ms)` between page fetches. Tune or disable via
  the `:page_delay_ms` / `:jitter_ms` options.
  """

  alias ExListerPros.{Client, Session}

  @default_page_delay_ms 800
  @default_jitter_ms 1_200

  @type listing :: map()
  @type pagination :: %{
          current_page: pos_integer(),
          last_page: pos_integer(),
          per_page: pos_integer(),
          total: non_neg_integer(),
          from: non_neg_integer() | nil,
          to: non_neg_integer() | nil,
          next_page: pos_integer() | nil,
          prev_page: pos_integer() | nil
        }
  @type page :: %{listings: [listing()], pagination: pagination()}

  @doc """
  Fetches a single page of listings.

  ## Options

    - `:page` — 1-based page number (default `1`).

  Returns `{:ok, %{listings: [...], pagination: %{...}}}` or `{:error, term}`.
  """
  @spec list_listings(Session.t(), keyword()) :: {:ok, page()} | {:error, term()}
  def list_listings(%Session{} = session, opts \\ []) do
    page = Keyword.get(opts, :page, 1)

    headers = [
      {"x-inertia-partial-component", Client.listings_component()},
      {"x-inertia-partial-data", "listings"}
    ]

    case Client.inertia_get(session, "/listings", headers: headers, params: [page: page]) do
      {:ok, props} -> {:ok, normalize(props)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Fetches every page and returns all listings as one list.

  Applies the anti-bot pacing between page requests. Returns `{:error, term}` if
  any page fails.

  ## Options

    - `:page_delay_ms` — base delay between pages (default #{@default_page_delay_ms}).
    - `:jitter_ms` — random extra delay ceiling (default #{@default_jitter_ms}).
    - `:sleep_fn` — 1-arity sleeper, injectable for tests (default `Process.sleep/1`).
  """
  @spec list_all_listings(Session.t(), keyword()) :: {:ok, [listing()]} | {:error, term()}
  def list_all_listings(%Session{} = session, opts \\ []) do
    collect_pages(session, 1, [], opts)
  end

  @doc """
  Lazily streams listings across all pages, newest first.

  Emits one listing map at a time. Applies the anti-bot pacing between pages.
  Raises `ExListerPros.Error` if a page request fails mid-stream — use
  `list_all_listings/2` when you'd rather get an `{:error, _}` tuple.
  """
  @spec stream_listings(Session.t(), keyword()) :: Enumerable.t()
  def stream_listings(%Session{} = session, opts \\ []) do
    Stream.resource(
      fn -> {1, :first} end,
      fn
        :halt ->
          {:halt, nil}

        {page_num, phase} ->
          if phase != :first, do: pace(opts)

          case list_listings(session, Keyword.put(opts, :page, page_num)) do
            {:ok, %{listings: listings, pagination: %{last_page: last}}} ->
              next = if page_num >= last, do: :halt, else: {page_num + 1, :more}
              {listings, next}

            {:error, reason} ->
              raise ExListerPros.Error, reason: reason, page: page_num
          end
      end,
      fn _ -> :ok end
    )
  end

  # --- internals --------------------------------------------------------------

  defp collect_pages(session, page_num, acc, opts) do
    if page_num > 1, do: pace(opts)

    case list_listings(session, Keyword.put(opts, :page, page_num)) do
      {:ok, %{listings: listings, pagination: %{last_page: last}}} ->
        acc = acc ++ listings

        if page_num >= last,
          do: {:ok, acc},
          else: collect_pages(session, page_num + 1, acc, opts)

      {:error, _} = err ->
        err
    end
  end

  defp normalize(%{"listings" => %{"data" => data, "meta" => meta}}) do
    %{listings: data, pagination: normalize_meta(meta)}
  end

  # Defensive fallback if the envelope shape drifts.
  defp normalize(props) do
    data = get_in(props, ["listings", "data"]) || []
    meta = get_in(props, ["listings", "meta"]) || %{}
    %{listings: data, pagination: normalize_meta(meta)}
  end

  defp normalize_meta(meta) do
    current = meta["current_page"] || 1
    last = meta["last_page"] || current

    %{
      current_page: current,
      last_page: last,
      per_page: meta["per_page"],
      total: meta["total"],
      from: meta["from"],
      to: meta["to"],
      next_page: if(current < last, do: current + 1, else: nil),
      prev_page: if(current > 1, do: current - 1, else: nil)
    }
  end

  defp pace(opts) do
    base = Keyword.get(opts, :page_delay_ms, @default_page_delay_ms)
    jitter = Keyword.get(opts, :jitter_ms, @default_jitter_ms)
    sleep_fn = Keyword.get(opts, :sleep_fn, &Process.sleep/1)

    extra = if jitter > 0, do: :rand.uniform(jitter), else: 0
    sleep_fn.(base + extra)
  end
end

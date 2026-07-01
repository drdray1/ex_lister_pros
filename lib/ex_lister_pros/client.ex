defmodule ExListerPros.Client do
  @moduledoc """
  Low-level HTTP for a `ExListerPros.Session`.

  Every request is dressed to look exactly like the browser the session belongs
  to — a real Chrome `User-Agent`, client-hints, `sec-fetch-*`, `Referer` /
  `Origin`, plus the session `Cookie` and `X-XSRF-TOKEN` header. Combined with
  reusing one session across polls (rather than re-logging-in) and the polite
  pacing in `ExListerPros.Listings`, this keeps the automated session from being
  flagged as a bot.
  """

  alias ExListerPros.Session

  @type response :: {:ok, term()} | {:error, term()}

  # Mirror the captured browser exactly. Bump these when Chrome ships a new
  # major or ListerPros changes the tenant host.
  @user_agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " <>
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36"
  @sec_ch_ua ~s|"Chromium";v="149", "Not)A;Brand";v="24"|
  @sec_ch_ua_platform ~s|"macOS"|

  # Inertia partial-reload identifiers for the customer listings index.
  @listings_component "Customer/Listings/IndexListing"

  @doc "The Inertia component name behind the listings page."
  @spec listings_component() :: String.t()
  def listings_component, do: @listings_component

  @doc """
  Performs a raw request for `session`, returning the full `Req.Response` (so
  callers can read `Set-Cookie`). Merges the browser base headers, cookie jar,
  and XSRF header; `opts[:headers]` are appended, `opts[:json]`/`opts[:params]`
  passed through.
  """
  @spec raw_request(Session.t(), atom(), String.t(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, term()}
  def raw_request(%Session{} = session, method, path, opts) do
    req_opts =
      [
        method: method,
        base_url: session.base_url,
        url: path,
        headers: headers(session, Keyword.get(opts, :headers, []))
      ]
      |> Keyword.merge(retry_opts(session.plug))
      |> maybe_put(:json, Keyword.get(opts, :json))
      |> maybe_put(:params, Keyword.get(opts, :params))
      |> maybe_plug(session.plug)

    Req.request(req_opts)
  end

  @doc """
  Issues an authenticated Inertia partial reload of `path` and normalizes the
  result via `handle_response/1`. Used for GET data endpoints once logged in.
  """
  @spec inertia_get(Session.t(), String.t(), keyword()) :: response()
  def inertia_get(%Session{} = session, path, opts) do
    inertia_headers = [
      {"x-inertia", "true"},
      {"x-inertia-version", session.inertia_version || ""},
      {"accept", "text/html, application/xhtml+xml"}
      | Keyword.get(opts, :headers, [])
    ]

    session
    |> raw_request(:get, path, Keyword.put(opts, :headers, inertia_headers))
    |> handle_response()
  end

  @doc """
  Normalizes an Inertia/JSON response to `{:ok, props}` or `{:error, term}`.
  """
  @spec handle_response({:ok, Req.Response.t()} | {:error, term()}) :: response()
  def handle_response({:ok, %Req.Response{status: status, body: %{"props" => props}}})
      when status in 200..299,
      do: {:ok, props}

  def handle_response({:ok, %Req.Response{status: status, body: body}})
      when status in 200..299,
      do: {:ok, body}

  # Inertia asset-version mismatch — the app was redeployed; caller must refresh.
  def handle_response({:ok, %Req.Response{status: 409}}),
    do: {:error, :inertia_version_changed}

  def handle_response({:ok, %Req.Response{status: status}}) when status in [401, 419],
    do: {:error, :unauthenticated}

  def handle_response({:ok, %Req.Response{status: 403}}), do: {:error, :forbidden}
  def handle_response({:ok, %Req.Response{status: 404}}), do: {:error, :not_found}
  def handle_response({:ok, %Req.Response{status: 429}}), do: {:error, :rate_limited}

  def handle_response({:ok, %Req.Response{status: status}}) when status >= 400,
    do: {:error, {:unexpected_status, status}}

  def handle_response({:error, reason}), do: {:error, {:connection_error, reason}}

  # --- Headers ----------------------------------------------------------------

  @doc "The browser-identical base headers plus session cookie / XSRF headers."
  @spec headers(Session.t(), [{String.t(), String.t()}]) :: [{String.t(), String.t()}]
  def headers(%Session{} = session, extra) do
    base_headers(session.base_url) ++
      cookie_headers(session) ++
      extra
  end

  defp base_headers(base_url) do
    [
      {"user-agent", user_agent()},
      {"accept-language", "en-US,en;q=0.9"},
      {"sec-ch-ua", @sec_ch_ua},
      {"sec-ch-ua-mobile", "?0"},
      {"sec-ch-ua-platform", @sec_ch_ua_platform},
      {"sec-fetch-dest", "empty"},
      {"sec-fetch-mode", "cors"},
      {"sec-fetch-site", "same-origin"},
      {"x-requested-with", "XMLHttpRequest"},
      {"origin", base_url},
      {"referer", base_url <> "/"}
    ]
  end

  defp cookie_headers(%Session{cookies: cookies} = session) do
    cookie =
      if map_size(cookies) > 0,
        do: [{"cookie", Session.cookie_header(session)}],
        else: []

    xsrf =
      case session.xsrf_token do
        nil -> []
        token -> [{"x-xsrf-token", token}]
      end

    cookie ++ xsrf
  end

  @doc "The User-Agent string (overridable via `config :ex_lister_pros, :user_agent`)."
  @spec user_agent() :: String.t()
  def user_agent, do: Application.get_env(:ex_lister_pros, :user_agent, @user_agent)

  # Retry transient errors / 429s in the real client; disable under a test plug
  # so stubbed error responses return immediately and deterministically.
  defp retry_opts(nil),
    do: [retry: :transient, max_retries: 3, retry_delay: &retry_delay/1]

  defp retry_opts(_plug), do: [retry: false]

  # Exponential backoff for transient errors / 429s.
  defp retry_delay(attempt), do: 500 * Integer.pow(2, attempt)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_plug(opts, nil), do: opts
  defp maybe_plug(opts, plug), do: Keyword.put(opts, :plug, plug)
end

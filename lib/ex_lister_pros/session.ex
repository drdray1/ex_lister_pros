defmodule ExListerPros.Session do
  @moduledoc """
  An authenticated ListerPros browser session.

  ListerPros (a white-label of Aryeo) has no public API — it's a Laravel +
  Inertia.js app authenticated with a session cookie + XSRF token. Since `Req`
  has no built-in cookie jar, a `%Session{}` carries that state explicitly:
  the cookie jar, the decoded XSRF token, the Inertia asset version, and the
  tenant `company_id` (all bootstrapped from the `/login` page).

  Build one with `login/3`, then hand it to `ExListerPros.Listings`. Reuse the
  same session across polls — re-authenticating on every request is the biggest
  "this is a bot" tell (see `ExListerPros.Client`).

      {:ok, session} = ExListerPros.Session.login("me@example.com", "secret")
      {:ok, page} = ExListerPros.Listings.list_listings(session)
  """

  alias ExListerPros.Client

  @default_base_url "https://media.listerpros.com"

  @type t :: %__MODULE__{
          base_url: String.t(),
          cookies: %{optional(String.t()) => String.t()},
          xsrf_token: String.t() | nil,
          inertia_version: String.t() | nil,
          company_id: String.t() | nil,
          plug: term() | nil
        }

  defstruct base_url: @default_base_url,
            cookies: %{},
            xsrf_token: nil,
            inertia_version: nil,
            company_id: nil,
            plug: nil

  @doc """
  Authenticates against ListerPros and returns a ready-to-use `%Session{}`.

  Replicates the browser's two-step login exactly:

    1. `GET /login` — bootstrap the XSRF cookie, Inertia asset version, and the
       tenant `company_id` (read from the page's Inertia `data-page` payload).
    2. `POST /v1/auth/email-check` — confirm the account exists / is active.
    3. `POST /v1/login` — submit the password; the response sets the
       authenticated session cookie.

  ## Options

    - `:base_url` — override the ListerPros host (default `#{@default_base_url}`).
    - `:plug` — a `{Req.Test, stub}` plug for testing.
    - `:skip_email_check` — skip step 2 (default `false`).

  ## Returns

    - `{:ok, %Session{}}`
    - `{:error, :account_not_found}` — email-check reported no active account
    - `{:error, :invalid_credentials}` — password rejected (HTTP 401/422)
    - `{:error, term}` — transport / unexpected error
  """
  @spec login(String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def login(email, password, opts \\ []) when is_binary(email) and is_binary(password) do
    session = %__MODULE__{
      base_url: Keyword.get(opts, :base_url, @default_base_url),
      plug: Keyword.get(opts, :plug)
    }

    with {:ok, session} <- bootstrap(session),
         {:ok, session} <- maybe_email_check(session, email, opts),
         {:ok, session} <- submit_password(session, email, password) do
      {:ok, session}
    end
  end

  # --- Step 1: GET /login -----------------------------------------------------

  defp bootstrap(session) do
    case Client.raw_request(session, :get, "/login", []) do
      {:ok, %Req.Response{status: status, body: body} = resp} when status in 200..299 ->
        session = merge_set_cookies(session, resp)

        case parse_data_page(body) do
          {:ok, page} ->
            {:ok,
             %{
               session
               | inertia_version: page["version"],
                 company_id: get_in(page, ["props", "tenant", "company", "id"])
             }}

          {:error, _} = err ->
            err
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  # --- Step 2: POST /v1/auth/email-check --------------------------------------

  defp maybe_email_check(session, email, opts) do
    if Keyword.get(opts, :skip_email_check, false) do
      {:ok, session}
    else
      body = %{"email" => email, "company_id" => session.company_id}

      case Client.raw_request(session, :post, "/v1/auth/email-check", json: body) do
        {:ok, %Req.Response{status: status, body: %{"status" => "ACTIVE"}} = resp}
        when status in 200..299 ->
          {:ok, merge_set_cookies(session, resp)}

        {:ok, %Req.Response{status: status}} when status in 200..299 ->
          {:error, :account_not_found}

        {:ok, %Req.Response{status: status}} ->
          {:error, {:unexpected_status, status}}

        {:error, reason} ->
          {:error, {:connection_error, reason}}
      end
    end
  end

  # --- Step 3: POST /v1/login -------------------------------------------------

  defp submit_password(session, email, password) do
    body = %{
      "email" => email,
      "password" => password,
      "company_id" => session.company_id,
      "client" => "Web"
    }

    case Client.raw_request(session, :post, "/v1/login", json: body) do
      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        {:ok, merge_set_cookies(session, resp)}

      {:ok, %Req.Response{status: status}} when status in [401, 419, 422] ->
        {:error, :invalid_credentials}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  # --- Cookie jar -------------------------------------------------------------

  @doc """
  Merges the `Set-Cookie` headers from a response into the session's cookie jar,
  refreshing the decoded XSRF token whenever the `XSRF-TOKEN` cookie rotates.
  """
  @spec merge_set_cookies(t(), Req.Response.t()) :: t()
  def merge_set_cookies(session, %Req.Response{} = resp) do
    new_cookies =
      resp
      |> Req.Response.get_header("set-cookie")
      |> Enum.map(&parse_set_cookie/1)
      |> Enum.reject(&is_nil/1)
      |> Map.new()

    cookies = Map.merge(session.cookies, new_cookies)

    xsrf =
      case Map.get(cookies, "XSRF-TOKEN") do
        nil -> session.xsrf_token
        raw -> URI.decode(raw)
      end

    %{session | cookies: cookies, xsrf_token: xsrf}
  end

  @doc """
  Renders the cookie jar as a `Cookie` request-header value.
  """
  @spec cookie_header(t()) :: String.t()
  def cookie_header(%__MODULE__{cookies: cookies}) do
    cookies
    |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
    |> Enum.join("; ")
  end

  # Takes the leading `name=value` pair off a Set-Cookie string, dropping attrs.
  defp parse_set_cookie(value) when is_binary(value) do
    case String.split(value, ";", parts: 2) do
      [pair | _] ->
        case String.split(pair, "=", parts: 2) do
          [name, val] -> {String.trim(name), String.trim(val)}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_set_cookie(_), do: nil

  # --- Inertia data-page parsing ----------------------------------------------

  @doc """
  Extracts and decodes the Inertia `data-page` payload from the `/login` HTML.
  """
  @spec parse_data_page(binary()) :: {:ok, map()} | {:error, term()}
  def parse_data_page(html) when is_binary(html) do
    with {:ok, document} <- Floki.parse_document(html),
         [json | _] when is_binary(json) <-
           Floki.attribute(document, "#app", "data-page"),
         {:ok, page} <- Jason.decode(json) do
      {:ok, page}
    else
      [] -> {:error, :inertia_page_not_found}
      {:error, _} = err -> err
      other -> {:error, {:invalid_data_page, other}}
    end
  end

  def parse_data_page(_), do: {:error, :invalid_login_page}
end

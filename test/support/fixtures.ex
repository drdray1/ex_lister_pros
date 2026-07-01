defmodule ExListerPros.Fixtures do
  @moduledoc """
  Test fixtures for ExListerPros, seeded from a real captured HAR response.
  """

  alias ExListerPros.Session

  @company_id "test-company-id"
  @version "testversion123"

  def company_id, do: @company_id
  def inertia_version, do: @version

  @doc "A session that is already authenticated, wired to a `Req.Test` stub."
  def authed_session(stub_name) do
    %Session{
      base_url: "https://media.listerpros.com",
      cookies: %{"XSRF-TOKEN" => "encoded%3Dtoken", "listerpros_session" => "abc123"},
      xsrf_token: "encoded=token",
      inertia_version: @version,
      company_id: @company_id,
      plug: {Req.Test, stub_name}
    }
  end

  @doc "A blank session wired to a `Req.Test` stub, for exercising `login/3`."
  def login_session(stub_name) do
    %Session{base_url: "https://media.listerpros.com", plug: {Req.Test, stub_name}}
  end

  @doc "The trimmed real listings index response (page 1 of 8, 92 total)."
  def listings_index do
    Path.join(__DIR__, "listings_index.json")
    |> File.read!()
    |> Jason.decode!()
  end

  @doc """
  Builds a listings index response for an arbitrary page, cloning the fixture's
  data and rewriting the pagination meta. Used to test multi-page walking.
  """
  def listings_page(page, last_page \\ 8, per_page \\ 12, total \\ 92) do
    base = listings_index()

    meta = %{
      "current_page" => page,
      "last_page" => last_page,
      "per_page" => per_page,
      "total" => total,
      "from" => (page - 1) * per_page + 1,
      "to" => min(page * per_page, total)
    }

    put_in(base, ["props", "listings", "meta"], meta)
  end

  @doc "The `/login` HTML page carrying the Inertia `data-page` bootstrap payload."
  def login_html do
    data_page =
      %{
        "component" => "Customer/Core/Login/ShowLogin",
        "version" => @version,
        "props" => %{
          "csrf_token" => "csrf-abc",
          "tenant" => %{"company" => %{"id" => @company_id, "name" => "ListerPros"}}
        }
      }
      |> Jason.encode!()
      |> escape_attr()

    """
    <!DOCTYPE html>
    <html><head><meta name="csrf-token" content="csrf-abc"></head>
    <body><div id="app" data-page="#{data_page}"></div></body></html>
    """
  end

  # Minimal HTML-attribute escaping so Floki decodes it back to JSON.
  defp escape_attr(string) do
    string
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
  end
end

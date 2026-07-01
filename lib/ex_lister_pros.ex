defmodule ExListerPros do
  @moduledoc """
  Elixir client for [ListerPros](https://media.listerpros.com) — the photo /
  listing vendor, which runs on a white-labeled [Aryeo](https://aryeo.com)
  Laravel + Inertia.js app.

  ListerPros has no public API, so this library authenticates with a normal web
  login and reads the same JSON the browser's Inertia layer receives. It is
  built to look like a real browser session and to poll politely so the account
  is not flagged as a bot — see `ExListerPros.Client` and
  `ExListerPros.Listings`.

  ## Usage

      {:ok, session} = ExListerPros.login("you@example.com", "secret")

      # Newest listings (page 1) — the typical "what's new" poll:
      {:ok, %{listings: listings, pagination: page}} =
        ExListerPros.list_listings(session)

      # Every listing across all pages (paced to avoid bot detection):
      {:ok, all} = ExListerPros.list_all_listings(session)

  Reuse a single `session` across polls; only call `login/3` again after an
  `{:error, :unauthenticated}`.
  """

  alias ExListerPros.{Listings, Session}

  defdelegate login(email, password, opts \\ []), to: Session
  defdelegate list_listings(session, opts \\ []), to: Listings
  defdelegate list_all_listings(session, opts \\ []), to: Listings
  defdelegate stream_listings(session, opts \\ []), to: Listings
  defdelegate get_listing(session, id, opts \\ []), to: Listings
end

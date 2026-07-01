# ExListerPros

Elixir client for [ListerPros](https://media.listerpros.com) — Capital West's
photo/listing vendor, which runs on a white-labeled [Aryeo](https://aryeo.com)
Laravel + Inertia.js app.

ListerPros exposes **no public API**, so this library authenticates with a
normal web login and reads the same JSON the browser's Inertia layer receives.
It is deliberately built to look like a real browser session and to poll
politely, so the account is not flagged as a bot.

## Installation

```elixir
def deps do
  [
    {:ex_lister_pros, git: "https://github.com/drdray1/ex_lister_pros.git", tag: "0.1.0"}
  ]
end
```

## Usage

```elixir
{:ok, session} = ExListerPros.login("you@example.com", "secret")

# Newest listings (page 1) — the typical "what's new" poll:
{:ok, %{listings: listings, pagination: page}} = ExListerPros.list_listings(session)

# Every listing across all pages (paced to avoid bot detection):
{:ok, all} = ExListerPros.list_all_listings(session)

# Lazily stream listings, newest first:
session |> ExListerPros.stream_listings() |> Enum.take(20)

# Full detail for one listing, including its photo/video/floorplan galleries
# (the index only carries a single thumbnail). Pass the listing's `id`:
{:ok, listing} = ExListerPros.get_listing(session, "aryeo-listing-id")
listing["images"] # => [%{"original_url" => ..., "large_url" => ..., ...}, ...]
```

Each listing is a raw map (`id`, `slug`, `address`, `delivery_status`,
`payment_status`, `price`, `thumbnail_url`, `orders`, …). `pagination` is
normalized to `%{current_page, last_page, per_page, total, from, to, next_page,
prev_page}`. `get_listing/3` additionally merges the `images`, `videos`, and
`floorplans` galleries onto the returned listing map.

## How auth works

`login/3` replicates the browser's two-step flow exactly:

1. `GET /login` — bootstraps the XSRF cookie, the Inertia asset version, and the
   tenant `company_id` (read from the page's Inertia `data-page` payload).
2. `POST /v1/auth/email-check` — confirms the account is active.
3. `POST /v1/login` — submits the password; the response sets the authenticated
   session cookie.

The returned `%ExListerPros.Session{}` carries the cookie jar, decoded XSRF
token, Inertia version, and `company_id`. **Reuse one session across polls** —
re-authenticating on every request is the biggest "this is a bot" tell. Only
call `login/3` again after an `{:error, :unauthenticated}`.

## Staying under the radar

- Every request sends browser-identical headers (real Chrome `User-Agent`,
  client-hints, `sec-fetch-*`, `Referer`/`Origin`) plus the session cookie and
  `X-XSRF-TOKEN`.
- `list_all_listings/2` and `stream_listings/2` sleep a randomized
  `page_delay_ms + rand(jitter_ms)` between page fetches (defaults 800ms +
  0–1200ms). Tune with `:page_delay_ms` / `:jitter_ms`.
- For a "new listings" poller, fetch **page 1 only** and diff against what you've
  already stored; poll on a modest interval (e.g. every 15–30 min), not a tight
  loop.

## Configuration

Override the User-Agent if Chrome's version drifts:

```elixir
config :ex_lister_pros, :user_agent, "Mozilla/5.0 (...) Chrome/XYZ ..."
```

Point at a different host (e.g. for testing) via the `:base_url` option to
`login/3`.

## Testing

```
mix test
```

Tests use `Req.Test` stubs seeded from a real captured response — no network
access required.

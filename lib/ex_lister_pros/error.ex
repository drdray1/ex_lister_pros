defmodule ExListerPros.Error do
  @moduledoc """
  Raised by streaming helpers (e.g. `ExListerPros.Listings.stream_listings/2`)
  when a page request fails mid-iteration and there's no tuple to return.
  """

  defexception [:reason, :page]

  @impl true
  def message(%__MODULE__{reason: reason, page: page}) do
    "ListerPros request failed on page #{inspect(page)}: #{inspect(reason)}"
  end
end

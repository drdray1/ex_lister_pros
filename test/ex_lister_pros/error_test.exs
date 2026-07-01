defmodule ExListerPros.ErrorTest do
  use ExUnit.Case, async: true

  test "message/1 includes the page and reason" do
    error = %ExListerPros.Error{reason: :unauthenticated, page: 3}
    assert Exception.message(error) =~ "page 3"
    assert Exception.message(error) =~ "unauthenticated"
  end
end

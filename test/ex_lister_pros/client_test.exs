defmodule ExListerPros.ClientTest do
  use ExUnit.Case, async: true

  alias ExListerPros.Client

  describe "handle_response/1" do
    test "unwraps Inertia props on success" do
      resp = %Req.Response{status: 200, body: %{"props" => %{"listings" => %{}}}}
      assert {:ok, %{"listings" => %{}}} = Client.handle_response({:ok, resp})
    end

    test "returns the raw body when there is no props envelope" do
      resp = %Req.Response{status: 200, body: %{"status" => "ACTIVE"}}
      assert {:ok, %{"status" => "ACTIVE"}} = Client.handle_response({:ok, resp})
    end

    test "maps known status codes to atoms" do
      assert {:error, :inertia_version_changed} =
               Client.handle_response({:ok, %Req.Response{status: 409}})

      assert {:error, :unauthenticated} =
               Client.handle_response({:ok, %Req.Response{status: 401}})

      assert {:error, :unauthenticated} =
               Client.handle_response({:ok, %Req.Response{status: 419}})

      assert {:error, :forbidden} = Client.handle_response({:ok, %Req.Response{status: 403}})
      assert {:error, :not_found} = Client.handle_response({:ok, %Req.Response{status: 404}})
      assert {:error, :rate_limited} = Client.handle_response({:ok, %Req.Response{status: 429}})
    end

    test "maps other 4xx/5xx to :unexpected_status" do
      assert {:error, {:unexpected_status, 500}} =
               Client.handle_response({:ok, %Req.Response{status: 500}})
    end

    test "wraps transport errors" do
      assert {:error, {:connection_error, :timeout}} =
               Client.handle_response({:error, :timeout})
    end
  end

  describe "user_agent/0" do
    test "defaults to the captured Chrome UA" do
      assert Client.user_agent() =~ "Chrome/149"
    end

    test "is overridable via application config" do
      Application.put_env(:ex_lister_pros, :user_agent, "Custom/1.0")
      on_exit(fn -> Application.delete_env(:ex_lister_pros, :user_agent) end)
      assert Client.user_agent() == "Custom/1.0"
    end
  end

  test "listings_component/0 returns the Inertia component name" do
    assert Client.listings_component() == "Customer/Listings/IndexListing"
  end
end

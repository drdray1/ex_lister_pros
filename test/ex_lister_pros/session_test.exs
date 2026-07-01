defmodule ExListerPros.SessionTest do
  use ExUnit.Case, async: true

  alias ExListerPros.{Fixtures, Session}

  @stub __MODULE__.Stub

  describe "login/3" do
    test "runs the full GET /login -> email-check -> /v1/login flow" do
      test_pid = self()

      Req.Test.stub(@stub, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/login"} ->
            conn
            |> Plug.Conn.put_resp_header("set-cookie", "XSRF-TOKEN=login%3Dxsrf; path=/")
            |> Plug.Conn.put_resp_content_type("text/html")
            |> Plug.Conn.send_resp(200, Fixtures.login_html())

          {"POST", "/v1/auth/email-check"} ->
            body = read_json(conn)
            send(test_pid, {:email_check, body})
            Req.Test.json(conn, %{"status" => "ACTIVE", "has_admin_account" => false})

          {"POST", "/v1/login"} ->
            body = read_json(conn)
            send(test_pid, {:login, body})

            conn
            |> Plug.Conn.put_resp_header(
              "set-cookie",
              "listerpros_session=sess-999; path=/; httponly"
            )
            |> Req.Test.json(%{"data" => %{"redirect" => "/dashboard"}})
        end
      end)

      assert {:ok, session} =
               Session.login("you@example.com", "hunter2", plug: {Req.Test, @stub})

      # Bootstrap values came from the login page's data-page payload.
      assert session.company_id == Fixtures.company_id()
      assert session.inertia_version == Fixtures.inertia_version()
      # XSRF cookie was captured and decoded for the header.
      assert session.xsrf_token == "login=xsrf"
      # Authenticated session cookie merged into the jar.
      assert session.cookies["listerpros_session"] == "sess-999"

      # email-check carried email + tenant company_id.
      assert_received {:email_check, %{"email" => "you@example.com", "company_id" => company_id}}

      assert company_id == Fixtures.company_id()

      # password submit carried the exact field set the browser sends.
      assert_received {:login, login_body}

      assert login_body == %{
               "email" => "you@example.com",
               "password" => "hunter2",
               "company_id" => Fixtures.company_id(),
               "client" => "Web"
             }
    end

    test "returns :account_not_found when email-check is not ACTIVE" do
      Req.Test.stub(@stub, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/login"} -> send_login_page(conn)
          {"POST", "/v1/auth/email-check"} -> Req.Test.json(conn, %{"status" => "INACTIVE"})
        end
      end)

      assert {:error, :account_not_found} =
               Session.login("nobody@example.com", "x", plug: {Req.Test, @stub})
    end

    test "returns :invalid_credentials when /v1/login rejects the password" do
      Req.Test.stub(@stub, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/login"} -> send_login_page(conn)
          {"POST", "/v1/auth/email-check"} -> Req.Test.json(conn, %{"status" => "ACTIVE"})
          {"POST", "/v1/login"} -> Plug.Conn.send_resp(conn, 422, "")
        end
      end)

      assert {:error, :invalid_credentials} =
               Session.login("me@example.com", "wrong", plug: {Req.Test, @stub})
    end

    test "skip_email_check option bypasses the email-check call" do
      test_pid = self()

      Req.Test.stub(@stub, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/login"} ->
            send_login_page(conn)

          {"POST", "/v1/auth/email-check"} ->
            send(test_pid, :email_check_called)
            Req.Test.json(conn, %{"status" => "ACTIVE"})

          {"POST", "/v1/login"} ->
            Req.Test.json(conn, %{"data" => %{}})
        end
      end)

      assert {:ok, _session} =
               Session.login("me@example.com", "pw",
                 plug: {Req.Test, @stub},
                 skip_email_check: true
               )

      refute_received :email_check_called
    end

    test "surfaces an unexpected status from GET /login" do
      Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)

      assert {:error, {:unexpected_status, 503}} =
               Session.login("me@example.com", "pw", plug: {Req.Test, @stub})
    end

    test "surfaces an unexpected status from email-check" do
      Req.Test.stub(@stub, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/login"} -> send_login_page(conn)
          {"POST", "/v1/auth/email-check"} -> Plug.Conn.send_resp(conn, 500, "")
        end
      end)

      assert {:error, {:unexpected_status, 500}} =
               Session.login("me@example.com", "pw", plug: {Req.Test, @stub})
    end

    test "surfaces an unexpected status from /v1/login" do
      Req.Test.stub(@stub, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/login"} -> send_login_page(conn)
          {"POST", "/v1/auth/email-check"} -> Req.Test.json(conn, %{"status" => "ACTIVE"})
          {"POST", "/v1/login"} -> Plug.Conn.send_resp(conn, 500, "")
        end
      end)

      assert {:error, {:unexpected_status, 500}} =
               Session.login("me@example.com", "pw", plug: {Req.Test, @stub})
    end
  end

  describe "parse_data_page/1" do
    test "extracts and decodes the Inertia payload" do
      assert {:ok, page} = Session.parse_data_page(Fixtures.login_html())
      assert page["version"] == Fixtures.inertia_version()
      assert get_in(page, ["props", "tenant", "company", "id"]) == Fixtures.company_id()
    end

    test "errors when the #app node is missing" do
      assert {:error, :inertia_page_not_found} =
               Session.parse_data_page("<html><body>nope</body></html>")
    end
  end

  describe "cookie jar" do
    test "merge_set_cookies/2 accumulates cookies and decodes the XSRF token" do
      resp = %Req.Response{
        status: 200,
        headers: %{
          "set-cookie" => [
            "XSRF-TOKEN=abc%3D%3D; path=/; secure",
            "listerpros_session=zzz; path=/; httponly"
          ]
        }
      }

      session = Session.merge_set_cookies(%Session{}, resp)

      assert session.cookies["XSRF-TOKEN"] == "abc%3D%3D"
      assert session.cookies["listerpros_session"] == "zzz"
      assert session.xsrf_token == "abc=="
    end

    test "cookie_header/1 renders name=value pairs" do
      session = %Session{cookies: %{"a" => "1", "b" => "2"}}
      header = Session.cookie_header(session)
      assert header =~ "a=1"
      assert header =~ "b=2"
    end
  end

  defp send_login_page(conn) do
    conn
    |> Plug.Conn.put_resp_header("set-cookie", "XSRF-TOKEN=login%3Dxsrf; path=/")
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(200, Fixtures.login_html())
  end

  defp read_json(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    Jason.decode!(body)
  end
end

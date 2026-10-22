# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.BearerTokenTest do
  # The token cache is shared by all processes, and tokens are fetched from many of them.
  use ExUnit.Case, async: false
  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  defmodule Api do
    use Tesla

    adapter(AshJsonApiWrapper.MockAdapter)

    plug(AshJsonApiWrapper.Tesla.BearerToken,
      config: {:ash_json_api_wrapper, :bearer_token_test},
      adapter: AshJsonApiWrapper.MockAdapter
    )
  end

  @api "https://api.example.com/things"

  # Each test gets its own token endpoint, so cached tokens do not leak between tests.
  setup do
    token_url = "https://login.example.com/#{System.unique_integer([:positive])}/token"

    Application.put_env(:ash_json_api_wrapper, :bearer_token_test,
      token_url: token_url,
      client_id: "client-id",
      client_secret: "client-secret",
      scope: "https://api.example.com/.default"
    )

    on_exit(fn -> Application.delete_env(:ash_json_api_wrapper, :bearer_token_test) end)
    %{token_url: token_url}
  end

  defp token_response(token, expires_in \\ 3599) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body:
         Jason.encode!(%{
           "token_type" => "Bearer",
           "expires_in" => expires_in,
           "access_token" => token
         })
     }}
  end

  defp ok, do: {:ok, %Tesla.Env{status: 200, body: "{}"}}

  defp authorization(env), do: Tesla.get_header(env, "authorization")

  test "fetches a token with client credentials and caches it", %{token_url: token_url} do
    expect(AshJsonApiWrapper.MockAdapter, :call, 3, fn
      %{url: ^token_url} = env, _ ->
        assert env.method == :post
        assert Tesla.get_header(env, "content-type") == "application/x-www-form-urlencoded"

        assert URI.decode_query(env.body) == %{
                 "grant_type" => "client_credentials",
                 "client_id" => "client-id",
                 "client_secret" => "client-secret",
                 "scope" => "https://api.example.com/.default"
               }

        token_response("token-1")

      %{url: @api} = env, _ ->
        assert authorization(env) == "Bearer token-1"
        ok()
    end)

    assert {:ok, %{status: 200}} = Api.get(@api)
    assert {:ok, %{status: 200}} = Api.get(@api)
  end

  test "gets a new token before the old one expires", %{token_url: token_url} do
    counter = :counters.new(1, [])

    expect(AshJsonApiWrapper.MockAdapter, :call, 4, fn
      %{url: ^token_url}, _ ->
        :counters.add(counter, 1, 1)
        # Valid for less than the default 60 seconds of `refresh_before`.
        token_response("token-#{:counters.get(counter, 1)}", 30)

      %{url: @api} = env, _ ->
        send(self(), {:authorization, authorization(env)})
        ok()
    end)

    Api.get(@api)
    Api.get(@api)

    assert_received {:authorization, "Bearer token-1"}
    assert_received {:authorization, "Bearer token-2"}
  end

  test "concurrent requests share one refresh", %{token_url: token_url} do
    expect(AshJsonApiWrapper.MockAdapter, :call, 21, fn
      %{url: ^token_url}, _ ->
        Process.sleep(100)
        token_response("shared")

      %{url: @api} = env, _ ->
        assert authorization(env) == "Bearer shared"
        ok()
    end)

    1..20
    |> Task.async_stream(fn _ -> Api.get(@api) end, max_concurrency: 20)
    |> Enum.each(fn result -> assert {:ok, {:ok, %{status: 200}}} = result end)
  end

  test "a 401 triggers one refresh and retry", %{token_url: token_url} do
    counter = :counters.new(1, [])

    expect(AshJsonApiWrapper.MockAdapter, :call, 8, fn
      %{url: ^token_url}, _ ->
        :counters.add(counter, 1, 1)
        token_response("token-#{:counters.get(counter, 1)}")

      %{url: @api} = env, _ ->
        case authorization(env) do
          "Bearer token-1" -> {:ok, %Tesla.Env{status: 401, body: ""}}
          "Bearer token-2" -> ok()
          # Every token is rejected from here on.
          _ -> {:ok, %Tesla.Env{status: 401, body: ""}}
        end
    end)

    assert {:ok, %{status: 200}} = Api.get(@api)

    # A token that keeps being rejected is retried once, not forever.
    :counters.put(counter, 1, 10)
    AshJsonApiWrapper.TokenCache.invalidate(cache_key(token_url), "token-2")
    assert {:ok, %{status: 401}} = Api.get(@api)
  end

  test "credentials are read from the application environment on every request",
       %{token_url: token_url} do
    expect(AshJsonApiWrapper.MockAdapter, :call, 4, fn
      %{url: ^token_url} = env, _ ->
        token_response("for-" <> URI.decode_query(env.body)["client_id"])

      %{url: @api} = env, _ ->
        send(self(), {:authorization, authorization(env)})
        ok()
    end)

    Api.get(@api)

    config = Application.get_env(:ash_json_api_wrapper, :bearer_token_test)

    Application.put_env(
      :ash_json_api_wrapper,
      :bearer_token_test,
      Keyword.put(config, :client_id, "rotated")
    )

    Api.get(@api)

    assert_received {:authorization, "Bearer for-client-id"}
    assert_received {:authorization, "Bearer for-rotated"}
  end

  test "custom grants exchange other credentials, e.g. an API key", %{token_url: token_url} do
    Application.put_env(:ash_json_api_wrapper, :bearer_token_test,
      token_url: token_url,
      grant: :custom,
      body_format: :json,
      params: %{"apiKey" => "key"},
      token_key: "token",
      expires_in_key: "ttl"
    )

    expect(AshJsonApiWrapper.MockAdapter, :call, 2, fn
      %{url: ^token_url} = env, _ ->
        assert Jason.decode!(env.body) == %{"apiKey" => "key"}
        {:ok, %Tesla.Env{status: 200, body: ~s({"token": "from-key", "ttl": "600"})}}

      %{url: @api} = env, _ ->
        assert authorization(env) == "Bearer from-key"
        ok()
    end)

    assert {:ok, %{status: 200}} = Api.get(@api)
  end

  test "a failing token request is returned as an error", %{token_url: token_url} do
    expect(AshJsonApiWrapper.MockAdapter, :call, fn %{url: ^token_url}, _ ->
      {:ok, %Tesla.Env{status: 400, body: ~s({"error": "invalid_client"})}}
    end)

    assert {:error, message} = Api.get(@api)
    assert message =~ "failed with status 400"
    assert message =~ "invalid_client"
  end

  test "the next waiting caller takes over when the refreshing one dies" do
    key = make_ref()
    test = self()

    refresher =
      spawn(fn ->
        AshJsonApiWrapper.TokenCache.fetch(key, fn ->
          send(test, :refreshing)
          Process.sleep(:infinity)
        end)
      end)

    assert_receive :refreshing

    waiter =
      Task.async(fn -> AshJsonApiWrapper.TokenCache.fetch(key, fn -> {:ok, "next", 600} end) end)

    Process.sleep(50)
    Process.exit(refresher, :kill)

    assert {:ok, "next"} = Task.await(waiter)
  end

  defp cache_key(token_url) do
    {AshJsonApiWrapper.Tesla.BearerToken, token_url, "client-id",
     "https://api.example.com/.default", :erlang.phash2({"client-secret", nil})}
  end
end

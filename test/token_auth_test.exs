# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.TokenAuthTest do
  use ExUnit.Case, async: false

  alias AshJsonApiWrapper.TokenAuth

  # A token endpoint in the shape of the Microsoft identity platform's client
  # credentials flow. Each call hands out the next token.
  defmodule TokenEndpoint do
    @behaviour Tesla.Adapter

    def start, do: Agent.start_link(fn -> %{calls: 0, bodies: []} end, name: __MODULE__)
    def calls, do: Agent.get(__MODULE__, & &1.calls)
    def bodies, do: Agent.get(__MODULE__, &Enum.reverse(&1.bodies))

    @impl true
    def call(env, opts) do
      Process.sleep(Keyword.get(opts, :delay, 0))

      calls =
        Agent.get_and_update(__MODULE__, fn state ->
          state = %{state | calls: state.calls + 1, bodies: [env.body | state.bodies]}
          {state.calls, state}
        end)

      body =
        Jason.encode!(%{
          "token_type" => "Bearer",
          "expires_in" => Keyword.get(opts, :expires_in, 3599),
          "access_token" => "token-#{calls}"
        })

      {:ok, %{env | status: 200, body: body}}
    end
  end

  # The API: answers 401 to every token listed as revoked.
  defmodule Api do
    @behaviour Tesla.Adapter

    def start(revoked), do: Agent.start_link(fn -> {revoked, []} end, name: __MODULE__)
    def seen, do: Agent.get(__MODULE__, fn {_, seen} -> Enum.reverse(seen) end)

    @impl true
    def call(env, _opts) do
      auth = Tesla.get_header(env, "authorization")
      revoked = Agent.get_and_update(__MODULE__, fn {r, s} -> {r, {r, [auth | s]}} end)

      if auth in Enum.map(revoked, &"Bearer #{&1}") do
        {:ok, %{env | status: 401, body: ""}}
      else
        {:ok, %{env | status: 200, body: "{}"}}
      end
    end
  end

  defmodule Client do
    use Tesla
    adapter(AshJsonApiWrapper.TokenAuthTest.Api)
    plug(AshJsonApiWrapper.TokenAuth, name: AshJsonApiWrapper.TokenAuthTest.Token)
  end

  def config(adapter_opts \\ []) do
    [
      url: "https://login.example.com/tenant-id/oauth2/v2.0/token",
      form: %{
        "grant_type" => "client_credentials",
        "client_id" => "client-id",
        "client_secret" => "client-secret",
        "scope" => "https://api.example.com/.default"
      },
      adapter: {TokenEndpoint, adapter_opts}
    ]
  end

  defp start_token(config) do
    start_supervised!({TokenAuth, name: __MODULE__.Token, config: config})
  end

  setup do
    {:ok, _} = TokenEndpoint.start()
    :ok
  end

  test "fetches a token once and puts it on every request" do
    {:ok, _} = Api.start([])
    start_token({__MODULE__, :config, []})

    assert {:ok, %{status: 200}} = Client.get("https://api.example.com/items")
    assert {:ok, %{status: 200}} = Client.get("https://api.example.com/items")

    assert Api.seen() == ["Bearer token-1", "Bearer token-1"]
    assert TokenEndpoint.calls() == 1

    assert [body] = TokenEndpoint.bodies()
    assert URI.decode_query(body)["grant_type"] == "client_credentials"
  end

  test "concurrent requests share one fetch" do
    {:ok, _} = Api.start([])
    start_token(fn -> config(delay: 100) end)

    1..10
    |> Task.async_stream(fn _ -> Client.get("https://api.example.com/items") end)
    |> Enum.each(fn {:ok, {:ok, %{status: 200}}} -> :ok end)

    assert TokenEndpoint.calls() == 1
  end

  test "refreshes before the token expires" do
    {:ok, _} = Api.start([])
    # 30 seconds lifetime, 60 seconds margin: every request needs a new token
    start_token(fn -> config(expires_in: 30) end)

    Client.get("https://api.example.com/items")
    Client.get("https://api.example.com/items")

    assert Api.seen() == ["Bearer token-1", "Bearer token-2"]
  end

  test "a 401 triggers one refresh and one retry" do
    {:ok, _} = Api.start(["token-1"])
    start_token(fn -> config() end)

    assert {:ok, %{status: 200}} = Client.get("https://api.example.com/items")
    assert Api.seen() == ["Bearer token-1", "Bearer token-2"]
    assert TokenEndpoint.calls() == 2
  end

  test "a second 401 is returned, not retried again" do
    {:ok, _} = Api.start(["token-1", "token-2"])
    start_token(fn -> config() end)

    assert {:ok, %{status: 401}} = Client.get("https://api.example.com/items")
    assert TokenEndpoint.calls() == 2
  end

  test "reads lifetimes as numbers or duration strings" do
    assert TokenAuth.seconds("12h") == 43_200
    assert TokenAuth.seconds("30m") == 1800
    assert TokenAuth.seconds("3600") == 3600
    assert TokenAuth.seconds(3599) == 3599
    assert TokenAuth.seconds("soon") == nil
  end
end

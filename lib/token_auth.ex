# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.TokenAuth do
  @moduledoc """
  Bearer tokens from a token endpoint: fetched on first use, cached, refreshed
  before they expire, and refreshed once more when the API answers 401.

  It has two parts: a process that holds the token, started in your supervision
  tree, and a Tesla middleware that puts the token on every request.

      # application.ex
      children = [
        {AshJsonApiWrapper.TokenAuth, name: MyApp.GraphToken, config: {MyApp.GraphToken, :config, []}}
      ]

      # the Tesla client of your resources
      defmodule MyApp.GraphClient do
        use Tesla
        plug AshJsonApiWrapper.TokenAuth, name: MyApp.GraphToken
      end

  Credentials never go into the resource DSL or the Tesla module: `config` is a
  `{module, function, args}` (or a zero-arity function, or a keyword list) that is
  called each time a token is fetched, so it can read runtime configuration.

  ## Example: Microsoft identity platform, client credentials

      defmodule MyApp.GraphToken do
        def config do
          env = Application.fetch_env!(:my_app, :graph)

          [
            url: "https://login.microsoftonline.com/\#{env[:tenant_id]}/oauth2/v2.0/token",
            form: %{
              "grant_type" => "client_credentials",
              "client_id" => env[:client_id],
              "client_secret" => env[:client_secret],
              "scope" => "https://graph.microsoft.com/.default"
            }
          ]
        end
      end

  The endpoint answers `{"access_token": "...", "expires_in": 3599, ...}`, which
  matches the defaults of `:token_path` and `:expires_in_path`.

  ## Example: exchanging an API key

      [
        url: "https://api.example.com/auth/token",
        json: %{"apiKey" => System.fetch_env!("EXAMPLE_API_KEY")},
        token_path: ["data", "token"],
        expires_in_path: ["data", "expiresIn"]
      ]

  ## Config

  * `:url` - the token endpoint (required)
  * `:form` - a map sent as `application/x-www-form-urlencoded`, or
  * `:json` - a map sent as JSON
  * `:headers` - extra headers for the token request
  * `:token_path` - where the token is in the response, `["access_token"]` by default
  * `:expires_in_path` - where its lifetime is, `["expires_in"]` by default. Seconds
    as a number or string, or a duration like `"12h"`, `"30m"`, `"45s"`, `"1d"`.
  * `:default_ttl` - lifetime in seconds when the response names none (3600)
  * `:refresh_margin` - refresh this many seconds before expiry (60)
  * `:adapter` - the Tesla adapter for the token request (Tesla's default)

  ## Middleware options

  * `:name` - the token process (required)
  * `:header` - `"authorization"` by default
  * `:scheme` - `"Bearer"` by default
  """

  @behaviour Tesla.Middleware

  use GenServer

  require Logger

  @timeout 30_000

  # ── process ──

  def child_spec(opts) do
    %{id: Keyword.fetch!(opts, :name), start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The current token, fetching or refreshing it first when needed."
  @spec token(GenServer.server()) :: {:ok, String.t()} | {:error, term}
  def token(server), do: GenServer.call(server, :token, @timeout)

  @doc """
  Fetches a new token, unless the cached one already differs from `stale_token`
  (another request refreshed it in the meantime).
  """
  @spec refresh(GenServer.server(), String.t() | nil) :: {:ok, String.t()} | {:error, term}
  def refresh(server, stale_token), do: GenServer.call(server, {:refresh, stale_token}, @timeout)

  @impl GenServer
  def init(opts) do
    {:ok, %{config: Keyword.fetch!(opts, :config), token: nil, expires_at: nil}}
  end

  @impl GenServer
  def handle_call(:token, _from, state) do
    if fresh?(state) do
      {:reply, {:ok, state.token}, state}
    else
      fetch(state)
    end
  end

  def handle_call({:refresh, stale_token}, _from, state) do
    if state.token && state.token != stale_token && fresh?(state) do
      {:reply, {:ok, state.token}, state}
    else
      fetch(state)
    end
  end

  defp fresh?(%{token: nil}), do: false

  defp fresh?(%{expires_at: expires_at}) do
    System.monotonic_time(:second) < expires_at
  end

  defp fetch(state) do
    config = resolve(state.config)

    case request_token(config) do
      {:ok, token, ttl} ->
        margin = Keyword.get(config, :refresh_margin, 60)
        expires_at = System.monotonic_time(:second) + max(ttl - margin, 0)
        {:reply, {:ok, token}, %{state | token: token, expires_at: expires_at}}

      {:error, error} ->
        Logger.warning("Fetching a token from #{config[:url]} failed: #{inspect(error)}")
        {:reply, {:error, error}, %{state | token: nil, expires_at: nil}}
    end
  end

  defp resolve({module, function, args}), do: apply(module, function, args)
  defp resolve(function) when is_function(function, 0), do: function.()
  defp resolve(config) when is_list(config), do: config

  defp request_token(config) do
    {body, content_type} =
      cond do
        form = config[:form] -> {URI.encode_query(form), "application/x-www-form-urlencoded"}
        json = config[:json] -> {Jason.encode!(json), "application/json"}
        true -> {"", "application/json"}
      end

    headers =
      [{"content-type", content_type}, {"accept", "application/json"}] ++
        Keyword.get(config, :headers, [])

    client = Tesla.client([], config[:adapter])

    case Tesla.request(client,
           method: :post,
           url: Keyword.fetch!(config, :url),
           body: body,
           headers: headers
         ) do
      {:ok, %Tesla.Env{status: status, body: body}} when status in 200..299 ->
        with {:ok, decoded} <- decode(body),
             token when is_binary(token) <-
               get_in(decoded, Keyword.get(config, :token_path, ["access_token"])) do
          ttl =
            decoded
            |> get_in(Keyword.get(config, :expires_in_path, ["expires_in"]))
            |> seconds()

          {:ok, token, ttl || Keyword.get(config, :default_ttl, 3600)}
        else
          {:error, error} -> {:error, error}
          _ -> {:error, :no_token_in_response}
        end

      {:ok, %Tesla.Env{status: status}} ->
        {:error, {:status, status}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp decode(body) when is_binary(body), do: Jason.decode(body)
  defp decode(body), do: {:ok, body}

  @units %{"s" => 1, "m" => 60, "h" => 3600, "d" => 86_400}

  @doc false
  def seconds(value) when is_integer(value), do: value
  def seconds(value) when is_float(value), do: trunc(value)

  def seconds(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> number
      {number, unit} -> if factor = @units[String.trim(unit)], do: number * factor
      :error -> nil
    end
  end

  def seconds(_), do: nil

  # ── middleware ──

  @impl Tesla.Middleware
  def call(env, next, opts) do
    server = Keyword.fetch!(opts, :name)

    with {:ok, token} <- token(server) do
      case Tesla.run(put_token(env, token, opts), next) do
        {:ok, %Tesla.Env{status: 401}} ->
          with {:ok, new_token} <- refresh(server, token) do
            Tesla.run(put_token(env, new_token, opts), next)
          end

        other ->
          other
      end
    end
  end

  defp put_token(env, token, opts) do
    header = Keyword.get(opts, :header, "authorization")
    scheme = Keyword.get(opts, :scheme, "Bearer")
    value = if scheme, do: "#{scheme} #{token}", else: token

    Tesla.put_header(env, header, value)
  end
end

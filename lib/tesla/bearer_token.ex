# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.Tesla.BearerToken do
  @moduledoc """
  A Tesla middleware that authenticates requests with a short-lived bearer token from a token
  endpoint.

  The token is cached and refreshed `refresh_before` seconds before it expires; concurrent
  requests share one refresh (see `AshJsonApiWrapper.TokenCache`). When the API answers `401`,
  the token is dropped and the request is retried once with a new one.

  Credentials are read from the application environment on every request, so they can come from
  `config/runtime.exs`:

  ```elixir
  defmodule MyApp.GraphTesla do
    use Tesla

    plug AshJsonApiWrapper.Tesla.BearerToken, config: {:my_app, :graph_auth}
  end
  ```

  ```elixir
  # config/runtime.exs, Microsoft identity platform client credentials
  config :my_app, :graph_auth,
    token_url:
      "https://login.microsoftonline.com/\#{System.fetch_env!("GRAPH_TENANT_ID")}/oauth2/v2.0/token",
    client_id: System.fetch_env!("GRAPH_CLIENT_ID"),
    client_secret: System.fetch_env!("GRAPH_CLIENT_SECRET"),
    scope: "https://graph.microsoft.com/.default"
  ```

  ## Options

  Options can be given to `plug` and in the configured application environment, which wins.

  * `:config` - `{otp_app, key}` of the keyword list in the application environment.
  * `:token_url` - the token endpoint.
  * `:grant` - `:client_credentials` (default) sends `grant_type=client_credentials`,
    `client_id`, `client_secret` and `scope` as a form. `:custom` sends only `:params`, for
    example to exchange an API key for a token.
  * `:client_id`, `:client_secret`, `:scope` - for client credentials.
  * `:params` - additional (or, with `grant: :custom`, all) parameters of the token request.
  * `:body_format` - `:form` (default) or `:json`.
  * `:token_key` - the key of the token in the response, default `"access_token"`.
  * `:expires_in_key` - the key of the lifetime in seconds in the response, default
    `"expires_in"`. Tokens without one are kept for an hour.
  * `:refresh_before` - seconds before expiry to get a new token, default `60`.
  * `:adapter` - the Tesla adapter for the token request, default Tesla's default adapter.
  """

  @behaviour Tesla.Middleware

  alias AshJsonApiWrapper.TokenCache

  @impl Tesla.Middleware
  def call(env, next, opts) do
    config = config(opts)
    key = cache_key(config)
    fetch = fn -> request_token(config) end
    refresh_before = config[:refresh_before] || 60

    with {:ok, token} <- TokenCache.fetch(key, fetch, refresh_before) do
      case Tesla.run(authorize(env, token), next) do
        {:ok, %{status: 401}} ->
          TokenCache.invalidate(key, token)

          with {:ok, token} <- TokenCache.fetch(key, fetch, refresh_before) do
            Tesla.run(authorize(env, token), next)
          end

        result ->
          result
      end
    end
  end

  defp authorize(env, token) do
    Tesla.put_header(env, "authorization", "Bearer " <> token)
  end

  defp config(opts) do
    case opts[:config] do
      {otp_app, key} -> Keyword.merge(opts, Application.get_env(otp_app, key, []))
      nil -> opts
    end
  end

  # Identifies a token by where and for whom it is issued, without keeping secrets in the key.
  defp cache_key(config) do
    {__MODULE__, config[:token_url], config[:client_id], config[:scope],
     :erlang.phash2({config[:client_secret], config[:params]})}
  end

  defp request_token(config) do
    token_url = config[:token_url] || raise ArgumentError, "missing :token_url"

    params =
      case config[:grant] || :client_credentials do
        :client_credentials ->
          %{
            "grant_type" => "client_credentials",
            "client_id" => config[:client_id],
            "client_secret" => config[:client_secret],
            "scope" => config[:scope]
          }
          |> Map.reject(fn {_, value} -> is_nil(value) end)
          |> Map.merge(Map.new(config[:params] || %{}))

        :custom ->
          Map.new(config[:params] || %{})
      end

    {body, content_type} =
      case config[:body_format] || :form do
        :form -> {URI.encode_query(params), "application/x-www-form-urlencoded"}
        :json -> {Jason.encode!(params), "application/json"}
      end

    client = Tesla.client([], config[:adapter])

    case Tesla.post(client, token_url, body,
           headers: [{"content-type", content_type}, {"accept", "application/json"}]
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        token_from_response(body, config)

      {:ok, %{status: status, body: body}} ->
        {:error, "Token request to #{token_url} failed with status #{status}: #{inspect(body)}"}

      {:error, error} ->
        {:error, error}
    end
  end

  defp token_from_response(body, config) do
    token_key = config[:token_key] || "access_token"
    expires_in_key = config[:expires_in_key] || "expires_in"

    with {:ok, decoded} <- decode(body),
         token when is_binary(token) <- decoded[token_key] do
      {:ok, token, expires_in(decoded[expires_in_key])}
    else
      _ -> {:error, "Token response has no #{inspect(token_key)}"}
    end
  end

  defp decode(body) when is_binary(body), do: Jason.decode(body)
  defp decode(body), do: {:ok, body}

  defp expires_in(seconds) when is_integer(seconds), do: seconds
  defp expires_in(seconds) when is_binary(seconds), do: String.to_integer(seconds)
  defp expires_in(_), do: 3600
end

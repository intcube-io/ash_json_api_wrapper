# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.Request do
  @moduledoc """
  An HTTP request built by a query dialect, and the code that sends it.

  Map and list bodies are encoded as JSON before they reach the Tesla client, and
  string response bodies are decoded as JSON, so a client with or without
  `Tesla.Middleware.JSON` works the same.
  """

  defstruct method: :get, path: nil, query_params: %{}, body: nil, headers: []

  @type t :: %__MODULE__{
          method: :get | :post | :put | :patch | :delete,
          path: String.t(),
          query_params: map,
          body: term,
          headers: [{String.t(), String.t()}]
        }

  @doc """
  Sends the request through the resource's Tesla client.

  Returns `{:ok, decoded_body, env}` for a 2xx response and `{:error, reason}` otherwise.
  """
  @spec send(Ash.Resource.t(), t) :: {:ok, term, Tesla.Env.t()} | {:error, term}
  def send(resource, %__MODULE__{} = request) do
    tesla = AshJsonApiWrapper.DataLayer.Info.tesla(resource)
    {body, headers} = encode_body(request.body, request.headers || [])

    opts =
      [
        method: request.method || :get,
        url: request.path,
        query: request.query_params || %{},
        headers: headers
      ]
      |> then(fn opts -> if is_nil(body), do: opts, else: Keyword.put(opts, :body, body) end)

    case tesla.request(opts) do
      {:ok, %Tesla.Env{status: status} = env} when status >= 200 and status < 300 ->
        case decode_body(env.body) do
          {:ok, decoded} -> {:ok, decoded, env}
          {:error, error} -> {:error, error}
        end

      {:ok, %Tesla.Env{status: status} = env} ->
        {:error,
         "Received status code #{status} from #{String.upcase(to_string(request.method))} " <>
           "#{request.path}. Response: #{inspect(env.body)}"}

      {:error, error} ->
        {:error, error}
    end
  end

  defp encode_body(body, headers) when is_map(body) or is_list(body) do
    headers =
      if Enum.any?(headers, fn {key, _} -> String.downcase(key) == "content-type" end) do
        headers
      else
        [{"content-type", "application/json"} | headers]
      end

    {Jason.encode!(body), headers}
  end

  defp encode_body(body, headers), do: {body, headers}

  defp decode_body(body) when is_binary(body) do
    case body do
      "" -> {:ok, nil}
      body -> Jason.decode(body)
    end
  end

  defp decode_body(body), do: {:ok, body}
end

# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.Request do
  @moduledoc """
  A request built by a `AshJsonApiWrapper.QueryDialect`.

  A `body` that is not a binary is encoded as JSON. `private` is for the dialect's own use, for
  example to remember the first page's request when building the next one.
  """

  defstruct method: :get, path: nil, query: %{}, body: nil, headers: [], private: %{}

  @type t :: %__MODULE__{
          method: :get | :post | :put | :patch | :delete,
          path: String.t() | nil,
          query: map,
          body: term,
          headers: [{String.t(), String.t()}],
          private: map
        }

  @doc false
  def merge_params(%__MODULE__{} = request, params) when is_map(params) do
    %{request | query: Ash.Helpers.deep_merge_maps(request.query || %{}, params)}
  end

  @doc false
  def merge_headers(%__MODULE__{} = request, headers) when is_map(headers) do
    %{
      request
      | headers:
          request.headers
          |> Kernel.||([])
          |> Map.new()
          |> Map.merge(headers)
          |> Map.to_list()
    }
  end
end

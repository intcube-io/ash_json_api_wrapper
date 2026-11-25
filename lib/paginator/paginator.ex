# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.Paginator do
  @moduledoc """
  Behavior for scanning pages of a paginated endpoint.
  """

  @type ref :: {module, Keyword.t()}

  defmacro __using__(_) do
    quote do
      @behaviour AshJsonApiWrapper.Paginator
    end
  end

  @callback start(opts :: Keyword.t()) ::
              {:ok, %{optional(:params) => map, optional(:headers) => map}}

  @doc """
  Called after each page with the decoded response and the entities read from it.

  `opts` are the paginator's options plus `:pages_fetched`, the number of pages
  read so far (including this one). Return the params/headers for the next page,
  `:halt` when this was the last page, or `{:error, reason}` to fail the read.
  """
  @callback continue(
              response :: term,
              entities :: [Ash.Resource.record()],
              opts :: Keyword.t()
            ) ::
              {:ok, %{optional(:params) => map, optional(:headers) => map}}
              | :halt
              | {:error, term}
              | :halt
end

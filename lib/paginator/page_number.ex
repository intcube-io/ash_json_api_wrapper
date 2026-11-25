# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.Paginator.PageNumber do
  @moduledoc """
  A paginator for endpoints paged by a page number query param.

  It asks for the first page, then for the next one while the last page came
  back full (`page_size` entities). The response needs no paging metadata, so
  it also works for endpoints that answer with a bare JSON array.

  Use it through the builtin:

      paginator page_number("page", page_size_param: "per_page", page_size: 100, max_pages: 50)

  ## Options

    * `:page_size` - entities per page (required). A page with fewer entities is the last one.
    * `:page_size_param` - query param that sets the page size. Without it, the
      page size is only used to recognise the last page.
    * `:first_page` - number of the first page, default `1`.
    * `:max_pages` - the most pages one read may fetch. When the last allowed
      page is still full, the read fails instead of returning a partial result.
  """
  use AshJsonApiWrapper.Paginator

  @impl true
  def start(opts) do
    {:ok, %{params: params(opts[:first_page] || 1, opts)}}
  end

  @impl true
  def continue(_response, entities, opts) do
    pages_fetched = opts[:pages_fetched] || 1
    max_pages = opts[:max_pages]

    cond do
      length(entities) < Keyword.fetch!(opts, :page_size) ->
        :halt

      max_pages && pages_fetched >= max_pages ->
        {:error,
         "Stopped after #{max_pages} pages of #{opts[:page_size]} entities and there are more. " <>
           "Narrow the read or raise `max_pages`."}

      true ->
        {:ok, %{params: params((opts[:first_page] || 1) + pages_fetched, opts)}}
    end
  end

  defp params(page, opts) do
    params = %{opts[:param] => page}

    case opts[:page_size_param] do
      nil -> params
      size_param -> Map.put(params, size_param, opts[:page_size])
    end
  end
end

<!--
SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>

SPDX-License-Identifier: MIT
-->

# Writing a dialect

A dialect implements `AshJsonApiWrapper.QueryDialect`. It decides what a read can do, and how it
turns into requests. The data layer sends the requests, follows pages, reads the records into the
resource and applies whatever the dialect left to the runtime.

This guide builds a dialect for a made-up API that takes `POST /search` with a body like
`{"where": {"status": "open"}, "limit": 20, "offset": 40}` and answers
`{"rows": [...], "total": 1234}`.

```elixir
defmodule MyApp.SearchDialect do
  use AshJsonApiWrapper.QueryDialect

  alias Ash.Query.{BooleanExpression, Ref}
  alias Ash.Query.Operator.Eq
  alias AshJsonApiWrapper.Request

  # 1. What the API can do. Ash rejects everything else before a request is made.
  @impl true
  def can?(_, feature)
      when feature in [:filter, :boolean_filter, :nested_expressions, :limit, :offset, :sort],
      do: true

  def can?(_, {:sort, _}), do: true
  def can?(_, {:query_aggregate, :count}), do: true
  def can?(_, {:filter_expr, %Eq{left: %Ref{relationship_path: []}}}), do: true
  def can?(_, _), do: false

  # 2. Translate the filter. Ash does not ask `can?/2` about `and`/`or`, so reject shapes the
  #    API cannot express here.
  @impl true
  def filter(query, filter, _resource) do
    with {:ok, where} <- where(filter.expression) do
      {:ok, %{query | dialect: Map.put(query.dialect, :where, where)}}
    end
  end

  defp where(%BooleanExpression{op: :and, left: left, right: right}) do
    with {:ok, left} <- where(left), {:ok, right} <- where(right) do
      {:ok, Map.merge(left, right)}
    end
  end

  defp where(%Eq{left: %Ref{attribute: %{name: name}}, right: value}),
    do: {:ok, %{to_string(name) => value}}

  defp where(expression), do: {:error, "Cannot search by #{inspect(expression)}"}

  # 3. Sorting: not supported by the API, so leave it in `query.sort` to apply it to the
  #    fetched records. Offset pagination always sorts, at least by the primary key.
  @impl true
  def sort(query, sort, _resource), do: {:ok, %{query | sort: sort}}

  # 4. Limit, offset and counting. Clear what the API handles; the rest is applied after.
  @impl true
  def paginate(query, _resource) do
    page =
      if query.count?,
        do: %{"limit" => 1},
        else: %{"limit" => query.limit, "offset" => query.offset}

    {:ok, %{query | dialect: Map.put(query.dialect, :page, page), limit: nil, offset: nil}}
  end

  # 5. The requests. Non-binary bodies are sent as JSON.
  @impl true
  def build_requests(query, _resource) do
    body =
      query.dialect
      |> Map.get(:page, %{})
      |> Map.put("where", query.dialect[:where] || %{})
      |> Map.reject(fn {_, value} -> is_nil(value) end)

    {:ok, [%Request{method: :post, path: query.endpoint.path, body: body}]}
  end

  # 6. Records, total and the next page (none here).
  @impl true
  def unwrap_response(%{"rows" => rows} = body, _request, _query, _resource) do
    {:ok, %{records: rows, total: body["total"], next: nil}}
  end
end
```

## What the data layer does with it

1. Ash asks `c:AshJsonApiWrapper.QueryDialect.can?/2` about every feature, operator and function
   (except `:create`), and fails the query early if one is not supported.
2. `filter/3` and `sort/3` run while the query is built, `paginate/2` and `build_requests/2` when
   it runs.
3. Each request is sent through the resource's Tesla module; several requests run concurrently.
   Each JSON response goes to `unwrap_response/4`, and `next` requests are followed.
4. Records are read into the resource by field paths or by attribute names as keys. Dialects
   whose API uses other names usually rename the keys in `unwrap_response/4`.
5. `query.runtime_filter`, `query.sort`, `query.offset` and `query.limit`, whatever is left of
   them, are applied to the records.
6. Page counts (`page: [count: true]`) run the query with `count?: true` and use the `total` of
   the first response, if the dialect supports `{:query_aggregate, :count}`.

## Options

A resource can pass options with `dialect {MyApp.SearchDialect, index: "items"}`. Implement
`c:AshJsonApiWrapper.QueryDialect.opts_schema/0` to validate them at compile time, and read them
with `AshJsonApiWrapper.DataLayer.Info.dialect_opts/1`.

## Generating resources

Implement `c:AshJsonApiWrapper.QueryDialect.query_body?/1` so the resource generator recognizes
`POST` operations whose body is a query in your dialect and generates them as reads.

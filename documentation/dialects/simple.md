<!--
SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>

SPDX-License-Identifier: MIT
-->

# The simple dialect

`AshJsonApiWrapper.Dialect.Simple` is the default dialect. It fits APIs that filter with query
params and fetch single records by path, which covers most REST APIs.

## Filters

Only equality and `in` filters are sent to the API. How depends on the field:

```elixir
json_api_wrapper do
  fields do
    # ?status=open
    field :status do
      filter_handler :simple
    end

    # ?state=open
    field :status do
      filter_handler {:simple, "state"}
    end

    # ?ids=1,2,3 for `id in [1, 2, 3]` or `id == 1 or id == 2`
    field :id do
      filter_handler {:place_in_csv_list, ["ids"]}
    end
  end
end
```

`{:place_in_list, path}` puts the values in a list instead of a comma separated string.

A `get_endpoint` fills its path template from an equality filter on its field, and makes one
request per value for `in`:

```elixir
endpoints do
  get_endpoint :read, :id do
    path "/pets/:id"
  end
end
```

Other equality filters are applied to the fetched records. Any other operator is rejected.

## Sorting, limits and paging

* Sorting happens on the fetched records, and only on endpoints with `runtime_sort? true`.
* `limit_with {:param, "per_page"}` sends the limit as a query param. Limit and offset are also
  applied to the fetched records.
* `paginator` follows pages, for example with a continuation property in the response:

  ```elixir
  endpoint :read do
    path "/items"
    entity_path "data"
    paginator continuation_property("next_cursor", param: "cursor")
  end
  ```

  See `AshJsonApiWrapper.Paginator` to write your own.

## Requests

Reads are `GET` requests unless the endpoint sets `method :post`. Query params, a body and
headers can be added per query:

```elixir
MyApp.Item
|> Ash.Query.for_read(:search)
|> AshJsonApiWrapper.merge_query_params(%{"include" => "owner"})
|> AshJsonApiWrapper.set_body_param("query", "lamp")
|> Ash.read!()
```

Responses are read from `entity_path` (a JSON path, per endpoint or as `base_entity_path`), and
each attribute from its field `path` or from the key of the same name.

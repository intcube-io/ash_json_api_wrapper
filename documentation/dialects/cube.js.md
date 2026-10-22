<!--
SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>

SPDX-License-Identifier: MIT
-->

# Cube.js

`AshJsonApiWrapper.Dialect.CubeJs` reads from APIs that speak the
[Cube.js REST query format](https://cube.dev/docs/product/apis-integrations/rest-api/query-format).
Each read becomes one `POST` with a body like this:

```json
{
  "query": {
    "dimensions": ["Orders.id", "Orders.status"],
    "filters": [{"member": "Orders.status", "operator": "equals", "values": ["shipped"]}],
    "order": [["Orders.createdAt", "desc"]],
    "limit": 20,
    "offset": 40
  }
}
```

## A resource

```elixir
defmodule MyApp.Order do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: AshJsonApiWrapper.DataLayer

  json_api_wrapper do
    tesla MyApp.CubeTesla
    dialect {AshJsonApiWrapper.Dialect.CubeJs, cube: "Orders"}

    endpoints do
      base "https://cube.example.com"

      endpoint :read do
        path "/cubejs-api/v1/load"
      end
    end
  end

  actions do
    read :read do
      primary? true
      pagination offset?: true, countable: true, required?: false
    end
  end

  attributes do
    integer_primary_key :id, public?: true
    attribute :status, :string, public?: true
    attribute :created_at, :naive_datetime, public?: true
  end
end
```

Authentication, for example the `Authorization` header Cube expects, belongs in the Tesla
module.

## Member names

Each attribute maps to the dimension `<cube>.<name>`:

| Option | Default | Effect |
| --- | --- | --- |
| `cube` | required | The prefix of all member names. |
| `member_case` | `:camel` | `created_at` becomes `createdAt`. With `:snake` the name is used as is. |
| `members` | `[]` | Full member names per attribute, e.g. `[total: "Orders.totalAmount"]`. |

Response keys are matched to members ignoring case and underscores, so a response with
`orders.created_at` still fills `created_at`.

## What is sent

* **Dimensions**: only the selected attributes (`Ash.Query.select/2`), or all attributes.
* **Filters**: see the table in `AshJsonApiWrapper.Dialect.CubeJs`. A filter Cube cannot express,
  for example a comparison between two attributes or a calculation, is rejected before any
  request is made.
* **Order**: the query's sort. Only attributes can be sorted by.
* **Limit and offset**: from the query or from offset pagination. Without a limit, all rows are
  read in pages of `page_size` (default 10 000) rows.
* **Total**: page counts (`page: [count: true]`) send one extra request with `total: true`.

Cube groups rows by their dimensions. Include a unique dimension such as the primary key, or
set `ungrouped: true`.

## Not supported

* Measures, `timeDimensions` and granularity.
* Cube's "Continue wait" responses for long running queries are returned as errors.

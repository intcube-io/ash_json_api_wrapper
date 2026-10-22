<!--
SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>

SPDX-License-Identifier: MIT
-->

# OData

`AshJsonApiWrapper.Dialect.OData` reads from OData v4 services. Each read becomes a `GET` on an
entity set with system query options:

```
GET /users?$filter=accountEnabled eq true and startswith(displayName,'A')
          &$select=id,displayName,mail
          &$orderby=displayName asc
          &$top=20&$skip=40
```

The examples use [Microsoft Graph](https://learn.microsoft.com/graph/query-parameters), a public
OData API.

## A resource

```elixir
defmodule MyApp.Graph.User do
  use Ash.Resource,
    domain: MyApp.Graph,
    data_layer: AshJsonApiWrapper.DataLayer

  json_api_wrapper do
    tesla MyApp.GraphTesla

    dialect {AshJsonApiWrapper.Dialect.OData,
             count: true, consistency_level: "eventual", properties: [email: "mail"]}

    endpoints do
      base "https://graph.microsoft.com/v1.0"

      endpoint :read do
        path "/users"
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
    uuid_primary_key :id, public?: true
    attribute :display_name, :string, public?: true
    attribute :email, :string, public?: true
    attribute :account_enabled, :boolean, public?: true
    attribute :created_date_time, :utc_datetime, public?: true
  end
end
```

The Tesla module is responsible for authentication, for example a bearer token header.

## Options

| Option | Default | Effect |
| --- | --- | --- |
| `property_case` | `:camel` | `display_name` becomes `displayName`. With `:snake` the name is used as is. |
| `properties` | `[]` | Property names per attribute, e.g. `[email: "mail"]`. |
| `count` | `false` | Sends `$count=true` with every request and supports page counts via `@odata.count`. |
| `consistency_level` | `nil` | Value of the `ConsistencyLevel` header. |
| `in_operator` | `:in` | `:in` sends the OData 4.01 `in` operator; `:or` sends `eq` joined with `or` for v4.0 services. |

Microsoft Graph only accepts some filters (`endswith`, `ne`, `not`, ...) and `$count` on
directory objects together with `ConsistencyLevel: eventual`. Set both `count: true` and
`consistency_level: "eventual"` for those resources.

## What is sent

* **`$filter`**: see the table in `AshJsonApiWrapper.Dialect.OData`. Strings are quoted with `'`
  (and `'` doubled inside), UUID attributes, numbers, booleans, dates and times are not. A filter
  OData cannot express, for example a comparison between two attributes, is rejected before any
  request is made.
* **`$select`**: the selected attributes (`Ash.Query.select/2`).
* **`$orderby`**: the query's sort. Only attributes can be sorted by.
* **`$top` and `$skip`**: from the query's limit and offset or from offset pagination. Some
  services, Graph's directory objects among them, do not support `$skip`.
* **Paging**: `@odata.nextLink` is followed until the limit is reached or there are no more
  pages.

## Not supported

* `$expand`, `$search`, batching and delta queries.
* Lambda operators (`any`, `all`) on collections.
* Writes.

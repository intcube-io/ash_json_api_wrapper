<!--
SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>

SPDX-License-Identifier: MIT
-->

# Generating resources from an OpenAPI spec

`mix ash_json_api_wrapper.gen.resources <spec.json> <config.exs>` writes one
resource module per configured resource. Rerun it whenever the spec changes;
everything the spec does not say lives in the config, so nothing has to be
edited in the generated files.

## Example

A made-up inventory API lists products with `POST /api/products`, taking a
Cube.js-style query and answering `{"data": [...], "total": 42}` with
snake_case keys:

```elixir
# priv/specs/inventory.exs
[
  domain: MyApp.Inventory,
  tesla: MyApp.Inventory.Client,
  endpoint: "https://inventory.example.com",
  dialect: {AshJsonApiWrapper.Dialect.CubeJs, response_case: :snake},
  resources: [
    "MyApp.Inventory.Product": [
      path: "/api/products",
      operations: ["queryProducts"],
      # the spec has no key
      primary_key: "product_id",
      # a nicer name; the response key stays the field's path
      rename: [name: :title],
      # nobody needs it
      skip: [:internal_note],
      # what the API can filter; everything else gets `filter_operators []`
      filterable: [category: [:eq, :in], updated_at: [:gte, :lte]],
      relationships: [
        belongs_to: [
          warehouse: [destination: MyApp.Inventory.Warehouse, source_attribute: :warehouse_id]
        ]
      ]
    ]
  ]
]
```

```bash
mix ash_json_api_wrapper.gen.resources priv/specs/inventory.json priv/specs/inventory.exs
```

The POST becomes a `read` because its request body is a query in the dialect's
shape; the rows are taken from `data`; `updated_at` is a time dimension because
the request schema lists it under `timeDimensions`; fields the response has but
the request cannot ask for get `member false`.

A field named in an override that the spec does not have stops the generator
with an error naming the resource and the field.

The same hints can live in the spec as vendor extensions (`x-ash-primary-key`,
`x-ash-name`, `x-ash-skip`, `x-ash-filter-operators`, `x-ash-relationship`); the
config wins when both say something. See
`AshJsonApiWrapper.OpenApi.ResourceGenerator` for every option.

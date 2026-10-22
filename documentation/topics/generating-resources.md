<!--
SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>

SPDX-License-Identifier: MIT
-->

# Generating resources

`mix ash_json_api_wrapper.gen.resources` generates resources from an OpenAPI spec (JSON). The
spec and a config file stay in your project; the generated files are overwritten on every run, so
re-run the task when the spec changes and review the diff. Everything you would otherwise change
by hand in a generated file goes into the config.

## The config

```elixir
# priv/specs/inventory.exs
[
  spec: "inventory.json",
  domain: MyApp.Inventory,
  tesla: MyApp.InventoryTesla,
  endpoint: "https://inventory.example.com",
  resources: [
    "MyApp.Inventory.Product": [
      path: "/products",
      reads: ["searchProducts"],

      # Overrides
      primary_key: "id",
      skip: ["internalNotes"],
      rename: [releasedOn: :launch_date],
      filterable: [status: [:==, :in], name: [:==, :contains]],
      relationships: [
        category: [destination: MyApp.Inventory.Category, source_attribute: "categoryId"]
      ]
    ],
    "MyApp.Inventory.Category": [
      path: "/categories",
      primary_key: "id",
      relationships: [
        products: [
          type: :has_many,
          destination: MyApp.Inventory.Product,
          destination_attribute: :category_id
        ]
      ]
    ]
  ]
]
```

```bash
mix ash_json_api_wrapper.gen.resources priv/specs/inventory.exs
```

Each resource gets an endpoint and an action per operation under `path`. `GET` operations become
reads. `POST` operations become reads when listed in `reads` or when their body is a query in the
resource's `dialect` (for example a Cube.js query), and creates when they respond with JSON.
Other `POST` operations are commands; write them by hand as generic actions.

See `AshJsonApiWrapper.OpenApi.ResourceGenerator` for all options and the type mapping.

## Overrides

Specs rarely say everything a resource needs. Overrides name properties by their name in the spec
(`"releasedOn"`) or by their attribute name (`:released_on`).

| Override | Effect |
| --- | --- |
| `primary_key` | The primary key property, or a list of them. |
| `skip` | Properties that do not become attributes. |
| `rename` | Attribute names for properties. The original name is kept as the field `path` (simple dialect) or in the dialect's names (`properties` for OData, `members` for Cube.js). |
| `filterable` | The only properties filters may use, each with the Ash operators and functions it allows, e.g. `[:==, :in, :contains, :string_starts_with]`. Other attributes get `filterable? false`; the operators become the field's `filter_operators`. Primary keys and relationship attributes stay filterable. |
| `relationships` | Relationships between generated resources: `type` (default `:belongs_to`), `destination`, and `source_attribute` (a property, default `<name>_id`) or `destination_attribute`. |

An override that names a property the spec does not have fails the generator with an error that
lists the properties, so a renamed or removed property in a new version of the spec does not go
unnoticed.

## Hints in the spec

A spec author can provide the same hints as vendor extensions. Overrides in the config win, per
property.

```json
{
  "Item": {
    "type": "object",
    "x-ash-primary-key": "sku",
    "x-ash-relationships": [
      {"name": "reviews", "type": "has_many", "destination": "MyApp.Review", "destination_attribute": "item_sku"}
    ],
    "properties": {
      "sku": {"type": "string"},
      "title": {"type": "string", "x-ash-name": "name"},
      "status": {"type": "string", "x-ash-filter-operators": ["==", "in"]},
      "categoryId": {
        "type": "integer",
        "x-ash-relationship": {"name": "category", "destination": "MyApp.Category"}
      },
      "internalNote": {"type": "string", "x-ash-skip": true}
    }
  }
}
```

| Extension | On | Same as |
| --- | --- | --- |
| `x-ash-primary-key` | schema | `primary_key` |
| `x-ash-skip: true` | property | `skip` |
| `x-ash-name` | property | `rename` |
| `x-ash-filter-operators` | property | `filterable` |
| `x-ash-relationship` | property | a `belongs_to` with this property as `source_attribute` |
| `x-ash-relationships` | schema | `relationships` |

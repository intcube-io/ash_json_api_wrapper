<!--
SPDX-FileCopyrightText: 2020 Zach Daniel

SPDX-License-Identifier: MIT
-->

![Elixir CI](https://github.com/ash-project/ash_json_api_wrapper/workflows/CI/badge.svg)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Hex version badge](https://img.shields.io/hexpm/v/ash_json_api_wrapper.svg)](https://hex.pm/packages/ash_json_api_wrapper)
[![Hexdocs badge](https://img.shields.io/badge/docs-hexdocs-purple)](https://hexdocs.pm/ash_json_api_wrapper)
[![REUSE status](https://api.reuse.software/badge/github.com/ash-project/ash_json_api_wrapper)](https://api.reuse.software/info/github.com/ash-project/ash_json_api_wrapper)

# AshJsonApiWrapper

An [Ash](https://ash-hq.org) data layer for resources backed by external JSON APIs.

Reads become HTTP requests: Ash filters, sorts, limits and offsets are translated into the query
language the API speaks, pages are followed, and the JSON response is read into resource records.
Whatever the API cannot do is either applied to the fetched records or rejected before a request
is made.

* **Query dialects**: how a query is sent is pluggable. Included are a simple dialect (query
  params and path templates), [Cube.js](documentation/dialects/cube.js.md) and
  [OData v4](documentation/dialects/odata.md). See
  [writing a dialect](documentation/topics/writing-a-dialect.md) for others.
* **Resource generation** from OpenAPI specs, with overrides for what specs leave out. See
  [generating resources](documentation/topics/generating-resources.md).
* **Authentication** with any Tesla middleware, including bearer tokens from a token endpoint.
  See [authentication](documentation/topics/authentication.md).

## Installation

This fork is not on Hex. Add it as a git dependency:

```elixir
def deps do
  [
    {:ash_json_api_wrapper,
     git: "https://github.com/intcube-io/ash_json_api_wrapper.git", branch: "next"}
  ]
end
```

Pin a commit with `ref: "<sha>"` instead of `branch` for reproducible builds. Add
`:ash_json_api_wrapper` to `import_deps` in your `.formatter.exs` to format the DSL without
parens.

## A minimal resource

```elixir
defmodule MyApp.Pet do
  use Ash.Resource,
    domain: MyApp.Pets,
    data_layer: AshJsonApiWrapper.DataLayer

  json_api_wrapper do
    endpoints do
      base "https://petstore3.swagger.io/api/v3"

      endpoint :by_status do
        path "/pet/findByStatus"

        field :status do
          filter_handler :simple
        end
      end

      get_endpoint :read, :id do
        path "/pet/:id"
      end
    end
  end

  actions do
    defaults [:read]
    read :by_status
  end

  attributes do
    integer_primary_key :id, public?: true
    attribute :name, :string, public?: true
    attribute :status, :string, public?: true
  end
end
```

```elixir
# GET /pet/findByStatus?status=available
MyApp.Pet
|> Ash.Query.for_read(:by_status)
|> Ash.Query.filter(status == "available")
|> Ash.read!()

# GET /pet/10
Ash.get!(MyApp.Pet, 10)
```

## Guides

* [The simple dialect](documentation/dialects/simple.md)
* [Cube.js](documentation/dialects/cube.js.md)
* [OData](documentation/dialects/odata.md)
* [Writing a dialect](documentation/topics/writing-a-dialect.md)
* [Generating resources](documentation/topics/generating-resources.md)
* [Authentication](documentation/topics/authentication.md)

Run `mix docs` for the full API documentation.

## Changes

See the [changelog](CHANGELOG.md).

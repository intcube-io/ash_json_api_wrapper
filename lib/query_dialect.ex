# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.QueryDialect do
  @moduledoc """
  Behaviour for the query language an API speaks.

  A resource picks its dialect in the DSL:

  ```elixir
  json_api_wrapper do
    dialect AshJsonApiWrapper.Dialect.CubeJs
    # or, with options
    dialect {AshJsonApiWrapper.Dialect.CubeJs, cube: "Orders"}
  end
  ```

  The default is `AshJsonApiWrapper.Dialect.Simple`, which sends equality filters as query
  params or path segments.

  ## How a read runs

  1. `c:can?/2` answers every `Ash.DataLayer.can?/2` question except `:create`, so Ash rejects
     filters, sorts and features the dialect cannot handle before any request is made.
  2. `c:filter/3` and `c:sort/3` translate the Ash filter and sort into the query.
  3. When the read runs, `c:paginate/2` applies `limit`, `offset` and `count?`, then
     `c:build_requests/2` turns the query into one or more `AshJsonApiWrapper.Request`s.
  4. Each response body (decoded from JSON) goes to `c:unwrap_response/4`, which returns the raw
     records, the total if the API reports one, and the request for the next page, if any.

  Whatever a dialect leaves in `query.runtime_filter`, `query.sort`, `query.offset` and
  `query.limit` is applied to the records after they are fetched. A dialect that handles one of
  these remotely clears the corresponding field.

  Records returned by `c:unwrap_response/4` are read into the resource like any other response:
  by the configured `field` paths, or by the attribute name as a string key.

  Dialect options are available through `AshJsonApiWrapper.DataLayer.Info.dialect_opts/1`. A
  dialect that implements `c:opts_schema/0` has its options validated at compile time.
  """

  alias AshJsonApiWrapper.DataLayer.Query
  alias AshJsonApiWrapper.Request

  @type ref :: {module, Keyword.t()}

  @type page :: %{
          records: [map],
          total: non_neg_integer | nil,
          next: Request.t() | nil
        }

  @doc "Whether the dialect supports a data layer feature, see `t:Ash.DataLayer.feature/0`."
  @callback can?(Ash.Resource.t() | Spark.Dsl.t(), Ash.DataLayer.feature()) :: boolean

  @doc "Translates an Ash filter into the query."
  @callback filter(Query.t(), Ash.Filter.t(), Ash.Resource.t()) ::
              {:ok, Query.t()} | {:error, term}

  @doc "Translates an Ash sort into the query."
  @callback sort(Query.t(), Ash.Sort.t(), Ash.Resource.t()) ::
              {:ok, Query.t()} | {:error, term}

  @doc """
  Applies `query.limit`, `query.offset` and `query.count?` to the query.

  Set `limit` or `offset` to `nil` once the API handles them, otherwise they are also applied to
  the fetched records.
  """
  @callback paginate(Query.t(), Ash.Resource.t()) :: {:ok, Query.t()} | {:error, term}

  @doc """
  Builds the requests for a query. Results of all requests are concatenated.
  """
  @callback build_requests(Query.t(), Ash.Resource.t()) ::
              {:ok, [Request.t()]} | {:error, term}

  @doc """
  Extracts records, the total and the next page request from a decoded response body.
  """
  @callback unwrap_response(body :: term, Request.t(), Query.t(), Ash.Resource.t()) ::
              {:ok, page} | {:error, term}

  @doc "A `Spark.Options` schema for the dialect's options."
  @callback opts_schema() :: Keyword.t()

  @doc """
  Whether a request body schema from an OpenAPI spec (with `$ref`s resolved) is a query in this
  dialect. The resource generator turns `POST` operations with such a body into reads.
  """
  @callback query_body?(schema :: map) :: boolean

  @optional_callbacks opts_schema: 0, query_body?: 1

  defmacro __using__(_) do
    quote do
      @behaviour AshJsonApiWrapper.QueryDialect
    end
  end
end

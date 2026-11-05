# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.QueryDialect do
  @moduledoc """
  How a read is sent to an API: which filters it understands, where sort and
  paging go, how the request looks and how records come back out of the response.

  A resource picks its dialect in the DSL:

      json_api_wrapper do
        dialect AshJsonApiWrapper.Dialect.CubeJs
        # or with options
        dialect {AshJsonApiWrapper.Dialect.CubeJs, query_key: "query", page_size: 500}
      end

  The default is `AshJsonApiWrapper.Dialect.Simple`, the behaviour the data layer
  always had: equality filters as query params, path templates, CSV lists and the
  paginators.

  ## The read cycle

  1. `c:can?/3` answers the data layer's `can?/2`. Ash asks it for every filter
     expression before the read runs, so a filter the dialect cannot express is
     rejected up front instead of being silently dropped.
  2. `c:filter/4` and `c:sort/4` translate the Ash filter and sort and keep the
     result in the query (usually in `dialect_state`). Limit, offset and the
     selected attributes are set on the query by the data layer.
  3. `c:build_request/3` turns the query into an `AshJsonApiWrapper.Request`:
     method, path, query params or JSON body, headers. Limit/offset or a cursor
     are applied here.
  4. `c:unwrap_response/4` gets the decoded body and returns the raw entities,
     the total (if the API reports one) and how to get the next page, if any.

  A dialect that needs full control (parallel requests, custom paging) can
  implement `c:run_query/3` instead of steps 3 and 4.

  ## The query

  Callbacks receive and return the data layer's query struct,
  `AshJsonApiWrapper.DataLayer.Query`. A dialect keeps its own translation in
  the `dialect_state` field; `limit`, `offset`, `select`, `endpoint` and
  `context` are set by the data layer.
  """

  @type query :: AshJsonApiWrapper.DataLayer.Query.t()
  @type opts :: Keyword.t()
  @type ref :: {module, opts}

  @type unwrapped :: %{
          required(:entities) => [map],
          optional(:total) => non_neg_integer | nil,
          optional(:next) => :halt | {:continue, query}
        }

  @doc "Whether the dialect supports an `Ash.DataLayer` feature for this resource."
  @callback can?(resource :: Ash.Resource.t() | map, feature :: term, opts) :: boolean

  @doc "Translates an `Ash.Filter` into the query."
  @callback filter(query, Ash.Filter.t(), resource :: Ash.Resource.t(), opts) ::
              {:ok, query} | {:error, term}

  @doc "Translates an Ash sort into the query."
  @callback sort(query, Ash.Sort.t(), resource :: Ash.Resource.t(), opts) ::
              {:ok, query} | {:error, term}

  @doc "Builds the HTTP request for the query, with its limit/offset or cursor applied."
  @callback build_request(query, resource :: Ash.Resource.t(), opts) ::
              {:ok, AshJsonApiWrapper.Request.t()} | {:error, term}

  @doc """
  Extracts the entities from a decoded response body.

  `:next` is `{:continue, query}` when another page has to be fetched to answer
  the read, and `:halt` (or absent) otherwise.
  """
  @callback unwrap_response(body :: term, query, resource :: Ash.Resource.t(), opts) ::
              {:ok, unwrapped} | {:error, term}

  @doc "The response key holding an attribute that has no `path` configured."
  @callback response_key(attribute :: atom, resource :: Ash.Resource.t(), opts) :: String.t()

  @doc "Runs the whole read itself instead of using `build_request/3` and `unwrap_response/4`."
  @callback run_query(query, resource :: Ash.Resource.t(), opts) ::
              {:ok, [Ash.Resource.record()]} | {:error, term}

  @doc "Runs aggregates (for example the count behind a page's `count`)."
  @callback run_aggregate_query(query, [Ash.Query.Aggregate.t()], Ash.Resource.t(), opts) ::
              {:ok, map} | {:error, term}

  @doc """
  Whether an OpenAPI request body schema is a query in this dialect's shape.

  The resource generator uses it to turn POST endpoints into reads.
  """
  @callback query_request?(request_schema :: map, spec :: map, opts) :: boolean

  @doc "The JSON path of the entities in a response of this dialect, for the generator."
  @callback entity_path(opts) :: String.t() | nil

  @optional_callbacks run_query: 3,
                      run_aggregate_query: 4,
                      build_request: 3,
                      unwrap_response: 4,
                      response_key: 3,
                      query_request?: 3,
                      entity_path: 1

  defmacro __using__(_) do
    quote do
      @behaviour AshJsonApiWrapper.QueryDialect
    end
  end
end

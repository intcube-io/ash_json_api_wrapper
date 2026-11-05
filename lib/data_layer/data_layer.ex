# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.DataLayer do
  @moduledoc """
  A data layer for wrapping external JSON APIs.
  """

  @field %Spark.Dsl.Entity{
    name: :field,
    target: AshJsonApiWrapper.Field,
    schema: AshJsonApiWrapper.Field.schema(),
    docs: """
    Configure an individual field's behavior, for example its path in the response.
    """,
    args: [:name]
  }

  @fields %Spark.Dsl.Section{
    name: :fields,
    describe: "Contains configuration for individual fields in the response",
    entities: [
      @field
    ]
  }

  @endpoint %Spark.Dsl.Entity{
    name: :endpoint,
    target: AshJsonApiWrapper.Endpoint,
    schema: AshJsonApiWrapper.Endpoint.schema(),
    identifier: {:auto, :unique_integer},
    docs: """
    Configure the endpoint that a given action will use.

    Accepts overrides for fields as well.
    """,
    entities: [
      fields: [@field]
    ],
    args: [:action]
  }

  @get_endpoint %Spark.Dsl.Entity{
    name: :get_endpoint,
    target: AshJsonApiWrapper.Endpoint,
    schema: AshJsonApiWrapper.Endpoint.get_schema(),
    docs: """
    Configure the endpoint that a given action will use.

    Accepts overrides for fields as well.

    Expresses that this endpoint is used to fetch a single item.
    Doing this will make the data layer support equality filters over that field when using that action.
    If "in" or "or equals" is used, then multiple requests will be made in parallel to fetch
    all of those records. However, keep in mind you can't combine a filter over one of these
    fields with an `or` with anything other than *more* filters on this field. For example        Doing this will make the data layer support equality filters over that field.
    If "in" or "or equals" is used, then multiple requests will be made in parallel to fetch
    all of those records. However, keep in mind you can't combine a filter over one of these
    fields with an `or` with anything other than *more* filters on this field. For example,
    `filter(resource, id == 1 or foo == true)`, since we wouldn't be able to turn this into
    multiple requests to the get endpoint for `id`. If other filters are supported, they can be used
    with `and`, e.g `filter(resource, id == 1 or id == 2 and other_supported_filter == true)`, since those
    filters will be applied to each request.

    Expects the field to be available in the path template, e.g with `get_for` of `:id`, path should contain `:id`, e.g
    `/get/:id` or `/:id`,
    `filter(resource, id == 1 or foo == true)`, since we wouldn't be able to turn this into
    multiple requests to the get endpoint for `id`. If other filters are supported, they can be used
    with `and`, e.g `filter(resource, id == 1 or id == 2 and other_supported_filter == true)`, since those
    filters will be applied to each request.

    Expects the field to be available in the path template, e.g with `get_for` of `:id`, path should contain `:id`, e.g
    `/get/:id` or `/:id`
    """,
    entities: [
      fields: [@field]
    ],
    args: [:action, :get_for]
  }

  @endpoints %Spark.Dsl.Section{
    name: :endpoints,
    describe: "Contains the configuration for the endpoints used in each action",
    schema: [
      base: [
        type: :string,
        doc: "The base endpoint to which all relative urls provided will be appended."
      ]
    ],
    entities: [
      @endpoint,
      @get_endpoint
    ]
  }

  @json_api_wrapper %Spark.Dsl.Section{
    name: :json_api_wrapper,
    describe: "Contains the configuration for the json_api_wrapper data layer",
    sections: [
      @fields,
      @endpoints
    ],
    imports: [
      AshJsonApiWrapper.Paginator.Builtins
    ],
    schema: [
      base_entity_path: [
        type: :string,
        doc: """
        Where in the response to find resulting entities. Can be overridden per endpoint.
        """
      ],
      base_paginator: [
        type:
          {:spark_behaviour, AshJsonApiWrapper.Paginator, AshJsonApiWrapper.Paginator.Builtins},
        doc: """
        A module implementing the `AshJSonApiWrapper.Paginator` behaviour, to allow scanning pages when reading.
        """
      ],
      tesla: [
        type: :atom,
        default: AshJsonApiWrapper.DefaultTesla,
        doc: """
        The Tesla module to use.
        """
      ],
      dialect: [
        type: {:spark_behaviour, AshJsonApiWrapper.QueryDialect},
        default: AshJsonApiWrapper.Dialect.Simple,
        doc: """
        The `AshJsonApiWrapper.QueryDialect` that translates reads into requests, with options:
        `dialect AshJsonApiWrapper.Dialect.CubeJs` or `dialect {AshJsonApiWrapper.Dialect.CubeJs, page_size: 500}`.
        """
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@json_api_wrapper],
    transformers: [AshJsonApiWrapper.DataLayer.Transformers.SetEndpointDefaults]

  alias AshJsonApiWrapper.DataLayer.Info

  defmodule Query do
    @moduledoc """
    The data layer query handed to `AshJsonApiWrapper.QueryDialect` callbacks.

    `dialect_state` belongs to the dialect; everything else is set by the data layer.
    """
    defstruct [
      :domain,
      :context,
      :headers,
      :action,
      :limit,
      :offset,
      :filter,
      :runtime_filter,
      :path,
      :query_params,
      :body,
      :sort,
      :select,
      :endpoint,
      :templates,
      :override_results,
      :dialect_state
    ]

    @type t :: %__MODULE__{}
  end

  @behaviour Ash.DataLayer

  @impl true
  def can?(resource, feature) do
    {dialect, opts} = Info.dialect(resource)
    dialect.can?(resource, feature, opts)
  end

  @impl true
  def resource_to_query(resource, domain \\ nil) do
    %Query{path: Info.endpoint_base(resource), domain: domain}
  end

  @impl true
  def filter(query, filter, resource) do
    cond do
      filter == false || match?(%Ash.Filter{expression: false}, filter) ->
        {:ok, %{query | override_results: []}}

      filter == nil || filter == true || match?(%Ash.Filter{expression: nil}, filter) ->
        {:ok, %{query | filter: filter}}

      true ->
        {dialect, opts} = Info.dialect(resource)
        dialect.filter(query, filter, resource, opts)
    end
  end

  @impl true
  def sort(query, sort, _resource) when sort in [nil, []] do
    {:ok, query}
  end

  def sort(query, sort, resource) do
    {dialect, opts} = Info.dialect(resource)
    dialect.sort(query, sort, resource, opts)
  end

  @impl true
  def select(query, select, _resource) do
    {:ok, %{query | select: select}}
  end

  @impl true
  def set_context(resource, query, context) do
    params = context[:data_layer][:query_params] || %{}
    headers = Map.to_list(context[:data_layer][:headers] || %{})

    action = context[:action]

    {:ok,
     %{
       query
       | query_params: params,
         headers: headers,
         domain: query.domain,
         action: action,
         endpoint: action && Info.endpoint(resource, action.name),
         context: context
     }}
  end

  @impl true
  def limit(query, limit, _resource) do
    {:ok, %{query | limit: limit}}
  end

  @impl true
  def offset(query, offset, _resource) do
    {:ok, %{query | offset: offset}}
  end

  @impl true
  def create(resource, changeset) do
    endpoint = Info.endpoint(resource, changeset.action.name)

    base =
      case endpoint.fields_in || :body do
        :body ->
          changeset.context[:data_layer][:body] || %{}

        :params ->
          changeset.context[:data_layer][:query_params] || %{}
      end

    {:ok, with_attrs} =
      changeset.attributes
      |> Kernel.||(%{})
      |> Enum.reduce_while({:ok, base}, fn {key, value}, {:ok, acc} ->
        attribute = Ash.Resource.Info.attribute(resource, key)
        field = Info.field(resource, attribute.name)

        case Ash.Type.dump_to_embedded(
               attribute.type,
               value,
               attribute.constraints
             ) do
          {:ok, dumped} ->
            path =
              if field && field.write_path do
                field.write_path
              else
                [to_string(attribute.name)]
              end

            path =
              if endpoint.write_entity_path do
                endpoint.write_entity_path ++ path
              else
                path
              end

            {:cont, {:ok, put_in!(acc, path, dumped)}}

          :error ->
            {:halt,
             {:error,
              Ash.Error.Changes.InvalidAttribute.exception(
                field: attribute.name,
                message: "Could not be dumped to embedded"
              )}}
        end
      end)

    {body, params} =
      case endpoint.fields_in do
        :params ->
          {changeset.context[:data_layer][:body] || %{}, with_attrs}

        :body ->
          {with_attrs, changeset.context[:data_layer][:query_params] || %{}}
      end

    path = endpoint.path || Info.endpoint_base(resource)
    headers = [{"Content-Type", "application/json"}, {"Accept", "application/json"}]

    request = %AshJsonApiWrapper.Request{
      method: endpoint.method || :get,
      path: path,
      body: body,
      query_params: params,
      headers: headers
    }

    with {:ok, body, _env} <- AshJsonApiWrapper.Request.send(resource, request),
         {:ok, entities} <-
           AshJsonApiWrapper.Dialect.Simple.get_entities(body, endpoint, resource),
         {:ok, processed} <-
           AshJsonApiWrapper.Records.process_entities(entities, resource, endpoint) do
      {:ok, Enum.at(processed, 0)}
    end
  end

  defp put_in!(body, [key], value) do
    Map.put(body || %{}, key, value)
  end

  defp put_in!(body, [first | rest], value) do
    body
    |> Map.put_new(first, %{})
    |> Map.update!(first, &put_in!(&1, rest, value))
  end

  @impl true
  def run_query(%{override_results: results} = query, _resource)
      when not is_nil(results) do
    if query.sort in [nil, []] do
      {:ok, results}
    else
      {:ok, Ash.Sort.runtime_sort(results, query.sort, [])}
    end
  end

  def run_query(query, resource) do
    {dialect, opts} = Info.dialect(resource)
    query = %{query | endpoint: query.endpoint || Info.endpoint(resource, query.action.name)}

    if function_exported?(dialect, :run_query, 3) do
      dialect.run_query(query, resource, opts)
    else
      run_pages(query, resource, dialect, opts, [])
    end
  end

  defp run_pages(query, resource, dialect, opts, acc) do
    with {:ok, request} <- dialect.build_request(query, resource, opts),
         {:ok, body, _env} <- AshJsonApiWrapper.Request.send(resource, request),
         {:ok, unwrapped} <- dialect.unwrap_response(body, query, resource, opts),
         {:ok, records} <-
           AshJsonApiWrapper.Records.process_entities(
             unwrapped.entities,
             resource,
             query.endpoint,
             &dialect.response_key(&1, resource, opts)
           ) do
      case Map.get(unwrapped, :next, :halt) do
        {:continue, next_query} ->
          run_pages(next_query, resource, dialect, opts, [records | acc])

        :halt ->
          {:ok, [records | acc] |> Enum.reverse() |> Enum.concat()}
      end
    end
  end

  @impl true
  def run_aggregate_query(query, aggregates, resource) do
    {dialect, opts} = Info.dialect(resource)

    if function_exported?(dialect, :run_aggregate_query, 4) do
      query = %{query | endpoint: query.endpoint || Info.endpoint(resource, query.action.name)}
      dialect.run_aggregate_query(query, aggregates, resource, opts)
    else
      {:error, "#{inspect(dialect)} does not support aggregates"}
    end
  end
end

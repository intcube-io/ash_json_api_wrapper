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
      dialect: [
        type: {:spark_behaviour, AshJsonApiWrapper.QueryDialect},
        default: {AshJsonApiWrapper.Dialect.Simple, []},
        doc: """
        The query language the API speaks, as a module implementing `AshJsonApiWrapper.QueryDialect`, optionally with options: `{module, opts}`.
        """
      ],
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
      ]
    ]
  }

  require Logger

  alias AshJsonApiWrapper.DataLayer.Info

  use Spark.Dsl.Extension,
    sections: [@json_api_wrapper],
    transformers: [
      AshJsonApiWrapper.DataLayer.Transformers.ValidateDialect,
      AshJsonApiWrapper.DataLayer.Transformers.SetEndpointDefaults
    ]

  defmodule Query do
    @moduledoc """
    The data layer query that a `AshJsonApiWrapper.QueryDialect` builds up.

    `runtime_filter`, `sort`, `limit` and `offset` are applied to the fetched records, see
    `AshJsonApiWrapper.QueryDialect`. `dialect` is free for the dialect's own state.
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
      count?: false,
      dialect: %{}
    ]

    @type t :: %__MODULE__{}
  end

  @behaviour Ash.DataLayer

  @impl true
  def can?(_, :create), do: true
  def can?(resource, feature), do: Info.dialect_module(resource).can?(resource, feature)

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
        Info.dialect_module(resource).filter(query, filter, resource)
    end
  end

  @impl true
  def sort(query, sort, _resource) when sort in [nil, []] do
    {:ok, query}
  end

  def sort(query, sort, resource) do
    Info.dialect_module(resource).sort(query, sort, resource)
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
         body: context[:data_layer][:body],
         headers: headers,
         domain: query.domain,
         action: action,
         endpoint: Info.endpoint(resource, action.name),
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

    with {:ok, %{status: status} = response} when status >= 200 and status < 300 <-
           Info.tesla(resource).get(path,
             body: body,
             query: params,
             headers: headers
           ),
         {:ok, body} <- Jason.decode(response.body),
         {:ok, entities} <- get_entities(body, endpoint),
         {:ok, processed} <-
           process_entities(entities, resource, endpoint) do
      {:ok, Enum.at(processed, 0)}
    else
      {:ok, %{status: status} = response} ->
        # TODO: add method/query params
        {:error,
         "Received status code #{status} from GET #{path}. Response: #{inspect(response)}"}

      other ->
        other
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

  defp get_entities(body, endpoint) do
    case endpoint.entity_path do
      nil ->
        {:ok, List.wrap(body)}

      path ->
        case ExJSONPath.eval(body, path) do
          {:ok, [entities | _]} -> {:ok, List.wrap(entities)}
          {:ok, _} -> {:ok, []}
          {:error, error} -> {:error, error}
        end
    end
  end

  @impl true
  def run_query(%{override_results: results} = query, _resource) when not is_nil(results) do
    {:ok, runtime_sort(results, query)}
  end

  def run_query(query, resource) do
    with {:ok, query} <- Info.dialect_module(resource).paginate(query, resource),
         {:ok, records, _total} <- fetch(query, resource),
         {:ok, records} <- process_entities(records, resource, endpoint(query, resource)),
         {:ok, records} <- runtime_filter(records, query) do
      {:ok, records |> runtime_sort(query) |> limit_offset(query)}
    end
  end

  @impl true
  def run_aggregate_query(query, aggregates, resource) do
    if Enum.all?(aggregates, &countable?(&1, resource)) do
      with {:ok, count} <- count(query, resource) do
        {:ok, Map.new(aggregates, &{&1.name, count})}
      end
    else
      {:error, "Aggregate queries not supported by #{inspect(__MODULE__)}"}
    end
  end

  defp countable?(%{kind: :count, field: nil} = aggregate, resource) do
    is_nil(aggregate.query && aggregate.query.filter) &&
      can?(resource, {:query_aggregate, :count})
  end

  defp countable?(_, _), do: false

  defp count(query, resource) do
    query = %{query | limit: nil, offset: nil, sort: nil}

    with {:ok, nil} <- remote_count(query, resource),
         {:ok, records} <- run_query(query, resource) do
      {:ok, length(records)}
    end
  end

  # Without a runtime filter the total the API reports is the count. Returns `{:ok, nil}` when
  # the records have to be fetched and counted instead.
  defp remote_count(%{runtime_filter: nil} = query, resource) do
    with {:ok, query} <-
           Info.dialect_module(resource).paginate(%{query | count?: true}, resource),
         {:ok, _records, total} <- fetch(query, resource, first_page_only?: true) do
      {:ok, total}
    end
  end

  defp remote_count(_query, _resource), do: {:ok, nil}

  # Returns all raw records of a paginated query and the total reported by the API, or `nil`
  # if any request did not report one.
  defp fetch(query, resource, opts \\ []) do
    dialect = Info.dialect_module(resource)

    with {:ok, requests} <- dialect.build_requests(query, resource) do
      case requests do
        [request] ->
          fetch_pages(request, query, resource, dialect, opts)

        requests ->
          requests
          |> Task.async_stream(&fetch_pages(&1, query, resource, dialect, opts),
            timeout: :infinity
          )
          |> Enum.reduce_while({:ok, [], 0}, fn
            {:ok, {:ok, records, total}}, {:ok, all_records, all_total} ->
              {:cont, {:ok, records ++ all_records, add_total(total, all_total)}}

            {:ok, {:error, error}}, _ ->
              {:halt, {:error, error}}

            {:exit, reason}, _ ->
              {:halt, {:error, "Request process exited with #{inspect(reason)}"}}
          end)
      end
    end
  end

  defp add_total(nil, _), do: nil
  defp add_total(_, nil), do: nil
  defp add_total(left, right), do: left + right

  defp fetch_pages(request, query, resource, dialect, opts, pages \\ [], total \\ nil) do
    with {:ok, body} <- send_request(resource, request),
         {:ok, page} <- dialect.unwrap_response(body, request, query, resource) do
      total = if pages == [], do: page.total, else: total
      pages = [page.records | pages]

      if page.next && !opts[:first_page_only?] do
        fetch_pages(page.next, query, resource, dialect, opts, pages, total)
      else
        {:ok, pages |> Enum.reverse() |> Enum.concat(), total}
      end
    end
  end

  defp send_request(resource, request) do
    {body, headers} = encode_body(request.body, request.headers || [])

    case Info.tesla(resource).request(
           method: request.method,
           url: request.path,
           query: request.query || %{},
           body: body,
           headers: headers
         ) do
      {:ok, %{status: status, body: body}} when status >= 200 and status < 300 ->
        decode_body(body)

      {:ok, %{status: status} = response} ->
        {:error,
         "Received status code #{status} from #{String.upcase(to_string(request.method))} #{request.path}. Response: #{inspect(response)}"}

      {:error, error} ->
        {:error, error}
    end
  end

  defp encode_body(body, headers) when is_nil(body) or is_binary(body), do: {body, headers}

  defp encode_body(body, headers) do
    headers =
      if List.keymember?(headers, "content-type", 0) ||
           List.keymember?(headers, "Content-Type", 0) do
        headers
      else
        [{"content-type", "application/json"} | headers]
      end

    {Jason.encode!(body), headers}
  end

  defp decode_body(body) when is_binary(body), do: Jason.decode(body)
  defp decode_body(body), do: {:ok, body}

  defp runtime_filter(results, %{runtime_filter: nil}), do: {:ok, results}

  defp runtime_filter(results, query) do
    Ash.Filter.Runtime.filter_matches(query.domain, results, query.runtime_filter)
  end

  defp runtime_sort(results, %{sort: sort}) when sort not in [nil, []] do
    Ash.Sort.runtime_sort(results, sort, [])
  end

  defp runtime_sort(results, _), do: results

  defp limit_offset(results, %Query{limit: limit, offset: offset}) do
    results =
      if offset do
        Enum.drop(results, offset)
      else
        results
      end

    if limit do
      Enum.take(results, limit)
    else
      results
    end
  end

  defp endpoint(query, resource) do
    query.endpoint || Info.endpoint(resource, query.action.name)
  end

  defp process_entities(entities, resource, endpoint) do
    Enum.reduce_while(entities, {:ok, []}, fn entity, {:ok, entities} ->
      case process_entity(entity, resource, endpoint) do
        {:ok, entity} -> {:cont, {:ok, [entity | entities]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, entities} -> {:ok, Enum.reverse(entities)}
      {:error, error} -> {:error, error}
    end
  end

  defp process_entity(entity, resource, endpoint) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.reduce_while(
      {:ok,
       struct(resource,
         __meta__: %Ecto.Schema.Metadata{
           state: :loaded
         }
       )},
      fn attr, {:ok, record} ->
        case get_field(entity, attr, resource, endpoint) do
          {:ok, value} ->
            {:cont, {:ok, Map.put(record, attr.name, value)}}

          {:error, error} ->
            {:halt, {:error, error}}
        end
      end
    )
  end

  defp get_field(entity, attr, resource, endpoint) do
    raw_value = get_raw_value(entity, attr, resource, endpoint)

    case Ash.Type.cast_stored(attr.type, raw_value, attr.constraints) do
      {:ok, value} ->
        {:ok, value}

      _ ->
        {:error,
         AshJsonApiWrapper.Errors.InvalidData.exception(field: attr.name, value: raw_value)}
    end
  end

  defp get_raw_value(entity, attr, resource, endpoint) do
    case get_field(resource, endpoint, attr.name) do
      %{path: ""} ->
        entity

      %{path: path} when not is_nil(path) ->
        case ExJSONPath.eval(entity, path) do
          {:ok, [value | _]} ->
            value

          _ ->
            nil
        end

      _ ->
        Map.get(entity, to_string(attr.name))
    end
  end

  defp get_field(resource, endpoint, field) do
    Enum.find(endpoint.fields || [], &(&1.name == field)) ||
      Enum.find(Info.fields(resource), &(&1.name == field))
  end
end

# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.Dialect.OData do
  @moduledoc """
  A dialect for OData v4 APIs.

  Reads are sent as `GET` to the endpoint's path (an entity set such as `/users`) with system
  query options:

  * the filter becomes `$filter`
  * selected attributes become `$select`
  * the sort becomes `$orderby`
  * limit and offset become `$top` and `$skip`
  * `@odata.nextLink` is followed until the limit is reached or there are no more pages

  Each attribute maps to the property of the same name in camelCase (or as is with
  `property_case: :snake`). Set a property explicitly with `properties`.

  ```elixir
  json_api_wrapper do
    dialect {AshJsonApiWrapper.Dialect.OData, count: true, consistency_level: "eventual"}

    endpoints do
      base "https://graph.microsoft.com/v1.0"
      endpoint :read do
        path "/users"
      end
    end
  end
  ```

  ## Filters

  | Ash | OData |
  | --- | --- |
  | `==`, `!=`, `>`, `>=`, `<`, `<=` | `eq`, `ne`, `gt`, `ge`, `lt`, `le` |
  | `in` | `in (...)`, or `eq` joined with `or` when `in_operator: :or` |
  | `is_nil(x)` | `x eq null` |
  | `contains(x, v)` | `contains(x, v)` |
  | `string_starts_with(x, v)` | `startswith(x, v)` |
  | `string_ends_with(x, v)` | `endswith(x, v)` |
  | `and`, `or`, `not` | `and`, `or`, `not` |

  Strings are quoted, UUID attributes, numbers, booleans, dates and times are not.

  ## Counting

  With `count: true`, every request sends `$count=true` and page counts use `@odata.count`.
  Some APIs (Microsoft Graph among them) only accept advanced filters together with
  `$count=true` and the `ConsistencyLevel: eventual` header, set with `consistency_level`.
  """

  use AshJsonApiWrapper.QueryDialect

  alias Ash.Query.{BooleanExpression, Not, Ref}
  alias Ash.Query.Function.{Contains, StringEndsWith, StringStartsWith}

  alias Ash.Query.Operator.{
    Eq,
    GreaterThan,
    GreaterThanOrEqual,
    In,
    IsNil,
    LessThan,
    LessThanOrEqual,
    NotEq
  }

  alias AshJsonApiWrapper.DataLayer.Info
  alias AshJsonApiWrapper.Dialect.{Expr, Naming}
  alias AshJsonApiWrapper.Request

  require Expr

  @impl true
  def opts_schema do
    [
      property_case: [
        type: {:in, [:camel, :snake]},
        default: :camel,
        doc:
          "How attribute names become property names: `display_name` as `displayName` or as is."
      ],
      properties: [
        type: :keyword_list,
        default: [],
        doc: "Property names for attributes, e.g. `[email: \"mail\"]`."
      ],
      count: [
        type: :boolean,
        default: false,
        doc: "Sends `$count=true` with every request and supports page counts."
      ],
      consistency_level: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Sends this value in the `ConsistencyLevel` header, e.g. `\"eventual\"`."
      ],
      in_operator: [
        type: {:in, [:in, :or]},
        default: :in,
        doc: "Sends `in` filters with the OData 4.01 `in` operator, or as `eq` joined with `or`."
      ]
    ]
  end

  @impl true
  def can?(_, feature)
      when feature in [:filter, :boolean_filter, :nested_expressions, :limit, :offset, :select],
      do: true

  def can?(_, :sort), do: true
  def can?(_, {:sort, _}), do: true
  def can?(resource, {:query_aggregate, :count}), do: Info.dialect_opts(resource)[:count]
  def can?(_, {:filter_expr, expr}), do: Expr.supported?(expr)
  def can?(_, _), do: false

  @impl true
  def filter(query, filter, resource) do
    with {:ok, filter} <- translate(filter.expression, resource) do
      {:ok, put_param(query, "$filter", filter)}
    end
  end

  defp translate(%BooleanExpression{op: op, left: left, right: right}, resource) do
    with {:ok, left_filter} <- translate(left, resource),
         {:ok, right_filter} <- translate(right, resource) do
      {:ok, "#{group(left_filter, left, op)} #{op} #{group(right_filter, right, op)}"}
    end
  end

  defp translate(%Not{expression: expression}, resource) do
    with {:ok, filter} <- translate(expression, resource) do
      {:ok, "not (#{filter})"}
    end
  end

  defp translate(%IsNil{left: %Ref{} = ref, right: nil?}, resource) when is_boolean(nil?) do
    {:ok, "#{property(ref, resource)} #{if nil?, do: "eq", else: "ne"} null"}
  end

  defp translate(%In{left: %Ref{} = ref, right: values}, resource) do
    property = property(ref, resource)
    literals = Enum.map(values, &literal(&1, ref))

    case Info.dialect_opts(resource)[:in_operator] do
      :in -> {:ok, "#{property} in (#{Enum.join(literals, ",")})"}
      :or -> {:ok, "(#{Enum.map_join(literals, " or ", &"#{property} eq #{&1}")})"}
    end
  end

  defp translate(%operator{left: left, right: %Ref{}} = expression, resource)
       when operator in Expr.comparisons() and not is_struct(left, Ref) do
    translate(Expr.attribute_left(expression), resource)
  end

  defp translate(%operator{left: %Ref{} = ref, right: value}, resource)
       when operator in Expr.comparisons() do
    {:ok, "#{property(ref, resource)} #{comparison(operator)} #{literal(value, ref)}"}
  end

  defp translate(%function{arguments: [%Ref{} = ref, value]}, resource)
       when function in Expr.functions() do
    {:ok, "#{string_function(function)}(#{property(ref, resource)},#{literal(value, ref)})"}
  end

  defp translate(expression, _resource) do
    {:error, "Cannot translate filter to OData: #{inspect(expression)}"}
  end

  # Parenthesizes a nested `and`/`or` with a different operator than its parent.
  defp group(filter, %BooleanExpression{op: op}, parent_op) when op != parent_op,
    do: "(#{filter})"

  defp group(filter, _expression, _parent_op), do: filter

  defp comparison(Eq), do: "eq"
  defp comparison(NotEq), do: "ne"
  defp comparison(GreaterThan), do: "gt"
  defp comparison(GreaterThanOrEqual), do: "ge"
  defp comparison(LessThan), do: "lt"
  defp comparison(LessThanOrEqual), do: "le"

  defp string_function(Contains), do: "contains"
  defp string_function(StringStartsWith), do: "startswith"
  defp string_function(StringEndsWith), do: "endswith"

  defp literal(nil, _ref), do: "null"
  defp literal(value, _ref) when is_boolean(value), do: to_string(value)
  defp literal(value, _ref) when is_number(value), do: to_string(value)
  defp literal(%Decimal{} = value, _ref), do: Decimal.to_string(value, :normal)
  defp literal(%NaiveDateTime{} = value, _ref), do: NaiveDateTime.to_iso8601(value) <> "Z"

  defp literal(%struct{} = value, _ref) when struct in [Date, Time, DateTime],
    do: Naming.encode_value(value)

  defp literal(value, %Ref{attribute: %{type: type}}) when type in [Ash.Type.UUID, :uuid],
    do: to_string(value)

  defp literal(value, _ref) do
    "'" <> String.replace(to_string(value), "'", "''") <> "'"
  end

  @impl true
  def sort(query, sort, resource) do
    sort
    |> Enum.reduce_while({:ok, []}, fn
      {field, direction}, {:ok, order} when is_atom(field) ->
        if Ash.Resource.Info.attribute(resource, field) do
          {:cont, {:ok, ["#{property(field, resource)} #{direction(direction)}" | order]}}
        else
          {:halt, {:error, "Cannot sort an OData query by #{inspect(field)}"}}
        end

      {field, _direction}, _ ->
        {:halt, {:error, "Cannot sort an OData query by #{inspect(field)}"}}
    end)
    |> case do
      {:ok, order} ->
        {:ok,
         %{put_param(query, "$orderby", order |> Enum.reverse() |> Enum.join(",")) | sort: nil}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp direction(direction) when direction in [:asc, :asc_nils_first, :asc_nils_last], do: "asc"

  defp direction(direction) when direction in [:desc, :desc_nils_first, :desc_nils_last],
    do: "desc"

  @impl true
  def paginate(%{count?: true} = query, _resource) do
    query =
      query
      |> put_param("$top", 1)
      |> put_param("$count", "true")

    {:ok, %{query | limit: nil, offset: nil}}
  end

  def paginate(query, _resource) do
    query =
      query
      |> put_param("$top", query.limit)
      |> put_param("$skip", if(query.offset != 0, do: query.offset))

    {:ok,
     %{query | limit: nil, offset: nil, dialect: Map.put(query.dialect, :limit, query.limit)}}
  end

  @impl true
  def build_requests(query, resource) do
    opts = Info.dialect_opts(resource)

    params =
      query.dialect
      |> Map.get(:params, %{})
      |> Map.merge(select(query, resource))
      |> Map.merge(if opts[:count], do: %{"$count" => "true"}, else: %{})
      |> Map.merge(query.query_params || %{})

    headers =
      if opts[:consistency_level] do
        [{"ConsistencyLevel", opts[:consistency_level]} | query.headers || []]
      else
        query.headers || []
      end

    {:ok,
     [
       %Request{
         method: :get,
         path: endpoint(query, resource).path,
         query: params,
         headers: headers,
         private: %{remaining: query.dialect[:limit]}
       }
     ]}
  end

  defp select(%{select: nil}, _resource), do: %{}

  defp select(query, resource) do
    properties =
      resource
      |> Ash.Resource.Info.attributes()
      |> Enum.filter(&(&1.name in query.select))
      |> Enum.map_join(",", &property(&1.name, resource))

    %{"$select" => properties}
  end

  @impl true
  def unwrap_response(body, request, _query, resource) do
    case body do
      %{"value" => records} when is_list(records) ->
        lookup = lookup(resource)

        {:ok,
         %{
           records: Enum.map(records, &Naming.rename_keys(&1, lookup)),
           total: body["@odata.count"],
           next: next_request(body["@odata.nextLink"], request, length(records))
         }}

      %{"error" => error} ->
        {:error, "OData request failed: #{inspect(error)}"}

      record when is_map(record) ->
        {:ok, %{records: [Naming.rename_keys(record, lookup(resource))], total: nil, next: nil}}

      body ->
        {:error, "Unexpected OData response: #{inspect(body)}"}
    end
  end

  defp next_request(nil, _request, _count), do: nil

  defp next_request(next_link, %{private: %{remaining: nil}} = request, _count) do
    %{request | path: next_link, query: %{}}
  end

  defp next_request(next_link, %{private: %{remaining: remaining}} = request, count) do
    if remaining > count do
      %{request | path: next_link, query: %{}, private: %{remaining: remaining - count}}
    end
  end

  # Maps normalized property names to attribute names.
  defp lookup(resource) do
    resource
    |> Ash.Resource.Info.attribute_names()
    |> Map.new(&{Naming.normalize(property(&1, resource)), to_string(&1)})
  end

  defp property(%Ref{attribute: %{name: name}}, resource), do: property(name, resource)

  defp property(name, resource) do
    opts = Info.dialect_opts(resource)
    Naming.remote_name(name, opts[:property_case], opts[:properties])
  end

  defp put_param(query, _key, nil), do: query

  defp put_param(query, key, value) do
    %{
      query
      | dialect: Map.update(query.dialect, :params, %{key => value}, &Map.put(&1, key, value))
    }
  end

  defp endpoint(query, resource) do
    query.endpoint || Info.endpoint(resource, query.action.name)
  end
end

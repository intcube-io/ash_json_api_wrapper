# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.Dialect.CubeJs do
  @moduledoc """
  A dialect for APIs that speak the Cube.js REST query format.

  Reads are sent as `POST` to the endpoint's path (usually `/cubejs-api/v1/load`) with the body
  `{"query": {...}}`:

  * selected attributes become `dimensions`
  * the filter becomes `filters`
  * the sort becomes `order`
  * limit and offset become `limit` and `offset`, and page counts set `total`

  Each attribute maps to the member `<cube>.<name>`, where the name is the attribute name in
  camelCase (or as is with `member_case: :snake`). Set a member explicitly with `members`.
  Response keys are matched to members ignoring case and underscores.

  ```elixir
  json_api_wrapper do
    dialect {AshJsonApiWrapper.Dialect.CubeJs,
             cube: "Orders", members: [total: "Orders.totalAmount"]}

    endpoints do
      base "https://cube.example.com"
      endpoint :read do
        path "/cubejs-api/v1/load"
      end
    end
  end
  ```

  ## Filters

  | Ash | Cube |
  | --- | --- |
  | `==`, `in` | `equals` |
  | `!=`, `not in` | `notEquals` |
  | `>`, `>=`, `<`, `<=` | `gt`, `gte`, `lt`, `lte` |
  | `is_nil(x)`, `not is_nil(x)` | `notSet`, `set` |
  | `contains(x, v)` | `contains` |
  | `string_starts_with(x, v)` | `startsWith` |
  | `string_ends_with(x, v)` | `endsWith` |
  | `and`, `or` | `and`, `or` groups |

  `not` is pushed down to the operators it wraps. Filter values are sent as strings, dates and
  times in ISO 8601.

  ## Paging

  Without a limit, all rows are fetched in pages of `page_size` rows.
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
      cube: [
        type: :string,
        required: true,
        doc: "The cube that member names are prefixed with."
      ],
      member_case: [
        type: {:in, [:camel, :snake]},
        default: :camel,
        doc: "How attribute names become member names: `created_at` as `createdAt` or as is."
      ],
      members: [
        type: :keyword_list,
        default: [],
        doc: "Full member names for attributes, e.g. `[total: \"Orders.totalAmount\"]`."
      ],
      ungrouped: [
        type: :boolean,
        default: false,
        doc: "Sends `ungrouped: true`, so rows are not grouped by their dimensions."
      ],
      page_size: [
        type: :pos_integer,
        default: 10_000,
        doc: "Rows per request when reading without a limit."
      ]
    ]
  end

  @impl true
  def can?(_, feature)
      when feature in [:filter, :boolean_filter, :nested_expressions, :limit, :offset, :select],
      do: true

  def can?(_, :sort), do: true
  def can?(_, {:sort, _}), do: true
  def can?(_, {:query_aggregate, :count}), do: true
  def can?(_, {:filter_expr, expr}), do: Expr.supported?(expr)
  def can?(_, _), do: false

  @impl true
  def filter(query, filter, resource) do
    with {:ok, filters} <- filters(filter.expression, resource) do
      {:ok, put_state(query, :filters, filters)}
    end
  end

  # A top level `and` is a plain list of filters.
  defp filters(%BooleanExpression{op: :and, left: left, right: right}, resource) do
    with {:ok, left} <- filters(left, resource),
         {:ok, right} <- filters(right, resource) do
      {:ok, left ++ right}
    end
  end

  defp filters(expression, resource) do
    with {:ok, filter} <- translate(expression, false, resource) do
      {:ok, [filter]}
    end
  end

  defp translate(%BooleanExpression{op: op, left: left, right: right}, negated?, resource) do
    # not (a or b) == not a and not b
    op = if negated?, do: flip(op), else: op

    with {:ok, left} <- translate(left, negated?, resource),
         {:ok, right} <- translate(right, negated?, resource) do
      {:ok, %{to_string(op) => flatten(op, left) ++ flatten(op, right)}}
    end
  end

  defp translate(%Not{expression: expression}, negated?, resource) do
    translate(expression, not negated?, resource)
  end

  defp translate(%IsNil{left: %Ref{} = ref, right: nil?}, negated?, resource)
       when is_boolean(nil?) do
    operator = if nil? != negated?, do: "notSet", else: "set"
    {:ok, %{"member" => member(ref, resource), "operator" => operator}}
  end

  defp translate(%In{left: %Ref{} = ref, right: values}, negated?, resource) do
    operator = if negated?, do: "notEquals", else: "equals"
    {:ok, member_filter(ref, operator, Enum.to_list(values), resource)}
  end

  defp translate(%operator{left: left, right: %Ref{}} = expression, negated?, resource)
       when operator in Expr.comparisons() and not is_struct(left, Ref) do
    translate(Expr.attribute_left(expression), negated?, resource)
  end

  defp translate(%operator{left: %Ref{} = ref, right: value}, negated?, resource)
       when operator in Expr.comparisons() do
    {:ok, member_filter(ref, comparison(operator, negated?), [value], resource)}
  end

  defp translate(%function{arguments: [%Ref{} = ref, value]}, negated?, resource)
       when function in Expr.functions() do
    {:ok, member_filter(ref, string_operator(function, negated?), [value], resource)}
  end

  defp translate(expression, _negated?, _resource) do
    {:error, "Cannot translate filter to a Cube query: #{inspect(expression)}"}
  end

  defp flip(:and), do: :or
  defp flip(:or), do: :and

  defp flatten(op, filter) do
    case Map.fetch(filter, to_string(op)) do
      {:ok, filters} -> filters
      :error -> [filter]
    end
  end

  defp comparison(Eq, false), do: "equals"
  defp comparison(Eq, true), do: "notEquals"
  defp comparison(NotEq, false), do: "notEquals"
  defp comparison(NotEq, true), do: "equals"
  defp comparison(GreaterThan, false), do: "gt"
  defp comparison(GreaterThan, true), do: "lte"
  defp comparison(GreaterThanOrEqual, false), do: "gte"
  defp comparison(GreaterThanOrEqual, true), do: "lt"
  defp comparison(LessThan, false), do: "lt"
  defp comparison(LessThan, true), do: "gte"
  defp comparison(LessThanOrEqual, false), do: "lte"
  defp comparison(LessThanOrEqual, true), do: "gt"

  defp string_operator(Contains, false), do: "contains"
  defp string_operator(Contains, true), do: "notContains"
  defp string_operator(StringStartsWith, false), do: "startsWith"
  defp string_operator(StringStartsWith, true), do: "notStartsWith"
  defp string_operator(StringEndsWith, false), do: "endsWith"
  defp string_operator(StringEndsWith, true), do: "notEndsWith"

  defp member_filter(ref, operator, values, resource) do
    %{
      "member" => member(ref, resource),
      "operator" => operator,
      "values" => Enum.map(values, &Naming.encode_value/1)
    }
  end

  @impl true
  def sort(query, sort, resource) do
    sort
    |> Enum.reduce_while({:ok, []}, fn
      {field, direction}, {:ok, order} when is_atom(field) ->
        if Ash.Resource.Info.attribute(resource, field) do
          {:cont, {:ok, [[member(field, resource), direction(direction)] | order]}}
        else
          {:halt, {:error, "Cannot sort a Cube query by #{inspect(field)}"}}
        end

      {field, _direction}, _ ->
        {:halt, {:error, "Cannot sort a Cube query by #{inspect(field)}"}}
    end)
    |> case do
      {:ok, order} -> {:ok, %{put_state(query, :order, Enum.reverse(order)) | sort: nil}}
      {:error, error} -> {:error, error}
    end
  end

  defp direction(direction) when direction in [:asc, :asc_nils_first, :asc_nils_last], do: "asc"

  defp direction(direction) when direction in [:desc, :desc_nils_first, :desc_nils_last],
    do: "desc"

  @impl true
  def paginate(%{count?: true} = query, _resource) do
    {:ok, %{put_state(query, :page, %{"limit" => 1, "total" => true}) | limit: nil, offset: nil}}
  end

  def paginate(query, _resource) do
    page =
      %{"limit" => query.limit, "offset" => query.offset}
      |> Map.reject(fn {_, value} -> value in [nil, 0] end)

    {:ok, %{put_state(query, :page, page) | limit: nil, offset: nil}}
  end

  @impl true
  def build_requests(query, resource) do
    opts = Info.dialect_opts(resource)
    page = query.dialect[:page] || %{}

    {page, private} =
      if Map.has_key?(page, "limit") do
        {page, %{}}
      else
        page_size = opts[:page_size]
        {Map.put(page, "limit", page_size), %{page_size: page_size}}
      end

    cube_query =
      %{
        "dimensions" => dimensions(query, resource),
        "filters" => query.dialect[:filters] || [],
        "order" => query.dialect[:order] || []
      }
      |> Map.merge(page)
      |> Map.merge(if opts[:ungrouped], do: %{"ungrouped" => true}, else: %{})

    {:ok,
     [
       %Request{
         method: :post,
         path: endpoint(query, resource).path,
         query: query.query_params || %{},
         body: %{"query" => cube_query},
         headers: query.headers || [],
         private: private
       }
     ]}
  end

  defp dimensions(query, resource) do
    names = query.select || Ash.Resource.Info.attribute_names(resource)

    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.filter(&(&1.name in names))
    |> Enum.map(&member(&1.name, resource))
  end

  @impl true
  def unwrap_response(body, request, _query, resource) do
    body =
      case body do
        %{"results" => [result | _]} -> result
        body -> body
      end

    case body do
      %{"error" => error} ->
        {:error, "Cube query failed: #{inspect(error)}"}

      %{"data" => rows} when is_list(rows) ->
        lookup = lookup(resource)

        {:ok,
         %{
           records: Enum.map(rows, &Naming.rename_keys(&1, lookup)),
           total: body["total"],
           next: next_request(request, rows)
         }}

      body ->
        {:error, "Unexpected Cube response: #{inspect(body)}"}
    end
  end

  defp next_request(%{private: %{page_size: page_size}} = request, rows)
       when length(rows) == page_size do
    query = request.body["query"]
    query = Map.put(query, "offset", (query["offset"] || 0) + page_size)
    %{request | body: %{request.body | "query" => query}}
  end

  defp next_request(_request, _rows), do: nil

  # Maps normalized member names, with and without the cube prefix, to attribute names.
  defp lookup(resource) do
    resource
    |> Ash.Resource.Info.attribute_names()
    |> Enum.flat_map(fn name ->
      member = member(name, resource)
      short = member |> String.split(".") |> List.last()
      [{Naming.normalize(member), to_string(name)}, {Naming.normalize(short), to_string(name)}]
    end)
    |> Map.new()
  end

  defp member(%Ref{attribute: %{name: name}}, resource), do: member(name, resource)

  defp member(name, resource) do
    opts = Info.dialect_opts(resource)

    case Keyword.fetch(opts[:members], name) do
      {:ok, member} -> member
      :error -> "#{opts[:cube]}.#{Naming.remote_name(name, opts[:member_case], [])}"
    end
  end

  defp put_state(query, key, value) do
    %{query | dialect: Map.put(query.dialect, key, value)}
  end

  defp endpoint(query, resource) do
    query.endpoint || Info.endpoint(resource, query.action.name)
  end
end

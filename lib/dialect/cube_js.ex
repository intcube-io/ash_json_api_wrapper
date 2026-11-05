# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.Dialect.CubeJs do
  @moduledoc """
  Reads from APIs that take a [Cube.js REST query](https://cube.dev/docs/product/apis-integrations/rest-api/query-format):
  `dimensions`, `filters` (`member`/`operator`/`values`, nested `and`/`or`),
  `timeDimensions`, `order`, `limit`, `offset` and `total`.

      json_api_wrapper do
        tesla MyApp.ApiClient
        dialect {AshJsonApiWrapper.Dialect.CubeJs, member_case: :camel, response_case: :snake}

        endpoints do
          base "https://api.example.com"
          endpoint :read do
            path "/load/orders"
          end
        end

        fields do
          field :created_at do
            time_dimension? true
          end
        end
      end

  ## Translation

  | Ash                                 | Cube                                        |
  | ----------------------------------- | ------------------------------------------- |
  | `a == x`, `a in [x, y]`             | `equals` (`values` as strings)              |
  | `contains(a, x)`                    | `contains`                                  |
  | `string_starts_with(a, x)`          | `startsWith`                                |
  | `is_nil(a)` / `not is_nil(a)`       | `notSet` / `set`                            |
  | `a > x`, `>=`, `<`, `<=`            | `gt`, `gte`, `lt`, `lte`                    |
  | `and` / `or`                        | the root list (AND) / nested `and`/`or`     |
  | `t >= x and t <= y` on a time field | `timeDimensions: [%{dateRange: [x, y]}]`    |
  | sort                                | `order`, in sort order                      |
  | limit / offset                      | `limit` / `offset`, paged by `page_size`    |
  | selected attributes                 | `dimensions`                                |

  Cube's `contains` and `startsWith` are usually case-insensitive while Ash's
  runtime versions are not. A range on a time dimension needs both ends and
  cannot sit inside an `or`.

  Which filters a field accepts can be narrowed with the field's
  `filter_operators`; `member false` marks a field the API returns on its own
  but does not accept as a dimension.

  ## Options

  * `:query_key` - the body key wrapping the query, `"query"` by default. `nil`
    sends the query as the body itself.
  * `:member_case` - how attribute names become member names: `:camel` (default),
    `:snake` or `:as_is`. A field's `member` overrides it.
  * `:response_case` - how attribute names become response keys: `:camel`
    (default), `:snake` or `:as_is`. A field's `path` overrides it.
  * `:page_size` - the most rows asked for in one request (default 1000). A read
    without a limit, or with a bigger one, fetches page after page.
  * `:total` - send `"total": true`, so responses carry the match count (default
    `true`). Set to `false` for APIs that reject it; the count behind
    `page[count]` is then read from whatever `total` the response carries.
  * `:entity_key` / `:total_key` - where rows and the count are in the response
    (`"data"` and `"total"`).
  """

  use AshJsonApiWrapper.QueryDialect

  alias AshJsonApiWrapper.DataLayer.Info
  alias AshJsonApiWrapper.Request

  @operators %{
    Ash.Query.Operator.Eq => :eq,
    Ash.Query.Operator.In => :in,
    Ash.Query.Operator.IsNil => :is_nil,
    Ash.Query.Operator.GreaterThan => :gt,
    Ash.Query.Operator.GreaterThanOrEqual => :gte,
    Ash.Query.Operator.LessThan => :lt,
    Ash.Query.Operator.LessThanOrEqual => :lte,
    Ash.Query.Function.Contains => :contains,
    Ash.Query.Function.StringStartsWith => :string_starts_with
  }

  @all_operators Map.values(@operators)
  @time_operators [:gte, :lte]

  @cube_operators %{
    contains: "contains",
    string_starts_with: "startsWith",
    gt: "gt",
    gte: "gte",
    lt: "lt",
    lte: "lte"
  }

  @defaults [
    query_key: "query",
    member_case: :camel,
    response_case: :camel,
    page_size: 1000,
    total: true,
    entity_key: "data",
    total_key: "total"
  ]

  defp opt(opts, key), do: Keyword.get(opts, key, @defaults[key])

  # ── can? ──

  @impl true
  def can?(_, :read, _), do: true
  def can?(_, :filter, _), do: true
  def can?(_, :boolean_filter, _), do: true
  def can?(_, :nested_expressions, _), do: true
  def can?(_, :limit, _), do: true
  def can?(_, :offset, _), do: true
  def can?(_, :sort, _), do: true
  def can?(_, {:sort, _}, _), do: true
  def can?(_, :select, _), do: true
  def can?(_, {:query_aggregate, :count}, _), do: true

  def can?(resource, {:filter_expr, %Ash.Query.Not{expression: expression}}, _) do
    match?(%Ash.Query.Operator.IsNil{}, expression) and
      filterable?(resource, expression)
  end

  def can?(resource, {:filter_expr, expression}, _), do: filterable?(resource, expression)
  def can?(_, _, _), do: false

  defp filterable?(resource, expression) do
    case comparison(expression) do
      {:ok, operator, %Ash.Query.Ref{relationship_path: [], attribute: %{name: name}}, _value} ->
        field = Info.field(resource, name)
        operator in allowed_operators(field)

      _ ->
        false
    end
  end

  defp allowed_operators(nil), do: @all_operators

  defp allowed_operators(field) do
    supported =
      cond do
        field.member == false -> []
        field.time_dimension? -> @time_operators
        true -> @all_operators
      end

    case field.filter_operators do
      nil -> supported
      operators -> Enum.filter(supported, &(&1 in operators))
    end
  end

  # Splits a supported expression into {operator, ref, value}, with the ref on the left.
  defp comparison(%{__struct__: struct} = expression) do
    case Map.fetch(@operators, struct) do
      {:ok, operator} ->
        {left, right} = sides(expression)

        case {left, right} do
          {%Ash.Query.Ref{} = ref, value} when not is_struct(value, Ash.Query.Ref) ->
            if expression?(value), do: :error, else: {:ok, operator, ref, value}

          {value, %Ash.Query.Ref{} = ref} when operator in [:eq] ->
            if expression?(value), do: :error, else: {:ok, operator, ref, value}

          {value, %Ash.Query.Ref{} = ref} when operator in [:gt, :gte, :lt, :lte] ->
            if expression?(value), do: :error, else: {:ok, flip(operator), ref, value}

          _ ->
            :error
        end

      :error ->
        :error
    end
  end

  defp comparison(_), do: :error

  defp sides(%{arguments: [left, right]}), do: {left, right}
  defp sides(%{left: left, right: right}), do: {left, right}

  defp flip(:gt), do: :lt
  defp flip(:gte), do: :lte
  defp flip(:lt), do: :gt
  defp flip(:lte), do: :gte

  defp expression?(value) do
    is_struct(value) and
      (Ash.Expr.expr?(value) or match?(%Ash.Query.Ref{}, value))
  end

  # ── filter ──

  @impl true
  def filter(query, %Ash.Filter{expression: expression}, resource, opts) do
    with {:ok, filters, ranges} <- translate_root(expression, resource, opts) do
      state = state(query)

      with {:ok, ranges} <- merge_ranges(state.ranges, ranges) do
        {:ok,
         %{query | dialect_state: %{state | filters: state.filters ++ filters, ranges: ranges}}}
      end
    end
  end

  defp translate_root(expression, resource, opts) do
    expression
    |> and_parts()
    |> Enum.reduce_while({:ok, [], %{}}, fn part, {:ok, filters, ranges} ->
      case time_range(part, resource) do
        {:ok, member_name, bound, value} ->
          {:cont, {:ok, filters, add_bound(ranges, member_name, bound, value)}}

        :error ->
          case translate(part, resource, opts) do
            {:ok, filter} -> {:cont, {:ok, filters ++ [filter], ranges}}
            {:error, error} -> {:halt, {:error, error}}
          end
      end
    end)
  end

  defp and_parts(%Ash.Query.BooleanExpression{op: :and, left: left, right: right}),
    do: and_parts(left) ++ and_parts(right)

  defp and_parts(expression), do: [expression]

  defp time_range(expression, resource) do
    with {:ok, operator, %{attribute: %{name: name}}, value} when operator in @time_operators <-
           comparison(expression),
         %{time_dimension?: true} = field <- Info.field(resource, name) do
      {:ok, field.name, if(operator == :gte, do: :from, else: :to), value}
    else
      _ -> :error
    end
  end

  defp add_bound(ranges, name, bound, value) do
    Map.update(ranges, name, %{bound => value}, &Map.put(&1, bound, value))
  end

  defp merge_ranges(left, right) do
    Enum.reduce_while(right, {:ok, left}, fn {name, bounds}, {:ok, acc} ->
      merged = Map.merge(Map.get(acc, name, %{}), bounds)
      {:cont, {:ok, Map.put(acc, name, merged)}}
    end)
  end

  defp translate(%Ash.Query.BooleanExpression{op: op} = expression, resource, opts) do
    expression
    |> flatten(op)
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case translate(part, resource, opts) do
        {:ok, filter} -> {:cont, {:ok, acc ++ [filter]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, %{to_string(op) => parts}}
      {:error, error} -> {:error, error}
    end
  end

  defp translate(%Ash.Query.Not{expression: %Ash.Query.Operator.IsNil{} = is_nil}, resource, opts) do
    with {:ok, %{"operator" => operator} = filter} <- translate(is_nil, resource, opts) do
      {:ok, %{filter | "operator" => if(operator == "set", do: "notSet", else: "set")}}
    end
  end

  defp translate(expression, resource, opts) do
    case comparison(expression) do
      {:ok, operator, %{attribute: %{name: name}}, value} ->
        field = Info.field(resource, name)

        cond do
          field && field.time_dimension? ->
            {:error,
             "A range on the time dimension #{inspect(name)} has to be a top-level `>=`/`<=` " <>
               "pair; it cannot be part of an `or`."}

          operator not in allowed_operators(field) ->
            {:error, "Filtering #{inspect(name)} with #{operator} is not supported."}

          true ->
            {:ok, cube_filter(member(resource, name, opts), operator, value)}
        end

      :error ->
        {:error, "Cannot translate #{inspect(expression)} into a Cube.js filter."}
    end
  end

  defp flatten(%Ash.Query.BooleanExpression{op: op, left: left, right: right}, op),
    do: flatten(left, op) ++ flatten(right, op)

  defp flatten(expression, _op), do: [expression]

  defp cube_filter(member, :eq, value),
    do: %{"member" => member, "operator" => "equals", "values" => [value_string(value)]}

  defp cube_filter(member, :in, values) do
    %{
      "member" => member,
      "operator" => "equals",
      "values" => Enum.map(values, &value_string/1)
    }
  end

  defp cube_filter(member, :is_nil, true), do: %{"member" => member, "operator" => "notSet"}
  defp cube_filter(member, :is_nil, false), do: %{"member" => member, "operator" => "set"}

  defp cube_filter(member, operator, value) do
    %{
      "member" => member,
      "operator" => Map.fetch!(@cube_operators, operator),
      "values" => [value_string(value)]
    }
  end

  defp value_string(%Ash.CiString{} = value), do: Ash.CiString.value(value)
  defp value_string(%Date{} = value), do: Date.to_iso8601(value)
  defp value_string(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp value_string(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp value_string(%Decimal{} = value), do: Decimal.to_string(value)
  defp value_string(value) when is_binary(value), do: value
  defp value_string(value), do: to_string(value)

  # ── sort ──

  @impl true
  def sort(query, sort, resource, opts) do
    sort
    |> Enum.reduce_while({:ok, []}, fn
      {name, direction}, {:ok, acc} when is_atom(name) ->
        case Info.field(resource, name) do
          %{member: false} ->
            {:halt, {:error, "Cannot sort by #{inspect(name)}."}}

          _ ->
            {:cont, {:ok, acc ++ [{member(resource, name, opts), direction(direction)}]}}
        end

      {other, _}, _ ->
        {:halt, {:error, "Cannot sort by #{inspect(other)}."}}
    end)
    |> case do
      {:ok, order} ->
        state = state(query)
        {:ok, %{query | dialect_state: %{state | order: order}}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp direction(direction) when direction in [:desc, :desc_nils_first, :desc_nils_last],
    do: "desc"

  defp direction(_), do: "asc"

  # ── request ──

  @impl true
  def build_request(query, resource, opts) do
    with {:ok, body} <- query_body(query, resource, opts, page_limit(query, opts)) do
      {:ok, request(query, opts, body)}
    end
  end

  defp request(query, opts, body) do
    body =
      case opt(opts, :query_key) do
        nil -> body
        key -> %{key => body}
      end

    %Request{
      method: query.endpoint.method || :post,
      path: query.endpoint.path,
      query_params: query.query_params || %{},
      body: body,
      headers: query.headers || []
    }
  end

  defp query_body(query, resource, opts, limit) do
    state = state(query)

    with {:ok, time_dimensions} <- time_dimensions(state.ranges, resource, opts) do
      body =
        [
          {"dimensions", dimensions(query, resource, opts)},
          {"filters", state.filters},
          {"timeDimensions", time_dimensions},
          {"order", if(state.order != [], do: Jason.OrderedObject.new(state.order))},
          {"limit", limit},
          {"offset", (query.offset || 0) + state.fetched},
          {"total", if(opt(opts, :total), do: true)}
        ]
        |> Enum.reject(fn {_key, value} -> value in [nil, []] end)
        |> Map.new()

      {:ok, body}
    end
  end

  defp dimensions(query, resource, opts) do
    primary_key = Ash.Resource.Info.primary_key(resource)

    names =
      case query.select do
        nil -> Enum.map(Ash.Resource.Info.attributes(resource), & &1.name)
        select -> Enum.uniq(primary_key ++ select)
      end

    names
    |> Enum.reject(fn name ->
      case Info.field(resource, name) do
        %{member: false} -> true
        %{time_dimension?: true} -> true
        _ -> false
      end
    end)
    |> Enum.map(&member(resource, &1, opts))
  end

  defp time_dimensions(ranges, resource, opts) do
    Enum.reduce_while(ranges, {:ok, []}, fn
      {name, %{from: from, to: to}}, {:ok, acc} ->
        {:cont,
         {:ok,
          acc ++
            [
              %{
                "dimension" => member(resource, name, opts),
                "dateRange" => [value_string(from), value_string(to)]
              }
            ]}}

      {name, _}, _ ->
        {:halt,
         {:error,
          "A filter on the time dimension #{inspect(name)} needs both a lower (`>=`) and an upper (`<=`) bound."}}
    end)
  end

  defp page_limit(query, opts) do
    page_size = opt(opts, :page_size)
    fetched = state(query).fetched

    case query.limit do
      nil -> page_size
      limit -> min(limit - fetched, page_size)
    end
  end

  # ── response ──

  @impl true
  def unwrap_response(body, query, _resource, opts) when is_map(body) do
    case Map.fetch(body, opt(opts, :entity_key)) do
      {:ok, entities} when is_list(entities) ->
        total = Map.get(body, opt(opts, :total_key))
        {:ok, %{entities: entities, total: total, next: next(query, entities, total, opts)}}

      _ ->
        case body do
          %{"error" => error} ->
            {:error, error}

          _ ->
            {:error,
             "The response has no #{inspect(opt(opts, :entity_key))} list: #{inspect(body)}"}
        end
    end
  end

  def unwrap_response(body, _query, _resource, _opts) do
    {:error, "Expected a JSON object, got: #{inspect(body)}"}
  end

  defp next(query, entities, total, opts) do
    asked = page_limit(query, opts)
    state = state(query)
    fetched = state.fetched + length(entities)
    position = (query.offset || 0) + fetched

    cond do
      length(entities) < asked -> :halt
      query.limit && fetched >= query.limit -> :halt
      is_integer(total) && position >= total -> :halt
      true -> {:continue, %{query | dialect_state: %{state | fetched: fetched}}}
    end
  end

  @impl true
  def response_key(attribute, _resource, opts) do
    convert(attribute, opt(opts, :response_case))
  end

  # ── count ──

  @impl true
  def run_aggregate_query(query, aggregates, resource, opts) do
    if Enum.all?(aggregates, &(&1.kind == :count)) do
      count_query = %{query | offset: 0, limit: nil, dialect_state: %{state(query) | order: []}}

      with {:ok, body} <- query_body(count_query, resource, opts, 1),
           {:ok, response, _env} <- Request.send(resource, request(count_query, opts, body)) do
        case response do
          %{} ->
            case Map.get(response, opt(opts, :total_key)) do
              total when is_integer(total) ->
                {:ok, Map.new(aggregates, &{&1.name, total})}

              _ ->
                {:error, "The response carries no total, so the records cannot be counted."}
            end

          other ->
            {:error, "Expected a JSON object, got: #{inspect(other)}"}
        end
      end
    else
      {:error, "Only count aggregates are supported."}
    end
  end

  # ── generator support ──

  @impl true
  def query_request?(schema, spec, opts) do
    schema = resolve(schema, spec)

    query =
      case opt(opts, :query_key) do
        nil -> schema
        key -> resolve(get_in(schema, ["properties", key]) || %{}, spec)
      end

    properties = Map.keys(Map.get(query, "properties", %{}))
    Enum.any?(["dimensions", "filters", "measures", "timeDimensions"], &(&1 in properties))
  end

  @impl true
  def entity_path(opts), do: opt(opts, :entity_key)

  defp resolve(%{"$ref" => "#/" <> ref}, spec) do
    spec
    |> get_in(String.split(ref, "/"))
    |> resolve(spec)
  end

  defp resolve(schema, _spec), do: schema || %{}

  # ── helpers ──

  defp state(%{dialect_state: %{filters: _} = state}), do: state
  defp state(_), do: %{filters: [], ranges: %{}, order: [], fetched: 0}

  @doc false
  def member(resource, name, opts) do
    case Info.field(resource, name) do
      %{member: member} when is_binary(member) -> member
      _ -> convert(name, opt(opts, :member_case))
    end
  end

  @doc false
  def convert_name(name, style), do: convert(name, style)

  defp convert(name, :as_is), do: to_string(name)
  defp convert(name, :snake), do: name |> to_string() |> Macro.underscore()

  defp convert(name, :camel) do
    case name |> to_string() |> Macro.camelize() do
      <<first::utf8, rest::binary>> -> String.downcase(<<first::utf8>>) <> rest
      "" -> ""
    end
  end
end

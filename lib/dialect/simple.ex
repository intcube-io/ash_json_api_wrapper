# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.Dialect.Simple do
  @moduledoc """
  The default dialect.

  * Equality and `in` filters over fields with a `filter_handler` become query
    params (`:simple`), list or CSV list entries (`{:place_in_list, path}`,
    `{:place_in_csv_list, path}`), or fill a `get_endpoint`'s path template.
    Everything else is filtered at runtime after the response arrives.
  * Sorting happens at runtime when the endpoint sets `runtime_sort? true`.
  * Limits go into a query param with `limit_with {:param, "name"}`; paging
    through results uses the endpoint's `paginator`.
  """

  use AshJsonApiWrapper.QueryDialect

  require Logger

  alias AshJsonApiWrapper.DataLayer.Info
  alias AshJsonApiWrapper.DataLayer.Query

  @impl true
  def can?(_, :create, _), do: true
  def can?(_, :read, _), do: true
  def can?(_, :boolean_filter, _), do: true
  def can?(_, :filter, _), do: true
  def can?(_, :limit, _), do: true
  def can?(_, :offset, _), do: true

  def can?(
        _,
        {:filter_expr,
         %Ash.Query.Operator.Eq{
           left: %Ash.Query.Operator.Eq{left: %Ash.Query.Ref{}, right: %Ash.Query.Ref{}}
         }},
        _
      ),
      do: false

  def can?(_, {:filter_expr, %Ash.Query.Operator.Eq{right: %Ash.Query.Ref{}}}, _), do: true
  def can?(_, {:filter_expr, %Ash.Query.Operator.Eq{left: %Ash.Query.Ref{}}}, _), do: true
  def can?(_, {:filter_expr, %Ash.Query.Operator.In{right: %Ash.Query.Ref{}}}, _), do: false

  def can?(_, {:filter_expr, %Ash.Query.Operator.In{left: %Ash.Query.Ref{}}}, _), do: true
  def can?(_, :nested_expressions, _), do: true
  def can?(_, :sort, _), do: true
  def can?(_, {:sort, _}, _), do: true
  def can?(_, _, _), do: false

  @impl true
  def response_key(attribute, _resource, _opts), do: to_string(attribute)

  @impl true
  def filter(query, filter, resource, _opts) do
    if query.action do
      case validate_filter(filter, resource, query.action) do
        {:ok, {endpoint, templates, instructions}, remaining_filter} ->
          {templates, instructions} = expand_templates(templates, instructions)

          new_query_params =
            Enum.reduce(instructions || [], query.query_params || %{}, fn
              {:set, field, value}, query ->
                field =
                  field
                  |> List.wrap()
                  |> Enum.map(&to_string/1)

                AshJsonApiWrapper.Helpers.put_at_path(query, field, value)

              {:place_in_list, path, value}, query ->
                update_in!(query, path, [value], &[value | &1])

              {:place_in_csv_list, path, value}, query ->
                update_in!(query, path, "#{value}", &"#{&1},#{value}")
            end)

          {:ok,
           %{
             query
             | endpoint: endpoint,
               templates: templates,
               runtime_filter: remaining_filter,
               query_params: new_query_params
           }}

        {:error, error} ->
          {:error, error}
      end
    else
      {:ok, %{query | filter: filter}}
    end
  end

  defp expand_templates(templates, instructions) do
    if templates && !Enum.empty?(templates) do
      {templates, instructions}
    else
      instructions =
        instructions
        |> Enum.reduce([], fn
          {:expand_set, field, values} = instruction, new_instructions ->
            if Enum.any?(new_instructions, &match?({:expand_set, ^field, _}, &1)) do
              Enum.map(new_instructions, fn
                {:expand_set, ^field, other_values} ->
                  {:expand_set, field,
                   other_values
                   |> MapSet.new()
                   |> MapSet.intersection(MapSet.new(values))
                   |> MapSet.to_list()}

                other ->
                  other
              end)
            else
              [instruction | new_instructions]
            end

          instruction, new_instructions ->
            [instruction | new_instructions]
        end)

      {expand_set, instructions} =
        Enum.split_with(instructions || [], &match?({:expand_set, _, _}, &1))

      templates =
        case Enum.at(expand_set, 0) do
          nil -> nil
          {:expand_set, field, values} -> Enum.map(values, &{:set, field, &1})
        end

      {templates, instructions}
    end
  end

  @impl true
  def sort(query, sort, _resource, _opts) do
    if query.endpoint.runtime_sort? do
      {:ok, %{query | sort: sort}}
    else
      {:error, "Sorting is not supported"}
    end
  end

  defp validate_filter(filter, resource, action) when filter in [nil, true] do
    {:ok, {Info.endpoint(resource, action.name), nil, []}, filter}
  end

  defp validate_filter(filter, resource, action) do
    case AshJsonApiWrapper.Filter.find_filter_that_uses_get_endpoint(filter, resource, action) do
      {:ok, {remaining_filter, get_endpoint, templates}} ->
        {:ok, {get_endpoint, templates, []}, remaining_filter}

      {:ok, nil} ->
        endpoint = Info.endpoint(resource, action.name)

        case filter_instructions(filter, resource, endpoint) do
          {:ok, instructions, remaining_filter} ->
            {:ok, {endpoint, nil, instructions}, remaining_filter}

          {:error, error} ->
            {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp filter_instructions(filter, resource, endpoint) do
    fields =
      endpoint.fields
      |> Enum.concat(Info.fields(resource))
      |> Enum.uniq_by(& &1.name)
      |> List.wrap()
      |> Enum.filter(& &1.filter_handler)

    Enum.reduce_while(fields, {:ok, [], filter}, fn field, {:ok, instructions, filter} ->
      case field_filter(filter, field) do
        {:ok, nil} ->
          {:cont, {:ok, instructions, filter}}

        {:ok, {remaining_filter, new_instructions}} ->
          {:cont, {:ok, new_instructions ++ instructions, remaining_filter}}
      end
    end)
  end

  defp field_filter(filter, field) do
    case field.filter_handler do
      :simple ->
        AshJsonApiWrapper.Filter.find_simple_filter(filter, field.name)

      {:simple, path} ->
        case AshJsonApiWrapper.Filter.find_simple_filter(filter, field.name) do
          {:ok, {remaining_filter, new_instructions}} ->
            field_name = field.name

            {:ok,
             {remaining_filter,
              Enum.map(new_instructions, fn
                {:set, ^field_name, value} -> {:set, path, value}
                {:expand_set, ^field_name, values} -> {:expand_set, path, values}
                other -> other
              end)}}

          other ->
            other
        end

      {:place_in_list, path} ->
        AshJsonApiWrapper.Filter.find_place_in_list_filter(
          filter,
          field.name,
          path,
          :place_in_list
        )

      {:place_in_csv_list, path} ->
        AshJsonApiWrapper.Filter.find_place_in_list_filter(
          filter,
          field.name,
          path,
          :place_in_csv_list
        )
    end
  end

  defp update_in!(body, [key], default, func) do
    body
    |> Kernel.||(%{})
    |> Map.put_new(key, default)
    |> Map.update!(key, func)
  end

  defp update_in!(body, [first | rest], default, func) do
    body
    |> Map.put_new(first, %{})
    |> Map.update!(first, &update_in!(&1, rest, default, func))
  end

  @impl true
  def run_query(query, resource, opts, overridden? \\ false)

  def run_query(query, resource, opts, overridden?) do
    endpoint = query.endpoint || Info.endpoint(resource, query.action.name)

    query =
      if overridden? do
        query
      else
        %{query | path: endpoint.path}
      end

    if query.templates do
      query.templates
      |> Enum.uniq()
      |> Task.async_stream(
        fn template ->
          query
          |> fill_template(template)
          |> Map.put(:templates, nil)
          |> run_query(resource, opts, true)
        end,
        timeout: :infinity
      )
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, {:ok, results}}, {:ok, all_results} ->
          {:cont, {:ok, results ++ all_results}}

        {:ok, {:error, error}}, _ ->
          {:halt, {:error, error}}

        {:exit, reason}, _ ->
          {:halt, {:error, "Request process exited with #{inspect(reason)}"}}
      end)
    else
      query = apply_limit(query, endpoint)

      query =
        if endpoint.paginator do
          %{paginator: {module, paginator_opts}} = endpoint
          {:ok, instructions} = module.start(paginator_opts)
          apply_instructions(query, instructions)
        else
          query
        end

      with {:ok, body, _env} <- make_request(resource, query, endpoint),
           {:ok, entities} <- get_entities(body, endpoint, resource, paginate_with: query) do
        entities
        |> limit_offset(query)
        |> AshJsonApiWrapper.Records.process_entities(resource, endpoint)
      end
    end
    |> do_sort(query)
    |> runtime_filter(query)
  end

  defp apply_limit(query, endpoint) do
    if query.limit do
      if query.offset && query.offset != 0 do
        Logger.warning(
          "ash_json_api_wrapper does not support limits with offsets yet, and so they will both be applied after."
        )
      end

      case endpoint.limit_with do
        {:param, param} ->
          %{query | query_params: Map.put(query.query_params || %{}, param, query.limit)}

        _ ->
          query
      end
    else
      query
    end
  end

  defp runtime_filter({:ok, results}, query) do
    if is_nil(query.runtime_filter) do
      {:ok, results}
    else
      Ash.Filter.Runtime.filter_matches(query.domain, results, query.runtime_filter)
    end
  end

  defp runtime_filter(other, _), do: other

  defp do_sort({:ok, results}, %{sort: sort}) when sort not in [nil, []] do
    {:ok, Ash.Sort.runtime_sort(results, sort, [])}
  end

  defp do_sort(other, _), do: other

  defp fill_template(query, template) do
    template
    |> List.wrap()
    |> Enum.reduce(query, fn
      {key, replacement}, query ->
        %{query | path: String.replace(query.path, ":#{key}", to_string(replacement))}

      {:set, key, value}, query ->
        key =
          key
          |> List.wrap()
          |> Enum.map(&to_string/1)

        %{
          query
          | query_params: AshJsonApiWrapper.Helpers.put_at_path(query.query_params, key, value)
        }
    end)
  end

  defp limit_offset(results, %Query{limit: limit, offset: offset}) do
    results = if offset, do: Enum.drop(results, offset), else: results
    if limit, do: Enum.take(results, limit), else: results
  end

  defp make_request(resource, query, endpoint) do
    AshJsonApiWrapper.Request.send(resource, %AshJsonApiWrapper.Request{
      method: endpoint.method || :get,
      path: query.path,
      query_params: query.query_params,
      body: query.body,
      headers: query.headers || []
    })
  end

  @doc false
  def get_entities(body, endpoint, resource, opts \\ []) do
    if opts[:paginate_with] && endpoint.paginator do
      with {:ok, entities} <-
             get_entities(body, endpoint, resource, Keyword.delete(opts, :paginate_with)),
           {:ok, bodies} <-
             get_all_bodies(
               body,
               endpoint,
               resource,
               opts[:paginate_with],
               &get_entities(&1, endpoint, resource, Keyword.delete(opts, :paginate_with)),
               [entities]
             ) do
        {:ok, bodies |> Enum.reverse() |> List.flatten()}
      end
    else
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
  end

  defp get_all_bodies(
         body,
         %{paginator: {module, opts}} = endpoint,
         resource,
         paginate_with,
         entity_callback,
         bodies
       ) do
    case module.continue(body, Enum.at(bodies, 0), opts) do
      :halt ->
        {:ok, bodies}

      {:ok, instructions} ->
        query = apply_instructions(paginate_with, instructions)

        with {:ok, new_body, _env} <- make_request(resource, query, endpoint),
             {:ok, entities} <- entity_callback.(new_body) do
          get_all_bodies(new_body, endpoint, resource, paginate_with, entity_callback, [
            entities | bodies
          ])
        end
    end
  end

  defp apply_instructions(query, instructions) do
    query
    |> apply_params(instructions)
    |> apply_headers(instructions)
  end

  defp apply_params(query, %{params: params}) when is_map(params) do
    %{query | query_params: Ash.Helpers.deep_merge_maps(query.query_params || %{}, params)}
  end

  defp apply_params(query, _), do: query

  defp apply_headers(query, %{headers: headers}) when is_map(headers) do
    %{
      query
      | headers:
          query.headers
          |> Kernel.||(%{})
          |> Map.new()
          |> Map.merge(headers)
          |> Map.to_list()
    }
  end

  defp apply_headers(query, _), do: query
end

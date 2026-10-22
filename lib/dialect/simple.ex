# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.Dialect.Simple do
  @moduledoc """
  The default dialect.

  * Equality and `in` filters over fields with a `filter_handler` become query params, see
    `AshJsonApiWrapper.Field`.
  * Equality and `in` filters over the field of a `get_endpoint` fill its path template, with one
    request per value.
  * Other equality filters are applied to the fetched records.
  * Sorting is applied to the fetched records when the endpoint sets `runtime_sort? true`.
  * `limit` is sent as a query param when the endpoint sets `limit_with`. Limit and offset are
    always applied to the fetched records as well.
  * Paging follows the endpoint's `paginator`, see `AshJsonApiWrapper.Paginator`.
  """

  use AshJsonApiWrapper.QueryDialect

  require Logger

  alias AshJsonApiWrapper.DataLayer.Info
  alias AshJsonApiWrapper.Request

  @impl true
  def can?(_, :boolean_filter), do: true
  def can?(_, :filter), do: true
  def can?(_, :limit), do: true
  def can?(_, :offset), do: true

  def can?(
        _,
        {:filter_expr,
         %Ash.Query.Operator.Eq{
           left: %Ash.Query.Operator.Eq{left: %Ash.Query.Ref{}, right: %Ash.Query.Ref{}}
         }}
      ),
      do: false

  def can?(
        _,
        {:filter_expr, %Ash.Query.Operator.Eq{right: %Ash.Query.Ref{}}}
      ),
      do: true

  def can?(
        _,
        {:filter_expr, %Ash.Query.Operator.Eq{left: %Ash.Query.Ref{}}}
      ),
      do: true

  def can?(
        _,
        {:filter_expr, %Ash.Query.Operator.In{right: %Ash.Query.Ref{}}}
      ),
      do: false

  def can?(
        _,
        {:filter_expr, %Ash.Query.Operator.In{left: %Ash.Query.Ref{}, right: %Ash.Query.Ref{}}}
      ),
      do: false

  def can?(
        _,
        {:filter_expr, %Ash.Query.Operator.In{left: %Ash.Query.Ref{}}}
      ),
      do: true

  def can?(_, :nested_expressions), do: true

  def can?(_, :sort), do: true
  def can?(_, {:sort, _}), do: true
  def can?(_, _), do: false

  @impl true
  def filter(query, filter, resource) do
    if query.action do
      case validate_filter(filter, resource, query.action) do
        {:ok, {endpoint, templates, instructions}, remaining_filter} ->
          {templates, instructions} =
            if templates && !Enum.empty?(templates) do
              {templates, instructions}
            else
              instructions =
                instructions
                |> Enum.reduce([], fn
                  {:expand_set, field, values} = instruction, new_instructions ->
                    if Enum.any?(new_instructions, fn
                         {:expand_set, ^field, _other_values} ->
                           true

                         _ ->
                           false
                       end) do
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
                Enum.split_with(instructions || [], fn
                  {:expand_set, _, _} ->
                    true

                  _ ->
                    false
                end)

              templates =
                expand_set
                |> Enum.at(0)
                |> case do
                  nil ->
                    nil

                  {:expand_set, field, values} ->
                    Enum.map(values, &{:set, field, &1})
                end

              {templates, instructions}
            end

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
      result =
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
                    {:set, ^field_name, value} ->
                      {:set, path, value}

                    {:expand_set, ^field_name, values} ->
                      {:expand_set, path, values}

                    other ->
                      # don't think this is possible
                      other
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

      case result do
        {:ok, nil} ->
          {:cont, {:ok, instructions, filter}}

        {:ok, {remaining_filter, new_instructions}} ->
          {:cont, {:ok, new_instructions ++ instructions, remaining_filter}}
      end
    end)
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
  def sort(query, sort, _resource) do
    if query.endpoint.runtime_sort? do
      {:ok, %{query | sort: sort}}
    else
      {:error, "Sorting is not supported"}
    end
  end

  @impl true
  def paginate(%{limit: nil} = query, _resource), do: {:ok, query}

  def paginate(query, resource) do
    if query.offset && query.offset != 0 do
      Logger.warning(
        "ash_json_api_wrapper does not support limits with offsets yet, and so they will both be applied after."
      )
    end

    case endpoint(query, resource).limit_with do
      {:param, param} ->
        {:ok, %{query | query_params: Map.put(query.query_params || %{}, param, query.limit)}}

      _ ->
        {:ok, query}
    end
  end

  @impl true
  def build_requests(query, resource) do
    endpoint = endpoint(query, resource)

    request = %Request{
      path: endpoint.path,
      query: query.query_params || %{},
      body: query.body,
      headers: query.headers || []
    }

    requests =
      case query.templates do
        nil -> [request]
        templates -> templates |> Enum.uniq() |> Enum.map(&fill_template(request, &1))
      end

    case endpoint.paginator do
      {module, opts} ->
        {:ok, instructions} = module.start(opts)

        {:ok,
         Enum.map(requests, fn request ->
           request = apply_instructions(request, instructions)
           %{request | private: Map.put(request.private, :first_page, request)}
         end)}

      nil ->
        {:ok, requests}
    end
  end

  defp fill_template(request, template) do
    template
    |> List.wrap()
    |> Enum.reduce(request, fn
      {:set, key, value}, request ->
        key =
          key
          |> List.wrap()
          |> Enum.map(&to_string/1)

        %{request | query: AshJsonApiWrapper.Helpers.put_at_path(request.query, key, value)}

      {key, replacement}, request ->
        %{request | path: String.replace(request.path, ":#{key}", to_string(replacement))}
    end)
  end

  @impl true
  def unwrap_response(body, request, query, resource) do
    endpoint = endpoint(query, resource)

    with {:ok, records} <- get_entities(body, endpoint) do
      {:ok, %{records: records, total: nil, next: next_request(body, records, request, endpoint)}}
    end
  end

  defp next_request(body, records, request, %{paginator: {module, opts}}) do
    case module.continue(body, records, opts) do
      :halt ->
        nil

      {:ok, instructions} ->
        first_page = request.private.first_page

        first_page
        |> apply_instructions(instructions)
        |> Map.put(:private, request.private)
    end
  end

  defp next_request(_body, _records, _request, _endpoint), do: nil

  defp get_entities(body, endpoint) do
    case endpoint.entity_path do
      nil ->
        {:ok, List.wrap(body)}

      path ->
        case ExJSONPath.eval(body, path) do
          {:ok, [entities | _]} ->
            {:ok, List.wrap(entities)}

          {:ok, _} ->
            {:ok, []}

          {:error, error} ->
            {:error, error}
        end
    end
  end

  defp apply_instructions(request, instructions) do
    request
    |> apply_params(instructions)
    |> apply_headers(instructions)
  end

  defp apply_params(request, %{params: params}) when is_map(params),
    do: Request.merge_params(request, params)

  defp apply_params(request, _), do: request

  defp apply_headers(request, %{headers: headers}) when is_map(headers),
    do: Request.merge_headers(request, headers)

  defp apply_headers(request, _), do: request

  defp endpoint(query, resource) do
    query.endpoint || Info.endpoint(resource, query.action.name)
  end
end

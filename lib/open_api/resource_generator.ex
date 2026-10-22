# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.OpenApi.ResourceGenerator do
  @moduledoc """
  Generates resources from an OpenAPI specification.

  `generate/3` takes the decoded spec, the domain and a config, and returns a list of
  `{resource, code}`. `mix ash_json_api_wrapper.gen.resources` writes them to files.

  ## Config

  * `:tesla` - the Tesla module of all resources
  * `:endpoint` - the base URL of all resources
  * `:resources` - a keyword list of resource module names and their config:
    * `:path` - generate endpoints and actions for all operations under this path prefix
    * `:object_type` - a JSON path to the entity schema in the spec, e.g.
      `"components.schemas.Order"`. Defaults to the entity schema of the first read operation.
    * `:primary_key` - the property (or list of properties) of the primary key
    * `:dialect` - the `AshJsonApiWrapper.QueryDialect` of the resource, a module or
      `{module, opts}`. Defaults to `AshJsonApiWrapper.Dialect.Simple`.
    * `:reads` - operation ids of `POST` operations that are reads, for example search
      endpoints that take a query in the body
    * `:entity_path` - where the entities are in read responses. Defaults to the wrapper property
      (`data`, `items`, `value`, `results`, `records`, ...) of the response schema, if any.
    * `:fields` - field config by property name, e.g. `[id: [filter_handler: :simple]]`

  ## Operations

  `GET` operations become reads. `POST` operations become reads when they are listed in `:reads`
  or when their request body is a query in the resource's dialect (see
  `c:AshJsonApiWrapper.QueryDialect.query_body?/1`). Other `POST` operations become creates if
  they respond with JSON, and are skipped otherwise, since commands are better written by hand
  as generic actions.

  Attribute names are property names in snake case, without any prefix up to the last `.`.
  With the simple dialect, properties whose name changes get a `field` with their `path`.

  ## Types

  | OpenAPI | Ash |
  | --- | --- |
  | `string` | `:string` |
  | `string` with `format` `uuid`, `date-time`, `date`, `time`, `binary`/`byte` | `:uuid`, `:utc_datetime_usec`, `:date`, `:time`, `:binary` |
  | `integer` | `:integer` |
  | `number` with `format` `float`/`double` | `:float` |
  | `number` | `:decimal` |
  | `boolean` | `:boolean` |
  | `enum` of strings | `:atom` with `one_of` |
  | `array` | `{:array, type}` |
  | `object`, or anything else | `:map` |

  Properties listed in the schema's `required` that are not `nullable` get `allow_nil? false`.
  """

  @wrappers ["data", "items", "value", "values", "results", "records", "objects", "entries"]

  # sobelow_skip ["DOS.StringToAtom"]
  def generate(json, domain, main_config) do
    main_config[:resources]
    |> Enum.map(fn {resource, config} ->
      {dialect, dialect_opts} = dialect(config)
      simple? = dialect == AshJsonApiWrapper.Dialect.Simple

      operations =
        json
        |> operations(config)
        |> Enum.map(fn {path, method, operation} ->
          {path, method, operation, action_type(json, method, operation, config, dialect)}
        end)
        |> Enum.reject(fn {_path, _method, _operation, type} -> type == :skip end)

      reads = for {path, method, operation, :read} <- operations, do: {path, method, operation}

      endpoints =
        Enum.map_join(operations, "\n\n", fn {path, method, operation, type} ->
          entity_path =
            if type == :read && simple? do
              config[:entity_path] || detect_entity_path(json, operation)
            end

          entity_path =
            if entity_path do
              "entity_path \"#{entity_path}\""
            end

          method =
            if type == :read && method == "post" && simple? do
              "method :post"
            end

          """
          endpoint :#{operation_id(operation)} do
            path "#{path}"
            #{entity_path}
            #{method}
          end
          """
        end)

      actions =
        Enum.map_join(operations, "\n\n", fn {_path, _method, operation, type} ->
          """
          #{type} :#{operation_id(operation)}
          """
        end)

      properties = properties(json, config, reads)

      field_configs =
        Enum.map(config[:fields] || [], fn {name, field_config} ->
          {to_string(name), field_config}
        end)

      fields =
        properties
        |> Enum.map(fn {name, _property} -> name end)
        |> Enum.concat(Enum.map(field_configs, &elem(&1, 0)))
        |> Enum.uniq()
        |> Enum.flat_map(fn name ->
          field_config = find_field_config(field_configs, name)

          filter_handler =
            if field_config[:filter_handler] do
              "filter_handler #{inspect(field_config[:filter_handler])}"
            end

          path =
            if simple? && attribute_name(name) != name do
              "path #{inspect(name)}"
            end

          if filter_handler || path do
            [
              """
              field :#{attribute_name(name)} do
                #{path}
                #{filter_handler}
              end
              """
            ]
          else
            []
          end
        end)
        |> Enum.join("\n\n")
        |> case do
          "" ->
            ""

          other ->
            """
            fields do
              #{other}
            end
            """
        end

      required = required(json, config, reads)

      attributes =
        properties
        |> Enum.map(fn {name, property} ->
          {attribute_name(name), name, property}
        end)
        |> Enum.sort_by(fn {name, _, _} ->
          name not in List.wrap(config[:primary_key])
        end)
        |> Enum.map_join("\n\n", fn {name, original_name, property} ->
          property = deref(json, property)
          type = type(json, property)

          constraints =
            case property do
              %{"enum" => values} when is_list(values) ->
                if Enum.all?(values, &is_binary/1) do
                  "one_of: #{inspect(Enum.map(values, &String.to_atom/1))}"
                end

              %{"maxLength" => max, "minLength" => min} ->
                "min_length: #{min}, max_length: #{max}"

              %{"maxLength" => max} ->
                "max_length: #{max}"

              %{"minLength" => min} ->
                "min_length: #{min}"

              _ ->
                nil
            end

          constraints = if type == ":string" || type == ":atom", do: constraints

          primary_key? = name in List.wrap(config[:primary_key])
          required? = original_name in required && !nullable?(property)

          if constraints || primary_key? || required? do
            constraints =
              if constraints do
                "constraints #{constraints}"
              end

            allow_nil =
              cond do
                primary_key? ->
                  """
                  primary_key? true
                  allow_nil? false
                  """

                required? ->
                  "allow_nil? false"

                true ->
                  nil
              end

            """
            attribute :#{name}, #{type} do
              #{allow_nil}
              #{constraints}
            end
            """
          else
            """
            attribute :#{name}, #{type}
            """
          end
        end)

      tesla =
        if main_config[:tesla] do
          "tesla #{inspect(main_config[:tesla])}"
        end

      dialect =
        if !simple? do
          if dialect_opts == [] do
            "dialect #{inspect(dialect)}"
          else
            "dialect {#{inspect(dialect)}, #{inspect(dialect_opts)}}"
          end
        end

      endpoint =
        if main_config[:endpoint] do
          "base \"#{main_config[:endpoint]}\""
        end

      code =
        """
        defmodule #{inspect_module(resource)} do
          use Ash.Resource, domain: #{inspect(domain)}, data_layer: AshJsonApiWrapper.DataLayer

          json_api_wrapper do
            #{tesla}
            #{dialect}

            endpoints do
              #{endpoint}
              #{endpoints}
            end

            #{fields}
          end

          actions do
            #{actions}
          end

          attributes do
            #{attributes}
          end
        end
        """
        |> Code.format_string!(locals_without_parens: locals_without_parens())
        |> IO.iodata_to_binary()

      {resource, code}
    end)
  end

  # The DSL of resources, so the generated code reads like hand-written resources.
  defp locals_without_parens do
    [Ash.Resource.Dsl, AshJsonApiWrapper.DataLayer]
    |> Enum.flat_map(& &1.sections())
    |> Enum.flat_map(&dsl_names/1)
    |> Enum.uniq()
    |> Enum.map(&{&1, :*})
  end

  defp dsl_names(%Spark.Dsl.Section{} = section) do
    [section.name | Keyword.keys(section.schema)] ++
      Enum.flat_map(section.entities, &dsl_names/1) ++
      Enum.flat_map(section.sections, &dsl_names/1)
  end

  defp dsl_names(%Spark.Dsl.Entity{} = entity) do
    nested = entity.entities |> Keyword.values() |> List.flatten()
    [entity.name | Keyword.keys(entity.schema)] ++ Enum.flat_map(nested, &dsl_names/1)
  end

  defp inspect_module(resource) do
    resource |> to_string() |> String.replace_prefix("Elixir.", "")
  end

  defp find_field_config(field_configs, name) do
    Enum.find_value(field_configs, [], fn {field_name, config} ->
      if field_name == name || field_name == attribute_name(name), do: config
    end)
  end

  # `createdAt` becomes `created_at`, `Sales.region` becomes `region`.
  defp attribute_name(name) do
    name
    |> String.split(".")
    |> List.last()
    |> Macro.underscore()
    |> String.replace(~r/\W/, "_")
  end

  defp dialect(config) do
    case config[:dialect] do
      nil -> {AshJsonApiWrapper.Dialect.Simple, []}
      {module, opts} -> {module, opts}
      module -> {module, []}
    end
  end

  defp action_type(_json, "get", _operation, _config, _dialect), do: :read

  defp action_type(json, "post", operation, config, dialect) do
    cond do
      operation["operationId"] in List.wrap(config[:reads]) ->
        :read

      Code.ensure_loaded?(dialect) && function_exported?(dialect, :query_body?, 1) &&
          dialect.query_body?(request_body_schema(json, operation)) ->
        :read

      # Commands without an entity in the response stay hand-written.
      is_nil(response_schema(json, operation)) ->
        :skip

      true ->
        :create
    end
  end

  defp request_body_schema(json, operation) do
    case get_in(operation, ["requestBody", "content", "application/json", "schema"]) do
      nil -> %{}
      schema -> deref(json, schema, 5)
    end
  end

  defp response_schema(json, operation) do
    operation
    |> Map.get("responses", %{})
    |> Enum.filter(fn {status, _} -> String.starts_with?(status, "2") end)
    |> Enum.sort()
    |> Enum.find_value(fn {_status, response} ->
      get_in(deref(json, response), ["content", "application/json", "schema"])
    end)
    |> case do
      nil -> nil
      schema -> deref(json, schema)
    end
  end

  # The wrapper property of a response that holds the entities, if any.
  defp detect_entity_path(json, operation) do
    case response_schema(json, operation) do
      %{"properties" => properties} ->
        Enum.find(@wrappers, fn wrapper ->
          match?(%{"type" => "array"}, deref(json, properties[wrapper] || %{}))
        end)

      _ ->
        nil
    end
  end

  # The schema of a single entity in the responses of the read operations.
  defp entity_schema(json, reads) do
    Enum.find_value(reads, fn {_path, _method, operation} ->
      case all_of(response_schema(json, operation), json) do
        %{"type" => "array", "items" => items} ->
          deref(json, items)

        %{"properties" => properties} = schema ->
          wrapper =
            Enum.find_value(@wrappers, fn wrapper ->
              case deref(json, properties[wrapper] || %{}) do
                %{"type" => "array", "items" => items} -> deref(json, items)
                _ -> nil
              end
            end)

          wrapper || schema

        _ ->
          nil
      end
    end)
  end

  defp object(json, config, reads) do
    if config[:object_type] do
      {:ok, [object]} = ExJSONPath.eval(json, config[:object_type])
      deref(json, object)
    else
      entity_schema(json, reads) ||
        raise "Could not find the entity schema of #{inspect(config[:path])}, set `object_type`"
    end
  end

  defp properties(json, config, reads) do
    json
    |> object(config, reads)
    |> all_of(json)
    |> Map.get("properties", %{})
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp required(json, config, reads) do
    json
    |> object(config, reads)
    |> all_of(json)
    |> Map.get("required", [])
  end

  # Merges the properties of `allOf` schemas.
  defp all_of(%{"allOf" => schemas} = schema, json) do
    schemas
    |> Enum.map(&all_of(deref(json, &1), json))
    |> Enum.reduce(Map.delete(schema, "allOf"), fn sub_schema, acc ->
      acc
      |> Map.update("properties", sub_schema["properties"] || %{}, fn properties ->
        Map.merge(properties, sub_schema["properties"] || %{})
      end)
      |> Map.update("required", sub_schema["required"] || [], fn required ->
        required ++ (sub_schema["required"] || [])
      end)
    end)
  end

  defp all_of(schema, _json), do: schema

  defp nullable?(%{"nullable" => true}), do: true
  defp nullable?(%{"type" => types}) when is_list(types), do: "null" in types
  defp nullable?(_), do: false

  defp type(json, property) do
    case property do
      %{"enum" => values} when is_list(values) ->
        if Enum.all?(values, &is_binary/1), do: ":atom", else: base_type(json, property)

      property ->
        base_type(json, property)
    end
  end

  defp base_type(json, property) do
    case property do
      %{"type" => types} when is_list(types) ->
        case types -- ["null"] do
          [type] -> base_type(json, %{property | "type" => type})
          _ -> ":map"
        end

      %{"type" => "string", "format" => "uuid"} ->
        ":uuid"

      %{"type" => "string", "format" => "date-time"} ->
        ":utc_datetime_usec"

      %{"type" => "string", "format" => "date"} ->
        ":date"

      %{"type" => "string", "format" => "time"} ->
        ":time"

      %{"type" => "string", "format" => format} when format in ["binary", "byte"] ->
        ":binary"

      %{"type" => "string"} ->
        ":string"

      %{"type" => "integer"} ->
        ":integer"

      %{"type" => "number", "format" => format} when format in ["float", "double"] ->
        ":float"

      %{"type" => "number"} ->
        ":decimal"

      %{"type" => "boolean"} ->
        ":boolean"

      %{"type" => "array", "items" => items} ->
        "{:array, #{type(json, deref(json, items))}}"

      _ ->
        ":map"
    end
  end

  # Resolves `$ref`s, `depth` levels deep into properties and items.
  defp deref(json, schema, depth \\ 0)

  defp deref(json, %{"$ref" => "#/" <> ref}, depth) do
    resolved = get_in(json, ref |> String.split("/") |> Enum.map(&unescape_pointer/1))
    deref(json, resolved, depth)
  end

  defp deref(json, %{} = schema, depth) when depth > 0 do
    schema
    |> Map.new(fn
      {"properties", properties} when is_map(properties) ->
        {"properties", Map.new(properties, fn {k, v} -> {k, deref(json, v, depth - 1)} end)}

      {"items", items} ->
        {"items", deref(json, items, depth - 1)}

      other ->
        other
    end)
  end

  defp deref(_json, schema, _depth), do: schema

  defp unescape_pointer(segment) do
    segment |> String.replace("~1", "/") |> String.replace("~0", "~")
  end

  defp operation_id(%{"operationId" => operationId}) do
    operationId
    |> Macro.underscore()
  end

  defp operations(json, config) do
    json["paths"]
    |> Enum.filter(fn {path, _value} ->
      String.starts_with?(path, config[:path])
    end)
    |> Enum.flat_map(fn {path, methods} ->
      Enum.map(methods, fn {method, config} ->
        {path, method, config}
      end)
    end)
    |> Enum.filter(fn {_path, method, _config} ->
      method in ["get", "post"]
    end)
  end
end

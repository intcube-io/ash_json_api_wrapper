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

  The first read and the first create are primary actions.
  """

  alias AshJsonApiWrapper.Dialect.Naming

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

      # The first read and the first create are primary, so they are used by default and for
      # loading relationships.
      primary_operations =
        operations
        |> Enum.uniq_by(fn {_path, _method, _operation, type} -> type end)
        |> Enum.map(fn {_path, _method, operation, _type} -> operation end)

      actions =
        Enum.map_join(operations, "\n\n", fn {_path, _method, operation, type} ->
          if operation in primary_operations do
            """
            #{type} :#{operation_id(operation)} do
              primary? true
            end
            """
          else
            """
            #{type} :#{operation_id(operation)}
            """
          end
        end)

      schema = json |> object(config, reads) |> all_of(json)
      overrides = overrides(schema, config, resource)

      properties =
        schema
        |> Map.get("properties", %{})
        |> Enum.reject(fn {name, property} ->
          name in overrides.skip || property["x-ash-skip"] == true
        end)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {name, property} ->
          {Map.get(overrides.names, name, attribute_name(name)), name, deref(json, property)}
        end)

      dialect_opts = naming_opts(dialect, dialect_opts, properties)

      field_configs =
        Enum.map(config[:fields] || [], fn {name, field_config} ->
          {to_string(name), field_config}
        end)

      fields =
        properties
        |> Enum.map(fn {attribute, name, _property} -> {attribute, name} end)
        |> Enum.concat(
          for {name, _} <- field_configs,
              !Enum.any?(properties, fn {attribute, original, _} ->
                name in [attribute, original]
              end),
              do: {attribute_name(name), name}
        )
        |> Enum.flat_map(fn {attribute, name} ->
          field_config =
            find_field_config(field_configs, attribute) || find_field_config(field_configs, name) ||
              []

          operators = overrides.filterable && overrides.filterable[name]

          filter_handler =
            cond do
              field_config[:filter_handler] ->
                "filter_handler #{inspect(field_config[:filter_handler])}"

              simple? && operators && Enum.any?(operators, &(&1 in [:==, :in])) ->
                if attribute == name do
                  "filter_handler :simple"
                else
                  "filter_handler {:simple, #{inspect(name)}}"
                end

              true ->
                nil
            end

          filter_operators =
            if operators do
              "filter_operators #{inspect(operators)}"
            end

          path =
            if simple? && attribute != name do
              "path #{inspect(name)}"
            end

          if filter_handler || filter_operators || path do
            [
              """
              field :#{attribute} do
                #{path}
                #{filter_handler}
                #{filter_operators}
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

      required = Map.get(schema, "required", [])

      attributes =
        properties
        |> Enum.sort_by(fn {_attribute, name, _} -> name not in overrides.primary_key end)
        |> Enum.map_join("\n\n", fn {name, original_name, property} ->
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

          primary_key? = original_name in overrides.primary_key
          required? = original_name in required && !nullable?(property)

          filterable =
            if overrides.filterable && !Map.has_key?(overrides.filterable, original_name) &&
                 !primary_key? && original_name not in overrides.relationship_attributes do
              "filterable? false"
            end

          if constraints || primary_key? || required? || filterable do
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
              #{filterable}
              #{constraints}
            end
            """
          else
            """
            attribute :#{name}, #{type}
            """
          end
        end)

      relationships =
        case Enum.map_join(overrides.relationships, "\n\n", &relationship(&1, properties)) do
          "" ->
            ""

          relationships ->
            """
            relationships do
              #{relationships}
            end
            """
        end

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

          #{relationships}
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
    Enum.find_value(field_configs, fn {field_name, config} ->
      if field_name == name, do: config
    end)
  end

  # Overrides from the config and from `x-ash-*` extensions in the spec, by property name. The
  # config wins.
  # sobelow_skip ["DOS.StringToAtom"]
  defp overrides(schema, config, resource) do
    properties = Map.get(schema, "properties", %{})
    property = &property_name!(properties, &1, &2, resource)

    extension_names =
      for {name, %{"x-ash-name" => attribute}} <- properties, into: %{}, do: {name, attribute}

    config_names =
      for {key, attribute} <- config[:rename] || [],
          into: %{},
          do: {property.(key, :rename), to_string(attribute)}

    extension_operators =
      for {name, %{"x-ash-filter-operators" => operators}} <- properties,
          into: %{},
          do: {name, Enum.map(operators, &String.to_atom/1)}

    config_operators =
      for {key, operators} <- config[:filterable] || [],
          into: %{},
          do: {property.(key, :filterable), operators}

    filterable =
      if config[:filterable] || extension_operators != %{} do
        Map.merge(extension_operators, config_operators)
      end

    primary_key =
      (config[:primary_key] || schema["x-ash-primary-key"])
      |> List.wrap()
      |> Enum.map(&property.(&1, :primary_key))

    extension_relationships =
      Enum.concat(
        for {name, %{"x-ash-relationship" => relationship}} <- properties do
          Map.put_new(relationship, "source_attribute", name)
        end,
        schema["x-ash-relationships"] || []
      )
      |> Enum.map(fn relationship ->
        {relationship["name"], Enum.map(Map.delete(relationship, "name"), &relationship_opt/1)}
      end)

    relationships =
      extension_relationships
      |> Keyword.new(fn {name, opts} -> {String.to_atom(name), opts} end)
      |> Keyword.merge(config[:relationships] || [])
      |> Enum.map(fn {name, opts} ->
        opts =
          case opts[:source_attribute] do
            nil -> opts
            source -> Keyword.put(opts, :source_attribute, property.(source, :relationships))
          end

        {name, opts}
      end)

    %{
      relationship_attributes:
        Enum.flat_map(relationships, &List.wrap(elem(&1, 1)[:source_attribute])),
      skip: Enum.map(config[:skip] || [], &property.(&1, :skip)),
      names: Map.merge(extension_names, config_names),
      filterable: filterable,
      primary_key: primary_key,
      relationships: relationships
    }
  end

  # sobelow_skip ["DOS.StringToAtom"]
  defp relationship_opt({"type", type}), do: {:type, String.to_atom(type)}
  # sobelow_skip ["DOS.StringToAtom"]
  defp relationship_opt({key, value}), do: {String.to_atom(key), value}

  defp property_name!(properties, key, override, resource) do
    key = to_string(key)

    Enum.find(Map.keys(properties), &(&1 == key)) ||
      Enum.find(Map.keys(properties), &(attribute_name(&1) == key)) ||
      raise ArgumentError, """
      #{inspect_module(resource)}: `#{override}` names #{inspect(key)}, which is not a property of the entity schema.

      Properties: #{properties |> Map.keys() |> Enum.sort() |> Enum.join(", ")}
      """
  end

  defp relationship({name, opts}, properties) do
    type = opts[:type] || :belongs_to

    destination =
      inspect_module(opts[:destination] || raise("Relationship #{name} needs a destination"))

    body =
      case type do
        :belongs_to ->
          source_name = opts[:source_attribute]

          source =
            Enum.find_value(properties, "#{name}_id", fn {attribute, original, _} ->
              if original == source_name, do: attribute
            end)

          """
          source_attribute :#{source}
          define_attribute? false
          """

        _ ->
          destination_attribute =
            opts[:destination_attribute] ||
              raise "Relationship #{name} needs a destination_attribute"

          "destination_attribute :#{destination_attribute}"
      end

    """
    #{type} :#{name}, #{destination} do
      #{body}
    end
    """
  end

  # sobelow_skip ["DOS.StringToAtom"]
  defp naming_opts(AshJsonApiWrapper.Dialect.OData, opts, properties) do
    explicit =
      for {attribute, name, _} <- properties,
          Naming.remote_name(String.to_atom(attribute), opts[:property_case] || :camel, []) !=
            name,
          do: {String.to_atom(attribute), name}

    merge_names(opts, :properties, explicit)
  end

  # sobelow_skip ["DOS.StringToAtom"]
  defp naming_opts(AshJsonApiWrapper.Dialect.CubeJs, opts, properties) do
    cube = opts[:cube]

    explicit =
      for {attribute, name, _} <- properties,
          member = if(String.contains?(name, "."), do: name, else: "#{cube}.#{name}"),
          default =
            "#{cube}.#{Naming.remote_name(String.to_atom(attribute), opts[:member_case] || :camel, [])}",
          member != default,
          do: {String.to_atom(attribute), member}

    merge_names(opts, :members, explicit)
  end

  defp naming_opts(_dialect, opts, _properties), do: opts

  defp merge_names(opts, _key, []), do: opts

  defp merge_names(opts, key, explicit) do
    Keyword.update(opts, key, explicit, &Keyword.merge(explicit, &1))
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

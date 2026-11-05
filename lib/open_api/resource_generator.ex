# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.OpenApi.ResourceGenerator do
  @moduledoc """
  Generates resource modules from an OpenAPI 3 specification.

  `generate/3` returns `[{module, code}]`; `mix ash_json_api_wrapper.gen.resources`
  writes the same code to files, so the output can be reviewed and regenerated
  when the spec changes.

  ## Config

      [
        tesla: MyApp.ApiClient,
        endpoint: "https://api.example.com",
        dialect: {AshJsonApiWrapper.Dialect.CubeJs, response_case: :snake},
        resources: [
          "MyApp.Api.Order": [
            path: "/orders",
            operations: ["queryOrders"],
            primary_key: "id",
            # everything below is optional
            reads: ["queryOrders"],
            object_type: "components.schemas.Order",
            entity_path: "data",
            rename: [orderNumber: :number],
            skip: [:internalNotes],
            filterable: [status: [:eq, :in], created_at: [:gte, :lte]],
            relationships: [
              belongs_to: [customer: [destination: MyApp.Api.Customer, source_attribute: :customer_id]]
            ],
            fields: [created_at: [time_dimension?: true]]
          ]
        ]
      ]

  Top level:

  * `:tesla`, `:endpoint` - the Tesla client and the base URL of every resource
  * `:dialect` - the `AshJsonApiWrapper.QueryDialect` of every resource

  Per resource:

  * `:path` - operations whose path starts with this belong to the resource
  * `:dialect` - a dialect (with options) for this resource only
  * `:endpoint_actions` - `[generated_action: [:other_action]]`: hand-written actions
    (in a fragment) that use the endpoint of a generated one
  * `:fragments` - `Spark.Dsl.Fragment`s of `Ash.Resource` added to the generated
    module. Hand-written actions, preparations and policies go there, so they
    survive regeneration.
  * `:operations` - narrows them to these operation ids
  * `:reads` - POST operations that are reads. Without it, a POST is a read when its
    request body is a query in the dialect's shape (`c:AshJsonApiWrapper.QueryDialect.query_request?/3`),
    and a `create` otherwise. GET operations are always reads.
  * `:object_type` - a JSON path into the spec for the entity schema. Without it,
    the schema comes from the first read's `200` response: a list, or a wrapper
    object holding the list in `data`, `items`, `value`, `results` or the dialect's
    entity key.
  * `:entity_path` - where the entities are in the response; detected with the schema

  ## Overrides

  Specs rarely say which field is the key, how resources relate, or what can be
  filtered. These overrides fill that in and survive regeneration, because they
  live in the config rather than in the generated files:

  * `:primary_key` - the key field(s), by spec name or attribute name
  * `:rename` - `[spec_name: :attribute_name]`; the response key is kept as the
    field's `path`
  * `:skip` - fields left out of the resource
  * `:filterable` - `[field: [operators]]`; every field not listed gets
    `filter_operators []`, so Ash rejects filters the API would not accept
  * `:relationships` - `[belongs_to: [name: opts], has_many: [...]]`, written
    into a `relationships` block as given
  * `:types` - `[field: ash_type]` where the spec's type is too loose (a date sent
    as a plain string)
  * `:fields` - any `field` options of the data layer per attribute
    (`filter_handler`, `member`, `time_dimension?`, `filter_operators`, `path`)

  The same hints can come from vendor extensions in the spec:

  * `x-ash-primary-key` - on the schema (a name or a list of names) or `true` on a property
  * `x-ash-name` - the attribute name of a property
  * `x-ash-skip: true` - leave the property out
  * `x-ash-filter-operators` - a list of operator names on a property
  * `x-ash-relationship` - on a property: `{"type": "belongs_to", "name": "customer", "destination": "MyApp.Customer"}`

  The config wins over vendor extensions. A field named in an override but
  missing from the spec raises an `ArgumentError` naming the resource and field.

  ## Dialect hints

  With a dialect that names query members (`AshJsonApiWrapper.Dialect.CubeJs`),
  response fields that the request schema does not list as dimensions get
  `member false`, and fields listed as time dimensions get `time_dimension? true`.
  """

  alias AshJsonApiWrapper.Dialect.CubeJs

  @wrapper_keys ["data", "items", "value", "results"]
  @http_methods ["get", "post", "put", "patch", "delete"]

  # sobelow_skip ["DOS.StringToAtom"]
  @spec generate(map, module, Keyword.t()) :: [{module | String.t(), String.t()}]
  def generate(spec, domain, main_config) do
    Enum.map(main_config[:resources], fn {resource, config} ->
      {resource, generate_resource(spec, domain, main_config, resource, config)}
    end)
  end

  defp generate_resource(spec, domain, main_config, resource, config) do
    main_config = Keyword.merge(main_config, Keyword.take(config, [:dialect]))
    {dialect, dialect_opts} = dialect(main_config)
    operations = operations(spec, config)

    if operations == [] do
      raise ArgumentError,
            "#{inspect(resource)}: no operation in the spec matches path #{inspect(config[:path])}" <>
              if(config[:operations],
                do: " and operations #{inspect(config[:operations])}",
                else: ""
              )
    end

    operations =
      Enum.map(operations, fn {path, method, operation} ->
        {path, method, operation,
         action_type(spec, method, operation, config, dialect, dialect_opts)}
      end)
      |> Enum.reject(fn {_, _, _, type} ->
        # writes the dialect cannot make stay hand-written generic actions
        type == :create and not dialect.can?(nil, :create, dialect_opts)
      end)

    {object, entity_path} = object_schema(spec, config, operations, dialect, dialect_opts)
    object = resolve(object, spec)
    properties = Map.get(object, "properties") || raise_no_properties(resource)

    request_hints = request_hints(spec, operations, dialect, dialect_opts)

    attributes =
      attributes(resource, object, properties, config, request_hints, dialect, dialect_opts)

    validate_overrides!(resource, config, attributes, path_params(operations))

    code = """
    defmodule #{module_name(resource)} do
      use Ash.Resource, domain: #{inspect(domain)}, data_layer: AshJsonApiWrapper.DataLayer#{fragments(config)}

      json_api_wrapper do
        #{if main_config[:tesla], do: "tesla #{inspect(main_config[:tesla])}"}
        #{dialect_line(main_config)}

        endpoints do
          #{if main_config[:endpoint], do: "base #{inspect(main_config[:endpoint])}"}
          #{endpoints(operations, entity_path, config)}
        end

        #{fields_block(attributes, extra_fields(config, attributes))}
      end

      actions do
        #{actions(operations, {dialect, dialect_opts})}
      end

      attributes do
        #{Enum.map_join(attributes, "\n\n", &attribute_code/1)}
      end

      #{relationships_block(config, properties, attributes)}
    end
    """

    code
    |> Code.format_string!(locals_without_parens: locals_without_parens())
    |> IO.iodata_to_binary()
  end

  defp locals_without_parens do
    [
      tesla: 1,
      dialect: 1,
      base: 1,
      endpoint: 2,
      path: 1,
      method: 1,
      entity_path: 1,
      field: 2,
      member: 1,
      filter_operators: 1,
      time_dimension?: 1,
      filter_handler: 1,
      read: 1,
      read: 2,
      create: 1,
      create: 2,
      attribute: 2,
      attribute: 3,
      primary?: 1,
      pagination: 1,
      primary_key?: 1,
      allow_nil?: 1,
      public?: 1,
      constraints: 1,
      belongs_to: 2,
      belongs_to: 3,
      has_many: 2,
      has_many: 3,
      has_one: 2,
      has_one: 3,
      source_attribute: 1,
      destination_attribute: 1,
      define_attribute?: 1
    ]
  end

  defp fragments(config) do
    case config[:fragments] do
      nil -> ""
      [] -> ""
      fragments -> ", fragments: #{inspect(fragments)}"
    end
  end

  defp module_name(resource) when is_atom(resource),
    do: resource |> inspect() |> String.trim_leading(":") |> String.trim("\"")

  defp module_name(resource), do: to_string(resource)

  defp raise_no_properties(resource) do
    raise ArgumentError, "#{inspect(resource)}: the entity schema has no properties"
  end

  # ── dialect ──

  defp dialect(config) do
    {module, opts} =
      case config[:dialect] do
        nil -> {AshJsonApiWrapper.Dialect.Simple, []}
        {module, opts} -> {module, opts}
        module -> {module, []}
      end

    Code.ensure_loaded!(module)
    {module, opts}
  end

  defp dialect_line(config) do
    case config[:dialect] do
      nil -> nil
      dialect -> "dialect #{inspect(dialect)}"
    end
  end

  # ── operations ──

  defp operations(spec, config) do
    spec["paths"]
    |> Enum.filter(fn {path, _} -> String.starts_with?(path, config[:path] || "") end)
    |> Enum.flat_map(fn {path, methods} ->
      methods
      |> Enum.filter(fn {method, _} -> method in @http_methods end)
      |> Enum.map(fn {method, operation} -> {path, method, operation} end)
    end)
    |> Enum.filter(fn {_, method, operation} ->
      method in ["get", "post"] and
        (is_nil(config[:operations]) or operation["operationId"] in config[:operations])
    end)
    |> Enum.sort_by(fn {path, method, _} -> {path, method} end)
  end

  defp action_type(_spec, "get", _operation, _config, _dialect, _opts), do: :read

  defp action_type(spec, "post", operation, config, dialect, opts) do
    cond do
      operation["operationId"] in List.wrap(config[:reads]) ->
        :read

      function_exported?(dialect, :query_request?, 3) and
          dialect.query_request?(request_schema(operation), spec, opts) ->
        :read

      true ->
        :create
    end
  end

  defp request_schema(operation) do
    get_in(operation, ["requestBody", "content", "application/json", "schema"]) || %{}
  end

  defp operation_id(%{"operationId" => operation_id}), do: Macro.underscore(operation_id)

  defp operation_id(operation) do
    raise ArgumentError, "operation without operationId: #{inspect(operation)}"
  end

  defp endpoints(operations, entity_path, config) do
    Enum.map_join(operations, "\n\n", fn {path, method, operation, type} ->
      action = String.to_atom(operation_id(operation))

      actions =
        case Keyword.get(config[:endpoint_actions] || [], action, []) do
          [] -> inspect(action)
          more -> inspect([action | more])
        end

      """
      endpoint #{actions} do
        path #{inspect(path)}
        #{if method != "get", do: "method :#{method}"}
        #{if entity_path && type == :read, do: "entity_path #{inspect(entity_path)}"}
      end
      """
    end)
  end

  defp actions(operations, {dialect, opts}) do
    countable? = dialect.can?(nil, {:query_aggregate, :count}, opts)

    {code, _} =
      Enum.map_reduce(operations, false, fn
        {_path, _method, operation, :read}, primary_set? ->
          options =
            [
              if(!primary_set?, do: "primary? true"),
              if(countable?, do: "pagination offset?: true, countable: true, required?: false")
            ]
            |> Enum.reject(&is_nil/1)

          code =
            if options == [] do
              "read :#{operation_id(operation)}"
            else
              """
              read :#{operation_id(operation)} do
                #{Enum.join(options, "\n")}
              end
              """
            end

          {code, true}

        {_path, _method, operation, :create}, primary_set? ->
          {"create :#{operation_id(operation)}", primary_set?}
      end)

    Enum.join(code, "\n\n")
  end

  # ── entity schema ──

  defp object_schema(spec, config, operations, dialect, opts) do
    if config[:object_type] do
      case ExJSONPath.eval(spec, config[:object_type]) do
        {:ok, [object]} ->
          {object, config[:entity_path]}

        _ ->
          raise ArgumentError,
                "object_type #{inspect(config[:object_type])} not found in the spec"
      end
    else
      {_, _, operation, _} =
        Enum.find(operations, &match?({_, _, _, :read}, &1)) || hd(operations)

      response =
        operation
        |> get_in(["responses", "200", "content", "application/json", "schema"])
        |> Kernel.||(
          get_in(operation, ["responses", "201", "content", "application/json", "schema"])
        )
        |> resolve(spec)

      unwrap(response, spec, config, dialect, opts)
    end
  end

  defp unwrap(%{"type" => "array", "items" => items}, spec, config, _dialect, _opts) do
    {resolve(items, spec), config[:entity_path]}
  end

  defp unwrap(%{"properties" => properties} = schema, spec, config, dialect, opts) do
    keys =
      if function_exported?(dialect, :entity_path, 1) do
        Enum.uniq([dialect.entity_path(opts) | @wrapper_keys])
      else
        @wrapper_keys
      end

    case Enum.find(keys, &match?(%{"type" => "array"}, resolve(properties[&1], spec))) do
      nil ->
        {schema, config[:entity_path]}

      key ->
        %{"items" => items} = resolve(properties[key], spec)
        {resolve(items, spec), config[:entity_path] || entity_path_for(key, dialect, opts)}
    end
  end

  defp unwrap(schema, _spec, config, _dialect, _opts), do: {schema, config[:entity_path]}

  # A dialect that unwraps the response itself needs no entity path.
  defp entity_path_for(key, dialect, opts) do
    if function_exported?(dialect, :entity_path, 1) and dialect.entity_path(opts) == key do
      nil
    else
      key
    end
  end

  defp resolve(%{"$ref" => "#/" <> ref}, spec) do
    spec
    |> get_in(String.split(ref, "/"))
    |> resolve(spec)
  end

  defp resolve(nil, _spec), do: %{}
  defp resolve(schema, _spec), do: schema

  # ── request hints (dimension members) ──

  defp request_hints(spec, operations, dialect, opts) do
    if dialect == CubeJs do
      query =
        operations
        |> Enum.filter(&match?({_, "post", _, :read}, &1))
        |> Enum.map(fn {_, _, operation, _} -> resolve(request_schema(operation), spec) end)
        |> Enum.map(fn schema ->
          case Keyword.get(opts, :query_key, "query") do
            nil -> schema
            key -> resolve(get_in(schema, ["properties", key]), spec)
          end
        end)

      dimensions = Enum.flat_map(query, &enum_of(&1, ["properties", "dimensions", "items"], spec))

      time_dimensions =
        Enum.flat_map(
          query,
          &enum_of(&1, ["properties", "timeDimensions", "items", "properties", "dimension"], spec)
        )

      if dimensions == [] and time_dimensions == [] do
        nil
      else
        %{dimensions: dimensions, time_dimensions: time_dimensions}
      end
    end
  end

  defp enum_of(schema, [], _spec), do: Map.get(schema, "enum", [])

  defp enum_of(schema, [key | rest], spec) do
    case resolve(schema, spec) do
      %{^key => value} -> enum_of(resolve(value, spec), rest, spec)
      _ -> []
    end
  end

  # ── attributes ──

  defp attributes(resource, object, properties, config, hints, dialect, opts) do
    context = %{
      resource: resource,
      config: config,
      hints: hints,
      dialect: dialect,
      opts: opts,
      renames: Map.new(config[:rename] || [], fn {from, to} -> {to_string(from), to} end),
      primary_key: primary_key(object, properties, config),
      filterable:
        config[:filterable] && Map.new(config[:filterable], fn {k, v} -> {to_string(k), v} end)
    }

    skip = Enum.map(config[:skip] || [], &to_string/1)

    properties
    |> Enum.reject(fn {name, property} ->
      name in skip or Macro.underscore(name) in skip or property["x-ash-skip"] == true
    end)
    |> Enum.map(&attribute(&1, context))
    |> Enum.sort_by(fn attribute -> {!attribute.primary_key?, attribute.name} end)
  end

  defp attribute({name, property}, context) do
    attribute_name =
      to_string(context.renames[name] || property["x-ash-name"] || Macro.underscore(name))

    field_options = field_options(context.config, name, attribute_name)

    %{
      spec_name: name,
      name: attribute_name,
      property: property,
      type: type_override(context.config, name, attribute_name),
      primary_key?: name in context.primary_key or attribute_name in context.primary_key,
      field:
        path_option(name, attribute_name, field_options, context) ++
          member_options(name, attribute_name, field_options, context) ++
          operator_options(name, attribute_name, property, field_options, context) ++
          field_options
    }
  end

  defp path_option(name, attribute_name, field_options, context) do
    response_key =
      if function_exported?(context.dialect, :response_key, 3) do
        context.dialect.response_key(
          String.to_atom(attribute_name),
          context.resource,
          context.opts
        )
      else
        attribute_name
      end

    if response_key != name and !Keyword.has_key?(field_options, :path),
      do: [path: "$.#{name}"],
      else: []
  end

  defp member_options(_name, _attribute_name, _field_options, %{hints: nil}), do: []

  defp member_options(name, attribute_name, field_options, context) do
    %{dimensions: dimensions, time_dimensions: time_dimensions} = context.hints

    member =
      CubeJs.convert_name(attribute_name, Keyword.get(context.opts, :member_case, :camel))

    cond do
      Keyword.has_key?(field_options, :member) or
          Keyword.has_key?(field_options, :time_dimension?) ->
        []

      member in time_dimensions ->
        [time_dimension?: true]

      name in time_dimensions ->
        [time_dimension?: true, member: name]

      member in dimensions ->
        []

      name in dimensions ->
        [member: name]

      true ->
        [member: false]
    end
  end

  defp operator_options(name, attribute_name, property, field_options, context) do
    cond do
      Keyword.has_key?(field_options, :filter_operators) ->
        []

      context.filterable ->
        [
          filter_operators: context.filterable[name] || context.filterable[attribute_name] || []
        ]

      ops = property["x-ash-filter-operators"] ->
        [filter_operators: Enum.map(ops, &String.to_atom/1)]

      true ->
        []
    end
  end

  defp field_options(config, name, attribute_name) do
    fields = config[:fields] || []

    Enum.find_value(fields, [], fn {key, options} ->
      if to_string(key) in [name, attribute_name], do: options
    end)
  end

  defp primary_key(object, properties, config) do
    from_config = config[:primary_key] && Enum.map(List.wrap(config[:primary_key]), &to_string/1)

    from_schema =
      case object["x-ash-primary-key"] do
        nil -> nil
        names -> List.wrap(names)
      end

    from_properties =
      for {name, %{"x-ash-primary-key" => true}} <- properties, do: name

    from_config || from_schema || from_properties
  end

  defp path_params(operations) do
    operations
    |> Enum.flat_map(fn {path, _, _, _} ->
      Regex.scan(~r/\{([^}]+)\}/, path, capture: :all_but_first)
    end)
    |> List.flatten()
    |> Enum.uniq()
  end

  defp validate_overrides!(resource, config, attributes, path_params) do
    known = Enum.flat_map(attributes, &[&1.spec_name, &1.name])

    named =
      [
        {:primary_key, List.wrap(config[:primary_key])},
        {:rename, Keyword.keys(config[:rename] || [])},
        {:filterable, Keyword.keys(config[:filterable] || [])},
        {:types, Keyword.keys(config[:types] || [])},
        {:fields, Keyword.keys(config[:fields] || []) -- Enum.map(path_params, &String.to_atom/1)}
      ]

    for {option, names} <- named, name <- names, to_string(name) not in known do
      raise ArgumentError,
            "#{inspect(resource)}: #{option} names #{inspect(name)}, which is not a field in the spec " <>
              "(fields: #{Enum.join(Enum.uniq(known), ", ")})"
    end

    :ok
  end

  defp type_override(config, name, attribute_name) do
    Enum.find_value(config[:types] || [], fn {key, type} ->
      if to_string(key) in [name, attribute_name], do: type
    end)
  end

  defp attribute_code(%{name: name, property: property, primary_key?: primary_key?} = attribute) do
    {type, constraints} =
      case attribute.type do
        nil -> type(property, name)
        type -> {inspect(type), nil}
      end

    options =
      [
        if(primary_key?, do: "primary_key? true"),
        if(primary_key?, do: "allow_nil? false"),
        "public? true",
        if(constraints, do: "constraints #{constraints}")
      ]
      |> Enum.reject(&is_nil/1)

    """
    attribute :#{name}, #{type} do
      #{Enum.join(options, "\n")}
    end
    """
  end

  # sobelow_skip ["DOS.StringToAtom"]
  defp type(%{"enum" => values} = property, _name) when is_list(values) do
    if property["type"] in ["integer", "number"] do
      {":integer", nil}
    else
      {":atom", "one_of: #{inspect(Enum.map(values, &String.to_atom/1))}"}
    end
  end

  defp type(%{"type" => "array", "items" => items}, name) do
    {inner, constraints} = type(items, name)

    if constraints do
      {"{:array, #{inner}}", "items: [#{constraints}]"}
    else
      {"{:array, #{inner}}", nil}
    end
  end

  defp type(%{"format" => "uuid"}, _), do: {":uuid", nil}
  defp type(%{"format" => "date-time"}, _), do: {":utc_datetime_usec", nil}
  defp type(%{"format" => "date"}, _), do: {":date", nil}
  defp type(%{"type" => "number"}, _), do: {":float", nil}
  defp type(%{"type" => "integer"}, _), do: {":integer", nil}
  defp type(%{"type" => "boolean"}, _), do: {":boolean", nil}

  defp type(%{"type" => "string"} = property, _) do
    constraints =
      [
        if(property["minLength"], do: "min_length: #{property["minLength"]}"),
        if(property["maxLength"], do: "max_length: #{property["maxLength"]}")
      ]
      |> Enum.reject(&is_nil/1)

    {":string", if(constraints != [], do: Enum.join(constraints, ", "))}
  end

  defp type(%{"type" => "object"}, _), do: {":map", nil}
  defp type(%{"oneOf" => _}, _), do: {":term", nil}
  defp type(%{"anyOf" => _}, _), do: {":term", nil}
  defp type(%{"$ref" => _}, _), do: {":map", nil}
  defp type(property, _) when map_size(property) == 0, do: {":term", nil}

  defp type(property, name) do
    raise ArgumentError, "Unsupported property #{name}: #{inspect(property)}"
  end

  # `fields` entries for names that are not attributes, such as path parameters
  defp extra_fields(config, attributes) do
    names = Enum.flat_map(attributes, &[&1.spec_name, &1.name])

    for {name, options} <- config[:fields] || [], to_string(name) not in names do
      %{name: to_string(name), field: options}
    end
  end

  defp fields_block(attributes, extra) do
    fields =
      attributes
      |> Enum.reject(&(&1.field == []))
      |> Enum.concat(extra)
      |> Enum.map_join("\n\n", fn %{name: name, field: options} ->
        """
        field :#{name} do
          #{Enum.map_join(options, "\n", fn {key, value} -> "#{key} #{inspect(value)}" end)}
        end
        """
      end)

    if fields == "", do: "", else: "fields do\n#{fields}\nend"
  end

  # ── relationships ──

  defp relationships_block(config, properties, attributes) do
    from_config =
      for {type, relationships} <- config[:relationships] || [],
          {name, options} <- relationships do
        {type, name, options}
      end

    from_spec =
      for {name, %{"x-ash-relationship" => relationship}} <- properties,
          not Enum.any?(from_config, fn {_, rel_name, _} ->
            to_string(rel_name) == relationship["name"]
          end) do
        attribute = Enum.find(attributes, &(&1.spec_name == name))

        {String.to_atom(relationship["type"] || "belongs_to"),
         String.to_atom(relationship["name"]),
         [
           destination: Module.concat([relationship["destination"]]),
           source_attribute: attribute && String.to_atom(attribute.name)
         ]}
      end

    case from_config ++ from_spec do
      [] ->
        ""

      relationships ->
        body =
          Enum.map_join(relationships, "\n\n", fn {type, name, options} ->
            {destination, options} = Keyword.pop!(options, :destination)

            options =
              options
              |> Keyword.reject(fn {_, value} -> is_nil(value) end)
              |> then(fn options ->
                if type == :belongs_to,
                  do: Keyword.put_new(options, :define_attribute?, false),
                  else: options
              end)

            """
            #{type} :#{name}, #{inspect(destination)} do
              #{Enum.map_join(options, "\n", fn {key, value} -> "#{key} #{inspect(value)}" end)}
            end
            """
          end)

        "relationships do\n#{body}\nend"
    end
  end
end

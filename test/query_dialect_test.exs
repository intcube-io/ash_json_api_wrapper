# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.QueryDialectTest do
  use ExUnit.Case
  require Ash.Query
  import Mox

  setup :verify_on_exit!

  defmodule TestingTesla do
    use Tesla

    adapter(AshJsonApiWrapper.MockAdapter)
  end

  # Sends `{"where": {"field": value}, "limit": n, "offset": n, "fields": [...]}` as a POST
  # body and reads `{"items": [...], "total": n, "next": cursor}`.
  defmodule BodyDialect do
    use AshJsonApiWrapper.QueryDialect

    alias AshJsonApiWrapper.Request

    @impl true
    def opts_schema do
      [items_key: [type: :string, default: "items"]]
    end

    @impl true
    def can?(_, feature)
        when feature in [:filter, :boolean_filter, :nested_expressions, :limit, :offset] or
               feature in [:select, :sort],
        do: true

    def can?(_, {:sort, _}), do: true

    def can?(_, {:query_aggregate, :count}), do: true

    def can?(_, {:filter_expr, %Ash.Query.Operator.Eq{left: %Ash.Query.Ref{}}}), do: true
    def can?(_, _), do: false

    @impl true
    def filter(query, filter, _resource) do
      with {:ok, where} <- where(filter.expression) do
        {:ok, put_in(query.dialect[:where], where)}
      end
    end

    defp where(%Ash.Query.BooleanExpression{op: :and, left: left, right: right}) do
      with {:ok, left} <- where(left), {:ok, right} <- where(right) do
        {:ok, Map.merge(left, right)}
      end
    end

    defp where(%Ash.Query.Operator.Eq{left: %Ash.Query.Ref{attribute: %{name: name}}, right: v}),
      do: {:ok, %{to_string(name) => v}}

    defp where(expr), do: {:error, "Unsupported filter: #{inspect(expr)}"}

    @impl true
    def sort(query, sort, _resource), do: {:ok, %{query | sort: sort}}

    @impl true
    def paginate(query, _resource) do
      {:ok,
       %{
         query
         | dialect: Map.merge(query.dialect, %{limit: query.limit, offset: query.offset}),
           limit: nil,
           offset: nil
       }}
    end

    @impl true
    def build_requests(query, resource) do
      body =
        %{
          "where" => query.dialect[:where] || %{},
          "limit" => query.dialect[:limit],
          "offset" => query.dialect[:offset],
          "fields" => query.select && Enum.map(query.select, &to_string/1),
          "total" => query.count? || nil
        }
        |> Map.reject(fn {_, v} -> is_nil(v) end)

      {:ok,
       [
         %Request{
           method: :post,
           path: AshJsonApiWrapper.DataLayer.Info.endpoint(resource, query.action.name).path,
           body: body
         }
       ]}
    end

    @impl true
    def unwrap_response(body, request, _query, resource) do
      items_key = AshJsonApiWrapper.DataLayer.Info.dialect_opts(resource)[:items_key]

      next =
        if body["next"] do
          %{request | body: Map.put(request.body, "cursor", body["next"])}
        end

      {:ok, %{records: body[items_key], total: body["total"], next: next}}
    end
  end

  defmodule Widget do
    use Ash.Resource,
      domain: AshJsonApiWrapper.QueryDialectTest.Domain,
      data_layer: AshJsonApiWrapper.DataLayer,
      validate_domain_inclusion?: false

    json_api_wrapper do
      tesla(TestingTesla)
      dialect({AshJsonApiWrapper.QueryDialectTest.BodyDialect, items_key: "rows"})

      endpoints do
        base("https://api.example.com")

        endpoint :read do
          path("/widgets/query")
        end
      end
    end

    actions do
      read :read do
        primary? true
        pagination(offset?: true, required?: false, countable: true)
      end
    end

    attributes do
      attribute :id, :integer do
        primary_key?(true)
        allow_nil?(false)
        public?(true)
      end

      attribute(:name, :string, public?: true)
      attribute(:color, :string, public?: true)
      attribute(:size, :integer, public?: true)
    end
  end

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered?(true)
    end
  end

  defp respond(body, status \\ 200),
    do: {:ok, %Tesla.Env{status: status, body: Jason.encode!(body)}}

  test "the default dialect is Simple" do
    defmodule Plain do
      use Ash.Resource,
        domain: AshJsonApiWrapper.QueryDialectTest.Domain,
        data_layer: AshJsonApiWrapper.DataLayer,
        validate_domain_inclusion?: false

      attributes do
        integer_primary_key(:id)
      end
    end

    assert AshJsonApiWrapper.DataLayer.Info.dialect(Plain) ==
             {AshJsonApiWrapper.Dialect.Simple, []}
  end

  test "dialect options are validated against the dialect's schema" do
    assert AshJsonApiWrapper.DataLayer.Info.dialect_opts(Widget) == [items_key: "rows"]

    assert_raise Spark.Error.DslError, ~r/unknown options \[:bogus\]/, fn ->
      defmodule BadOpts do
        use Ash.Resource,
          domain: AshJsonApiWrapper.QueryDialectTest.Domain,
          data_layer: AshJsonApiWrapper.DataLayer,
          validate_domain_inclusion?: false

        json_api_wrapper do
          dialect({AshJsonApiWrapper.QueryDialectTest.BodyDialect, bogus: true})
        end

        attributes do
          integer_primary_key(:id)
        end
      end
    end
  end

  test "filters the dialect does not support are rejected before any request" do
    expect(AshJsonApiWrapper.MockAdapter, :call, 0, fn _, _ -> :unreachable end)

    assert {:error, error} =
             Widget
             |> Ash.Query.filter(size > 3)
             |> Ash.read()

    assert Exception.message(error) =~ "does not support the operator"

    # Ash does not ask `can?/2` about `and`/`or`, so the dialect's `filter/3` rejects them.
    assert {:error, error} =
             Widget
             |> Ash.Query.filter(color == "red" or color == "blue")
             |> Ash.read()

    assert Exception.message(error) =~ "Unsupported filter"
  end

  test "builds the request from filter, limit, offset and select" do
    expect(AshJsonApiWrapper.MockAdapter, :call, fn env, _ ->
      assert env.method == :post
      assert env.url == "https://api.example.com/widgets/query"
      assert {"content-type", "application/json"} in env.headers

      assert Jason.decode!(env.body) == %{
               "where" => %{"color" => "red", "size" => 2},
               "limit" => 5,
               "offset" => 10,
               "fields" => ["id", "name"]
             }

      respond(%{"rows" => [%{"id" => 1, "name" => "a", "color" => "red"}]})
    end)

    assert [%{id: 1, name: "a"}] =
             Widget
             |> Ash.Query.filter(color == "red" and size == 2)
             |> Ash.Query.select([:name])
             |> Ash.Query.limit(5)
             |> Ash.Query.offset(10)
             |> Ash.read!()
  end

  test "follows the next page until there is none" do
    expect(AshJsonApiWrapper.MockAdapter, :call, 3, fn env, _ ->
      case Jason.decode!(env.body) do
        %{"cursor" => "b"} -> respond(%{"rows" => [%{"id" => 3}]})
        %{"cursor" => "a"} -> respond(%{"rows" => [%{"id" => 2}], "next" => "b"})
        _ -> respond(%{"rows" => [%{"id" => 1}], "next" => "a"})
      end
    end)

    assert [1, 2, 3] = Widget |> Ash.read!() |> Enum.map(& &1.id)
  end

  test "page counts use the total the API reports" do
    expect(AshJsonApiWrapper.MockAdapter, :call, 2, fn env, _ ->
      case Jason.decode!(env.body) do
        %{"total" => true} = body ->
          refute Map.has_key?(body, "limit")
          respond(%{"rows" => [%{"id" => 1}], "total" => 42})

        _ ->
          respond(%{"rows" => [%{"id" => 1}, %{"id" => 2}]})
      end
    end)

    page = Ash.read!(Widget, page: [limit: 2, count: true])
    assert page.count == 42
    assert length(page.results) == 2
  end

  test "error statuses are returned as errors" do
    expect(AshJsonApiWrapper.MockAdapter, :call, fn _, _ -> respond(%{}, 500) end)

    assert {:error, error} = Ash.read(Widget)
    assert Exception.message(error) =~ "Received status code 500 from POST"
  end
end

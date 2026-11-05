# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.CubeJsTest do
  use ExUnit.Case
  require Ash.Query
  import Mox

  setup :verify_on_exit!

  # A made-up Cube API, written from the public Cube.js REST API docs.
  @meta "test/support/cube_js/meta.json" |> File.read!() |> Jason.decode!()
  @load_orders File.read!("test/support/cube_js/load_orders.json")
  @continue_wait File.read!("test/support/cube_js/load_continue_wait.json")

  defmodule TestingTesla do
    use Tesla

    adapter(AshJsonApiWrapper.MockAdapter)
  end

  defmodule Order do
    use Ash.Resource,
      domain: AshJsonApiWrapper.CubeJsTest.Domain,
      data_layer: AshJsonApiWrapper.DataLayer,
      validate_domain_inclusion?: false

    json_api_wrapper do
      tesla(TestingTesla)

      dialect(
        {AshJsonApiWrapper.Dialect.CubeJs,
         cube: "Orders", members: [customer: "Orders.customerName"], page_size: 2}
      )

      endpoints do
        base("https://cube.example.com")

        endpoint :read do
          path("/cubejs-api/v1/load")
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
      integer_primary_key(:id, public?: true)
      attribute(:status, :string, public?: true)
      attribute(:customer, :string, public?: true)
      attribute(:city, :string, public?: true)
      attribute(:amount, :decimal, public?: true)
      attribute(:created_at, :naive_datetime, public?: true)
    end
  end

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered?(true)
    end
  end

  defp respond(body) when is_binary(body), do: {:ok, %Tesla.Env{status: 200, body: body}}
  defp respond(body), do: respond(Jason.encode!(body))

  # Runs the query and returns the Cube query that was sent.
  defp sent_query(query) do
    test = self()

    expect(AshJsonApiWrapper.MockAdapter, :call, fn env, _ ->
      send(test, {:query, Jason.decode!(env.body)["query"]})
      respond(%{"data" => []})
    end)

    Ash.read!(query)
    assert_received {:query, cube_query}
    cube_query
  end

  defp sent_filters(query), do: sent_query(query)["filters"]

  test "filter, sort, limit and select become a Cube query" do
    expect(AshJsonApiWrapper.MockAdapter, :call, fn env, _ ->
      assert env.method == :post
      assert env.url == "https://cube.example.com/cubejs-api/v1/load"

      assert Jason.decode!(env.body) == %{
               "query" => %{
                 "dimensions" => [
                   "Orders.id",
                   "Orders.status",
                   "Orders.customerName",
                   "Orders.amount",
                   "Orders.createdAt"
                 ],
                 "filters" => [
                   %{"member" => "Orders.status", "operator" => "equals", "values" => ["shipped"]}
                 ],
                 "order" => [["Orders.createdAt", "desc"]],
                 "limit" => 2
               }
             }

      respond(@load_orders)
    end)

    assert [first, second] =
             Order
             |> Ash.Query.filter(status == "shipped")
             |> Ash.Query.sort(created_at: :desc)
             |> Ash.Query.select([:status, :customer, :amount, :created_at])
             |> Ash.Query.limit(2)
             |> Ash.read!()

    assert first.id == 2
    assert first.customer == "Ada Example"
    assert first.amount == Decimal.new("120.50")
    assert first.created_at == ~N[2024-03-02 10:15:00]
    assert second.customer == "Bo Sample"
  end

  test "every member the resource uses exists in the cube" do
    dimensions =
      for cube <- @meta["cubes"], dimension <- cube["dimensions"], do: dimension["name"]

    assert sent_query(Order)["dimensions"] -- dimensions == []
  end

  test "operators translate to Cube filters" do
    assert [%{"member" => "Orders.city", "operator" => "notSet"}] =
             sent_filters(Ash.Query.filter(Order, is_nil(city)))

    assert [%{"member" => "Orders.city", "operator" => "set"}] =
             sent_filters(Ash.Query.filter(Order, not is_nil(city)))

    assert [%{"operator" => "equals", "values" => values}] =
             sent_filters(Ash.Query.filter(Order, status in ["new", "shipped"]))

    assert Enum.sort(values) == ["new", "shipped"]

    assert [%{"operator" => "notEquals", "values" => ["new"]}] =
             sent_filters(Ash.Query.filter(Order, status != "new"))

    assert [%{"operator" => "contains", "values" => ["Ada"]}] =
             sent_filters(Ash.Query.filter(Order, contains(customer, "Ada")))

    assert [%{"operator" => "startsWith", "values" => ["Spr"]}] =
             sent_filters(Ash.Query.filter(Order, string_starts_with(city, "Spr")))

    assert [%{"operator" => "endsWith", "values" => ["field"]}] =
             sent_filters(Ash.Query.filter(Order, string_ends_with(city, "field")))

    assert [%{"member" => "Orders.amount", "operator" => "lt", "values" => ["100"]}] =
             sent_filters(Ash.Query.filter(Order, 100 > amount))

    assert [%{"operator" => "gte", "values" => ["2024-03-01T00:00:00"]}] =
             sent_filters(Ash.Query.filter(Order, created_at >= ^~N[2024-03-01 00:00:00]))
  end

  test "and/or become logical groups and `not` is pushed down" do
    filters =
      sent_filters(Ash.Query.filter(Order, status == "shipped" and (city == "X" or amount > 10)))

    assert length(filters) == 2

    assert %{"member" => "Orders.status", "operator" => "equals", "values" => ["shipped"]} in filters

    assert %{"or" => ors} = Enum.find(filters, &Map.has_key?(&1, "or"))

    assert ors |> Enum.map(&{&1["member"], &1["operator"]}) |> Enum.sort() ==
             [{"Orders.amount", "gt"}, {"Orders.city", "equals"}]

    assert [%{"and" => ands}] =
             sent_filters(Ash.Query.filter(Order, not (status == "new" or is_nil(city))))

    assert ands |> Enum.map(&{&1["member"], &1["operator"]}) |> Enum.sort() ==
             [{"Orders.city", "set"}, {"Orders.status", "notEquals"}]
  end

  test "filters Cube cannot express are rejected before any request" do
    expect(AshJsonApiWrapper.MockAdapter, :call, 0, fn _, _ -> :unreachable end)

    assert {:error, _} =
             Order
             |> Ash.Query.filter(string_length(city) > 3)
             |> Ash.read()

    assert {:error, _} =
             Order
             |> Ash.Query.filter(status == city)
             |> Ash.read()
  end

  test "page counts use the total Cube reports" do
    expect(AshJsonApiWrapper.MockAdapter, :call, 2, fn env, _ ->
      case Jason.decode!(env.body)["query"] do
        %{"total" => true} = query ->
          assert query["limit"] == 1
          refute Map.has_key?(query, "offset")
          respond(@load_orders)

        %{"limit" => 3, "offset" => 2} ->
          respond(@load_orders)
      end
    end)

    page = Ash.read!(Order, page: [limit: 2, offset: 2, count: true])
    assert page.count == 7
  end

  test "without a limit all rows are read in pages" do
    expect(AshJsonApiWrapper.MockAdapter, :call, 2, fn env, _ ->
      case Jason.decode!(env.body)["query"] do
        %{"limit" => 2, "offset" => 2} -> respond(%{"data" => [%{"Orders.id" => 3}]})
        %{"limit" => 2} -> respond(@load_orders)
      end
    end)

    assert [1, 2, 3] = Order |> Ash.read!() |> Enum.map(& &1.id) |> Enum.sort()
  end

  test "response keys are matched to members ignoring case and underscores" do
    expect(AshJsonApiWrapper.MockAdapter, :call, fn _, _ ->
      respond(%{
        "data" => [%{"orders.id" => 1, "orders.customer_name" => "Ada", "Status" => "x"}]
      })
    end)

    assert [%{id: 1, customer: "Ada", status: "x"}] = Ash.read!(Order)
  end

  test "Cube errors are returned as errors" do
    expect(AshJsonApiWrapper.MockAdapter, :call, fn _, _ -> respond(@continue_wait) end)

    assert {:error, error} = Ash.read(Order)
    assert Exception.message(error) =~ "Continue wait"
  end
end

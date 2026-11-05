# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.CubeJsTest do
  # Requests go to a made-up API in the Cube.js REST query format; the responses
  # are recorded JSON files written from the public Cube.js REST API docs.
  use ExUnit.Case
  require Ash.Query
  import Mox

  setup :verify_on_exit!

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
      dialect({AshJsonApiWrapper.Dialect.CubeJs, response_case: :snake, page_size: 2})

      endpoints do
        base("https://cube.example.com/cubejs-api/v1")

        endpoint [:read, :for_region] do
          path("/load")
        end
      end

      fields do
        field :id do
          member("orders.id")
        end

        field :status do
          member("orders.status")
          filter_operators([:eq, :in, :is_nil])
        end

        field :customer_name do
          member("orders.customerName")
        end

        field :amount do
          member(false)
        end

        field :created_at do
          member("orders.createdAt")
          time_dimension?(true)
        end
      end
    end

    actions do
      read :read do
        primary?(true)
        pagination(offset?: true, countable: true, required?: false)
      end

      read :for_region do
        argument(:region_id, :string, allow_nil?: false)

        prepare(fn query, _ ->
          AshJsonApiWrapper.Dialect.CubeJs.merge_query(query, %{
            "segment" => "online",
            "filters" => [
              %{
                "member" => "orders.regionId",
                "operator" => "equals",
                "values" => [query.arguments.region_id]
              }
            ]
          })
        end)
      end
    end

    attributes do
      attribute(:id, :integer, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:status, :string, public?: true)
      attribute(:customer_name, :string, public?: true)
      attribute(:amount, :float, public?: true)
      attribute(:created_at, :utc_datetime, public?: true)
    end
  end

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered?(true)
    end
  end

  defp recorded(name), do: File.read!("test/support/cube_js/#{name}.json")

  # Replies with the recorded page for the requested offset (0 or 2) and sends
  # each request body to the test.
  defp expect_requests(count) do
    test = self()

    expect(AshJsonApiWrapper.MockAdapter, :call, count, fn env, _opts ->
      %{"query" => query} = body = Jason.decode!(env.body)
      send(test, {:request, env.method, env.url, body})
      page = if query["offset"] in [nil, 0], do: "orders_page_1", else: "orders_page_2"
      {:ok, %Tesla.Env{env | status: 200, body: recorded(page)}}
    end)
  end

  defp query_sent do
    assert_received {:request, :post, "https://cube.example.com/cubejs-api/v1/load",
                     %{"query" => query}}

    query
  end

  test "the resource picks its dialect in the DSL" do
    assert AshJsonApiWrapper.DataLayer.Info.dialect(Order) ==
             {AshJsonApiWrapper.Dialect.CubeJs, [response_case: :snake, page_size: 2]}

    assert AshJsonApiWrapper.DataLayer.can?(Order, :select)
    refute AshJsonApiWrapper.DataLayer.can?(Order, :create)
  end

  test "reads every page and casts snake_case response keys" do
    expect_requests(2)

    orders = Ash.read!(Order)

    assert Enum.map(orders, & &1.id) == [1, 2, 3]
    assert [%{customer_name: "Ada Example", amount: 120.5} | _] = orders
    assert List.last(orders).created_at == ~U[2024-03-03 09:15:00Z]

    first = query_sent()
    assert first["limit"] == 2
    assert first["offset"] == 0
    assert first["total"] == true

    assert first["dimensions"] == ["orders.id", "orders.status", "orders.customerName"]

    second = query_sent()
    assert second["offset"] == 2
  end

  test "translates filters into Cube filters" do
    expect_requests(2)

    Order
    |> Ash.Query.filter(
      status in ["shipped", "completed"] and contains(customer_name, "Exa") and
        (is_nil(status) or not is_nil(customer_name) or
           string_starts_with(customer_name, "B")) and id == 3
    )
    |> Ash.read!()

    assert query_sent()["filters"] == [
             %{
               "member" => "orders.status",
               "operator" => "equals",
               "values" => ["completed", "shipped"]
             },
             %{"member" => "orders.customerName", "operator" => "contains", "values" => ["Exa"]},
             %{
               "or" => [
                 %{"member" => "orders.status", "operator" => "notSet"},
                 %{"member" => "orders.customerName", "operator" => "set"},
                 %{
                   "member" => "orders.customerName",
                   "operator" => "startsWith",
                   "values" => ["B"]
                 }
               ]
             },
             %{"member" => "orders.id", "operator" => "equals", "values" => ["3"]}
           ]
  end

  test "a range on a time dimension becomes a date range" do
    expect_requests(2)

    from = ~U[2024-03-01 00:00:00Z]
    to = ~U[2024-03-31 23:59:59Z]

    Order
    |> Ash.Query.filter(created_at >= ^from and created_at <= ^to)
    |> Ash.read!()

    query = query_sent()
    refute Map.has_key?(query, "filters")

    assert query["timeDimensions"] == [
             %{
               "dimension" => "orders.createdAt",
               "dateRange" => ["2024-03-01T00:00:00Z", "2024-03-31T23:59:59Z"]
             }
           ]
  end

  test "a time dimension range with one end is refused" do
    expect(AshJsonApiWrapper.MockAdapter, :call, 0, fn _, _ -> :unused end)
    from = ~U[2024-03-01 00:00:00Z]

    assert {:error, error} =
             Order
             |> Ash.Query.filter(created_at >= ^from)
             |> Ash.read()

    assert Exception.message(error) =~ "needs both a lower"
  end

  test "filters the API does not accept are rejected before any request" do
    expect(AshJsonApiWrapper.MockAdapter, :call, 0, fn _, _ -> :unused end)

    assert {:error, _} =
             Order
             |> Ash.Query.filter(contains(status, "ship"))
             |> Ash.read()

    assert {:error, _} =
             Order
             |> Ash.Query.filter(amount > 10)
             |> Ash.read()
  end

  test "sort, limit, offset and select" do
    expect_requests(1)

    Order
    |> Ash.Query.sort(status: :desc, id: :asc)
    |> Ash.Query.select([:status])
    |> Ash.Query.limit(1)
    |> Ash.Query.offset(4)
    |> Ash.read!()

    query = query_sent()
    assert query["dimensions"] == ["orders.id", "orders.status"]
    assert query["limit"] == 1
    assert query["offset"] == 4
    # the order of the keys is the sort order
    assert query["order"] == %{"orders.status" => "desc", "orders.id" => "asc"}
  end

  test "the order keeps the sort order on the wire" do
    test = self()

    expect(AshJsonApiWrapper.MockAdapter, :call, fn env, _opts ->
      send(test, {:raw, env.body})
      {:ok, %Tesla.Env{env | status: 200, body: recorded("orders_page_2")}}
    end)

    Order
    |> Ash.Query.sort(status: :desc, id: :asc)
    |> Ash.read!()

    assert_received {:raw, body}
    assert body =~ ~s("order":{"orders.status":"desc","orders.id":"asc"})
  end

  test "total feeds the page count" do
    expect_requests(3)

    page = Ash.read!(Order, page: [limit: 2, count: true])

    assert page.count == 3
    assert length(page.results) == 2
  end

  test "a preparation adds raw parts to the query" do
    expect_requests(2)

    Order
    |> Ash.Query.for_read(:for_region, %{region_id: "north"})
    |> Ash.Query.filter(status == "shipped")
    |> Ash.read!()

    query = query_sent()
    assert query["segment"] == "online"

    assert query["filters"] == [
             %{"member" => "orders.status", "operator" => "equals", "values" => ["shipped"]},
             %{"member" => "orders.regionId", "operator" => "equals", "values" => ["north"]}
           ]
  end
end

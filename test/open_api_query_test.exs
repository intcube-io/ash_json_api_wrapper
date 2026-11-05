# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.OpenApi.QueryTest do
  # A made-up API whose list endpoints take a Cube.js-style query in a POST body.
  use ExUnit.Case
  import Mox

  alias AshJsonApiWrapper.OpenApi.ResourceGenerator

  setup :verify_on_exit!

  @spec_json "test/support/query_api.json" |> File.read!() |> Jason.decode!()

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered?(true)
    end
  end

  defmodule Client do
    use Tesla
    adapter(AshJsonApiWrapper.MockAdapter)
  end

  defp config(product_overrides \\ []) do
    [
      tesla: Client,
      endpoint: "https://inventory.example.com",
      dialect: {AshJsonApiWrapper.Dialect.CubeJs, response_case: :snake},
      resources: [
        "Inventory.Product":
          Keyword.merge(
            [path: "/api/products", primary_key: "product_id"],
            product_overrides
          ),
        "Inventory.Warehouse": [path: "/api/warehouses"]
      ]
    ]
  end

  defp code(config, resource) do
    @spec_json
    |> ResourceGenerator.generate(Domain, config)
    |> Map.new()
    |> Map.fetch!(resource)
  end

  test "a POST with a query body becomes a read; writes the dialect cannot make are left out" do
    code = code(config(), :"Inventory.Product")

    assert code =~ "read :query_products do"
    assert code =~ ~s(description "Query products")
    assert code =~ "primary? true"
    assert code =~ "pagination offset?: true, countable: true, required?: false"
    refute code =~ "archive_products"
    assert code =~ ~s(method :post)
  end

  test "without a query dialect every POST is a create unless listed in reads" do
    config = Keyword.delete(config(reads: ["queryProducts"]), :dialect)
    code = code(config, :"Inventory.Product")

    assert code =~ "read :query_products"
    assert code =~ "create :archive_products"
    # the wrapper is unwrapped through the entity path
    assert code =~ ~s(entity_path "data")
  end

  test "maps OpenAPI types and formats to Ash types" do
    code = code(config(), :"Inventory.Product")

    assert code =~ "attribute :product_id, :uuid do"
    assert code =~ "attribute :price, :float"
    assert code =~ "attribute :stock_level, :integer"
    assert code =~ "attribute :tags, {:array, :string}"
    assert code =~ "attribute :released_on, :date"
    assert code =~ "attribute :updated_at, :utc_datetime_usec"
    assert code =~ "constraints one_of: [:tools, :garden, :kitchen]"
    assert code =~ "constraints max_length: 200"
    refute code =~ "internal_note"
  end

  test "dimension hints from the request schema" do
    code = code(config(), :"Inventory.Product")

    # stock_level is returned but not a dimension
    assert code =~ ~r/field :stock_level do\s+member false/
    assert code =~ ~r/field :updated_at do\s+time_dimension\? true/
  end

  test "overrides: rename, skip, filterable, fields, relationships" do
    code =
      code(
        config(
          rename: [name: :title],
          skip: [:tags],
          types: [stock_level: :decimal],
          filterable: [category: [:eq, :in]],
          fields: [price: [member: "unitPrice"]]
        ),
        :"Inventory.Product"
      )

    assert code =~ "attribute :title, :string"
    assert code =~ "attribute :stock_level, :decimal"
    assert code =~ ~r/field :title do\s+path "\$.name"/
    refute code =~ "attribute :tags"
    assert code =~ ~r/field :category do\s+filter_operators \[:eq, :in\]/
    assert code =~ ~r/field :product_id do\s+filter_operators \[\]/
    assert code =~ ~s(member "unitPrice")
    # from x-ash-relationship
    assert code =~ "belongs_to :warehouse, Inventory.Warehouse do"
    assert code =~ "source_attribute :warehouse_id"
  end

  test "vendor extensions: primary key and filter operators" do
    code = code(config(), :"Inventory.Warehouse")

    assert code =~ ~r/attribute :warehouse_id, :uuid do\s+primary_key\? true/
    assert code =~ ~r/field :city do\s+filter_operators \[:eq, :in\]/
  end

  test "an override naming a field the spec lacks fails with a clear error" do
    assert_raise ArgumentError, ~r/Inventory.Product.*filterable names :colour/, fn ->
      code(config(filterable: [colour: [:eq]]), :"Inventory.Product")
    end
  end

  test "fragments and a dialect per resource" do
    code =
      code(
        config(
          fragments: [Inventory.ProductActions],
          endpoint_actions: [query_products: [:by_warehouse]],
          dialect: {AshJsonApiWrapper.Dialect.CubeJs, response_case: :snake, total: false}
        ),
        :"Inventory.Product"
      )

    assert code =~ "fragments: [Inventory.ProductActions]"
    assert code =~ "endpoint [:query_products, :by_warehouse] do"
    assert code =~ "total: false"
  end

  test "regenerating gives the same code" do
    assert code(config(rename: [name: :title]), :"Inventory.Product") ==
             code(config(rename: [name: :title]), :"Inventory.Product")
  end

  test "the generated resources compile and read" do
    @spec_json
    |> ResourceGenerator.generate(Domain, config())
    |> Enum.each(fn {_resource, code} -> Code.eval_string(code) end)

    product = Module.concat(["Inventory.Product"])

    expect(AshJsonApiWrapper.MockAdapter, :call, fn env, _ ->
      assert env.url == "https://inventory.example.com/api/products"
      assert %{"query" => %{"filters" => [%{"member" => "category"}]}} = Jason.decode!(env.body)

      {:ok,
       %{
         env
         | status: 200,
           body:
             Jason.encode!(%{
               "data" => [
                 %{
                   "product_id" => "4b1c3e2a-0d9e-4f5a-9a51-0c6f3c2b1a00",
                   "name" => "Spade",
                   "category" => "garden",
                   "price" => 19.5,
                   "tags" => ["steel"],
                   "released_on" => "2023-04-01",
                   "updated_at" => "2024-01-02T03:04:05.000Z"
                 }
               ],
               "total" => 1
             })
       }}
    end)

    assert [%{name: "Spade", category: :garden, released_on: ~D[2023-04-01]}] =
             product
             |> Ash.Query.filter_input(%{category: %{eq: :garden}})
             |> Ash.read!()
  end
end

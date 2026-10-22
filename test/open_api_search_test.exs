# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.OpenApi.SearchTest do
  use ExUnit.Case
  require Ash.Query
  import Mox

  setup :verify_on_exit!

  # A made-up spec whose list endpoints take a query in a POST body.
  @json "test/support/search_api.json" |> File.read!() |> Jason.decode!()

  defmodule TestingTesla do
    use Tesla

    adapter(AshJsonApiWrapper.MockAdapter)
  end

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered? true
    end
  end

  @config [
    tesla: TestingTesla,
    endpoint: "https://inventory.example.com",
    resources: [
      "Inventory.Product": [
        path: "/products",
        primary_key: "id",
        reads: ["searchProducts"]
      ],
      "Inventory.Sale": [
        path: "/sales",
        primary_key: "id",
        dialect: {AshJsonApiWrapper.Dialect.CubeJs, cube: "Sales"}
      ]
    ]
  ]

  setup_all do
    generated = AshJsonApiWrapper.OpenApi.ResourceGenerator.generate(@json, Domain, @config)
    %{generated: Map.new(generated)}
  end

  test "POST operations become reads by config, others become creates", %{generated: generated} do
    code = generated[:"Inventory.Product"]

    assert code =~ "read :search_products"

    assert code =~
             ~r/endpoint :search_products do\s+path "\/products\/search"\s+entity_path "items"\s+method :post/

    assert code =~ "create :create_product"
    assert code =~ "read :get_product"
  end

  test "OpenAPI types map to Ash types", %{generated: generated} do
    code = generated[:"Inventory.Product"]

    assert code =~ ~r/attribute :id, :uuid do\s+primary_key\? true\s+allow_nil\? false/
    assert code =~ ~r/attribute :created_at, :utc_datetime_usec do\s+allow_nil\? false/

    assert code =~
             ~r/attribute :name, :string do\s+allow_nil\? false\s+constraints max_length: 200/

    assert code =~ "attribute :description, :string\n"
    assert code =~ "attribute :price, :float\n"
    assert code =~ "attribute :cost, :decimal\n"
    assert code =~ "attribute :stock, :integer\n"
    assert code =~ "attribute :active, :boolean\n"

    assert code =~
             ~r/attribute :status, :atom do\s+constraints one_of: \[:draft, :listed, :retired\]/

    assert code =~ "attribute :tags, {:array, :string}\n"
    assert code =~ "attribute :released_on, :date\n"
    assert code =~ "attribute :dimensions, :map\n"
    assert code =~ ~r/field :created_at do\s+path "createdAt"/
  end

  test "POST bodies that are queries in the dialect become reads", %{generated: generated} do
    code = generated[:"Inventory.Sale"]

    assert code =~ "dialect {AshJsonApiWrapper.Dialect.CubeJs, [cube: \"Sales\"]}"
    assert code =~ "read :load_sales"
    refute code =~ "entity_path"
    assert code =~ "attribute :region, :string"
    # A command without an entity response is not generated.
    refute code =~ "export_sales"
  end

  test "generated resources compile and read", %{generated: generated} do
    for {_resource, code} <- generated, do: Code.eval_string(code)

    expect(AshJsonApiWrapper.MockAdapter, :call, fn env, _ ->
      assert env.method == :post
      assert env.url == "https://inventory.example.com/products/search"
      assert Jason.decode!(env.body) == %{"limit" => 10}

      {:ok,
       %Tesla.Env{
         status: 200,
         body:
           Jason.encode!(%{
             "items" => [
               %{
                 "id" => "0e5a3f3e-5d6f-4d1e-9c55-4c3b2a1f0e9d",
                 "name" => "Desk lamp",
                 "createdAt" => "2024-02-01T12:00:00Z",
                 "releasedOn" => "2024-03-01",
                 "tags" => ["light"]
               }
             ],
             "total" => 1
           })
       }}
    end)

    assert [lamp] =
             Inventory.Product
             |> Ash.Query.for_read(:search_products)
             |> AshJsonApiWrapper.set_body_param("limit", 10)
             |> Ash.read!()

    assert lamp.name == "Desk lamp"
    assert lamp.created_at == ~U[2024-02-01 12:00:00.000000Z]
    assert lamp.released_on == ~D[2024-03-01]
  end

  test "the existing petstore spec still generates", %{} do
    json = "test/support/pet_store.json" |> File.read!() |> Jason.decode!()

    [{_, code}] =
      AshJsonApiWrapper.OpenApi.ResourceGenerator.generate(json, Domain,
        resources: [
          "Inventory.Pet": [path: "/pet", primary_key: "id"]
        ]
      )

    assert code =~ "read :find_pets_by_status"
    assert code =~ "attribute :photo_urls, {:array, :string}"
    assert code =~ ~r/field :photo_urls do\s+path "photoUrls"/
  end

  describe "mix ash_json_api_wrapper.gen.resources" do
    import Igniter.Test

    @tag :tmp_dir
    test "writes resource files and overwrites them when run again", %{tmp_dir: tmp_dir} do
      File.cp!("test/support/search_api.json", Path.join(tmp_dir, "inventory.json"))
      config_path = Path.join(tmp_dir, "inventory.exs")

      write_config = fn reads ->
        File.write!(config_path, """
        [
          spec: "inventory.json",
          domain: MyApp.Inventory,
          endpoint: "https://inventory.example.com",
          resources: [
            "MyApp.Inventory.Product": [path: "/products", primary_key: "id", reads: #{inspect(reads)}]
          ]
        ]
        """)
      end

      write_config.(["searchProducts"])

      igniter =
        test_project()
        |> Igniter.compose_task("ash_json_api_wrapper.gen.resources", [config_path])
        |> assert_creates("lib/my_app/inventory/product.ex")

      igniter
      |> Igniter.Test.apply_igniter!()
      |> then(fn igniter ->
        write_config.([])
        Igniter.compose_task(igniter, "ash_json_api_wrapper.gen.resources", [config_path])
      end)
      # The test project's formatter does not import the Ash DSL, so it adds parens.
      |> assert_has_patch("lib/my_app/inventory/product.ex", """
      - |    read(:search_products)
      + |    create(:search_products)
      """)
    end
  end
end

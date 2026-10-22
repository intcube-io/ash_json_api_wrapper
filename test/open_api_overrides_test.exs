# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.OpenApi.OverridesTest do
  use ExUnit.Case
  require Ash.Query
  import Mox

  setup :verify_on_exit!

  alias AshJsonApiWrapper.OpenApi.ResourceGenerator

  # A made-up spec with x-ash-* hints.
  @catalog "test/support/catalog_api.json" |> File.read!() |> Jason.decode!()
  @search "test/support/search_api.json" |> File.read!() |> Jason.decode!()

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

  @catalog_config [
    tesla: TestingTesla,
    endpoint: "https://catalog.example.com",
    resources: [
      "Catalog.Item": [path: "/items"],
      "Catalog.Category": [path: "/categories"]
    ]
  ]

  defp generate(json, resources) do
    json
    |> ResourceGenerator.generate(Domain, Keyword.put(@catalog_config, :resources, resources))
    |> Map.new()
  end

  test "x-ash-* extensions in the spec are applied" do
    generated = generate(@catalog, @catalog_config[:resources])
    item = generated[:"Catalog.Item"]
    category = generated[:"Catalog.Category"]

    assert item =~ ~r/attribute :sku, :string do\s+primary_key\? true\s+allow_nil\? false/
    refute item =~ "internal_note"
    assert item =~ ~r/field :name do\s+path "title"/
    assert item =~ ~r/field :status do\s+filter_handler :simple\s+filter_operators \[:==, :in\]/
    assert item =~ ~r/attribute :name, :string do\s+filterable\? false/
    # Primary keys and relationship attributes stay filterable.
    assert item =~ "attribute :category_id, :integer\n"
    refute item =~ ~r/allow_nil\? false\s+filterable\? false/

    assert item =~
             ~r/belongs_to :category, Catalog.Category do\s+source_attribute :category_id\s+define_attribute\? false/

    assert category =~ ~r/has_many :items, Catalog.Item do\s+destination_attribute :category_id/
  end

  test "config overrides win over extensions" do
    generated =
      generate(@catalog,
        "Catalog.Item": [
          path: "/items",
          rename: [title: :headline],
          filterable: [title: [:==]],
          skip: [:category_id],
          relationships: [
            category: [type: :has_one, destination: Catalog.Other, destination_attribute: :sku]
          ]
        ]
      )

    item = generated[:"Catalog.Item"]

    assert item =~
             ~r/field :headline do\s+path "title"\s+filter_handler \{:simple, "title"\}\s+filter_operators \[:==\]/

    # Extensions of other properties still apply.
    assert item =~ ~r/field :status do\s+filter_handler :simple\s+filter_operators \[:==, :in\]/
    refute item =~ "category_id"
    assert item =~ ~r/has_one :category, Catalog.Other do\s+destination_attribute :sku/
  end

  test "overrides naming a property that is not in the spec fail" do
    for override <- [
          skip: ["colour"],
          rename: [colour: :color],
          filterable: [colour: [:==]],
          primary_key: "colour",
          relationships: [shade: [destination: Catalog.Shade, source_attribute: "colour"]]
        ] do
      error =
        assert_raise ArgumentError, fn ->
          generate(@catalog, "Catalog.Item": [{:path, "/items"}, override])
        end

      assert error.message =~ "names \"colour\", which is not a property of the entity schema"
      assert error.message =~ "Properties: categoryId, internalNote, sku, status, title"
    end
  end

  test "renamed properties are explicit in the dialect's names" do
    generated =
      generate(@search,
        "Catalog.Product": [
          path: "/products",
          primary_key: "id",
          reads: ["searchProducts"],
          rename: [releasedOn: :launch_date],
          dialect: AshJsonApiWrapper.Dialect.OData
        ]
      )

    assert generated[:"Catalog.Product"] =~
             "dialect {AshJsonApiWrapper.Dialect.OData, [properties: [launch_date: \"releasedOn\"]]}"
  end

  test "generated resources enforce filterable fields and their operators" do
    for {_, code} <- generate(@catalog, @catalog_config[:resources]), do: Code.eval_string(code)

    expect(AshJsonApiWrapper.MockAdapter, :call, fn env, _ ->
      assert env.query == %{"status" => "active"}
      {:ok, %Tesla.Env{status: 200, body: ~s({"data": [{"sku": "a-1", "title": "Lamp"}]})}}
    end)

    assert [%{sku: "a-1", name: "Lamp"}] =
             Catalog.Item |> Ash.Query.filter(status == "active") |> Ash.read!()

    assert {:error, _} = Catalog.Item |> Ash.Query.filter(name == "Lamp") |> Ash.read()
  end

  test "filter_operators restrict what the dialect would allow" do
    defmodule Person do
      use Ash.Resource,
        domain: AshJsonApiWrapper.OpenApi.OverridesTest.Domain,
        data_layer: AshJsonApiWrapper.DataLayer,
        validate_domain_inclusion?: false

      json_api_wrapper do
        tesla(AshJsonApiWrapper.OpenApi.OverridesTest.TestingTesla)
        dialect(AshJsonApiWrapper.Dialect.OData)

        endpoints do
          base("https://people.example.com")
        end

        fields do
          field :name do
            filter_operators([:==, :string_starts_with])
          end
        end
      end

      actions do
        defaults([:read])
      end

      attributes do
        uuid_primary_key(:id, public?: true)
        attribute(:name, :string, public?: true)
      end
    end

    expect(AshJsonApiWrapper.MockAdapter, :call, 2, fn _, _ ->
      {:ok, %Tesla.Env{status: 200, body: ~s({"value": []})}}
    end)

    assert {:ok, []} = Person |> Ash.Query.filter(name == "A") |> Ash.read()
    assert {:ok, []} = Person |> Ash.Query.filter(string_starts_with(name, "A")) |> Ash.read()
    assert {:error, _} = Person |> Ash.Query.filter(contains(name, "A")) |> Ash.read()
    assert {:error, _} = Person |> Ash.Query.filter(name != "A") |> Ash.read()
  end

  describe "re-running the generator" do
    import Igniter.Test

    @tag :tmp_dir
    test "keeps overrides applied when the spec changes", %{tmp_dir: tmp_dir} do
      spec_path = Path.join(tmp_dir, "catalog.json")
      config_path = Path.join(tmp_dir, "catalog.exs")
      File.write!(spec_path, Jason.encode!(@catalog))

      File.write!(config_path, """
      [
        spec: "catalog.json",
        domain: MyApp.Catalog,
        resources: [
          "MyApp.Catalog.Item": [path: "/items", rename: [title: :headline]]
        ]
      ]
      """)

      run = &Igniter.compose_task(&1, "ash_json_api_wrapper.gen.resources", [config_path])

      igniter =
        test_project()
        |> run.()
        |> apply_igniter!()

      changed =
        put_in(@catalog, ["components", "schemas", "Item", "properties", "color"], %{
          "type" => "string"
        })

      File.write!(spec_path, Jason.encode!(changed))

      igniter = run.(igniter)
      source = Rewrite.source!(igniter.rewrite, "lib/my_app/catalog/item.ex")
      content = Rewrite.Source.get(source, :content)

      assert content =~ "attribute :color, :string do"
      assert content =~ ~r/field :headline do\s+path\("title"\)/
      assert content =~ "attribute :headline, :string do"
    end
  end
end

# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.SimpleDialectTest do
  use ExUnit.Case
  require Ash.Query
  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  defmodule TestingTesla do
    use Tesla

    adapter(AshJsonApiWrapper.MockAdapter)
  end

  defmodule Item do
    use Ash.Resource,
      domain: AshJsonApiWrapper.SimpleDialectTest.Domain,
      data_layer: AshJsonApiWrapper.DataLayer,
      validate_domain_inclusion?: false

    json_api_wrapper do
      tesla(TestingTesla)

      endpoints do
        base("https://api.example.com")

        endpoint :read do
          path("/items")
          entity_path("data")
          runtime_sort?(true)
          limit_with({:param, "per_page"})
          paginator(continuation_property("next", param: "cursor"))

          field :status do
            filter_handler(:simple)
          end

          field :tag do
            filter_handler({:place_in_csv_list, ["tags"]})
          end
        end

        get_endpoint :read, :id do
          path("/items/:id")
        end
      end
    end

    actions do
      defaults([:read])
    end

    attributes do
      integer_primary_key(:id, public?: true)
      attribute(:status, :string, public?: true)
      attribute(:tag, :string, public?: true)
      attribute(:name, :string, public?: true)
    end
  end

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered?(true)
    end
  end

  defp respond(body), do: {:ok, %Tesla.Env{status: 200, body: Jason.encode!(body)}}

  test "handled filters become query params, others run on the fetched records" do
    expect(AshJsonApiWrapper.MockAdapter, :call, fn env, _ ->
      assert env.method == :get
      assert env.url == "https://api.example.com/items"
      assert %{"status" => "open", "tags" => tags} = env.query
      assert tags |> String.split(",") |> Enum.sort() == ["a", "b"]

      respond(%{
        "data" => [
          %{"id" => 1, "name" => "x", "status" => "open"},
          %{"id" => 2, "name" => "y", "status" => "open"}
        ]
      })
    end)

    assert [%{id: 2}] =
             Item
             |> Ash.Query.filter(status == "open" and tag in ["a", "b"] and name == "y")
             |> Ash.read!()
  end

  test "get endpoint filters fill the path, one request per value" do
    expect(AshJsonApiWrapper.MockAdapter, :call, 2, fn env, _ ->
      "https://api.example.com/items/" <> id = env.url
      respond(%{"id" => String.to_integer(id), "name" => "item #{id}"})
    end)

    assert [1, 2] =
             Item
             |> Ash.Query.filter(id in [1, 2])
             |> Ash.Query.sort(:id)
             |> Ash.read!()
             |> Enum.map(& &1.id)
  end

  test "get endpoint filters combine with other filters" do
    expect(AshJsonApiWrapper.MockAdapter, :call, fn env, _ ->
      assert env.url == "https://api.example.com/items/7"
      respond(%{"id" => 7, "name" => "seven", "status" => "open"})
    end)

    assert [%{id: 7}] =
             Item
             |> Ash.Query.filter(id == 7 and name == "seven")
             |> Ash.read!()
  end

  test "an `or` over a list field only goes to the list when both sides do" do
    expect(AshJsonApiWrapper.MockAdapter, :call, 2, fn env, _ ->
      case env.query do
        %{"tags" => tags} ->
          assert tags |> String.split(",") |> Enum.sort() == ["a", "b"]
          respond(%{"data" => [%{"id" => 1, "tag" => "a"}]})

        query when query == %{} ->
          respond(%{"data" => [%{"id" => 1, "tag" => "a"}, %{"id" => 2, "name" => "n"}]})
      end
    end)

    assert [1] =
             Item
             |> Ash.Query.filter(tag == "a" or tag == "b")
             |> Ash.read!()
             |> Enum.map(& &1.id)

    assert [1, 2] =
             Item
             |> Ash.Query.filter(tag == "a" or name == "n")
             |> Ash.read!()
             |> Enum.map(& &1.id)
  end

  test "limit goes to the limit param and the paginator follows pages" do
    expect(AshJsonApiWrapper.MockAdapter, :call, 2, fn env, _ ->
      case env.query do
        %{"per_page" => 2, "cursor" => "c2"} ->
          respond(%{"data" => [%{"id" => 3, "name" => "c"}]})

        %{"per_page" => 2} ->
          respond(%{
            "data" => [%{"id" => 1, "name" => "b"}, %{"id" => 2, "name" => "a"}],
            "next" => "c2"
          })
      end
    end)

    assert ["a", "b"] =
             Item
             |> Ash.Query.sort(:name)
             |> Ash.Query.limit(2)
             |> Ash.read!()
             |> Enum.map(& &1.name)
  end
end

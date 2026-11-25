# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.PageNumberPagination.Test do
  use ExUnit.Case
  import Mox

  setup :verify_on_exit!

  defmodule TestingTesla do
    use Tesla
    adapter(AshJsonApiWrapper.MockAdapter)
  end

  defmodule Item do
    use Ash.Resource,
      domain: AshJsonApiWrapper.PageNumberPagination.Test.Domain,
      data_layer: AshJsonApiWrapper.DataLayer,
      validate_domain_inclusion?: false

    json_api_wrapper do
      tesla(TestingTesla)

      endpoints do
        base("https://api.example.com")

        endpoint :read do
          path("/items")
          paginator page_number("page", page_size_param: "per_page", page_size: 2)
        end

        endpoint :read_capped do
          path("/items")
          paginator page_number("page", page_size_param: "per_page", page_size: 2, max_pages: 2)
        end

        endpoint :read_from_zero do
          path("/items")
          paginator page_number("p", page_size: 2, first_page: 0)
        end
      end
    end

    actions do
      defaults [:read]
      read :read_capped
      read :read_from_zero
    end

    attributes do
      attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    end
  end

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered?(true)
    end
  end

  defp items(ids), do: Jason.encode!(Enum.map(ids, &%{"id" => &1}))

  defp serve(pages, page_param \\ "page") do
    fn %Tesla.Env{} = env, _opts ->
      page = env.query[page_param]

      case Map.fetch(pages, page) do
        {:ok, ids} -> {:ok, %Tesla.Env{env | status: 200, body: items(ids)}}
        :error -> {:ok, %Tesla.Env{env | status: 500, body: "unexpected #{inspect(env.query)}"}}
      end
    end
  end

  test "reads pages until one comes back short" do
    expect(AshJsonApiWrapper.MockAdapter, :call, 3, fn %Tesla.Env{} = env, opts ->
      assert env.query["per_page"] == 2
      serve(%{1 => ["a", "b"], 2 => ["c", "d"], 3 => ["e"]}).(env, opts)
    end)

    assert Item |> Ash.read!() |> Enum.map(& &1.id) == ["a", "b", "c", "d", "e"]
  end

  test "stops after an empty page" do
    expect(AshJsonApiWrapper.MockAdapter, :call, 2, serve(%{1 => ["a", "b"], 2 => []}))

    assert Item |> Ash.read!() |> Enum.map(& &1.id) == ["a", "b"]
  end

  test "fails when max_pages is reached and the last page is still full" do
    expect(AshJsonApiWrapper.MockAdapter, :call, 2, serve(%{1 => ["a", "b"], 2 => ["c", "d"]}))

    assert {:error, error} = Ash.read(Item, action: :read_capped)
    assert Exception.message(error) =~ "Stopped after 2 pages"
  end

  test "reads within max_pages" do
    expect(AshJsonApiWrapper.MockAdapter, :call, 2, serve(%{1 => ["a", "b"], 2 => ["c"]}))

    assert Item |> Ash.read!(action: :read_capped) |> Enum.map(& &1.id) == ["a", "b", "c"]
  end

  test "starts at first_page and works without a page size param" do
    expect(AshJsonApiWrapper.MockAdapter, :call, 2, fn %Tesla.Env{} = env, opts ->
      refute Map.has_key?(env.query, "per_page")
      serve(%{0 => ["a", "b"], 1 => ["c"]}, "p").(env, opts)
    end)

    assert Item |> Ash.read!(action: :read_from_zero) |> Enum.map(& &1.id) == ["a", "b", "c"]
  end
end

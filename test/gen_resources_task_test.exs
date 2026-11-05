# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshJsonApiWrapper.Gen.ResourcesTest do
  use ExUnit.Case
  import Igniter.Test

  test "writes one file per resource and rewrites it on the next run" do
    args = ["test/support/query_api.json", "test/support/query_api_config.exs"]

    igniter =
      test_project()
      |> Igniter.compose_task("ash_json_api_wrapper.gen.resources", args)

    igniter
    |> assert_creates("lib/inventory/product.ex")
    |> assert_creates("lib/inventory/warehouse.ex")

    igniter
    |> apply_igniter!()
    |> Igniter.compose_task("ash_json_api_wrapper.gen.resources", args)
    |> assert_unchanged()
  end
end

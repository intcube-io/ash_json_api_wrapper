# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshJsonApiWrapper.Gen.Resources do
    @example "mix ash_json_api_wrapper.gen.resources priv/specs/inventory.json priv/specs/inventory.exs"

    @moduledoc """
    Writes resources generated from an OpenAPI spec to files.

    The first argument is the spec (JSON), the second an `.exs` file that
    evaluates to the generator config plus a `:domain`:

        [
          domain: MyApp.Inventory,
          tesla: MyApp.Inventory.Client,
          endpoint: "https://inventory.example.com",
          dialect: AshJsonApiWrapper.Dialect.CubeJs,
          resources: [
            "MyApp.Inventory.Product": [path: "/api/products", primary_key: "product_id"]
          ]
        ]

    Each resource lands where its module name says (`lib/my_app/inventory/product.ex`)
    and is replaced on every run, so keep changes in the config (see the overrides in
    `AshJsonApiWrapper.OpenApi.ResourceGenerator`) and rerun the task when the spec
    changes.

    ## Example

    ```bash
    #{@example}
    ```
    """

    @shortdoc "Generates resources from an OpenAPI spec"
    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :ash_json_api_wrapper,
        example: @example,
        positional: [:spec, :config]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      %{spec: spec_path, config: config_path} = igniter.args.positional

      spec = spec_path |> File.read!() |> Jason.decode!()
      {config, _} = Code.eval_file(config_path)
      {domain, config} = Keyword.pop!(config, :domain)

      spec
      |> AshJsonApiWrapper.OpenApi.ResourceGenerator.generate(domain, config)
      |> Enum.reduce(igniter, fn {resource, code}, igniter ->
        module = Igniter.Project.Module.parse(to_string(resource))
        path = Igniter.Project.Module.proper_location(igniter, module)

        Igniter.create_or_update_elixir_file(igniter, path, code, fn zipper ->
          {:ok, Igniter.Code.Common.replace_code(zipper, code)}
        end)
      end)
    end
  end
else
  defmodule Mix.Tasks.AshJsonApiWrapper.Gen.Resources do
    @moduledoc "Writes resources generated from an OpenAPI spec to files. Needs igniter."
    @shortdoc @moduledoc
    use Mix.Task

    def run(_argv) do
      Mix.shell().error(
        "mix ash_json_api_wrapper.gen.resources needs igniter: add {:igniter, \"~> 0.5\"}"
      )

      exit({:shutdown, 1})
    end
  end
end

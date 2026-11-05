# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshJsonApiWrapper.Gen.Resources do
    use Igniter.Mix.Task

    @example "mix ash_json_api_wrapper.gen.resources priv/specs/inventory.exs"

    @shortdoc "Generates resources from an OpenAPI spec"
    @moduledoc """
    #{@shortdoc}

    Writes one file per resource, at the usual location for its module. Running the task again
    overwrites the files, so re-run it when the spec changes and review the diff.

    The argument is an `.exs` file that evaluates to the generator config, see
    `AshJsonApiWrapper.OpenApi.ResourceGenerator`, plus:

    * `:spec` - the path of the OpenAPI spec (JSON), relative to the config file
    * `:domain` - the domain of the generated resources

    ```elixir
    # priv/specs/inventory.exs
    [
      spec: "inventory.json",
      domain: MyApp.Inventory,
      endpoint: "https://inventory.example.com",
      resources: [
        "MyApp.Inventory.Product": [
          path: "/products",
          primary_key: "id",
          reads: ["searchProducts"]
        ]
      ]
    ]
    ```

    ## Example

    ```bash
    #{@example}
    ```
    """

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :ash_json_api_wrapper,
        example: @example,
        positional: [:config]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      config_path = igniter.args.positional.config
      {config, _binding} = Code.eval_file(config_path)

      spec =
        config_path
        |> Path.dirname()
        |> Path.join(Keyword.fetch!(config, :spec))
        |> File.read!()
        |> Jason.decode!()

      spec
      |> AshJsonApiWrapper.OpenApi.ResourceGenerator.generate(
        Keyword.fetch!(config, :domain),
        config
      )
      |> Enum.reduce(igniter, fn {resource, code}, igniter ->
        path = Igniter.Project.Module.proper_location(igniter, Module.concat([resource]))

        Igniter.create_or_update_elixir_file(igniter, path, code, fn zipper ->
          {:ok, Igniter.Code.Common.replace_code(zipper, code)}
        end)
      end)
    end
  end
end

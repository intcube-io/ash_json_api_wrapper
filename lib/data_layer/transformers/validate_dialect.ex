# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.DataLayer.Transformers.ValidateDialect do
  @moduledoc false
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl Spark.Dsl.Transformer
  def transform(dsl) do
    {module, opts} = AshJsonApiWrapper.DataLayer.Info.dialect(dsl)
    Code.ensure_compiled!(module)

    if function_exported?(module, :opts_schema, 0) do
      case Spark.Options.validate(opts, module.opts_schema()) do
        {:ok, opts} ->
          {:ok, Transformer.set_option(dsl, [:json_api_wrapper], :dialect, {module, opts})}

        {:error, error} ->
          {:error,
           Spark.Error.DslError.exception(
             module: Transformer.get_persisted(dsl, :module),
             path: [:json_api_wrapper, :dialect],
             message: Exception.message(error)
           )}
      end
    else
      {:ok, dsl}
    end
  end
end

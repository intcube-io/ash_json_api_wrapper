# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.Records do
  @moduledoc false
  # Turns decoded response entities into resource records. Shared by all dialects.

  @doc """
  Casts each entity into a record of `resource`.

  `key_fun` names the response key of an attribute that has no `path` configured.
  """
  def process_entities(entities, resource, endpoint, key_fun \\ &to_string/1) do
    Enum.reduce_while(entities, {:ok, []}, fn entity, {:ok, entities} ->
      case process_entity(entity, resource, endpoint, key_fun) do
        {:ok, entity} -> {:cont, {:ok, [entity | entities]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, entities} -> {:ok, Enum.reverse(entities)}
      {:error, error} -> {:error, error}
    end
  end

  defp process_entity(entity, resource, endpoint, key_fun) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.reduce_while(
      {:ok,
       struct(resource,
         __meta__: %Ecto.Schema.Metadata{
           state: :loaded
         }
       )},
      fn attr, {:ok, record} ->
        case get_field(entity, attr, resource, endpoint, key_fun) do
          {:ok, value} ->
            {:cont, {:ok, Map.put(record, attr.name, value)}}

          {:error, error} ->
            {:halt, {:error, error}}
        end
      end
    )
  end

  defp get_field(entity, attr, resource, endpoint, key_fun) do
    raw_value = get_raw_value(entity, attr, resource, endpoint, key_fun)

    case Ash.Type.cast_stored(attr.type, raw_value, attr.constraints) do
      {:ok, value} ->
        {:ok, value}

      _ ->
        {:error,
         AshJsonApiWrapper.Errors.InvalidData.exception(field: attr.name, value: raw_value)}
    end
  end

  defp get_raw_value(entity, attr, resource, endpoint, key_fun) do
    case field_config(resource, endpoint, attr.name) do
      %{path: ""} ->
        entity

      %{path: path} when not is_nil(path) ->
        case ExJSONPath.eval(entity, path) do
          {:ok, [value | _]} ->
            value

          _ ->
            nil
        end

      _ ->
        Map.get(entity, key_fun.(attr.name))
    end
  end

  @doc "The field config for an attribute, from the endpoint first, then the resource."
  def field_config(resource, endpoint, name) do
    Enum.find((endpoint && endpoint.fields) || [], &(&1.name == name)) ||
      AshJsonApiWrapper.DataLayer.Info.field(resource, name)
  end
end

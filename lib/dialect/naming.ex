# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.Dialect.Naming do
  @moduledoc false

  @doc "The remote name of an attribute: an explicit name from `names`, or the cased attribute name."
  @spec remote_name(atom, :camel | :snake, Keyword.t()) :: String.t()
  def remote_name(name, casing, names) do
    case Keyword.fetch(names, name) do
      {:ok, remote_name} -> remote_name
      :error -> apply_case(name, casing)
    end
  end

  defp apply_case(name, :snake), do: to_string(name)

  defp apply_case(name, :camel) do
    [first | rest] = name |> to_string() |> String.split("_")
    Enum.join([first | Enum.map(rest, &String.capitalize/1)])
  end

  @doc "A key for matching names that differ only in case or underscores."
  @spec normalize(String.t()) :: String.t()
  def normalize(name) do
    name |> String.downcase() |> String.replace("_", "")
  end

  @doc """
  Renames the keys of a record to attribute names. `lookup` maps normalized remote names to
  attribute names; keys without a match are kept as they are.
  """
  @spec rename_keys(map, %{String.t() => String.t()}) :: map
  def rename_keys(record, lookup) when is_map(record) do
    Map.new(record, fn {key, value} -> {Map.get(lookup, normalize(key), key), value} end)
  end

  @doc "Encodes a filter value as a string."
  @spec encode_value(term) :: String.t()
  def encode_value(%Date{} = value), do: Date.to_iso8601(value)
  def encode_value(%Time{} = value), do: Time.to_iso8601(value)
  def encode_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def encode_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def encode_value(value), do: to_string(value)
end

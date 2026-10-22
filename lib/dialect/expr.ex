# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.Dialect.Expr do
  @moduledoc false
  # Filter expressions that compare one attribute of the resource with a value, the shape most
  # query languages can express.

  alias Ash.Query.Function.{Contains, StringEndsWith, StringStartsWith}
  alias Ash.Query.{Not, Ref}

  alias Ash.Query.Operator.{
    Eq,
    GreaterThan,
    GreaterThanOrEqual,
    In,
    IsNil,
    LessThan,
    LessThanOrEqual,
    NotEq
  }

  @comparisons [Eq, NotEq, In, GreaterThan, GreaterThanOrEqual, LessThan, LessThanOrEqual, IsNil]
  @functions [Contains, StringStartsWith, StringEndsWith]

  defmacro comparisons, do: @comparisons
  defmacro functions, do: @functions

  @doc "Whether an expression compares an attribute with a value, or is a `not`."
  def supported?(%Not{}), do: true
  def supported?(%In{left: %Ref{relationship_path: []}, right: right}), do: not ref?(right)
  def supported?(%In{}), do: false

  def supported?(%operator{left: left, right: right}) when operator in @comparisons,
    do: attribute_and_value?(left, right) or attribute_and_value?(right, left)

  def supported?(%function{arguments: [ref, value]}) when function in @functions,
    do: attribute_and_value?(ref, value)

  def supported?(_), do: false

  defp attribute_and_value?(%Ref{relationship_path: []}, value), do: not ref?(value)
  defp attribute_and_value?(_, _), do: false

  defp ref?(value), do: is_struct(value, Ref)

  @doc "Puts the attribute of a comparison on the left, `3 > x` becomes `x < 3`."
  def attribute_left(%{left: %Ref{}} = op), do: op
  def attribute_left(%GreaterThan{} = op), do: %LessThan{left: op.right, right: op.left}

  def attribute_left(%GreaterThanOrEqual{} = op),
    do: %LessThanOrEqual{left: op.right, right: op.left}

  def attribute_left(%LessThan{} = op), do: %GreaterThan{left: op.right, right: op.left}

  def attribute_left(%LessThanOrEqual{} = op),
    do: %GreaterThanOrEqual{left: op.right, right: op.left}

  def attribute_left(op), do: %{op | left: op.right, right: op.left}
end

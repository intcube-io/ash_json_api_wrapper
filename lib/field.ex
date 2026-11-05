# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.Field do
  @moduledoc "Represents a field mapped in the target api."
  defstruct [
    :name,
    :path,
    :write_path,
    :filter_handler,
    :member,
    :filter_operators,
    time_dimension?: false,
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{}

  def schema do
    [
      name: [
        type: :atom,
        required: true,
        doc: "The attribute this field is configuring"
      ],
      path: [
        type: :string,
        doc: "The path of the value for this field, relative to the entity's path"
      ],
      write_path: [
        type: {:list, :string},
        doc: "The list path of the value for this field when writing."
      ],
      filter_handler: [
        type: :any,
        doc: """
        Specification for how the field is handled when used in filters. This is relatively limited at the moment.

        Supports the following:
        * `:simple` - Sets the value directly into the query params.
        * `{:simple, "key" | ["path", "to", "key"]}` - Sets the value directly into the query params using the provided key.
        * `{:place_in_list, ["path", "to", "list"]}` - Supports `or equals` and `in` filters over the given field, by placing their values in the provided list.
        * `{:place_in_csv_list, ["path", "to", "list"]}` - Supports `or equals` and `in` filters over the given field, by placing their values in the provided list.
        """
      ],
      member: [
        type: {:or, [:string, {:literal, false}]},
        doc: """
        The name of the field in queries, for dialects that name fields in the request
        (for example a Cube.js dimension). Defaults to the attribute name in the
        dialect's naming style. `false` means the API returns the field on its own and it
        can neither be requested nor filtered.
        """
      ],
      filter_operators: [
        type: {:list, :atom},
        doc: """
        The filters the API accepts on this field, by Ash operator or function name
        (`:eq`, `:in`, `:is_nil`, `:contains`, `:string_starts_with`, `:gt`, `:gte`,
        `:lt`, `:lte`). Unset means every filter the dialect supports; `[]` means the
        field is not filterable. Ash rejects any other filter on the field before a
        request is made.
        """
      ],
      time_dimension?: [
        type: :boolean,
        default: false,
        doc: """
        For dialects with separate time dimensions (Cube.js `timeDimensions`): range
        filters on this field go into a date range instead of the filters.
        """
      ]
    ]
  end
end

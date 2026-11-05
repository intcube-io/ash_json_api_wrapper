# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

[
  domain: Inventory,
  tesla: Inventory.Client,
  endpoint: "https://inventory.example.com",
  dialect: {AshJsonApiWrapper.Dialect.CubeJs, response_case: :snake},
  resources: [
    "Inventory.Product": [path: "/api/products", primary_key: "product_id"],
    "Inventory.Warehouse": [path: "/api/warehouses"]
  ]
]

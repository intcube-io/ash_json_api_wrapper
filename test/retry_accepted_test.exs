# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.Tesla.RetryAcceptedTest do
  use ExUnit.Case
  import Mox

  setup :verify_on_exit!

  defmodule Client do
    use Tesla
    adapter(AshJsonApiWrapper.MockAdapter)
    plug(AshJsonApiWrapper.Tesla.RetryAccepted, max_retries: 2, default_delay: 1)
  end

  test "repeats the request until the result is ready" do
    AshJsonApiWrapper.MockAdapter
    |> expect(:call, fn env, _ ->
      {:ok, %{env | status: 202, headers: [{"retry-after", "0"}], body: "{}"}}
    end)
    |> expect(:call, fn env, _ -> {:ok, %{env | status: 200, body: ~s({"data": []})}} end)

    assert {:ok, %{status: 200}} = Client.post("https://api.example.com/query", "{}")
  end

  test "gives up after max_retries" do
    expect(AshJsonApiWrapper.MockAdapter, :call, 3, fn env, _ ->
      {:ok, %{env | status: 202, body: ""}}
    end)

    assert {:error, :still_accepted} = Client.post("https://api.example.com/query", "{}")
  end
end

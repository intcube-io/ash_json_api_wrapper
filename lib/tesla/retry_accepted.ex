# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.Tesla.RetryAccepted do
  @moduledoc """
  Repeats a request that was answered `202 Accepted`.

  Some query APIs answer `202` with no result when a query is still running and
  expect the identical request again after `Retry-After` seconds. Treating that
  `202` as an empty result would silently drop rows, so this middleware waits and
  retries until a different status arrives or `:max_retries` is reached (the last
  `202` is then returned as an error).

      plug AshJsonApiWrapper.Tesla.RetryAccepted, max_retries: 10, max_delay: 30_000

  ## Options

  * `:max_retries` - retries before giving up (default 10)
  * `:default_delay` - milliseconds to wait without a `Retry-After` header (1000)
  * `:max_delay` - upper bound for one wait in milliseconds (30000)
  """

  @behaviour Tesla.Middleware

  @impl true
  def call(env, next, opts) do
    attempt(env, next, opts, Keyword.get(opts, :max_retries, 10))
  end

  defp attempt(env, next, opts, retries_left) do
    case Tesla.run(env, next) do
      {:ok, %Tesla.Env{status: 202} = response} when retries_left > 0 ->
        Process.sleep(delay(response, opts))
        attempt(env, next, opts, retries_left - 1)

      {:ok, %Tesla.Env{status: 202}} ->
        {:error, :still_accepted}

      other ->
        other
    end
  end

  defp delay(response, opts) do
    default = Keyword.get(opts, :default_delay, 1000)
    max = Keyword.get(opts, :max_delay, 30_000)

    seconds =
      case Tesla.get_header(response, "retry-after") do
        nil -> nil
        value -> value |> String.trim() |> Integer.parse()
      end

    case seconds do
      {seconds, _} when seconds >= 0 -> min(seconds * 1000, max)
      _ -> min(default, max)
    end
  end
end

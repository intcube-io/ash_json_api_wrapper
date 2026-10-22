# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.TokenCache do
  @moduledoc """
  Caches tokens and makes sure only one caller refreshes a token at a time.

  Valid tokens are read from a protected ETS table without going through the server. When a
  token is missing or expired, the first caller is told to fetch a new one in its own process;
  callers that ask in the meantime wait for its result. If the fetching caller dies, the next
  waiting caller takes over.

  Started by the `:ash_json_api_wrapper` application.
  """

  use GenServer

  @table __MODULE__

  @type key :: term
  @type fetch_fun :: (-> {:ok, String.t(), expires_in :: non_neg_integer} | {:error, term})

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the cached token for `key`, or fetches one with `fetch`.

  `fetch` returns the token and how many seconds it is valid. The token is used until
  `refresh_before` seconds before it expires.
  """
  @spec fetch(key, fetch_fun, refresh_before :: non_neg_integer) ::
          {:ok, String.t()} | {:error, term}
  def fetch(key, fetch, refresh_before \\ 60) do
    case cached(key) do
      {:ok, token} ->
        {:ok, token}

      :error ->
        case GenServer.call(__MODULE__, {:checkout, key}, :infinity) do
          :refresh -> refresh(key, fetch, refresh_before)
          result -> result
        end
    end
  end

  @doc """
  Drops `token` for `key`, for example after the API rejected it. Does nothing if the cached
  token is already a newer one.
  """
  @spec invalidate(key, String.t()) :: :ok
  def invalidate(key, token) do
    GenServer.call(__MODULE__, {:invalidate, key, token})
  end

  defp cached(key) do
    now = System.monotonic_time(:second)

    case :ets.lookup(@table, key) do
      [{^key, token, valid_until}] when valid_until > now -> {:ok, token}
      _ -> :error
    end
  end

  defp refresh(key, fetch, refresh_before) do
    result =
      try do
        fetch.()
      catch
        kind, reason -> {:error, Exception.format(kind, reason, __STACKTRACE__)}
      end

    result =
      case result do
        {:ok, token, expires_in} ->
          {:ok, token, System.monotonic_time(:second) + expires_in - refresh_before}

        {:error, error} ->
          {:error, error}
      end

    GenServer.call(__MODULE__, {:refreshed, key, result})
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, %{refreshing: %{}}}
  end

  @impl true
  def handle_call({:checkout, key}, {pid, _} = from, state) do
    case {cached(key), state.refreshing} do
      {{:ok, token}, _} ->
        {:reply, {:ok, token}, state}

      {:error, %{^key => {refresher, ref, waiting}}} ->
        {:noreply, put_in(state.refreshing[key], {refresher, ref, [from | waiting]})}

      {:error, _} ->
        ref = Process.monitor(pid)
        {:reply, :refresh, put_in(state.refreshing[key], {pid, ref, []})}
    end
  end

  def handle_call({:refreshed, key, result}, _from, state) do
    {{_pid, ref, waiting}, refreshing} = Map.pop(state.refreshing, key)
    Process.demonitor(ref, [:flush])

    reply =
      case result do
        {:ok, token, valid_until} ->
          :ets.insert(@table, {key, token, valid_until})
          {:ok, token}

        {:error, error} ->
          {:error, error}
      end

    Enum.each(waiting, &GenServer.reply(&1, reply))
    {:reply, reply, %{state | refreshing: refreshing}}
  end

  def handle_call({:invalidate, key, token}, _from, state) do
    :ets.match_delete(@table, {key, token, :_})
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.refreshing, fn {_key, {_pid, key_ref, _}} -> key_ref == ref end) do
      {key, {_pid, _ref, []}} ->
        {:noreply, %{state | refreshing: Map.delete(state.refreshing, key)}}

      {key, {_pid, _ref, waiting}} ->
        # The oldest waiting caller takes over the refresh.
        {{pid, _} = next, rest} = List.pop_at(waiting, -1)
        GenServer.reply(next, :refresh)
        new_ref = Process.monitor(pid)
        {:noreply, put_in(state.refreshing[key], {pid, new_ref, rest})}

      nil ->
        {:noreply, state}
    end
  end
end

defmodule PurpleChonkyWhale.AgentRun.Outcomes do
  # Defined ahead of the moduledoc, which reads them.
  @max_runs 512
  @evict_batch 64

  @moduledoc """
  The terminal-outcome cache for finished runs.

  A `PurpleChonkyWhale.AgentRun` is `restart: :temporary` and *stops* once it
  has settled: a finished run holds no state worth a process, and the durable
  truth already lives in the session log (`:"run/completed"` and friends).
  What a caller holds, though, is a pid — and a pid does not carry a run id,
  so an `await/2`, `status/1` or `cancel/2` that arrives after the run is
  gone has no way back to the run's own log entry. The outcome is therefore
  cached here just before the process exits.

  The cache is in memory only and bounded: at most #{@max_runs} runs, oldest
  evicted first (#{@evict_batch} at a time, so eviction is rare). Losing it
  (a BEAM restart) invalidates every outstanding pid anyway. A miss is
  reported as `:error`, never guessed — callers get a clear error instead of
  a stale answer.

  Rows are stored two ways so both handles resolve in O(1): `{:run, run_id}`
  carries the record and `{:pid, pid}` points at the run id.
  """

  use GenServer

  @table :pcw_run_outcomes

  @typedoc "One finished run: enough to answer `status/1` without the process."
  @type t :: %{
          run_id: String.t(),
          session_id: term(),
          pid: pid(),
          status: :completed | :failed | :cancelled,
          outcome: term(),
          at: integer()
        }

  ## Public API

  @doc false
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc """
  Remember the terminal state of `run_id`. Safe to call when the cache is not
  running (it degrades to a no-op).
  """
  @spec put(String.t(), map()) :: :ok
  def put(run_id, attrs) when is_binary(run_id) and is_map(attrs) do
    case table() do
      nil ->
        :ok

      _tab ->
        record =
          Map.merge(%{run_id: run_id, at: System.monotonic_time()}, attrs)

        :ets.insert(@table, {{:run, run_id}, record})
        :ets.insert(@table, {{:pid, record.pid}, run_id})
        evict()
        :ok
    end
  end

  @doc "The cached record for a finished run, by pid or by run id."
  @spec fetch(pid() | String.t()) :: {:ok, record()} | :error
  def fetch(pid) when is_pid(pid) do
    with tab when tab != nil <- table(),
         [{_key, run_id}] <- :ets.lookup(tab, {:pid, pid}),
         [{_key, record}] <- :ets.lookup(tab, {:run, run_id}) do
      {:ok, record}
    else
      _other -> :error
    end
  end

  def fetch(run_id) when is_binary(run_id) do
    with tab when tab != nil <- table(),
         [{_key, record}] <- :ets.lookup(tab, {:run, run_id}) do
      {:ok, record}
    else
      _other -> :error
    end
  end

  @doc false
  # Number of cached runs; used by tests.
  def size do
    case table() do
      nil -> 0
      _tab -> div(:ets.info(@table, :size), 2)
    end
  end

  ## GenServer

  @impl true
  def init(nil) do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :set,
          :public,
          read_concurrency: true,
          write_concurrency: true
        ])

      _existing ->
        @table
    end

    {:ok, %{}}
  end

  ## Internal

  defp table do
    case :ets.whereis(@table) do
      :undefined -> nil
      _tid -> @table
    end
  end

  # Drop the oldest batch once the cache is a full batch over its limit, so
  # the O(n log n) sort runs once every @evict_batch settlements, not once
  # per settlement.
  defp evict do
    if :ets.info(@table, :size) > (@max_runs + @evict_batch) * 2 do
      @table
      |> :ets.tab2list()
      |> Enum.filter(fn
        {{:run, _run_id}, _record} -> true
        _other -> false
      end)
      |> Enum.sort_by(fn {{:run, _run_id}, record} -> record.at end)
      |> Enum.take(@evict_batch)
      |> Enum.each(fn {{:run, run_id}, record} ->
        :ets.delete(@table, {:run, run_id})
        :ets.delete(@table, {:pid, record.pid})
      end)
    end

    :ok
  end
end

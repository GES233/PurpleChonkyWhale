defmodule PurpleChonkyWhale.AgentRunSupervisor do
  @moduledoc """
  Supervises and indexes `PurpleChonkyWhale.AgentRun` processes.

  May be used directly against the application-wide supervisor and registry
  (`PurpleChonkyWhale.AgentRunSupervisor` / `PurpleChonkyWhale.AgentRunRegistry`),
  or mounted as a Dexterous component providing `:runs` for per-composition
  supervision.

  Each run is supervised with `restart: :temporary`: an interrupted run must
  never be blindly restarted by OTP, because its in-flight tool calls may have
  had side effects with unknown outcomes.
  """

  use Dexterous.Component, provide: [:runs]

  alias PurpleChonkyWhale.AgentRun
  alias Dexterous.Context

  @default_sup __MODULE__
  @default_registry PurpleChonkyWhale.AgentRunRegistry

  @typedoc "A per-composition run supervisor handle bound to `:runs`."
  @type t :: %__MODULE__{
          sup: Supervisor.supervisor(),
          registry: atom(),
          scope: Context.scope() | nil
        }

  defstruct sup: @default_sup, registry: @default_registry, scope: nil

  @doc "Start a supervised `AgentRun` process."
  @spec start_run(t() | keyword(), keyword()) ::
          {:ok, pid(), String.t()} | {:error, term()}
  def start_run(handle_or_opts \\ %__MODULE__{}, maybe_opts \\ [])

  def start_run(opts, []) when is_list(opts) do
    start_run(%__MODULE__{}, opts)
  end

  def start_run(%__MODULE__{sup: sup, registry: registry}, opts) when is_list(opts) do
    run_id = Keyword.get_lazy(opts, :run_id, &AgentRun.generate_id/0)

    opts =
      opts
      |> Keyword.put(:run_id, run_id)
      |> Keyword.put_new(:registry, registry)

    spec = %{
      id: {AgentRun, run_id},
      start: {AgentRun, :start_link, [opts]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(sup, spec) do
      {:ok, pid} -> {:ok, pid, run_id}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Look up a run process by `run_id`."
  @spec lookup(t() | String.t(), String.t() | nil) :: {:ok, pid()} | :error
  def lookup(handle_or_run_id, maybe_run_id \\ nil)

  def lookup(run_id, nil) when is_binary(run_id) do
    lookup(%__MODULE__{}, run_id)
  end

  def lookup(%__MODULE__{registry: registry}, run_id) when is_binary(run_id) do
    case Registry.lookup(registry, {:run, run_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc "Return `{:ok, pid, run_id}` for the active run on `session_id`, or `:error`."
  @spec active_for_session(t() | term(), term()) :: {:ok, pid(), String.t()} | :error
  def active_for_session(handle_or_session_id, maybe_session_id \\ :__omitted__)

  def active_for_session(session_id, :__omitted__) when not is_struct(session_id, __MODULE__) do
    active_for_session(%__MODULE__{}, session_id)
  end

  def active_for_session(%__MODULE__{registry: registry}, session_id) do
    case Registry.lookup(registry, {:session, session_id}) do
      [{pid, run_id}] -> {:ok, pid, run_id}
      [] -> :error
    end
  end

  @doc "List all currently active runs (`[%{session_id:, run_id:, pid:}]`)."
  @spec list_active(t()) :: [%{session_id: term(), run_id: String.t(), pid: pid()}]
  def list_active(%__MODULE__{registry: registry} \\ %__MODULE__{}) do
    registry
    |> Registry.select([{{{:session, :"$1"}, :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.map(fn {session_id, pid, run_id} ->
      %{session_id: session_id, run_id: run_id, pid: pid}
    end)
  end

  ## Component

  @impl true
  def apply(ctx, _config) do
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
    registry = :"pcw_runs_registry_#{System.unique_integer([:positive])}"
    {:ok, registry_pid} = Registry.start_link(keys: :unique, name: registry)

    Process.unlink(sup)
    Process.unlink(registry_pid)
    Context.track(ctx, sup)
    Context.track(ctx, registry_pid)

    Context.set(ctx, :runs, %__MODULE__{
      sup: sup,
      registry: registry,
      scope: ctx.scope
    })
  end
end

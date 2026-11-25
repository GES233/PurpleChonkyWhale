defmodule PurpleChonkyWhale.AgentRunTest do
  use ExUnit.Case, async: false

  alias PurpleChonkyWhale.{AgentRun, AgentRunSupervisor, Session, Sessions, Tools}
  alias PurpleChonkyWhale.LLM.Client
  alias PurpleChonkyWhale.Tools.{Executor, Read, Write}
  alias Dexterous.Context

  defmodule EnvInspectTool do
    @moduledoc false
    @behaviour PurpleChonkyWhale.Tool

    @impl true
    def schema do
      %{
        name: "inspect_env",
        description: "Reports run-scoped identities from env",
        parameters: %{
          "type" => "object",
          "properties" => %{"tag" => %{"type" => "string"}}
        }
      }
    end

    @impl true
    def execute(args, env) do
      if notify = env[:notify_pid] do
        send(notify, {
          :tool_env_seen,
          args["tag"],
          %{
            session_id: env[:session_id],
            run_id: env[:run_id],
            tool_call_id: env[:tool_call_id]
          }
        })
      end

      {:ok,
       %{
         "tag" => args["tag"],
         "session_id" => to_string(env[:session_id]),
         "run_id" => env[:run_id],
         "tool_call_id" => env[:tool_call_id]
       }}
    end
  end

  defmodule BlockingTool do
    @moduledoc false
    @behaviour PurpleChonkyWhale.Tool

    @impl true
    def schema do
      %{
        name: "blocking_tool",
        description: "Blocks until cancelled or released",
        parameters: %{
          "type" => "object",
          "properties" => %{"step" => %{"type" => "string"}}
        }
      }
    end

    @impl true
    def execute(args, env) do
      if notify = env[:notify_pid] do
        send(notify, {:blocking_tool_started, args["step"], env[:tool_call_id], self()})
      end

      receive do
        :release -> {:ok, "released #{args["step"]}"}
      end
    end
  end

  defmodule RunBackend do
    @moduledoc false

    def stream_text(model, context, opts) do
      script_for = Keyword.fetch!(opts, :script_for)
      session_key = resolve_script_key(opts, context)
      script = script_for.(session_key)

      step =
        Agent.get_and_update(script, fn
          [head | rest] -> {head, rest}
          [] -> {{:text, "default done"}, []}
        end)

      {:ok, build_stream(step, model, context, opts)}
    end

    defp resolve_script_key(opts, _context) do
      opts[:script_key] || :default
    end

    defp build_stream({:text, text}, model, context, _opts) do
      %ReqLLM.StreamResponse{
        stream: [ReqLLM.StreamChunk.text(text), ReqLLM.StreamChunk.meta(%{finish_reason: "stop"})],
        metadata_handle: nil,
        cancel: fn -> :ok end,
        model: model,
        context: context
      }
    end

    defp build_stream({:tool_calls, calls}, model, context, _opts) do
      chunks =
        Enum.map(calls, fn call ->
          ReqLLM.StreamChunk.tool_call(call.name, call.arguments, %{"id" => call.id})
        end)

      %ReqLLM.StreamResponse{
        stream: chunks ++ [ReqLLM.StreamChunk.meta(%{finish_reason: "tool_use"})],
        metadata_handle: nil,
        cancel: fn -> :ok end,
        model: model,
        context: context
      }
    end

    defp build_stream({:blocking_stream, test_pid}, model, context, _opts) do
      stream =
        Stream.resource(
          fn -> :started end,
          fn :started ->
            send(test_pid, {:stream_in_flight, self()})

            receive do
              :never -> {[], :started}
            end
          end,
          fn _ -> :ok end
        )

      %ReqLLM.StreamResponse{
        stream: stream,
        metadata_handle: nil,
        cancel: fn ->
          send(test_pid, :req_llm_stream_cancel_called)
          :ok
        end,
        model: model,
        context: context
      }
    end
  end

  setup do
    scope = :"agent_run_test_#{System.unique_integer([:positive])}"
    dir = Path.join(System.tmp_dir!(), "pcw-run-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    ctx = Context.new(scope)
    {:ok, _} = Context.use(ctx, Sessions, dir: Path.join(dir, "sessions"))
    {:ok, _} = Context.use(ctx, AgentRunSupervisor, [])

    {:ok, Tools,
     tools: [Read, Write, EnvInspectTool, BlockingTool, Executor],
     env: %{cwd: dir, notify_pid: self()}}
    |> then(fn {_, mod, cfg} -> Context.use(ctx, mod, cfg) end)

    sessions = await(ctx, :sessions)
    tools = await(ctx, :tools)
    runs = await(ctx, :runs)

    {:ok, ctx: ctx, scope: scope, dir: dir, sessions: sessions, tools: tools, runs: runs}
  end

  test "persists run/start and run/completed, enforces one active run per session, and settles at most once",
       %{
         scope: scope,
         sessions: sessions,
         tools: tools,
         runs: runs
       } do
    {:ok, session} = Sessions.open(sessions, "s-lifecycle")

    {:ok, script} =
      Agent.start_link(fn -> [{:text, "first run done"}, {:text, "second run done"}] end)

    client = make_client(scope, fn _ -> script end)

    {:ok, run, run_id} =
      AgentRun.start(
        supervisor: runs,
        session: session,
        client: client,
        tools: tools,
        prompt: "hello"
      )

    assert AgentRun.run_id(run) == run_id
    assert {:ok, "first run done"} = AgentRun.await(run)

    assert %{status: :completed, run_id: ^run_id, outcome: {:ok, "first run done"}} =
             AgentRun.status(run)

    # Calling cancel after completion is a no-op and never writes a second terminal event.
    assert {:ok, :completed} = AgentRun.cancel(run, "late cancel")

    events = Session.events(session)
    types = Enum.map(events, & &1.type)

    assert types == [
             :"user/message",
             :"run/start",
             :"turn/start",
             :"step/start",
             :"assistant/message",
             :"turn/end",
             :"run/completed"
           ]

    terminal_events =
      Enum.filter(events, &(&1.type in [:"run/completed", :"run/failed", :"run/cancelled"]))

    assert length(terminal_events) == 1
    assert hd(terminal_events).data["runId"] == run_id

    # Once settled, the session has no active run and can start a new run.
    assert :error = AgentRunSupervisor.active_for_session(runs, "s-lifecycle")

    {:ok, run2, run2_id} =
      AgentRun.start(
        supervisor: runs,
        session: session,
        client: client,
        tools: tools,
        prompt: "follow up"
      )

    assert run2_id != run_id
    assert {:ok, "second run done"} = AgentRun.await(run2)
  end

  test "a settled run stops, and its outcome stays readable through the handle", %{
    scope: scope,
    sessions: sessions,
    tools: tools,
    runs: runs
  } do
    {:ok, session} = Sessions.open(sessions, "s-leaf")

    {:ok, script} = Agent.start_link(fn -> [{:text, "only run"}] end)
    client = make_client(scope, fn _ -> script end)

    {:ok, run, run_id} =
      AgentRun.start(
        supervisor: runs,
        session: session,
        client: client,
        tools: tools,
        prompt: "hello"
      )

    ref = Process.monitor(run)

    assert {:ok, "only run"} = AgentRun.await(run)
    assert_receive {:DOWN, ^ref, :process, ^run, :normal}, 1_000
    refute Process.alive?(run)

    # A finished run must not leave a process, an ETS table or a registry
    # entry behind per turn; the handle still answers from the cached outcome.
    assert {:ok, "only run"} = AgentRun.await(run)
    assert AgentRun.run_id(run) == run_id

    assert %{status: :completed, run_id: ^run_id, outcome: {:ok, "only run"}} =
             AgentRun.status(run)

    assert {:ok, :completed} = AgentRun.cancel(run, "late cancel")
    assert {:error, %{type: :not_running}} = AgentRun.steer(run, "too late")

    # The run-id handle resolves the same way once the registry entry is gone.
    assert :error = AgentRunSupervisor.lookup(runs, run_id)
    assert {:ok, "only run"} = AgentRun.await(run_id)
  end

  test "a settled run's cached outcome never outlives the process silently", %{
    scope: scope,
    sessions: sessions,
    tools: tools,
    runs: runs
  } do
    {:ok, session} = Sessions.open(sessions, "s-unknown")

    {:ok, script} = Agent.start_link(fn -> [{:text, "done"}] end)

    {:ok, run, _run_id} =
      AgentRun.start(
        supervisor: runs,
        session: session,
        client: make_client(scope, fn _ -> script end),
        tools: tools,
        prompt: "hello"
      )

    assert {:ok, "done"} = AgentRun.await(run)

    # A run id that was never started is an error, not a fabricated answer.
    assert_raise ArgumentError, fn -> AgentRun.await("run_never_started") end
  end

  test "parallel runs on a shared scope retain isolated session_id, run_id, and tool_call_id across events",
       %{
         ctx: ctx,
         scope: scope,
         sessions: sessions,
         tools: tools,
         runs: runs
       } do
    test_pid = self()

    {:ok, _} =
      Context.on(ctx, :"llm/request", fn req, next ->
        send(test_pid, {:llm_req_event, req.session_id, req.run_id})
        next.(req)
      end)

    {:ok, _} =
      Context.on(ctx, :"llm/chunk", fn chunk ->
        if chunk.type == :content do
          send(test_pid, {:llm_chunk_event, chunk.session_id, chunk.run_id, chunk.text})
        end
      end)

    {:ok, _} =
      Context.on(ctx, :"tools/pre-execute", fn call, next ->
        send(test_pid, {:tool_pre_event, call.session_id, call.run_id, call.tool_call_id})
        next.(call)
      end)

    {:ok, _} =
      Context.on(ctx, :"tools/post-execute", fn ev ->
        send(test_pid, {:tool_post_event, ev.session_id, ev.run_id, ev.tool_call_id})
      end)

    {:ok, s_a} = Sessions.open(sessions, "alpha")
    {:ok, s_b} = Sessions.open(sessions, "beta")

    {:ok, script_a} =
      Agent.start_link(fn ->
        [
          {:tool_calls, [%{id: "call_a1", name: "inspect_env", arguments: %{"tag" => "A"}}]},
          {:text, "alpha finished"}
        ]
      end)

    {:ok, script_b} =
      Agent.start_link(fn ->
        [
          {:tool_calls, [%{id: "call_b1", name: "inspect_env", arguments: %{"tag" => "B"}}]},
          {:text, "beta finished"}
        ]
      end)

    client_a = make_client(scope, fn _ -> script_a end)
    client_b = make_client(scope, fn _ -> script_b end)

    {:ok, run_a, run_a_id} =
      AgentRun.start(
        supervisor: runs,
        session: s_a,
        client: client_a,
        tools: tools,
        run_id: "run_alpha",
        prompt: "go alpha"
      )

    {:ok, run_b, run_b_id} =
      AgentRun.start(
        supervisor: runs,
        session: s_b,
        client: client_b,
        tools: tools,
        run_id: "run_beta",
        prompt: "go beta"
      )

    assert {:ok, "alpha finished"} = AgentRun.await(run_a)
    assert {:ok, "beta finished"} = AgentRun.await(run_b)

    assert_received {:tool_env_seen, "A",
                     %{session_id: "alpha", run_id: ^run_a_id, tool_call_id: "call_a1"}}

    assert_received {:tool_env_seen, "B",
                     %{session_id: "beta", run_id: ^run_b_id, tool_call_id: "call_b1"}}

    assert_received {:llm_req_event, "alpha", ^run_a_id}
    assert_received {:llm_req_event, "beta", ^run_b_id}
    assert_received {:llm_chunk_event, "alpha", ^run_a_id, "alpha finished"}
    assert_received {:llm_chunk_event, "beta", ^run_b_id, "beta finished"}
    assert_received {:tool_pre_event, "alpha", ^run_a_id, "call_a1"}
    assert_received {:tool_pre_event, "beta", ^run_b_id, "call_b1"}
    assert_received {:tool_post_event, "alpha", ^run_a_id, "call_a1"}
    assert_received {:tool_post_event, "beta", ^run_b_id, "call_b1"}
  end

  test "cancelling during an active stream invokes ReqLLM stream cancel and settles once as cancelled",
       %{
         scope: scope,
         sessions: sessions,
         tools: tools,
         runs: runs
       } do
    {:ok, session} = Sessions.open(sessions, "s-stream-cancel")
    test_pid = self()
    {:ok, script} = Agent.start_link(fn -> [{:blocking_stream, test_pid}] end)
    client = make_client(scope, fn _ -> script end)

    {:ok, run, run_id} =
      AgentRun.start(
        supervisor: runs,
        session: session,
        client: client,
        tools: tools,
        prompt: "stream forever"
      )

    assert_receive {:stream_in_flight, _pid}, 2_000

    assert {:ok, :cancelled} = AgentRun.cancel(run, "user stopped stream")
    assert_received :req_llm_stream_cancel_called
    assert {:error, {:cancelled, "user stopped stream"}} = AgentRun.await(run)

    # Second cancel does not duplicate run/cancelled.
    assert {:ok, :cancelled} = AgentRun.cancel(run, "second cancel")

    events = Session.events(session)

    cancelled_events = Enum.filter(events, &(&1.type == :"run/cancelled"))
    assert length(cancelled_events) == 1
    assert hd(cancelled_events).data["runId"] == run_id
    assert hd(cancelled_events).data["reason"] == "user stopped stream"
  end

  test "cancelling mid-tool-batch records outcome_unknown for started calls and cancelled for unstarted calls",
       %{
         scope: scope,
         sessions: sessions,
         tools: tools,
         runs: runs
       } do
    {:ok, session} = Sessions.open(sessions, "s-tool-cancel")

    {:ok, script} =
      Agent.start_link(fn ->
        [
          {:tool_calls,
           [
             %{id: "call_started", name: "blocking_tool", arguments: %{"step" => "first"}},
             %{id: "call_unstarted", name: "blocking_tool", arguments: %{"step" => "second"}}
           ]},
          {:text, "never reached"}
        ]
      end)

    client = make_client(scope, fn _ -> script end)

    {:ok, run, run_id} =
      AgentRun.start(
        supervisor: runs,
        session: session,
        client: client,
        tools: tools,
        tool_concurrency: 1,
        prompt: "run two blocking tools"
      )

    # Wait until the first tool call has started while the second is still queued.
    assert_receive {:blocking_tool_started, "first", "call_started", _pid}, 2_000

    # Concurrent active run on the same session is rejected while running.
    assert {:error, {:already_running, ^run}} =
             AgentRun.start(
               supervisor: runs,
               session: session,
               client: client,
               tools: tools,
               prompt: "duplicate"
             )

    assert {:ok, :cancelled} = AgentRun.cancel(run, "stop batch")
    assert {:error, {:cancelled, "stop batch"}} = AgentRun.await(run)
    refute_received {:blocking_tool_started, "second", _, _}

    tool_results =
      session
      |> Session.events()
      |> Enum.filter(&(&1.type == :"tool/result"))

    assert [r_started, r_unstarted] = tool_results

    assert r_started.data["runId"] == run_id
    assert r_started.data["message"]["toolCallId"] == "call_started"
    assert r_started.data["message"]["details"]["error"]["type"] == "outcome_unknown"
    assert r_started.data["message"]["details"]["error"]["state"] == "started"

    assert r_unstarted.data["runId"] == run_id
    assert r_unstarted.data["message"]["toolCallId"] == "call_unstarted"
    assert r_unstarted.data["message"]["details"]["error"]["type"] == "cancelled"
    assert r_unstarted.data["message"]["details"]["error"]["state"] == "not_started"

    # The session remains valid and projectable after mid-batch cancellation.
    messages = Session.messages(session)
    assert Enum.map(messages, & &1.role) == [:user, :assistant, :tool, :tool]
  end

  test "cancelling an active execute tool kills the live OS process tree while ordinary nonzero exit settles normally",
       %{
         scope: scope,
         dir: dir,
         sessions: sessions,
         tools: tools,
         runs: runs
       } do
    # 1. Ordinary nonzero exit is NOT a tool error and settles the run normally.
    {:ok, s_nonzero} = Sessions.open(sessions, "s-nonzero")

    {:ok, script_nonzero} =
      Agent.start_link(fn ->
        [
          {:tool_calls,
           [
             %{
               id: "c_fail",
               name: "execute",
               arguments: %{
                 "runtime" => "elixir_subprocess",
                 "code" => ~s[IO.puts("test failed"); System.halt(1)]
               }
             }
           ]},
          {:text, "handled exit 1"}
        ]
      end)

    {:ok, run_nz, _} =
      AgentRun.start(
        supervisor: runs,
        session: s_nonzero,
        client: make_client(scope, fn _ -> script_nonzero end),
        tools: tools,
        prompt: "run failing command"
      )

    assert {:ok, "handled exit 1"} = AgentRun.await(run_nz)

    [nz_result] =
      s_nonzero
      |> Session.events()
      |> Enum.filter(&(&1.type == :"tool/result"))

    assert nz_result.data["message"]["isError"] == false
    assert hd(nz_result.data["message"]["content"])["text"] =~ "exit status 1"

    # 2. Cancelling a live subprocess kills the OS process.
    {:ok, s_kill} = Sessions.open(sessions, "s-kill-tree")
    pid_file = Path.join(dir, "child_os.pid")

    code = """
    File.write!(#{inspect(pid_file)}, System.pid())
    Process.sleep(60_000)
    """

    {:ok, script_kill} =
      Agent.start_link(fn ->
        [
          {:tool_calls,
           [
             %{
               id: "c_hang",
               name: "execute",
               arguments: %{"runtime" => "elixir_subprocess", "code" => code}
             }
           ]},
          {:text, "unreachable"}
        ]
      end)

    {:ok, run_kill, _} =
      AgentRun.start(
        supervisor: runs,
        session: s_kill,
        client: make_client(scope, fn _ -> script_kill end),
        tools: tools,
        prompt: "spawn long subprocess"
      )

    os_pid =
      eventually(fn ->
        if File.exists?(pid_file) do
          case Integer.parse(String.trim(File.read!(pid_file))) do
            {pid, ""} -> pid
            _ -> nil
          end
        end
      end)

    assert is_integer(os_pid)
    assert os_process_alive?(os_pid)

    assert {:ok, :cancelled} = AgentRun.cancel(run_kill, "kill live subprocess")
    assert {:error, {:cancelled, "kill live subprocess"}} = AgentRun.await(run_kill)

    # Verify the external OS process was terminated by Runner cleanup.
    assert eventually(fn -> if not os_process_alive?(os_pid), do: :dead, else: nil end) == :dead
  end

  defp os_process_alive?(os_pid) when is_integer(os_pid) do
    case :os.type() do
      {:win32, _} ->
        {out, _} =
          System.cmd("tasklist", ["/FI", "PID eq #{os_pid}", "/NH"], stderr_to_stdout: true)

        String.contains?(out, Integer.to_string(os_pid))

      _posix ->
        match?(
          {_, 0},
          System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
        )
    end
  end

  defp make_client(scope, script_for) do
    %Client{
      scope: scope,
      model: "scripted",
      backend: RunBackend,
      opts: [script_for: script_for]
    }
  end

  defp await(ctx, key) do
    eventually(fn ->
      case Context.get(ctx, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end) || raise "#{key} was not bound in time"
  end

  defp eventually(fun, attempts \\ 200)
  defp eventually(_fun, 0), do: nil

  defp eventually(fun, attempts) do
    case fun.() do
      nil ->
        Process.sleep(25)
        eventually(fun, attempts - 1)

      other ->
        other
    end
  end
end

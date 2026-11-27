defmodule Noctilucent.CLI do
  @moduledoc """
  The personal agent's terminal front end: a multi-turn REPL over one session
  log per conversation, composed from a `Noctilucent.Presets` persona.

      mix noctilucent                      # personal persona, default model
      mix noctilucent -p tutor             # pick a persona
      mix noctilucent -p coding -m anthropic:kimi-for-coding
      mix noctilucent -s my-session        # open or resume a session

  Options:

    * `--persona, -p` — `coding` | `personal` | `tutor` (default: `personal`)
    * `--model, -m` — ReqLLM model spec (default: the persona's)
    * `--base-url` — custom provider endpoint (relays, e.g.
      `https://api.kimi.com/coding` for `anthropic:kimi-for-coding`)
    * `--session, -s` — open or resume a session id
    * `--cwd, -c` — the agent's working directory (default: launch cwd)
    * `--home` — persona state home (default: `~/.pcw`)
    * `--help, -h`

  Slash commands while chatting: `/quit` `/cancel` `/steer TEXT` `/reset`
  `/sessions` `/resume ID` `/log` `/grants` `/revoke`.

  Attach images inline with `@path/to/image.png` (png/jpeg/gif/webp, ≤ 5 MB,
  resolved against the working directory); attachments are ignored with a
  notice when the model has no image input, and corrupt or truncated files
  are skipped with a notice.

  The terminal rendering is driven entirely by seam events (`llm/chunk`,
  `tools/post-execute`, `tools/todo`); the REPL itself only appends
  `user/message` events and runs turns.
  """

  alias Noctilucent.{Policy, Presets}
  alias PurpleChonkyWhale.{AgentRun, Memory, Security.Grant, Session, Sessions, Tools}
  alias Dexterous.Context

  @switches [
    persona: :string,
    model: :string,
    base_url: :string,
    session: :string,
    cwd: :string,
    home: :string,
    help: :boolean
  ]
  @aliases [p: :persona, m: :model, s: :session, c: :cwd, h: :help]

  @commands [
    {"/quit, /exit", "end the session"},
    {"/cancel", "cancel the active run"},
    {"/steer TEXT", "inject a steering message into the active run"},
    {"/reset", "start a fresh session log (the old one stays on disk)"},
    {"/sessions", "list saved session ids"},
    {"/resume ID", "switch to (or open) session ID"},
    {"/log", "print the model-visible message count"},
    {"/grants", "list active capability leases"},
    {"/revoke", "revoke all active capability leases"},
    {"/help", "show the commands and options"}
  ]

  ## Entry

  def main(argv) do
    case parse_args(argv) do
      {:ok, %{help: true}} ->
        IO.puts(usage())

      {:error, message} ->
        IO.puts(:stderr, "#{message}\n\n#{usage()}")
        System.halt(2)

      {:ok, config} ->
        run(config)
    end
  end

  @doc false
  def parse_args(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches, aliases: @aliases)

    cond do
      opts[:help] ->
        {:ok, %{help: true}}

      invalid != [] ->
        {:error, "unknown or invalid options: #{inspect(invalid)}"}

      args != [] ->
        {:error, "unexpected arguments: #{Enum.join(args, " ")} (options only)"}

      true ->
        with {:ok, persona} <- parse_persona(opts[:persona]) do
          {:ok,
           %{
             help: false,
             persona: persona,
             model: opts[:model],
             base_url: opts[:base_url],
             session: opts[:session],
             cwd: opts[:cwd],
             home: opts[:home]
           }}
        end
    end
  end

  defp parse_persona(nil), do: {:ok, :personal}

  defp parse_persona(name) do
    case Enum.find(Presets.personas(), &(Atom.to_string(&1) == name)) do
      nil ->
        {:error, "unknown persona: #{name} (choose from: #{Enum.join(Presets.personas(), ", ")})"}

      persona ->
        {:ok, persona}
    end
  end

  defp commands_help do
    Enum.map_join(@commands, "\n", fn {cmd, doc} ->
      "  #{String.pad_trailing(cmd, 14)} #{doc}"
    end)
  end

  defp usage do
    """
    usage: mix noctilucent [options]

    Options:
      --persona, -p NAME   coding | personal | tutor (default: personal)
      --model, -m SPEC     ReqLLM model spec (default: the persona's)
      --base-url URL       custom provider endpoint (relays)
      --session, -s ID     open or resume session ID
      --cwd, -c PATH       working directory (default: current)
      --home PATH          persona state home (default: ~/.pcw)
      --help, -h           show this help

    Commands while chatting:
    #{commands_help()}
    """
  end

  ## Run

  defp run(config) do
    launch_cwd = File.cwd!()
    cwd = Path.expand(config.cwd || launch_cwd, launch_cwd)

    unless File.dir?(cwd) do
      IO.puts(:stderr, "working directory does not exist or is not a directory: #{cwd}")
      System.halt(2)
    end

    ctx = Dexterous.root()
    subscribe_renderers(ctx)
    repl = self()

    entries_opts =
      [
        cwd: cwd,
        llm_opts: if_set(:base_url, config.base_url),
        policy_opts: [ask: &request_approval(repl, &1)]
      ] ++
        if_set(:home, config.home) ++
        if_set(:model, config.model)

    {:ok, loader} =
      DexterousLoader.start_link(ctx, Presets.entries(config.persona, entries_opts))

    # The coding persona's tool set includes recompile, which needs the HMR
    # loop with this composition's loader registered.
    if config.persona == :coding do
      {:ok, _} = DexterousHMR.start_link()
      :ok = DexterousHMR.register(loader)
    end

    llm = await(ctx, :llm)
    sessions = await(ctx, :sessions)
    tools = await(ctx, :tools)
    memory = await(ctx, :memory)
    policy = await(ctx, :policy)

    system = Presets.system_prompt(config.persona, cwd: cwd) <> skill_section(tools)

    {session_id, session} =
      case open_session(sessions, config.session || fresh_id(config.persona), system, memory, cwd) do
        {:ok, opened} ->
          opened

        {:error, reason} ->
          IO.puts(:stderr, "cannot open session: #{describe_open_error(reason)}")
          System.halt(3)
      end

    IO.puts([
      "persona: #{config.persona}\n",
      "session: #{session_id}\n",
      "cwd: #{cwd}\n",
      "type /quit to leave; /help for commands; /cancel to stop a run; /steer TEXT to steer one\n",
      "---"
    ])

    spawn_stdin_reader()

    loop(%{
      session_id: session_id,
      session: session,
      sessions: sessions,
      system: system,
      llm: llm,
      tools: tools,
      policy: policy,
      persona: config.persona,
      cwd: cwd,
      vision?: tools.env[:vision?] != false,
      memory: memory
    })
  end

  @doc false
  def build_prompt(message, cwd, vision? \\ true) do
    tokens =
      Regex.scan(~r/@(\S+)/, message)
      |> Enum.map(fn [_full, token] -> Regex.replace(~r/[?!.,;:'"\)\]\}]+$/, token, "") end)
      |> Enum.uniq()

    image_tokens =
      Enum.filter(tokens, fn token ->
        match?({:ok, _}, PurpleChonkyWhale.Tools.Read.image_media_type(token))
      end)

    cond do
      image_tokens == [] ->
        {message, [], []}

      not vision? ->
        {message, [], ["image attachments ignored: the current model has no image input"]}

      true ->
        {parts, notices} =
          Enum.reduce(image_tokens, {[], []}, fn token, {parts, notices} ->
            case attach_image(token, cwd) do
              {:ok, part, notice} -> {parts ++ [part], [notice | notices]}
              {:skip, notice} -> {parts, [notice | notices]}
              :not_an_image -> {parts, notices}
            end
          end)

        {message, parts, Enum.reverse(notices)}
    end
  end

  defp attach_image(token, cwd) do
    path = Path.expand(token, cwd)

    with {:ok, media_type} <- PurpleChonkyWhale.Tools.Read.image_media_type(path),
         {:ok, %{size: size}} <- File.stat(path),
         :ok <- check_attach_size(token, size),
         {:ok, data} <- File.read(path),
         :ok <- check_attach_valid(token, data, media_type) do
      {:ok, PurpleChonkyWhale.ToolResult.image_part(data, media_type),
       "attached @#{token} (#{media_type}, #{size} bytes)"}
    else
      :error -> :not_an_image
      {:error, _} -> :not_an_image
      {:skip, notice} -> {:skip, notice}
    end
  end

  # A corrupt or truncated image must never enter the session log: it rides
  # along on every later request, and one bad image makes the provider reject
  # the whole payload. Same policy as the read tool.
  defp check_attach_valid(token, data, media_type) do
    if PurpleChonkyWhale.Tools.Read.valid_image_data?(data, media_type) do
      :ok
    else
      {:skip, "skipped @#{token}: corrupt or truncated image (not a complete #{media_type} file)"}
    end
  end

  defp check_attach_size(token, size) do
    limit = PurpleChonkyWhale.Tools.Read.max_image_bytes()

    if size > limit do
      {:skip, "skipped @#{token}: over the #{div(limit, 1_048_576)} MB image limit"}
    else
      :ok
    end
  end

  defp if_set(_key, nil), do: []
  defp if_set(key, value), do: [{key, value}]

  defp fresh_id(persona),
    do: "#{persona}-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

  defp await(ctx, key) do
    Enum.reduce_while(1..100, nil, fn _, _ ->
      case Context.get(ctx, key) do
        {:ok, value} -> {:halt, value}
        :error -> {:cont, Process.sleep(10)}
      end
    end) || raise "#{key} was not bound in time"
  end

  defp skill_section(tools) do
    Tools.Skill.prompt_section(tools.env)
  end

  # A fresh session is seeded with the persona's system prompt plus the
  # recalled memory as a second system message — recalled memory is
  # model-visible, therefore it must be logged. Resumed sessions keep their
  # log untouched (their recall happened when they were created).
  #
  # A log that cannot be opened (an unsupported format, or a corrupt file
  # that could not be moved aside) comes back as `{:error, reason}`: the REPL
  # shows it instead of crashing — the session log is the one thing a long
  # conversation cannot afford to take down.
  defp open_session(sessions, id, system, memory, cwd) do
    # `cwd` only lands in the header of a fresh log; it records the working
    # directory the session was opened for, which is not necessarily the
    # store process's own cwd (the CLI's `-c`).
    with {:ok, session} <- Sessions.open(sessions, id, cwd: cwd) do
      {:ok, _} = Session.seal_unsettled(session)

      if Session.events(session) == [] do
        {:ok, _} = Session.append(session, :"system/message", %{"content" => system})

        case Memory.recall(memory) do
          "" ->
            :ok

          recalled ->
            {:ok, _} =
              Session.append(session, :"system/message", %{
                "content" => "Recalled long-term memory:\n\n" <> recalled
              })
        end
      end

      {:ok, {id, session}}
    end
  end

  defp describe_open_error({:corrupt_session_log, path, line}) do
    "session log #{path} is corrupt (line #{line}) and could not be moved aside"
  end

  defp describe_open_error({:unsupported_session_format, version}) do
    "unsupported session log format version: #{inspect(version)}"
  end

  defp describe_open_error({:session_unreadable, path, reason}) do
    "cannot read #{path}: #{:file.format_error(reason)}"
  end

  defp describe_open_error(other), do: inspect(other)

  ## Rendering (driven by seam events, not by the REPL)

  defp subscribe_renderers(ctx) do
    {:ok, _} =
      Context.on(ctx, :"llm/chunk", fn chunk ->
        case chunk.type do
          :content -> IO.write(chunk.text)
          :thinking -> IO.write(IO.ANSI.faint() <> chunk.text <> IO.ANSI.reset())
          _ -> :ok
        end
      end)

    {:ok, _} =
      Context.on(ctx, :"tools/post-execute", fn %{name: name, result: result, duration_ms: ms} ->
        status =
          case result do
            {:ok, {:parts, parts}} -> "ok, parts: #{inspect(Enum.map(parts, & &1["type"]))}"
            {:ok, _} -> "ok"
            {:error, error} -> "error: #{inspect(error)}"
          end

        IO.puts("\n[tool #{name}] #{status} (#{ms}ms)")
      end)

    {:ok, _} =
      Context.on(ctx, :"memory/remember", fn %{layer: layer} ->
        IO.puts("\n[memory → #{layer}]")
      end)

    {:ok, _} =
      Context.on(ctx, :"memory/update", fn %{layer: layer, updated: count} ->
        IO.puts("\n[memory → #{layer}: #{count} updated]")
      end)

    {:ok, _} =
      Context.on(ctx, :"memory/delete", fn %{layer: layer, deleted: count} ->
        IO.puts("\n[memory → #{layer}: #{count} deleted]")
      end)

    {:ok, _} =
      Context.on(ctx, :"tools/todo", fn %{todos: todos} ->
        IO.puts("\n[todos]")

        Enum.each(todos, fn %{content: content, status: status} ->
          marker =
            case status do
              "completed" -> IO.ANSI.green() <> "[x]" <> IO.ANSI.reset()
              "in_progress" -> IO.ANSI.yellow() <> "[>]" <> IO.ANSI.reset()
              _ -> IO.ANSI.faint() <> "[ ]" <> IO.ANSI.reset()
            end

          IO.puts("  #{marker} #{content}")
        end)
      end)
  end

  ## The REPL

  # A dedicated stdin reader so /cancel and /steer work while a run is active.
  defp spawn_stdin_reader do
    repl = self()

    spawn_link(fn ->
      read = fn read ->
        case IO.gets("\n> ") do
          :eof ->
            send(repl, :stdin_eof)

          {:error, _} ->
            send(repl, :stdin_eof)

          line ->
            send(repl, {:stdin_line, String.trim(line)})
            read.(read)
        end
      end

      read.(read)
    end)
  end

  defp loop(state, queue \\ [], eof? \\ false) do
    case next_line(queue, eof?) do
      :eof ->
        IO.puts("\n(input closed — bye)")

      {:line, "", rest, eof?} ->
        loop(state, rest, eof?)

      {:line, cmd, _rest, _eof?} when cmd in ["/quit", "/exit"] ->
        IO.puts("bye (session: #{state.session_id})")

      {:line, "/cancel", rest, eof?} ->
        IO.puts("[no active run to cancel]")
        loop(state, rest, eof?)

      {:line, "/reset", rest, eof?} ->
        case open_session(
               state.sessions,
               fresh_id(state.persona),
               state.system,
               state.memory,
               state.cwd
             ) do
          {:ok, {id, session}} ->
            IO.puts("[reset — switched to fresh session #{id}]")
            loop(%{state | session_id: id, session: session}, rest, eof?)

          {:error, reason} ->
            IO.puts("[cannot reset: #{describe_open_error(reason)}]")
            loop(state, rest, eof?)
        end

      {:line, "/help", rest, eof?} ->
        IO.puts("commands:\n" <> commands_help())
        loop(state, rest, eof?)

      {:line, "/sessions", rest, eof?} ->
        ids = state.sessions |> Sessions.list() |> Enum.sort()
        IO.puts("[saved sessions (#{length(ids)}): #{Enum.join(ids, ", ")}]")
        loop(state, rest, eof?)

      {:line, "/resume " <> target, rest, eof?} ->
        case String.trim(target) do
          "" ->
            IO.puts("[usage: /resume SESSION_ID]")
            loop(state, rest, eof?)

          target ->
            case open_session(state.sessions, target, state.system, state.memory, state.cwd) do
              {:ok, {id, session}} ->
                count = length(Session.messages(session))
                IO.puts("[resumed session #{id} (#{count} model-visible messages)]")
                loop(%{state | session_id: id, session: session}, rest, eof?)

              {:error, reason} ->
                IO.puts("[cannot open session #{target}: #{describe_open_error(reason)}]")
                loop(state, rest, eof?)
            end
        end

      {:line, "/log", rest, eof?} ->
        count = length(Session.messages(state.session))
        IO.puts("[session #{state.session_id}: #{count} model-visible messages so far]")
        loop(state, rest, eof?)

      {:line, "/grants", rest, eof?} ->
        state.policy |> Policy.leases() |> format_leases() |> IO.puts()
        loop(state, rest, eof?)

      {:line, "/revoke", rest, eof?} ->
        :ok = Policy.revoke_all(state.policy)
        IO.puts("[revoked all active capability leases]")
        loop(state, rest, eof?)

      {:line, "/" <> _unknown = cmd, rest, eof?} ->
        IO.puts("[unknown command #{cmd} — #{Enum.map_join(@commands, ", ", &elem(&1, 0))}]")
        loop(state, rest, eof?)

      {:line, message, rest, eof?} ->
        {queue, eof?} = run_turn(state, message, Enum.reverse(rest), eof?)
        loop(state, queue, eof?)
    end
  end

  defp next_line([head | rest], eof?), do: {:line, head, rest, eof?}
  defp next_line([], true), do: :eof

  defp next_line([], false) do
    receive do
      {:stdin_line, line} -> {:line, line, [], false}
      :stdin_eof -> :eof
    end
  end

  defp run_turn(state, message, pending, eof?) do
    {text, parts, notices} = build_prompt(message, state.cwd, state.vision?)
    Enum.each(notices, &IO.puts("[#{&1}]"))

    {:ok, run_pid, run_id} =
      AgentRun.start(
        session: state.session,
        session_id: state.session_id,
        client: state.llm,
        tools: state.tools,
        prompt: text,
        parts: parts
      )

    repl = self()
    Task.start(fn -> send(repl, {:run_finished, run_id, AgentRun.await(run_pid)}) end)

    await_run(run_pid, run_id, pending, eof?)
  end

  defp await_run(run_pid, run_id, pending, eof?) do
    receive do
      {:run_finished, ^run_id, outcome} ->
        print_run_outcome(run_id, outcome)
        {Enum.reverse(pending), eof?}

      {:approval_request, ref, requester, request} ->
        if eof? do
          send(requester, {:approval_reply, ref, :deny})
          await_run(run_pid, run_id, pending, eof?)
        else
          IO.puts("\n" <> format_approval_prompt(request))
          await_approval_reply(run_pid, run_id, ref, requester, request, pending, eof?)
        end

      {:stdin_line, "/cancel"} ->
        IO.puts("\n[cancelling #{run_id}...]")
        Task.start(fn -> AgentRun.cancel(run_pid, "cancelled by user") end)
        await_run(run_pid, run_id, pending, eof?)

      {:stdin_line, "/steer " <> text} ->
        case String.trim(text) do
          "" ->
            :ok

          text ->
            case AgentRun.steer(run_pid, text) do
              {:ok, _} ->
                IO.puts("\n[steered into #{run_id}]")

              {:error, _reason} ->
                IO.puts("\n[#{run_id} has already finished — nothing to steer]")
            end
        end

        await_run(run_pid, run_id, pending, eof?)

      {:stdin_line, ""} ->
        await_run(run_pid, run_id, pending, eof?)

      {:stdin_line, other} ->
        await_run(run_pid, run_id, [other | pending], eof?)

      :stdin_eof ->
        await_run(run_pid, run_id, pending, true)
    end
  end

  defp await_approval_reply(run_pid, run_id, ref, requester, request, pending, eof?) do
    receive do
      {:run_finished, ^run_id, outcome} ->
        send(requester, {:approval_reply, ref, :deny})
        print_run_outcome(run_id, outcome)
        {Enum.reverse(pending), eof?}

      {:stdin_line, "/cancel"} ->
        send(requester, {:approval_reply, ref, :deny})
        IO.puts("\n[cancelling #{run_id}...]")
        Task.start(fn -> AgentRun.cancel(run_pid, "cancelled by user") end)
        await_run(run_pid, run_id, pending, eof?)

      {:stdin_line, line} ->
        choice = parse_approval_choice(line, request)
        send(requester, {:approval_reply, ref, choice})
        await_run(run_pid, run_id, pending, eof?)

      :stdin_eof ->
        send(requester, {:approval_reply, ref, :deny})
        await_run(run_pid, run_id, pending, true)
    end
  end

  defp print_run_outcome(run_id, outcome) do
    case outcome do
      {:ok, _text} -> IO.puts("\n== turn complete (#{run_id}) ==")
      {:error, {:cancelled, reason}} -> IO.puts("\n== turn cancelled: #{inspect(reason)} ==")
      {:error, error} -> IO.puts("\n== turn failed: #{inspect(error)} ==")
    end
  end

  defp request_approval(repl, request) do
    ref = make_ref()
    mon = Process.monitor(repl)
    send(repl, {:approval_request, ref, self(), request})

    receive do
      {:approval_reply, ^ref, choice} ->
        Process.demonitor(mon, [:flush])
        choice

      {:DOWN, ^mon, :process, ^repl, _reason} ->
        :deny
    end
  end

  @doc false
  def parse_approval_choice(line, request) when is_binary(line) and is_map(request) do
    leaseable = Map.get(request, :leaseable_capabilities, [])
    default_ttl = Map.get(request, :default_lease_ms, 15 * 60_000)

    case line |> String.trim() |> String.downcase() do
      choice when choice in ["y", "yes", "once"] ->
        :once

      choice when choice in ["l", "lease"] and leaseable != [] ->
        {:lease, default_ttl}

      _other ->
        :deny
    end
  end

  @doc false
  def format_approval_prompt(request) when is_map(request) do
    caps = request |> Map.get(:capabilities, []) |> Enum.map_join(", ", &to_string/1)
    warnings = Map.get(request, :warnings, [])
    leaseable = Map.get(request, :leaseable_capabilities, [])
    ttl_min = max(1, div(Map.get(request, :default_lease_ms, 15 * 60_000), 60_000))

    warning_lines =
      case warnings do
        [] -> []
        list -> Enum.map(list, &"  ! warning: #{&1}")
      end

    options =
      case leaseable do
        [] ->
          "  [y] allow once  /  [n] deny (default: deny)"

        caps_list ->
          cap_label = Enum.map_join(caps_list, "+", &to_string/1)

          "  [y] allow once  /  [l] lease #{cap_label} for #{ttl_min}m  /  [n] deny (default: deny)"
      end

    ([
       "[approval required] #{Map.get(request, :summary, request[:tool])}",
       "  tool: #{request[:tool]}  capabilities: [#{caps}]"
     ] ++ warning_lines ++ [options])
    |> Enum.join("\n")
  end

  @doc false
  def format_leases([]), do: "[active leases: none]"

  def format_leases(leases) when is_list(leases) do
    now_ms = System.monotonic_time(:millisecond)

    lines =
      Enum.map(leases, fn %Grant{} = grant ->
        caps = grant.capabilities |> Enum.sort() |> Enum.map_join(", ", &to_string/1)

        ttl =
          case Grant.remaining_ms(grant, now_ms) do
            nil -> "no expiry"
            ms -> "#{div(ms + 999, 1000)}s left"
          end

        "  - [#{caps}] (#{ttl}) #{grant.reason}"
      end)

    Enum.join(["[active leases (#{length(leases)})]" | lines], "\n")
  end
end

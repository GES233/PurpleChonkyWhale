defmodule PurpleChonkyWhale.MCP do
  @default_timeout 15_000

  @moduledoc """
  MCP (Model Context Protocol) servers as a source of tools.

  An MCP server is just another place tools come from: this module connects
  to the servers declared in a composition's `:mcp_servers` config (via
  [Anubis](https://github.com/zoedsoupe/anubis-mcp)), performs the handshake,
  lists each server's tools and turns every one of them into an ordinary
  `PurpleChonkyWhale.Tool` module that `PurpleChonkyWhale.Tools` registers
  like any built-in. MCP tools therefore ride the same
  `tools/pre-execute` / `tools/post-execute` pipeline — approval policy hooks
  cover them for free.

  Server config is plain data:

      %{
        name: :ableton,
        transport: {:stdio, command: "uv", args: ["run", "mcp_ableton_server.py"]},
        # optional:
        client_info: %{"name" => "my_app", "version" => "1.0.0"},
        timeout: 15_000
      }

  `:transport` is whatever `Anubis.Client` accepts (`{:stdio, opts}` or
  `{:streamable_http, opts}`); see `examples/mcp_kimi_docs.exs` for a live
  streamable-HTTP server. `:timeout` (default #{@default_timeout} ms) bounds
  the handshake, the `tools/list` listing and every `tools/call`.

  The streamable HTTP transport runs through a Finch pool that Anubis expects
  the caller to own ("you must start this pool yourself"): a composition with
  at least one `{:streamable_http, opts}` server gets one pool, supervised
  next to the clients under the same supervisor. A transport config that
  names its own `:finch_name` is used as given, and stdio-only compositions
  start no pool at all.

  ## Fail-open per server

  A server that refuses to start, answer the handshake or list its tools is
  dropped with a `Logger.warning`; its tools are simply absent from the
  catalog and the remaining servers are unaffected. MCP servers are external
  processes outside the harness's control — the ableton server, say, cannot
  even boot when Ableton Live is not running — so a dead server must never
  take the persona down with it. The supervision tree mirrors that: clients
  run as `:temporary` children, so a crash-looping server cannot exhaust the
  supervisor's restart intensity and kill its healthy siblings.

  ## Naming

  A server tool `foo.bar/baz` on server `:ableton` becomes
  `mcp_ableton_foo_bar_baz`: every character outside `[a-zA-Z0-9_]` is
  replaced by `_` (MCP tool names may contain `.`/`/` — or CJK characters,
  as the Kimi docs server does — while providers may not), runs of `_`
  collapse and a trailing `_` is trimmed. When two entries collide, later
  ones gain a short hash suffix and a warning is logged. The description is
  prefixed with `[<server>]` so the model can tell where a tool lives;
  `inputSchema` is passed through verbatim as the tool's `parameters` (it
  already is JSON Schema).

  ## Generated modules

  `tool_modules/1` `Module.create/3`s one real `PurpleChonkyWhale.Tool`
  implementation per catalog entry: the schema is a burnt-in literal and
  `execute/2` dispatches through the registry, so the modules are
  self-contained and depend on nothing in the execution env. This creates
  atoms at runtime — one module per composition × server × tool — which is
  bounded by the composition's config, the same way the tool list itself is.
  Do not call `tool_modules/1` with unbounded input.

  ## The `:backend` option

  `start_link/2` accepts `:backend` (default `Anubis.Client`), the module
  performing the client operations — it must implement `child_spec/1`,
  `await_ready/2`, `list_tools/2` and `call_tool/4` with `Anubis.Client`'s
  contract. Tests swap in a fake, mirroring `PurpleChonkyWhale.LLM`'s
  `:backend`.
  """

  require Logger

  alias Anubis.MCP.Response
  alias PurpleChonkyWhale.ToolResult

  @default_backend Anubis.Client
  @default_client_info %{"name" => "purple_chonky_whale"}

  @typedoc "One MCP server declaration (see the module doc)."
  @type server :: %{
          required(:name) => atom(),
          required(:transport) => tuple(),
          optional(:client_info) => map(),
          optional(:timeout) => non_neg_integer()
        }

  @typedoc "One catalog entry: where the tool lives and how it is presented."
  @type catalog_entry :: %{
          server: atom(),
          tool: String.t(),
          timeout: non_neg_integer(),
          schema: PurpleChonkyWhale.Tool.schema()
        }

  @typedoc "The MCP handle, kept on the `PurpleChonkyWhale.Tools` struct for debugging."
  @type t :: %__MODULE__{
          sup: pid(),
          registry: atom(),
          finch: atom() | nil,
          catalog: %{String.t() => catalog_entry()}
        }

  defstruct [:sup, :registry, :finch, :catalog]

  @doc """
  Start the clients for `servers` and return the handle with the flattened
  tool catalog. Options: `:backend` (see the module doc).

  The supervisor and registry are linked to the caller; a component adopting
  them should `Process.unlink/1` both and bind their lifetime with
  `Dexterous.Context.track/2` (as `PurpleChonkyWhale.Tools` does).
  """
  @spec start_link([server()], keyword()) :: {:ok, t()}
  def start_link(servers, opts \\ []) when is_list(servers) do
    backend = Keyword.get(opts, :backend, @default_backend)

    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
    registry = :"pcw_mcp_registry_#{System.unique_integer([:positive])}"
    {:ok, _registry_pid} = Registry.start_link(keys: :unique, name: registry)

    finch = maybe_start_finch(sup, registry, servers)

    catalog =
      servers
      |> Enum.flat_map(fn server ->
        case connect(sup, registry, server, backend, finch) do
          {:ok, entries} -> entries
          :error -> []
        end
      end)
      |> Enum.reduce(%{}, &put_entry/2)

    {:ok, %__MODULE__{sup: sup, registry: registry, finch: finch, catalog: catalog}}
  end

  @doc """
  Generate one `PurpleChonkyWhale.Tool` module per catalog entry, returned as
  a `%{name => module}` map ready to merge into the `Tools` registry. See the
  module doc for the bounded-atom caveat.
  """
  @spec tool_modules(t(), keyword()) :: %{String.t() => module()}
  def tool_modules(%__MODULE__{} = mcp, opts \\ []) do
    backend = Keyword.get(opts, :backend, @default_backend)

    Map.new(mcp.catalog, fn {name, entry} ->
      {name, define_tool_module(mcp, name, entry, backend)}
    end)
  end

  @doc """
  Call the MCP tool `tool` on the server registered as `server` under
  `registry`. Options: `:backend` and `:timeout`.

  Maps the MCP result onto the tool contract: text content becomes a plain
  string (multiple parts joined), any image content makes it
  `{:ok, {:parts, parts}}` (via `ToolResult.text_part/1` /
  `ToolResult.image_part/2`, so the images ride the session log's blob
  externalization), and MCP-level errors, protocol errors and missing clients
  all become `{:error, %{type: :mcp, message: _}}`. Never raises — tools
  never raise into the pipeline.
  """
  @spec call(atom(), atom(), String.t(), map(), keyword()) ::
          {:ok, term()} | {:error, map()}
  def call(registry, server, tool, args, opts \\ []) do
    backend = Keyword.get(opts, :backend, @default_backend)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case Registry.lookup(registry, server) do
      [{client, _value}] ->
        backend
        |> safe_call_tool(client, tool, args, timeout)
        |> map_call_result()

      [] ->
        {:error,
         %{type: :mcp, message: "MCP server #{inspect(server)} is not connected (anymore)"}}
    end
  end

  ## Connecting

  defp connect(sup, registry, %{name: name} = server, backend, finch) do
    via = {:via, Registry, {registry, name}}
    timeout = Map.get(server, :timeout, @default_timeout)

    client_opts = [
      name: via,
      transport_name: {:via, Registry, {registry, {name, :transport}}},
      transport: server |> Map.fetch!(:transport) |> inject_finch(finch),
      client_info: Map.get(server, :client_info, @default_client_info),
      capabilities: %{}
    ]

    # :temporary so a crash-looping server can never exhaust the supervisor's
    # intensity and take the healthy clients down with it (fail-open).
    spec = client_opts |> backend.child_spec() |> Supervisor.child_spec(restart: :temporary)

    with {:ok, _pid} <- start_child(sup, spec),
         :ok <- ready(backend, via, timeout),
         {:ok, tools} <- fetch_tools(backend, via, timeout) do
      {:ok, Enum.map(tools, &catalog_entry(name, &1, timeout))}
    else
      {:error, reason} ->
        Logger.warning(
          "MCP server #{inspect(name)} is unavailable (#{format_reason(reason)}); " <>
            "its tools will be absent"
        )

        # A started-but-unusable client (handshake or listing failed) is
        # useless; stop it instead of leaving a dangling subprocess.
        case Registry.lookup(registry, name) do
          [{pid, _value}] -> DynamicSupervisor.terminate_child(sup, pid)
          [] -> :ok
        end

        :error
    end
  end

  # The streamable HTTP transport talks through a Finch pool that Anubis
  # expects the caller to provide ("you must start this pool yourself"). One
  # composition-scoped pool covers every HTTP server of the composition;
  # stdio-only compositions get none. A transport that names its own
  # `:finch_name` is left alone.
  defp maybe_start_finch(sup, registry, servers) do
    if Enum.any?(servers, &needs_finch?/1) do
      name = :"#{registry}_finch"
      {:ok, _pid} = DynamicSupervisor.start_child(sup, {Finch, name: name})
      name
    end
  end

  defp needs_finch?(%{transport: {:streamable_http, opts}}) when is_list(opts),
    do: not Keyword.has_key?(opts, :finch_name)

  defp needs_finch?(_server), do: false

  defp inject_finch({:streamable_http, opts}, finch)
       when is_list(opts) and is_atom(finch) and not is_nil(finch) do
    if Keyword.has_key?(opts, :finch_name) do
      {:streamable_http, opts}
    else
      {:streamable_http, Keyword.put(opts, :finch_name, finch)}
    end
  end

  defp inject_finch(transport, _finch), do: transport

  defp start_child(sup, spec) do
    DynamicSupervisor.start_child(sup, spec)
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, reason}
  end

  defp ready(backend, client, timeout) do
    backend.await_ready(client, timeout: timeout)
  catch
    :exit, reason -> {:error, reason}
  end

  defp fetch_tools(backend, client, timeout) do
    fetch_tools(backend, client, timeout, nil, [])
  end

  defp fetch_tools(backend, client, timeout, cursor, acc) do
    opts = if cursor, do: [timeout: timeout, cursor: cursor], else: [timeout: timeout]

    case backend.list_tools(client, opts) do
      {:ok, response} ->
        result = Response.get_result(response)
        tools = acc ++ Map.get(result, "tools", [])

        case Map.get(result, "nextCursor") do
          nil -> {:ok, tools}
          next -> fetch_tools(backend, client, timeout, next, tools)
        end

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp catalog_entry(server_name, tool, timeout) do
    tool_name = Map.get(tool, "name", "")
    harness_name = harness_name(server_name, tool_name)
    description = Map.get(tool, "description") || "MCP tool #{tool_name}"

    schema = %{
      name: harness_name,
      description: "[#{server_name}] #{description}",
      parameters: Map.get(tool, "inputSchema") || %{"type" => "object", "properties" => %{}}
    }

    {harness_name, %{server: server_name, tool: tool_name, timeout: timeout, schema: schema}}
  end

  defp harness_name(server_name, tool_name) do
    sanitize("mcp_#{server_name}_#{tool_name}")
  end

  defp sanitize(name) do
    name
    |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
    |> String.replace(~r/_+/, "_")
    |> String.trim_trailing("_")
  end

  # Later entries colliding with an already-catalogued name gain a short hash
  # suffix; nothing is silently overwritten.
  defp put_entry({name, entry}, catalog) do
    if Map.has_key?(catalog, name) do
      renamed = "#{name}_#{short_hash("#{entry.server}:#{entry.tool}")}"

      Logger.warning(
        "MCP tool name #{name} is taken; " <>
          "registering #{entry.server}:#{entry.tool} as #{renamed}"
      )

      Map.put(catalog, renamed, %{entry | schema: %{entry.schema | name: renamed}})
    else
      Map.put(catalog, name, entry)
    end
  end

  defp short_hash(subject) do
    :crypto.hash(:md5, subject) |> Base.encode16(case: :lower) |> binary_part(0, 8)
  end

  ## Generated tool modules

  defp define_tool_module(mcp, name, entry, backend) do
    unique = System.unique_integer([:positive])
    module = Module.concat(PurpleChonkyWhale.MCP.Tool, "#{Macro.camelize(name)}#{unique}")

    call_opts = [backend: backend, timeout: entry.timeout]

    contents =
      quote do
        @moduledoc false
        @behaviour PurpleChonkyWhale.Tool

        @impl true
        def capabilities, do: [:mcp]

        @impl true
        def schema, do: unquote(Macro.escape(entry.schema))

        @impl true
        def execute(args, _env) do
          PurpleChonkyWhale.MCP.call(
            unquote(mcp.registry),
            unquote(entry.server),
            unquote(entry.tool),
            args,
            unquote(call_opts)
          )
        end
      end

    {:module, module, _binary, _term} =
      Module.create(module, contents, Macro.Env.location(__ENV__))

    module
  end

  ## Result mapping

  defp safe_call_tool(backend, client, tool, args, timeout) do
    backend.call_tool(client, tool, args, timeout: timeout)
  rescue
    exception -> {:exit, exception}
  catch
    :exit, reason -> {:exit, reason}
  end

  defp map_call_result({:ok, %Response{} = response}) do
    result = Response.get_result(response)
    content = Map.get(result, "content") || []

    if Response.error?(response) do
      {:error, %{type: :mcp, message: error_text(content)}}
    else
      {:ok, map_content(content)}
    end
  end

  defp map_call_result({:error, reason}) do
    {:error, %{type: :mcp, message: "MCP call failed: #{format_reason(reason)}"}}
  end

  defp map_call_result({:exit, reason}) do
    {:error, %{type: :mcp, message: "MCP call exited: #{format_reason(reason)}"}}
  end

  # All-text output collapses to one plain string; any image upgrades the
  # whole result to multi-part so the binary rides ToolResult's blob
  # externalization instead of being base64'd into the session log.
  defp map_content(content) do
    parts = Enum.flat_map(content, &content_parts/1)

    if Enum.any?(parts, &(&1["type"] == "image")) do
      {:parts, parts}
    else
      parts |> Enum.map(& &1["text"]) |> Enum.join("\n")
    end
  end

  defp content_parts(%{"type" => "text", "text" => text}) when is_binary(text) do
    [ToolResult.text_part(text)]
  end

  defp content_parts(%{"type" => "image", "data" => data} = part) when is_binary(data) do
    case Base.decode64(data) do
      {:ok, binary} ->
        [ToolResult.image_part(binary, Map.get(part, "mimeType") || "image/png")]

      :error ->
        [ToolResult.text_part("[undecodable MCP image content]")]
    end
  end

  defp content_parts(_other), do: []

  defp error_text(content) do
    texts =
      for %{"type" => "text", "text" => text} <- content, is_binary(text), do: text

    case texts do
      [] -> "MCP tool reported an error"
      _ -> Enum.join(texts, "\n")
    end
  end

  defp format_reason(%{message: message}) when is_binary(message), do: message
  defp format_reason(%{reason: reason}), do: format_reason(reason)
  defp format_reason(exception) when is_exception(exception), do: Exception.message(exception)
  defp format_reason(reason), do: inspect(reason)
end

defmodule Clearance.Lint.Ast.Elixir do
  @moduledoc """
  Native BEAM AST static risk analyzer for `execute` calls using the
  `"elixir_subprocess"` or `"elixir"` runtimes.

  Parses code with `Code.string_to_quoted/2` (pure syntax analysis — zero
  evaluation, zero subprocesses) and walks the AST while tracking:

    * local `alias` / `import` bindings (`alias File, as: F`, `import File`);
    * simple variable bindings (`dir = System.user_home!()`, `p = Path.join(...)`);
    * pipe desugaring (`System.user_home!() |> File.rm_rf!()`);
    * string concatenation and interpolation (`"\#{System.user_home!()}/.ssh"`).

  Because inspection operates on AST nodes rather than raw text, comments and
  string literals never trigger false positives, while aliased modules,
  Erlang calls (`:file.del_dir_r`), dynamic calls (`apply/3`, `Code.eval_*`),
  and embedded shell commands (`System.cmd/2`, `:os.cmd/1`) are classified
  accurately. Syntax errors fail closed to `:ask`.
  """

  alias Clearance.Lint
  alias Clearance.Lint.TargetRules

  @destructive_file_funs %{
    File => [:rm, :rm!, :rm_rf, :rm_rf!, :rmdir, :rmdir!],
    :file => [:delete, :del_dir, :del_dir_r]
  }

  @recursive_delete_funs %{
    File => [:rm_rf, :rm_rf!],
    :file => [:del_dir_r]
  }

  @write_file_funs %{
    File => [
      {:write, 0},
      {:write!, 0},
      {:open, 0},
      {:open!, 0},
      {:cp, 1},
      {:cp!, 1},
      {:cp_r, 1},
      {:cp_r!, 1},
      {:rename, 1},
      {:rename!, 1},
      {:chmod, 0},
      {:chmod!, 0}
    ],
    :file => [
      {:write_file, 0},
      {:rename, 1},
      {:change_mode, 0}
    ]
  }

  @perm_funs %{
    File => [:chmod, :chmod!, :chown, :chown!],
    :file => [:change_mode, :change_owner]
  }

  @dynamic_eval_funs %{
    Code => [:eval_string, :eval_quoted, :eval_file, :compile_string, :compile_quoted],
    Kernel => [:apply],
    :erlang => [:apply],
    Module => [:create, :eval_quoted]
  }

  @subprocess_funs %{
    System => [:cmd, :shell],
    :os => [:cmd],
    Port => [:open],
    :erlang => [:open_port]
  }

  @network_modules MapSet.new([
                     :httpc,
                     :gen_tcp,
                     :gen_udp,
                     :ssl,
                     :inets,
                     Req,
                     Finch,
                     Mint,
                     Mint.HTTP,
                     HTTPoison,
                     Tesla,
                     ReqLLM,
                     Mix.Tasks.Deps.Get
                   ])

  @beam_mutation_funs %{
    Application => [:put_env, :delete_env, :stop],
    System => [:halt, :stop],
    :init => [:stop, :restart],
    Process => [:exit],
    GenServer => [:stop],
    Supervisor => [:terminate_child, :stop],
    :code => [:purge, :soft_purge, :delete, :load_binary],
    :persistent_term => [:put, :erase]
  }

  @doc "Inspect Elixir `code` statically via `Code.string_to_quoted/2`."
  @spec inspect(String.t(), String.t(), keyword() | map()) :: map()
  def inspect(code, runtime \\ "elixir_subprocess", opts \\ []) when is_binary(code) do
    protected_dirs = opts |> Access.get(:protected_dirs, []) |> List.wrap()

    base_ask =
      if runtime == "elixir" do
        ["in-process Elixir runtime evaluates inside the agent BEAM"]
      else
        []
      end

    case Code.string_to_quoted(code, columns: true) do
      {:ok, ast} ->
        acc = %{
          deny: [],
          ask: base_ask,
          network?: false,
          credential_ref?: false,
          runtime: runtime,
          protected_dirs: protected_dirs
        }

        env = %{aliases: %{}, imports: [Kernel], vars: %{}}
        {acc, _env} = walk(ast, acc, env)

        acc =
          if acc.network? and acc.credential_ref? do
            add_deny(
              acc,
              "destructive or network operation referencing sensitive user/credential directory"
            )
          else
            acc
          end

        finalize(acc)

      {:error, _meta} ->
        %{
          verdict: :ask,
          risk: :high,
          reasons: Enum.uniq(base_ask ++ ["Elixir syntax error; cannot statically analyze AST"]),
          analyzer: :ast_elixir
        }
    end
  end

  ## AST traversal

  defp walk({:__block__, _meta, exprs}, acc, env) when is_list(exprs) do
    Enum.reduce(exprs, {acc, env}, fn expr, {acc, env} -> walk(expr, acc, env) end)
  end

  # alias Foo.Bar / alias Foo.Bar, as: B / alias Foo.{Bar, Baz}
  defp walk({:alias, _meta, args}, acc, env) do
    {acc, register_alias(args, env)}
  end

  # import File / import File, only: [...]
  defp walk({:import, _meta, [mod_ast | _rest]}, acc, env) do
    case resolve_module(mod_ast, env) do
      {:ok, mod} -> {acc, %{env | imports: [mod | env.imports]}}
      :dynamic -> {acc, env}
    end
  end

  # Variable assignment: `lhs = rhs`
  defp walk({:=, _meta, [lhs, rhs]}, acc, env) do
    {acc, _env_after_rhs} = walk(rhs, acc, env)

    env =
      case lhs do
        {var, _, ctx} when is_atom(var) and is_atom(ctx) ->
          case resolve_binding(rhs, env) do
            {:ok, val} -> put_in(env.vars[var], val)
            :unknown -> %{env | vars: Map.delete(env.vars, var)}
          end

        _ ->
          env
      end

    {acc, env}
  end

  # Pipe desugaring: `lhs |> rhs`
  defp walk({:|>, _meta, [lhs, rhs]}, acc, env) do
    {acc, _} = walk(lhs, acc, env)

    case inject_pipe_arg(rhs, lhs) do
      {:ok, desugared} ->
        inspect_call_node(desugared, acc, env)

      :error ->
        walk(rhs, acc, env)
    end
  end

  # Remote call: `Mod.fun(args...)` or `var.fun(args...)`
  defp walk({{:., _dot_meta, [_target, fun]}, _call_meta, args} = node, acc, env)
       when is_atom(fun) and is_list(args) do
    inspect_call_node(node, acc, env)
  end

  # Anonymous / dynamic function call: `fun.(args...)`
  defp walk({{:., _dot_meta, [callee]}, _call_meta, args}, acc, env) when is_list(args) do
    {acc, _} = walk(callee, acc, env)
    acc = walk_list(args, acc, env)
    {acc, env}
  end

  # Local / imported call: `apply(...)`, `rm_rf!(...)`, etc.
  defp walk({fun, _meta, args}, acc, env) when is_atom(fun) and is_list(args) do
    acc =
      case resolve_local_call(fun, length(args), env) do
        {:ok, mod} -> inspect_resolved_call(mod, fun, args, acc, env)
        :local -> acc
      end

    acc = walk_list(args, acc, env)
    {acc, env}
  end

  # Containers (tuples, lists, keyword lists, maps, fn clauses)
  defp walk({left, right}, acc, env) do
    {acc, _} = walk(left, acc, env)
    {acc, _} = walk(right, acc, env)
    {acc, env}
  end

  defp walk(list, acc, env) when is_list(list) do
    {walk_list(list, acc, env), env}
  end

  defp walk({_tag, _meta, children}, acc, env) when is_list(children) do
    {walk_list(children, acc, env), env}
  end

  defp walk(literal, acc, env) when is_binary(literal) do
    acc = maybe_flag_credential_literal(literal, acc)
    {acc, env}
  end

  defp walk(_other, acc, env), do: {acc, env}

  defp walk_list(nodes, acc, env) do
    Enum.reduce(nodes, acc, fn node, acc ->
      {acc, _} = walk(node, acc, env)
      acc
    end)
  end

  defp inspect_call_node({{:., _dot_meta, [target, fun]}, _call_meta, args}, acc, env) do
    acc =
      case resolve_module(target, env) do
        {:ok, mod} ->
          inspect_resolved_call(mod, fun, args, acc, env)

        :dynamic ->
          # Calling a known destructive/eval function name on a dynamic module
          # variable (e.g. `m = get_mod(); m.rm_rf!(...)`) cannot be proven safe.
          if fun in [:rm, :rm!, :rm_rf, :rm_rf!, :rmdir, :rmdir!, :del_dir_r, :cmd, :shell] do
            add_ask(acc, "dynamic expression evaluation or reflective call")
          else
            acc
          end
      end

    acc = walk_list(args, acc, env)
    {acc, env}
  end

  defp inspect_call_node(other, acc, env), do: walk(other, acc, env)

  ## Call classification

  defp inspect_resolved_call(mod, fun, args, acc, env) do
    acc = check_destructive_file(mod, fun, args, acc, env)
    acc = check_write_file(mod, fun, args, acc, env)
    acc = check_perm_file(mod, fun, acc)
    acc = check_dynamic_eval(mod, fun, args, acc)
    acc = check_subprocess(mod, fun, args, acc, env)
    acc = check_network(mod, acc)
    acc = check_beam_mutation(mod, fun, acc)
    check_credential_args(args, acc, env)
  end

  defp check_destructive_file(mod, fun, args, acc, env) do
    if fun in Map.get(@destructive_file_funs, mod, []) do
      target =
        case args do
          [first | _] -> eval_static_path(first, env)
          _ -> :dynamic
        end

      acc =
        if fun in Map.get(@recursive_delete_funs, mod, []) do
          add_ask(acc, "recursive or forced file deletion")
        else
          acc
        end

      case target do
        {:ok, path} ->
          cond do
            TargetRules.credential_target?(path) ->
              add_deny(
                acc,
                "destructive or network operation referencing sensitive user/credential directory"
              )

            TargetRules.dangerous_target?(path, acc.protected_dirs) ->
              add_deny(
                acc,
                "destructive Elixir file operation targeting protected path (#{path})"
              )

            true ->
              acc
          end

        :dynamic ->
          acc
      end
    else
      acc
    end
  end

  defp check_write_file(mod, fun, args, acc, env) do
    case List.keyfind(Map.get(@write_file_funs, mod, []), fun, 0) do
      {^fun, path_index} ->
        case Enum.at(args, path_index) do
          nil ->
            acc

          arg_ast ->
            case eval_static_path(arg_ast, env) do
              {:ok, path} ->
                if TargetRules.dangerous_target?(path, acc.protected_dirs) do
                  add_deny(acc, "writing or modifying protected host/user path (#{path})")
                else
                  acc
                end

              :dynamic ->
                acc
            end
        end

      nil ->
        acc
    end
  end

  defp check_perm_file(mod, fun, acc) do
    if fun in Map.get(@perm_funs, mod, []) do
      add_ask(acc, "recursive permission or ownership change")
    else
      acc
    end
  end

  defp check_dynamic_eval(mod, fun, _args, acc) do
    if fun in Map.get(@dynamic_eval_funs, mod, []) do
      add_ask(acc, "dynamic expression evaluation or reflective call")
    else
      acc
    end
  end

  defp check_subprocess(mod, fun, args, acc, env) do
    if fun in Map.get(@subprocess_funs, mod, []) do
      acc = add_ask(acc, "subprocess or shell execution")

      case extract_embedded_command(mod, fun, args, env) do
        {:ok, cmd_text} ->
          nested = Lint.inspect_shell_text(cmd_text, protected_dirs: acc.protected_dirs)

          case nested.verdict do
            :deny ->
              Enum.reduce(nested.reasons, acc, &add_deny(&2, &1))

            :ask ->
              Enum.reduce(nested.reasons, acc, fn r, a ->
                a =
                  if r == "network access or package installation",
                    do: %{a | network?: true},
                    else: a

                add_ask(a, r)
              end)

            :ok ->
              acc
          end

        :dynamic ->
          acc
      end
    else
      acc
    end
  end

  defp check_network(mod, acc) do
    if MapSet.member?(@network_modules, mod) do
      acc
      |> Map.put(:network?, true)
      |> add_ask("network access or package installation")
    else
      acc
    end
  end

  defp check_beam_mutation(mod, fun, %{runtime: "elixir"} = acc) do
    if fun in Map.get(@beam_mutation_funs, mod, []) do
      add_ask(acc, "mutates or terminates live agent BEAM state")
    else
      acc
    end
  end

  defp check_beam_mutation(_mod, _fun, acc), do: acc

  defp check_credential_args(args, acc, env) do
    Enum.reduce(args, acc, fn arg, acc ->
      case eval_static_path(arg, env) do
        {:ok, path} -> maybe_flag_credential_literal(path, acc)
        :dynamic -> acc
      end
    end)
  end

  defp maybe_flag_credential_literal(text, acc) do
    if TargetRules.credential_target?(text) do
      %{acc | credential_ref?: true}
    else
      acc
    end
  end

  ## Lexical environment & static expression resolution

  defp register_alias([{:__aliases__, _, parts}], env) do
    full = Module.concat(parts)
    short = List.last(parts)
    put_in(env.aliases[short], full)
  end

  defp register_alias([{:__aliases__, _, parts}, opts], env) when is_list(opts) do
    full = Module.concat(parts)

    case Keyword.get(opts, :as) do
      {:__aliases__, _, [short]} -> put_in(env.aliases[short], full)
      _ -> env
    end
  end

  defp register_alias([{{:., _, [{:__aliases__, _, prefix}, :{}]}, _, multi}], env)
       when is_list(multi) do
    Enum.reduce(multi, env, fn
      {:__aliases__, _, suffix}, acc_env ->
        full = Module.concat(prefix ++ suffix)
        short = List.last(suffix)
        put_in(acc_env.aliases[short], full)

      _, acc_env ->
        acc_env
    end)
  end

  defp register_alias([mod, opts], env) when is_atom(mod) and is_list(opts) do
    case Keyword.get(opts, :as) do
      {:__aliases__, _, [short]} -> put_in(env.aliases[short], mod)
      _ -> env
    end
  end

  defp register_alias(_other, env), do: env

  defp resolve_module(atom, _env) when is_atom(atom), do: {:ok, atom}

  defp resolve_module({:__aliases__, _, [first | rest]}, env) when is_atom(first) do
    case Map.fetch(env.aliases, first) do
      {:ok, base} when is_atom(base) ->
        if rest == [] do
          {:ok, base}
        else
          {:ok, Module.concat([base | rest])}
        end

      :error ->
        {:ok, Module.concat([first | rest])}
    end
  end

  defp resolve_module({var, _, ctx}, env) when is_atom(var) and is_atom(ctx) do
    case Map.get(env.vars, var) do
      {:module, mod} -> {:ok, mod}
      _ -> :dynamic
    end
  end

  defp resolve_module(_other, _env), do: :dynamic

  defp resolve_local_call(fun, _arity, env) do
    cond do
      fun == :apply ->
        {:ok, Kernel}

      Enum.any?(env.imports, fn mod ->
        fun in Map.get(@destructive_file_funs, mod, []) or
          fun in Map.get(@perm_funs, mod, []) or
          fun in Map.get(@dynamic_eval_funs, mod, []) or
          fun in Map.get(@subprocess_funs, mod, []) or
            List.keymember?(Map.get(@write_file_funs, mod, []), fun, 0)
      end) ->
        mod =
          Enum.find(env.imports, fn m ->
            fun in Map.get(@destructive_file_funs, m, []) or
              fun in Map.get(@perm_funs, m, []) or
              fun in Map.get(@dynamic_eval_funs, m, []) or
              fun in Map.get(@subprocess_funs, m, []) or
              List.keymember?(Map.get(@write_file_funs, m, []), fun, 0)
          end)

        {:ok, mod}

      true ->
        :local
    end
  end

  defp resolve_binding(rhs, env) do
    case resolve_module(rhs, env) do
      {:ok, mod} when is_atom(mod) and mod not in [true, false, nil] ->
        {:ok, {:module, mod}}

      _ ->
        case eval_static_path(rhs, env) do
          {:ok, str} -> {:ok, {:path, str}}
          :dynamic -> :unknown
        end
    end
  end

  defp eval_static_path(str, _env) when is_binary(str), do: {:ok, str}

  defp eval_static_path(charlist, _env) when is_list(charlist) do
    if List.ascii_printable?(charlist) do
      {:ok, List.to_string(charlist)}
    else
      :dynamic
    end
  end

  defp eval_static_path({var, _, ctx}, env) when is_atom(var) and is_atom(ctx) do
    case Map.get(env.vars, var) do
      {:path, val} -> {:ok, val}
      _ -> :dynamic
    end
  end

  defp eval_static_path({:<>, _, [left, right]}, env) do
    with {:ok, l} <- eval_static_path(left, env),
         {:ok, r} <- eval_static_path(right, env) do
      {:ok, l <> r}
    else
      _ -> :dynamic
    end
  end

  # String interpolation: `"#{expr}/sub"`
  defp eval_static_path({:<<>>, _, parts}, env) when is_list(parts) do
    parts
    |> Enum.reduce_while({:ok, []}, fn
      part, {:ok, acc} when is_binary(part) ->
        {:cont, {:ok, [part | acc]}}

      {:"::", _, [{{:., _, [Kernel, :to_string]}, _, [inner]}, {:binary, _, _}]}, {:ok, acc} ->
        case eval_static_path(inner, env) do
          {:ok, val} -> {:cont, {:ok, [val | acc]}}
          :dynamic -> {:halt, :dynamic}
        end

      _, _ ->
        {:halt, :dynamic}
    end)
    |> case do
      {:ok, pieces} -> {:ok, pieces |> Enum.reverse() |> IO.iodata_to_binary()}
      :dynamic -> :dynamic
    end
  end

  # Pipe inside path expression: `System.user_home!() |> Path.join(".ssh")`
  defp eval_static_path({:|>, _, [lhs, rhs]}, env) do
    case inject_pipe_arg(rhs, lhs) do
      {:ok, desugared} -> eval_static_path(desugared, env)
      :error -> :dynamic
    end
  end

  defp eval_static_path({{:., _, [target, fun]}, _, args}, env) when is_list(args) do
    case resolve_module(target, env) do
      {:ok, System} when fun in [:user_home, :user_home!] and args == [] ->
        {:ok, "<USER_HOME>"}

      {:ok, System} when fun in [:get_env, :fetch_env!] and length(args) >= 1 ->
        case eval_static_path(hd(args), env) do
          {:ok, var_name} ->
            if TargetRules.protected_env_var?(var_name) do
              {:ok, "<PROTECTED_ENV:#{String.upcase(var_name)}>"}
            else
              :dynamic
            end

          :dynamic ->
            :dynamic
        end

      {:ok, :os} when fun == :getenv and length(args) >= 1 ->
        case eval_static_path(hd(args), env) do
          {:ok, var_name} ->
            if TargetRules.protected_env_var?(var_name) do
              {:ok, "<PROTECTED_ENV:#{String.upcase(var_name)}>"}
            else
              :dynamic
            end

          :dynamic ->
            :dynamic
        end

      {:ok, Path} when fun == :join and length(args) == 2 ->
        with {:ok, a} <- eval_static_path(Enum.at(args, 0), env),
             {:ok, b} <- eval_static_path(Enum.at(args, 1), env) do
          {:ok, join_static(a, b)}
        else
          _ -> :dynamic
        end

      {:ok, Path} when fun == :join and length(args) == 1 ->
        case hd(args) do
          list when is_list(list) ->
            resolved = Enum.map(list, &eval_static_path(&1, env))

            if Enum.all?(resolved, &match?({:ok, _}, &1)) do
              joined = resolved |> Enum.map(&elem(&1, 1)) |> Enum.reduce(&join_static(&2, &1))
              {:ok, joined}
            else
              :dynamic
            end

          _ ->
            :dynamic
        end

      {:ok, Path} when fun == :expand and length(args) == 1 ->
        case eval_static_path(hd(args), env) do
          {:ok, "~"} -> {:ok, "<USER_HOME>"}
          {:ok, "~/" <> rest} -> {:ok, "<USER_HOME>/" <> rest}
          {:ok, other} -> {:ok, other}
          :dynamic -> :dynamic
        end

      {:ok, Path} when fun == :expand and length(args) == 2 ->
        with {:ok, rel} <- eval_static_path(Enum.at(args, 0), env),
             {:ok, base} <- eval_static_path(Enum.at(args, 1), env) do
          {:ok, join_static(base, rel)}
        else
          _ -> :dynamic
        end

      _ ->
        :dynamic
    end
  end

  defp eval_static_path(_other, _env), do: :dynamic

  defp join_static(a, b) do
    String.trim_trailing(a, "/") <> "/" <> String.trim_leading(b, "/")
  end

  defp extract_embedded_command(System, :cmd, [cmd_ast, args_ast | _], env) do
    with {:ok, cmd} <- eval_static_path(cmd_ast, env) do
      arg_strs =
        case args_ast do
          list when is_list(list) ->
            Enum.flat_map(list, fn item ->
              case eval_static_path(item, env) do
                {:ok, s} -> [s]
                :dynamic -> []
              end
            end)

          _ ->
            []
        end

      {:ok, Enum.join([cmd | arg_strs], " ")}
    end
  end

  defp extract_embedded_command(System, :shell, [cmd_ast | _], env) do
    eval_static_path(cmd_ast, env)
  end

  defp extract_embedded_command(:os, :cmd, [cmd_ast], env) do
    eval_static_path(cmd_ast, env)
  end

  defp extract_embedded_command(_mod, _fun, _args, _env), do: :dynamic

  defp inject_pipe_arg({{:., dot_meta, target_and_fun}, call_meta, args}, lhs)
       when is_list(args) do
    {:ok, {{:., dot_meta, target_and_fun}, call_meta, [lhs | args]}}
  end

  defp inject_pipe_arg({fun, meta, args}, lhs) when is_atom(fun) and is_list(args) do
    {:ok, {fun, meta, [lhs | args]}}
  end

  defp inject_pipe_arg({fun, meta, nil}, lhs) when is_atom(fun) do
    {:ok, {fun, meta, [lhs]}}
  end

  defp inject_pipe_arg(_other, _lhs), do: :error

  ## Result accumulation

  defp add_deny(acc, reason), do: %{acc | deny: [reason | acc.deny]}
  defp add_ask(acc, reason), do: %{acc | ask: [reason | acc.ask]}

  defp finalize(acc) do
    deny = acc.deny |> Enum.reverse() |> Enum.uniq()
    ask = acc.ask |> Enum.reverse() |> Enum.uniq()

    cond do
      deny != [] ->
        %{verdict: :deny, risk: :critical, reasons: deny, analyzer: :ast_elixir}

      ask != [] ->
        %{verdict: :ask, risk: :high, reasons: ask, analyzer: :ast_elixir}

      true ->
        %{verdict: :ok, risk: :low, reasons: [], analyzer: :ast_elixir}
    end
  end
end

defmodule Noctilucent.Policy.Ast.Python do
  @moduledoc """
  Python AST static risk analyzer backed by Python's standard library
  `ast.parse/1`.

  A lazy persistent `Noctilucent.Policy.Ast.Worker` runs a strictly read-only
  Python script that **only** parses input into an AST and emits structural
  JSON facts (imports, resolved calls, receiver paths, and syntax errors) —
  user code is **never** executed.

  All security verdicts (`:deny` / `:ask` / `:ok`) are computed deterministically
  in Elixir via `analyze_facts/2`, tracking aliased imports (`import shutil as s`,
  `from pathlib import Path as P`), `Path` receiver expressions
  (`(Path.home() / ".ssh").unlink()`), simple variable indirection, dynamic
  reflection (`eval`, `exec`, `__import__`, `ctypes`), subprocess execution, and
  network modules while avoiding false positives in comments and strings.
  """

  alias Noctilucent.Policy.Ast.Worker
  alias Noctilucent.Policy.{ShellLint, TargetRules}

  @worker_name __MODULE__.Worker

  @destructive_calls MapSet.new(~w(
    shutil.rmtree
    os.remove os.unlink os.rmdir os.removedirs
    pathlib.Path.unlink pathlib.Path.rmdir
    send2trash.send2trash
  ))

  @recursive_delete_calls MapSet.new(~w(
    shutil.rmtree os.removedirs
  ))

  @write_calls MapSet.new(~w(
    pathlib.Path.write_text pathlib.Path.write_bytes
    shutil.move shutil.copy shutil.copy2 shutil.copytree
    os.rename os.replace
  ))

  @perm_calls MapSet.new(~w(
    os.chmod os.chown pathlib.Path.chmod
  ))

  @dynamic_calls MapSet.new(~w(
    eval exec compile __import__
    builtins.eval builtins.exec builtins.compile builtins.__import__
    importlib.import_module
  ))

  @subprocess_calls MapSet.new(~w(
    os.system os.popen
    os.execl os.execle os.execlp os.execlpe os.execv os.execve os.execvp os.execvpe
    os.spawnl os.spawnle os.spawnlp os.spawnlpe os.spawnv os.spawnve os.spawnvp os.spawnvpe
    subprocess.run subprocess.Popen subprocess.call subprocess.check_call subprocess.check_output
    subprocess.getoutput subprocess.getstatusoutput
  ))

  @network_prefixes ~w(
    urllib http socket requests httpx aiohttp ftplib smtplib imaplib poplib
    telnetlib xmlrpc paramiko websockets pip
  )

  # Strictly read-only AST extractor. Uses ast.parse() only; never evaluates code.
  @extractor_script ~S"""
  import ast
  import base64
  import json
  import sys

  PROTECTED_ENV = {
      "USERPROFILE", "HOME", "SYSTEMROOT", "WINDIR",
      "PROGRAMFILES", "PROGRAMFILES(X86)", "PROGRAMW6432",
      "PROGRAMDATA", "APPDATA",
  }


  class Extractor(ast.NodeVisitor):
      def __init__(self):
          self.aliases = {}       # local_name -> canonical module/symbol
          self.vars = {}          # var_name -> resolved static path string
          self.path_vars = set()  # var_names known to hold pathlib.Path
          self.imports = []       # canonical imported module names
          self.calls = []         # extracted call records
          self.literals = []      # string literals (for credential checks)

      def visit_Import(self, node):
          for alias in node.names:
              asname = alias.asname or alias.name.split(".")[0]
              self.aliases[asname] = alias.name if alias.asname else alias.name.split(".")[0]
              self.imports.append(alias.name)

      def visit_ImportFrom(self, node):
          mod = node.module or ""
          if mod:
              self.imports.append(mod)
          for alias in node.names:
              if alias.name == "*":
                  continue
              asname = alias.asname or alias.name
              full = f"{mod}.{alias.name}" if mod else alias.name
              self.aliases[asname] = full

      def visit_Assign(self, node):
          self.visit(node.value)
          resolved = self.resolve_path(node.value)
          is_path_obj = self.is_path_expr(node.value)
          for target in node.targets:
              if isinstance(target, ast.Name):
                  if resolved is not None:
                      self.vars[target.id] = resolved
                  else:
                      self.vars.pop(target.id, None)
                  if is_path_obj:
                      self.path_vars.add(target.id)
                  else:
                      self.path_vars.discard(target.id)

      def visit_Call(self, node):
          callee, receiver = self.resolve_callee(node.func)
          args = []
          for arg in node.args:
              r = self.resolve_path(arg)
              if r is not None:
                  args.append(r)
              elif isinstance(arg, (ast.List, ast.Tuple)):
                  items = [self.resolve_path(elt) for elt in arg.elts]
                  if items and all(x is not None for x in items):
                      args.append(" ".join(items))
          kwargs = {}
          for kw in node.keywords:
              if kw.arg is not None:
                  r = self.resolve_path(kw.value)
                  if r is not None:
                      kwargs[kw.arg] = r
                  elif isinstance(kw.value, ast.Constant) and isinstance(kw.value.value, bool):
                      kwargs[kw.arg] = kw.value.value

          self.calls.append({
              "callee": callee,
              "receiver": receiver,
              "args": args,
              "kwargs": kwargs,
          })
          self.generic_visit(node)

      def visit_Constant(self, node):
          if isinstance(node.value, str) and len(node.value) <= 512:
              self.literals.append(node.value)

      def resolve_name(self, node):
          if isinstance(node, ast.Name):
              return self.aliases.get(node.id, node.id)
          if isinstance(node, ast.Attribute):
              base = self.resolve_name(node.value)
              if base:
                  return f"{base}.{node.attr}"
          return None

      def resolve_callee(self, func):
          if isinstance(func, ast.Attribute):
              # Check if receiver is a pathlib.Path expression (e.g. (Path.home() / ".ssh").unlink())
              if self.is_path_expr(func.value):
                  return f"pathlib.Path.{func.attr}", self.resolve_path(func.value)
              full = self.resolve_name(func)
              if full:
                  return full, None
              return f"<expr>.{func.attr}", None
          if isinstance(func, ast.Name):
              return self.aliases.get(func.id, func.id), None
          return "<dynamic>", None

      def is_path_expr(self, node):
          if isinstance(node, ast.Name):
              return node.id in self.path_vars
          if isinstance(node, ast.Call):
              full = self.resolve_name(node.func)
              if full in ("pathlib.Path", "pathlib.Path.home", "pathlib.Path.cwd", "pathlib.PosixPath", "pathlib.WindowsPath"):
                  return True
              if isinstance(node.func, ast.Attribute) and self.is_path_expr(node.func.value):
                  if node.func.attr in ("expanduser", "resolve", "joinpath", "with_name", "parent"):
                      return True
          if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Div):
              return self.is_path_expr(node.left)
          return False

      def resolve_path(self, node):
          if isinstance(node, ast.Constant) and isinstance(node.value, str):
              return node.value
          if isinstance(node, ast.Name):
              return self.vars.get(node.id)
          if isinstance(node, ast.JoinedStr):
              parts = []
              for v in node.values:
                  if isinstance(v, ast.Constant) and isinstance(v.value, str):
                      parts.append(v.value)
                  elif isinstance(v, ast.FormattedValue):
                      rv = self.resolve_path(v.value)
                      if rv is None:
                          return None
                      parts.append(rv)
                  else:
                      return None
              return "".join(parts)
          if isinstance(node, ast.BinOp):
              if isinstance(node.op, ast.Add):
                  l = self.resolve_path(node.left)
                  r = self.resolve_path(node.right)
                  if l is not None and r is not None:
                      return l + r
              if isinstance(node.op, ast.Div):
                  l = self.resolve_path(node.left)
                  r = self.resolve_path(node.right)
                  if l is not None and r is not None:
                      return l.rstrip("/\\") + "/" + r.lstrip("/\\")
          if isinstance(node, ast.Subscript):
              target = self.resolve_name(node.value)
              if target == "os.environ":
                  key = self.resolve_path(node.slice)
                  if key and key.upper() in PROTECTED_ENV:
                      return f"<PROTECTED_ENV:{key.upper()}>"
          if isinstance(node, ast.Call):
              full = self.resolve_name(node.func)
              if full == "pathlib.Path.home":
                  return "<USER_HOME>"
              if full in ("pathlib.Path", "pathlib.PosixPath", "pathlib.WindowsPath"):
                  parts = [self.resolve_path(a) for a in node.args]
                  if parts and all(p is not None for p in parts):
                      return "/".join(p.rstrip("/\\") if i == 0 else p.strip("/\\") for i, p in enumerate(parts))
              if full == "os.path.expanduser" and node.args:
                  p = self.resolve_path(node.args[0])
                  if p == "~":
                      return "<USER_HOME>"
                  if p and (p.startswith("~/") or p.startswith("~\\")):
                      return "<USER_HOME>/" + p[2:]
                  return p
              if full == "os.path.join" and node.args:
                  parts = [self.resolve_path(a) for a in node.args]
                  if parts and all(p is not None for p in parts):
                      out = parts[0]
                      for p in parts[1:]:
                          out = out.rstrip("/\\") + "/" + p.lstrip("/\\")
                      return out
              if full in ("os.getenv", "os.environ.get") and node.args:
                  key = self.resolve_path(node.args[0])
                  if key and key.upper() in PROTECTED_ENV:
                      return f"<PROTECTED_ENV:{key.upper()}>"
              if isinstance(node.func, ast.Attribute) and self.is_path_expr(node.func.value):
                  base = self.resolve_path(node.func.value)
                  if node.func.attr == "expanduser" and base is not None:
                      if base == "~":
                          return "<USER_HOME>"
                      if base.startswith("~/") or base.startswith("~\\"):
                          return "<USER_HOME>/" + base[2:]
                      return base
                  if node.func.attr == "resolve" and base is not None:
                      return base
                  if node.func.attr == "joinpath" and base is not None:
                      parts = [self.resolve_path(a) for a in node.args]
                      if all(p is not None for p in parts):
                          out = base
                          for p in parts:
                              out = out.rstrip("/\\") + "/" + p.lstrip("/\\")
                          return out
          return None


  def extract(code):
      try:
          tree = ast.parse(code)
      except SyntaxError as exc:
          return {"ok": True, "syntax_error": str(exc), "imports": [], "calls": [], "literals": []}
      visitor = Extractor()
      visitor.visit(tree)
      return {
          "ok": True,
          "syntax_error": None,
          "imports": visitor.imports,
          "calls": visitor.calls,
          "literals": visitor.literals,
      }


  for line in sys.stdin:
      line = line.strip()
      if not line:
          continue
      try:
          code = base64.b64decode(line).decode("utf-8", errors="replace")
          result = extract(code)
      except Exception as exc:
          result = {"ok": False, "error": str(exc)}
      sys.stdout.write(json.dumps(result, ensure_ascii=False) + "\n")
      sys.stdout.flush()
  """

  @doc "Child options for `Noctilucent.Policy.Ast.Worker` in `Noctilucent.Supervisor`."
  @spec worker_opts() :: keyword()
  def worker_opts do
    [
      id: @worker_name,
      name: @worker_name,
      command_builder: &__MODULE__.command_spec/0,
      timeout_ms: 5_000,
      startup_timeout_ms: 8_000
    ]
  end

  @doc "Locate a working Python executable (skipping Windows Store stubs) and build the worker spec."
  @spec command_spec() :: {:ok, Worker.command_spec()} | {:error, String.t()}
  def command_spec do
    case find_python() do
      nil ->
        {:error, "no working python3/python executable found on PATH"}

      exe ->
        {:ok,
         %{
           exe: exe,
           args: ["-u", :script],
           script_name: "py_ast_worker.py",
           script_content: @extractor_script,
           env: [{~c"PYTHONIOENCODING", ~c"utf-8"}, {~c"PYTHONUTF8", ~c"1"}]
         }}
    end
  end

  @doc "Whether a non-stub Python executable is available on PATH."
  @spec available?() :: boolean()
  def available?, do: not is_nil(find_python())

  @doc """
  Parse Python `code` via the persistent AST worker and evaluate static risk.

  Returns `{:ok, assessment}` on success, or `{:error, reason}` if Python or
  the worker is unavailable (letting callers fail closed).
  """
  @spec inspect(String.t(), keyword() | map()) :: {:ok, map()} | {:error, String.t()}
  def inspect(code, opts \\ []) when is_binary(code) do
    worker = Access.get(opts, :worker, @worker_name)

    with {:ok, %{"ok" => true} = facts} <- Worker.parse(worker, code) do
      {:ok, analyze_facts(facts, opts)}
    else
      {:ok, %{"ok" => false, "error" => err}} -> {:error, "Python AST error: #{err}"}
      {:ok, other} -> {:error, "unexpected Python AST payload: #{Kernel.inspect(other)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Pure-Elixir risk classification over JSON facts produced by the Python AST
  extractor. Exposed publicly for deterministic unit testing.
  """
  @spec analyze_facts(map(), keyword() | map()) :: map()
  def analyze_facts(facts, opts \\ []) when is_map(facts) do
    protected_dirs = opts |> Access.get(:protected_dirs, []) |> List.wrap()

    case Map.get(facts, "syntax_error") do
      err when is_binary(err) and err != "" ->
        %{
          verdict: :ask,
          risk: :high,
          reasons: ["Python syntax error; cannot statically analyze AST"],
          analyzer: :ast_python
        }

      _ ->
        acc = %{
          deny: [],
          ask: [],
          network?: false,
          credential_ref?: false,
          protected_dirs: protected_dirs
        }

        acc =
          acc
          |> check_literals(facts)
          |> check_imports(facts)
          |> check_calls(facts)

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
    end
  end

  ## Pure Elixir analysis of Python AST facts

  defp check_literals(acc, facts) do
    has_cred? =
      facts
      |> list_field("literals")
      |> Enum.any?(&TargetRules.credential_target?(to_string(&1)))

    if has_cred?, do: %{acc | credential_ref?: true}, else: acc
  end

  defp check_imports(acc, facts) do
    Enum.reduce(list_field(facts, "imports"), acc, fn mod, acc ->
      mod_str = to_string(mod)
      root = mod_str |> String.split(".") |> hd()

      cond do
        root in @network_prefixes ->
          acc |> Map.put(:network?, true) |> add_ask("network access or package installation")

        root == "ctypes" ->
          add_ask(acc, "dynamic expression evaluation or reflective call")

        root == "subprocess" ->
          add_ask(acc, "subprocess or shell execution")

        true ->
          acc
      end
    end)
  end

  defp check_calls(acc, facts) do
    Enum.reduce(list_field(facts, "calls"), acc, fn call, acc ->
      callee = call |> Map.get("callee", "") |> to_string()
      receiver = Map.get(call, "receiver")
      args = call |> list_field("args") |> Enum.map(&to_string/1)
      kwargs = Map.get(call, "kwargs") || %{}

      all_targets =
        ([receiver | args] ++ Map.values(kwargs))
        |> Enum.filter(&is_binary/1)

      acc =
        if Enum.any?(all_targets, &TargetRules.credential_target?/1) do
          %{acc | credential_ref?: true}
        else
          acc
        end

      acc
      |> check_destructive_call(callee, receiver, args)
      |> check_write_call(callee, receiver, args, kwargs)
      |> check_perm_call(callee)
      |> check_dynamic_call(callee)
      |> check_subprocess_call(callee, args)
      |> check_network_call(callee)
    end)
  end

  defp check_destructive_call(acc, callee, receiver, args) do
    if MapSet.member?(@destructive_calls, callee) do
      acc =
        if MapSet.member?(@recursive_delete_calls, callee) do
          add_ask(acc, "recursive or forced file deletion")
        else
          acc
        end

      targets =
        case {receiver, args} do
          {r, _} when is_binary(r) -> [r]
          {_, [first | _]} -> [first]
          _ -> []
        end

      cond do
        Enum.any?(targets, &TargetRules.credential_target?/1) ->
          add_deny(
            acc,
            "destructive or network operation referencing sensitive user/credential directory"
          )

        Enum.any?(targets, &TargetRules.dangerous_target?(&1, acc.protected_dirs)) ->
          add_deny(
            acc,
            "destructive Python file operation targeting protected root, OS dir, or user home"
          )

        true ->
          acc
      end
    else
      acc
    end
  end

  defp check_write_call(acc, callee, receiver, args, kwargs) do
    cond do
      callee in ["open", "builtins.open", "io.open", "pathlib.Path.open"] ->
        mode =
          (Map.get(kwargs, "mode") || Enum.at(args, 1) || "r")
          |> to_string()

        target = if is_binary(receiver), do: receiver, else: Enum.at(args, 0)

        if write_mode?(mode) and is_binary(target) and
             TargetRules.dangerous_target?(target, acc.protected_dirs) do
          add_deny(acc, "writing or modifying protected host/user path (#{target})")
        else
          acc
        end

      MapSet.member?(@write_calls, callee) ->
        target =
          cond do
            is_binary(receiver) ->
              receiver

            callee in [
              "shutil.move",
              "shutil.copy",
              "shutil.copy2",
              "shutil.copytree",
              "os.rename",
              "os.replace"
            ] ->
              Enum.at(args, 1) || Enum.at(args, 0)

            true ->
              Enum.at(args, 0)
          end

        if is_binary(target) and TargetRules.dangerous_target?(target, acc.protected_dirs) do
          add_deny(acc, "writing or modifying protected host/user path (#{target})")
        else
          acc
        end

      true ->
        acc
    end
  end

  defp write_mode?(mode) do
    String.contains?(mode, "w") or String.contains?(mode, "a") or
      String.contains?(mode, "x") or String.contains?(mode, "+")
  end

  defp check_perm_call(acc, callee) do
    if MapSet.member?(@perm_calls, callee) do
      add_ask(acc, "recursive permission or ownership change")
    else
      acc
    end
  end

  defp check_dynamic_call(acc, callee) do
    cond do
      MapSet.member?(@dynamic_calls, callee) ->
        add_ask(acc, "dynamic expression evaluation or reflective call")

      String.starts_with?(callee, "ctypes.") ->
        add_ask(acc, "dynamic expression evaluation or reflective call")

      true ->
        acc
    end
  end

  defp check_subprocess_call(acc, callee, args) do
    if MapSet.member?(@subprocess_calls, callee) do
      acc = add_ask(acc, "subprocess or shell execution")

      case args do
        [cmd_text | _] when is_binary(cmd_text) ->
          nested = ShellLint.inspect_shell_text(cmd_text, protected_dirs: acc.protected_dirs)

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

        _ ->
          acc
      end
    else
      acc
    end
  end

  defp check_network_call(acc, callee) do
    root = callee |> String.split(".") |> hd()

    if root in @network_prefixes do
      acc |> Map.put(:network?, true) |> add_ask("network access or package installation")
    else
      acc
    end
  end

  # On Windows, `python3.exe` under `...\Microsoft\WindowsApps\` is a Microsoft
  # Store stub that fails to execute real Python. Skip it and fall back to
  # `python.exe` (e.g. Conda / official installer / Scoop).
  defp find_python do
    ["python3", "python"]
    |> Enum.find_value(fn name ->
      case System.find_executable(name) do
        nil -> nil
        path -> if windows_store_stub?(path), do: nil, else: path
      end
    end)
  end

  defp windows_store_stub?(path) do
    case :os.type() do
      {:win32, _} ->
        norm = path |> String.replace("\\", "/") |> String.downcase()
        String.contains?(norm, "/microsoft/windowsapps/")

      _posix ->
        false
    end
  end

  defp list_field(map, key) do
    case Map.get(map, key) do
      nil -> []
      list when is_list(list) -> list
      single -> [single]
    end
  end

  defp add_deny(acc, reason), do: %{acc | deny: [reason | acc.deny]}
  defp add_ask(acc, reason), do: %{acc | ask: [reason | acc.ask]}

  defp finalize(acc) do
    deny = acc.deny |> Enum.reverse() |> Enum.uniq()
    ask = acc.ask |> Enum.reverse() |> Enum.uniq()

    cond do
      deny != [] ->
        %{verdict: :deny, risk: :critical, reasons: deny, analyzer: :ast_python}

      ask != [] ->
        %{verdict: :ask, risk: :high, reasons: ask, analyzer: :ast_python}

      true ->
        %{verdict: :ok, risk: :low, reasons: [], analyzer: :ast_python}
    end
  end
end

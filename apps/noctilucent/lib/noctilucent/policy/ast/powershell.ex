defmodule Noctilucent.Policy.Ast.PowerShell do
  @moduledoc """
  PowerShell AST static risk analyzer backed by .NET's built-in
  `[System.Management.Automation.Language.Parser]::ParseInput/3`.

  A lazy persistent `Noctilucent.Policy.Ast.Worker` runs a strictly read-only
  PowerShell script that **only** parses input into an AST and emits structural
  JSON facts (assignments, commands, pipelines, .NET member invocations, file
  redirections, and parse errors) — user code is **never** evaluated.

  All security verdicts (`:deny` / `:ask` / `:ok`) are computed deterministically
  in Elixir via `analyze_facts/2`, catching syntax variants that regex misses
  (scoped/destructured `$global:home` assignments, backtick-escaped command
  names, simple variable indirection like `$p = $env:USERPROFILE; Remove-Item $p`,
  `[IO.Directory]::Delete(...)`, `$ErrorActionPreference` overrides) while
  eliminating false positives from comments and string literals.
  """

  alias Noctilucent.Policy.Ast.Worker
  alias Noctilucent.Policy.TargetRules

  @worker_name __MODULE__.Worker

  @readonly_auto_vars MapSet.new(~w(home pid pshome host shellid null true false))

  @set_var_cmds MapSet.new(~w(set-variable sv set new-variable nv))

  @destructive_cmds MapSet.new(~w(
    remove-item ri rm rmdir rd del erase
    clear-content clc move-item mi mv
    set-content sc
  ))

  @delete_cmds MapSet.new(~w(remove-item ri rm rmdir rd del erase))

  @network_download_cmds MapSet.new(~w(
    invoke-webrequest iwr invoke-restmethod irm curl wget
  ))

  @network_cmds MapSet.new(~w(
    invoke-webrequest iwr invoke-restmethod irm curl wget
    ssh scp rsync nc ncat
    install-module install-package install-script
  ))

  @shell_exec_cmds MapSet.new(~w(
    invoke-expression iex bash sh zsh ksh dash pwsh powershell cmd cmd.exe
  ))

  @dynamic_exec_cmds MapSet.new(~w(
    invoke-expression iex invoke-command icm start-process saps start
  ))

  @disk_cmds MapSet.new(~w(
    format-volume clear-disk initialize-disk diskpart fdisk mkfs
  ))

  @priv_proc_cmds MapSet.new(~w(
    sudo runas stop-process kill spps taskkill stop-service restart-service
    sc.exe systemctl icacls takeown
  ))

  @registry_write_cmds MapSet.new(~w(
    set-itemproperty sp new-itemproperty remove-itemproperty rp
    new-item remove-item
  ))

  @destructive_dotnet_types MapSet.new(~w(
    io.directory system.io.directory io.file system.io.file
  ))

  @destructive_dotnet_members MapSet.new(~w(delete move))

  @network_dotnet_types MapSet.new(~w(
    net.webclient system.net.webclient
    net.http.httpclient system.net.http.httpclient
    net.webrequest system.net.webrequest
    net.sockets.tcpclient system.net.sockets.tcpclient
  ))

  @dynamic_dotnet_calls MapSet.new([
                          {"scriptblock", "create"},
                          {"system.management.automation.scriptblock", "create"},
                          {"reflection.assembly", "load"},
                          {"reflection.assembly", "loadfrom"},
                          {"reflection.assembly", "loadfile"},
                          {"system.reflection.assembly", "load"},
                          {"system.reflection.assembly", "loadfrom"},
                          {"system.reflection.assembly", "loadfile"}
                        ])

  # Strictly read-only AST extractor script. Never evaluates user input.
  @extractor_script """
  \uFEFF$ProgressPreference = 'SilentlyContinue'
  $ErrorActionPreference = 'SilentlyContinue'
  [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
  [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

  function Strip-Scope([string]$userPath) {
    if ($null -eq $userPath) { return '' }
    return ($userPath -replace '^(?i)(global|script|local|private|using):', '')
  }

  function Resolve-Expr($node, [hashtable]$vars) {
    if ($null -eq $node) { return $null }

    if ($node -is [System.Management.Automation.Language.CommandExpressionAst]) {
      return (Resolve-Expr $node.Expression $vars)
    }
    if ($node -is [System.Management.Automation.Language.PipelineAst]) {
      if ($node.PipelineElements.Count -eq 1) {
        return (Resolve-Expr $node.PipelineElements[0] $vars)
      }
      return $null
    }
    if ($node -is [System.Management.Automation.Language.ParenExpressionAst]) {
      return (Resolve-Expr $node.Pipeline $vars)
    }
    if ($node -is [System.Management.Automation.Language.SubExpressionAst]) {
      if ($node.SubExpression.Statements.Count -eq 1) {
        return (Resolve-Expr $node.SubExpression.Statements[0] $vars)
      }
      return $null
    }
    if ($node -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
      return $node.Value
    }
    if ($node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
      if ($node.NestedExpressions.Count -eq 0) { return $node.Value }
      $text = $node.Value
      foreach ($nested in $node.NestedExpressions) {
        $resolved = Resolve-Expr $nested $vars
        if ($null -ne $resolved) {
          $text = $text.Replace($nested.Extent.Text, $resolved)
        }
      }
      return $text
    }
    if ($node -is [System.Management.Automation.Language.VariableExpressionAst]) {
      $vp = $node.VariablePath
      if ($vp.DriveName -ieq 'env') {
        $envName = $vp.UserPath -replace '^(?i)env:', ''
        return ('$env:' + $envName)
      }
      $clean = (Strip-Scope $vp.UserPath).ToLowerInvariant()
      if ($clean -eq 'home') { return '$HOME' }
      if ($vars.ContainsKey($clean)) { return $vars[$clean] }
      return $null
    }
    if ($node -is [System.Management.Automation.Language.BinaryExpressionAst]) {
      if ($node.Operator -eq [System.Management.Automation.Language.TokenKind]::Plus) {
        $l = Resolve-Expr $node.Left $vars
        $r = Resolve-Expr $node.Right $vars
        if ($null -ne $l -and $null -ne $r) { return ($l + $r) }
      }
      return $null
    }
    if ($node -is [System.Management.Automation.Language.CommandAst]) {
      $cname = $node.GetCommandName()
      if ($cname -ieq 'Join-Path') {
        $parts = [System.Collections.Generic.List[string]]::new()
        for ($i = 1; $i -lt $node.CommandElements.Count; $i++) {
          $el = $node.CommandElements[$i]
          if ($el -is [System.Management.Automation.Language.CommandParameterAst]) {
            if ($null -ne $el.Argument) {
              $rv = Resolve-Expr $el.Argument $vars
              if ($null -ne $rv) { $parts.Add($rv) }
            }
            continue
          }
          $rv = Resolve-Expr $el $vars
          if ($null -eq $rv) { return $null }
          $parts.Add($rv)
        }
        if ($parts.Count -gt 0) {
          return (($parts | ForEach-Object { $_.TrimEnd('/', '\\') }) -join '/')
        }
      }
      return $null
    }
    return $null
  }

  function Extract-Facts([string]$code) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$tokens, [ref]$errors)

    $parseErrors = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $errors) {
      foreach ($e in $errors) { $parseErrors.Add([string]$e.Message) }
    }

    $vars = @{}
    $assignments = [System.Collections.Generic.List[object]]::new()
    $assignNodes = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) | Sort-Object { $_.Extent.StartOffset }

    foreach ($a in $assignNodes) {
      $rhsResolved = Resolve-Expr $a.Right $vars
      $rhsText = if ($null -ne $rhsResolved) { $rhsResolved } else { $a.Right.Extent.Text }
      $lhsVars = $a.Left.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)
      foreach ($v in $lhsVars) {
        $vp = $v.VariablePath
        $clean = Strip-Scope $vp.UserPath
        $lower = $clean.ToLowerInvariant()
        $assignments.Add(@{
          name = $clean
          raw = $vp.UserPath
          drive = $vp.DriveName
          rhs = $rhsText
          resolved_rhs = $rhsResolved
        })
        if ($null -eq $vp.DriveName -and $null -ne $rhsResolved -and $lower -ne 'home') {
          $vars[$lower] = $rhsResolved
        }
      }
    }

    $commands = [System.Collections.Generic.List[object]]::new()
    $cmdNodes = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | Sort-Object { $_.Extent.StartOffset }

    foreach ($c in $cmdNodes) {
      $cname = $c.GetCommandName()
      $params = [System.Collections.Generic.List[string]]::new()
      $resolvedArgs = [System.Collections.Generic.List[string]]::new()
      $rawArgs = [System.Collections.Generic.List[string]]::new()

      for ($i = 1; $i -lt $c.CommandElements.Count; $i++) {
        $el = $c.CommandElements[$i]
        if ($el -is [System.Management.Automation.Language.CommandParameterAst]) {
          $params.Add([string]$el.ParameterName)
          if ($null -ne $el.Argument) {
            $rv = Resolve-Expr $el.Argument $vars
            if ($null -ne $rv) { $resolvedArgs.Add([string]$rv) }
            $rawArgs.Add([string]$el.Argument.Extent.Text)
          }
        } else {
          $rv = Resolve-Expr $el $vars
          if ($null -ne $rv) { $resolvedArgs.Add([string]$rv) }
          $rawArgs.Add([string]$el.Extent.Text)
        }
      }

      $commands.Add(@{
        name = $cname
        dynamic = ($null -eq $cname)
        operator = $c.InvocationOperator.ToString()
        params = $params.ToArray()
        args = $resolvedArgs.ToArray()
        raw_args = $rawArgs.ToArray()
      })
    }

    $pipelines = [System.Collections.Generic.List[object]]::new()
    $pipeNodes = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.PipelineAst] }, $true)
    foreach ($p in $pipeNodes) {
      if ($p.PipelineElements.Count -ge 2) {
        $stageNames = [System.Collections.Generic.List[string]]::new()
        foreach ($el in $p.PipelineElements) {
          if ($el -is [System.Management.Automation.Language.CommandAst]) {
            $n = $el.GetCommandName()
            $stageNames.Add($(if ($null -ne $n) { $n } else { '<dynamic>' }))
          } else {
            $stageNames.Add('<expr>')
          }
        }
        $pipelines.Add($stageNames.ToArray())
      }
    }

    $memberCalls = [System.Collections.Generic.List[object]]::new()
    $memberNodes = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)
    foreach ($m in $memberNodes) {
      $targetText = $m.Expression.Extent.Text.Trim('[', ']')
      $memberName = if ($m.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        $m.Member.Value
      } else {
        '<dynamic>'
      }
      $mArgs = [System.Collections.Generic.List[string]]::new()
      if ($null -ne $m.Arguments) {
        foreach ($arg in $m.Arguments) {
          $rv = Resolve-Expr $arg $vars
          if ($null -ne $rv) { $mArgs.Add([string]$rv) } else { $mArgs.Add([string]$arg.Extent.Text) }
        }
      }
      $memberCalls.Add(@{
        target = $targetText
        member = $memberName
        static = [bool]$m.Static
        args = $mArgs.ToArray()
      })
    }

    $redirections = [System.Collections.Generic.List[string]]::new()
    $redirNodes = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FileRedirectionAst] }, $true)
    foreach ($r in $redirNodes) {
      $rv = Resolve-Expr $r.Location $vars
      if ($null -ne $rv) { $redirections.Add([string]$rv) } else { $redirections.Add([string]$r.Location.Extent.Text) }
    }

    return @{
      ok = $true
      parse_errors = $parseErrors.ToArray()
      assignments = $assignments.ToArray()
      commands = $commands.ToArray()
      pipelines = $pipelines.ToArray()
      member_calls = $memberCalls.ToArray()
      redirections = $redirections.ToArray()
    }
  }

  while ($null -ne ($line = [Console]::In.ReadLine())) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
      $bytes = [Convert]::FromBase64String($line.Trim())
      $code = [Text.Encoding]::UTF8.GetString($bytes)
      $facts = Extract-Facts $code
      $json = ConvertTo-Json -InputObject $facts -Depth 8 -Compress
      [Console]::Out.WriteLine($json)
      [Console]::Out.Flush()
    } catch {
      $errObj = @{ ok = $false; error = [string]$_.Exception.Message }
      $json = ConvertTo-Json -InputObject $errObj -Depth 4 -Compress
      [Console]::Out.WriteLine($json)
      [Console]::Out.Flush()
    }
  }
  """

  @doc "Child options for `Noctilucent.Policy.Ast.Worker` in `Noctilucent.Supervisor`."
  @spec worker_opts() :: keyword()
  def worker_opts do
    [
      id: @worker_name,
      name: @worker_name,
      command_builder: &__MODULE__.command_spec/0,
      timeout_ms: 5_000,
      startup_timeout_ms: 12_000
    ]
  end

  @doc "Locate `pwsh` or `powershell` and return a read-only AST worker command spec."
  @spec command_spec() :: {:ok, Worker.command_spec()} | {:error, String.t()}
  def command_spec do
    case find_powershell() do
      nil ->
        {:error, "neither pwsh nor powershell found on PATH"}

      exe ->
        {:ok,
         %{
           exe: exe,
           args: ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", :script],
           script_name: "ps_ast_worker.ps1",
           script_content: @extractor_script
         }}
    end
  end

  @doc "Whether a PowerShell executable (`pwsh` or `powershell`) is available on PATH."
  @spec available?() :: boolean()
  def available?, do: not is_nil(find_powershell())

  @doc """
  Parse PowerShell `code` via the persistent AST worker and evaluate static risk.

  Returns `{:ok, assessment}` when AST parsing succeeded, or `{:error, reason}`
  when the PowerShell executable or worker is unavailable (allowing callers to
  fail closed to regex + `:ask`).
  """
  @spec inspect(String.t(), keyword() | map()) :: {:ok, map()} | {:error, String.t()}
  def inspect(code, opts \\ []) when is_binary(code) do
    worker = Access.get(opts, :worker, @worker_name)

    with {:ok, %{"ok" => true} = facts} <- Worker.parse(worker, code) do
      {:ok, analyze_facts(facts, opts)}
    else
      {:ok, %{"ok" => false, "error" => err}} -> {:error, "PowerShell AST error: #{err}"}
      {:ok, other} -> {:error, "unexpected PowerShell AST payload: #{Kernel.inspect(other)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Pure-Elixir risk classification over JSON facts produced by the PowerShell
  AST extractor. Exposed publicly for deterministic unit testing.
  """
  @spec analyze_facts(map(), keyword() | map()) :: map()
  def analyze_facts(facts, opts \\ []) when is_map(facts) do
    protected_dirs = opts |> Access.get(:protected_dirs, []) |> List.wrap()

    acc = %{deny: [], ask: [], protected_dirs: protected_dirs}

    acc =
      acc
      |> check_parse_errors(facts)
      |> check_assignments(facts)
      |> check_commands(facts)
      |> check_pipelines(facts)
      |> check_member_calls(facts)
      |> check_redirections(facts)

    finalize(acc)
  end

  ## Pure Elixir analysis of PowerShell AST facts

  defp check_parse_errors(acc, facts) do
    case list_field(facts, "parse_errors") do
      [] -> acc
      _errors -> add_ask(acc, "PowerShell syntax error; cannot statically analyze AST")
    end
  end

  defp check_assignments(acc, facts) do
    Enum.reduce(list_field(facts, "assignments"), acc, fn assign, acc ->
      name = assign |> Map.get("name", "") |> to_string() |> String.downcase()
      drive = Map.get(assign, "drive")
      rhs = assign |> Map.get("rhs", "") |> to_string() |> String.trim() |> String.downcase()

      cond do
        is_nil(drive) and MapSet.member?(@readonly_auto_vars, name) ->
          add_deny(
            acc,
            "assigning to PowerShell read-only automatic variable ($home/$pid/...) fails and can corrupt subsequent paths"
          )

        is_nil(drive) and name == "erroractionpreference" and
            rhs in [
              "continue",
              "silentlycontinue",
              "ignore",
              "'continue'",
              "'silentlycontinue'",
              "'ignore'",
              "\"continue\"",
              "\"silentlycontinue\"",
              "\"ignore\""
            ] ->
          add_ask(acc, "modifies PowerShell ErrorActionPreference safety preamble")

        true ->
          acc
      end
    end)
  end

  defp check_commands(acc, facts) do
    Enum.reduce(list_field(facts, "commands"), acc, fn cmd, acc ->
      raw_name = Map.get(cmd, "name")
      name = if is_binary(raw_name), do: String.downcase(raw_name), else: nil
      dynamic? = Map.get(cmd, "dynamic") == true
      params = cmd |> list_field("params") |> Enum.map(&(to_string(&1) |> String.downcase()))
      args = cmd |> list_field("args") |> Enum.map(&to_string/1)
      raw_args = cmd |> list_field("raw_args") |> Enum.map(&to_string/1)
      all_args = Enum.uniq(args ++ raw_args)

      acc
      |> check_dynamic_command(dynamic?, name, params)
      |> check_set_variable_cmd(name, all_args)
      |> check_strict_mode_cmd(name, params)
      |> check_destructive_cmd(name, params, all_args)
      |> check_disk_cmd(name, all_args)
      |> check_network_cmd(name, all_args)
      |> check_git_cmd(name, all_args)
      |> check_priv_and_registry_cmd(name, all_args)
    end)
  end

  defp check_dynamic_command(acc, true, _name, _params) do
    add_ask(acc, "dynamic expression evaluation or encoded command")
  end

  defp check_dynamic_command(acc, false, name, params) do
    cond do
      name in MapSet.to_list(@dynamic_exec_cmds) ->
        add_ask(acc, "dynamic expression evaluation or encoded command")

      name in ["pwsh", "pwsh.exe", "powershell", "powershell.exe"] and
          Enum.any?(params, &(&1 in ["encodedcommand", "enc", "e", "ec"])) ->
        add_ask(acc, "dynamic expression evaluation or encoded command")

      true ->
        acc
    end
  end

  defp check_set_variable_cmd(acc, name, args) do
    if is_binary(name) and MapSet.member?(@set_var_cmds, name) do
      targets_readonly? =
        Enum.any?(args, fn arg ->
          clean =
            arg |> String.trim() |> String.trim("'") |> String.trim("\"") |> String.downcase()

          MapSet.member?(@readonly_auto_vars, clean)
        end)

      if targets_readonly? do
        add_deny(
          acc,
          "assigning to PowerShell read-only automatic variable ($home/$pid/...) fails and can corrupt subsequent paths"
        )
      else
        acc
      end
    else
      acc
    end
  end

  defp check_strict_mode_cmd(acc, "set-strictmode", params) do
    if "off" in params do
      add_ask(acc, "modifies PowerShell StrictMode safety preamble")
    else
      acc
    end
  end

  defp check_strict_mode_cmd(acc, _name, _params), do: acc

  defp check_destructive_cmd(acc, name, params, args) do
    if is_binary(name) and MapSet.member?(@destructive_cmds, name) do
      acc =
        cond do
          Enum.any?(args, &TargetRules.credential_target?/1) ->
            add_deny(
              acc,
              "destructive or network operation referencing sensitive user/credential directory"
            )

          Enum.any?(args, &TargetRules.dangerous_target?(&1, acc.protected_dirs)) ->
            add_deny(
              acc,
              "destructive command targets a filesystem root, OS directory, user home, or protected directory"
            )

          true ->
            acc
        end

      recursive_or_force? =
        MapSet.member?(@delete_cmds, name) and
          (Enum.any?(params, fn p ->
             String.starts_with?("recurse", p) or String.starts_with?("force", p) or
               p in ["r", "rf", "fr", "f", "s", "q"]
           end) or
             Enum.any?(args, fn a -> String.downcase(a) in ["/s", "/q", "/f"] end))

      if recursive_or_force? do
        add_ask(acc, "recursive or forced file deletion")
      else
        acc
      end
    else
      acc
    end
  end

  defp check_disk_cmd(acc, name, args) do
    cond do
      is_binary(name) and MapSet.member?(@disk_cmds, name) ->
        add_deny(acc, "destructive disk or partition formatting command")

      name == "format" and Enum.any?(args, &Regex.match?(~r/\A[A-Za-z]:\z/, String.trim(&1))) ->
        add_deny(acc, "destructive disk or partition formatting command")

      name == "cipher" and Enum.any?(args, &String.starts_with?(String.downcase(&1), "/w:")) ->
        add_deny(acc, "destructive disk or partition formatting command")

      true ->
        acc
    end
  end

  defp check_network_cmd(acc, name, args) do
    pkg_install? =
      case {name, args} do
        {"mix", ["deps.get" | _]} -> true
        {"npm", [sub | _]} when sub in ["install", "i", "add"] -> true
        {"pnpm", [sub | _]} when sub in ["install", "i", "add"] -> true
        {"pip", ["install" | _]} -> true
        {"pip3", ["install" | _]} -> true
        {"cargo", ["install" | _]} -> true
        {"scoop", ["install" | _]} -> true
        {"winget", ["install" | _]} -> true
        {"choco", ["install" | _]} -> true
        _ -> false
      end

    is_net? = (is_binary(name) and MapSet.member?(@network_cmds, name)) or pkg_install?

    if is_net? do
      acc = add_ask(acc, "network access or package installation")

      if Enum.any?(args, &TargetRules.credential_target?/1) do
        add_deny(
          acc,
          "destructive or network operation referencing sensitive user/credential directory"
        )
      else
        acc
      end
    else
      acc
    end
  end

  defp check_git_cmd(acc, "git", args) do
    joined = args |> Enum.join(" ") |> String.downcase()

    if Regex.match?(
         ~r/\A(?:reset\s+--hard|clean\s+-[^\n]*f|push\s+(?:--force|-f)\b|checkout\s+--\s+\.)/,
         joined
       ) do
      add_ask(acc, "destructive git operation")
    else
      acc
    end
  end

  defp check_git_cmd(acc, _name, _args), do: acc

  defp check_priv_and_registry_cmd(acc, name, args) do
    cond do
      is_binary(name) and MapSet.member?(@priv_proc_cmds, name) ->
        add_ask(acc, "privileged, process, service, or registry operation")

      name == "reg" and Enum.any?(args, &(String.downcase(&1) in ["add", "delete", "import"])) ->
        add_ask(acc, "privileged, process, service, or registry operation")

      is_binary(name) and MapSet.member?(@registry_write_cmds, name) and
          Enum.any?(args, &Regex.match?(~r/\Ahk(?:lm|cu):/i, String.trim(&1))) ->
        add_ask(acc, "privileged, process, service, or registry operation")

      true ->
        acc
    end
  end

  defp check_pipelines(acc, facts) do
    Enum.reduce(list_field(facts, "pipelines"), acc, fn stages, acc ->
      names =
        stages
        |> List.wrap()
        |> Enum.map(&(to_string(&1) |> String.downcase()))

      has_download? = Enum.any?(names, &MapSet.member?(@network_download_cmds, &1))
      has_exec? = Enum.any?(names, &MapSet.member?(@shell_exec_cmds, &1))

      if has_download? and has_exec? do
        add_deny(acc, "piping remote content directly into a shell/interpreter")
      else
        acc
      end
    end)
  end

  defp check_member_calls(acc, facts) do
    Enum.reduce(list_field(facts, "member_calls"), acc, fn call, acc ->
      target = call |> Map.get("target", "") |> to_string() |> String.downcase()
      member = call |> Map.get("member", "") |> to_string() |> String.downcase()
      args = call |> list_field("args") |> Enum.map(&to_string/1)

      acc =
        if MapSet.member?(@destructive_dotnet_types, target) and
             MapSet.member?(@destructive_dotnet_members, member) do
          acc =
            cond do
              Enum.any?(args, &TargetRules.credential_target?/1) ->
                add_deny(
                  acc,
                  "destructive or network operation referencing sensitive user/credential directory"
                )

              Enum.any?(args, &TargetRules.dangerous_target?(&1, acc.protected_dirs)) ->
                add_deny(
                  acc,
                  "destructive .NET filesystem call targets a protected root, OS dir, or user home"
                )

              true ->
                acc
            end

          add_ask(acc, "recursive or forced file deletion")
        else
          acc
        end

      acc =
        if MapSet.member?(@network_dotnet_types, target) do
          add_ask(acc, "network access or package installation")
        else
          acc
        end

      if MapSet.member?(@dynamic_dotnet_calls, {target, member}) or member == "<dynamic>" do
        add_ask(acc, "dynamic expression evaluation or encoded command")
      else
        acc
      end
    end)
  end

  defp check_redirections(acc, facts) do
    Enum.reduce(list_field(facts, "redirections"), acc, fn target, acc ->
      target = to_string(target)

      cond do
        TargetRules.credential_target?(target) ->
          add_deny(
            acc,
            "destructive or network operation referencing sensitive user/credential directory"
          )

        TargetRules.dangerous_target?(target, acc.protected_dirs) ->
          add_deny(acc, "file redirection targets a protected host or user path")

        true ->
          acc
      end
    end)
  end

  defp find_powershell do
    System.find_executable("pwsh") || System.find_executable("powershell")
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
        %{verdict: :deny, risk: :critical, reasons: deny, analyzer: :ast_powershell}

      ask != [] ->
        %{verdict: :ask, risk: :high, reasons: ask, analyzer: :ast_powershell}

      true ->
        %{verdict: :ok, risk: :low, reasons: [], analyzer: :ast_powershell}
    end
  end
end

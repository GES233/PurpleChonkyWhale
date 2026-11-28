defmodule Noctilucent.Policy.ShellLint do
  @moduledoc """
  Static risk inspection for `execute` calls before they run or prompt.

  Dispatches by `runtime` so languages with built-in parsers are inspected
  structurally via AST rather than flat regex:

    * `"elixir"` / `"elixir_subprocess"` — `Noctilucent.Policy.Ast.Elixir`
      (native `Code.string_to_quoted/2` inside BEAM).
    * `"powershell"` — `Noctilucent.Policy.Ast.PowerShell` (.NET
      `Parser::ParseInput` via a lazy read-only Port worker, failing closed to
      regex + `:ask` if unavailable).
    * `"python"` — `Noctilucent.Policy.Ast.Python` (stdlib `ast.parse` via a
      lazy read-only Port worker, failing closed to regex + `:ask` if
      unavailable).
    * `"shell"` (and any other runtime) — static regex rules below.

  Classifies an `execute` call into one of three verdicts:

    * `:deny` (`:critical`) — catastrophic or self-destructive patterns that must
      never run and cannot be approved via leases or prompts (e.g. assigning
      PowerShell read-only automatic variables like `$home`, recursive wipes of
      drive roots / `$HOME` / `protected_dirs`, disk formatters, fork bombs,
      pipe-to-shell downloads, or credential-store destruction).
    * `:ask` (`:high`) — elevated-risk operations (workspace recursive deletes,
      `git reset --hard` / `push --force`, network requests / package installs,
      dynamic eval / encoded commands, process/registry edits, or in-process
      `"elixir"` evaluation). These bypass standing TTL leases and always
      require explicit one-shot confirmation.
    * `:ok` (`:low`) — ordinary commands governed by standard capability policy
      and active TTL leases.
  """

  alias Noctilucent.Policy.Ast.Elixir, as: ElixirAst
  alias Noctilucent.Policy.Ast.{PowerShell, Python}

  @type verdict :: :ok | :ask | :deny
  @type risk :: :low | :high | :critical
  @type analyzer :: :ast_elixir | :ast_powershell | :ast_python | :regex | :regex_fallback
  @type assessment :: %{
          verdict: verdict(),
          risk: risk(),
          reasons: [String.t()],
          analyzer: analyzer()
        }

  @destructive_verb_re ~r/\b(?:rm|rmdir|rd|del|erase|Remove-Item|ri|Clear-Content|Move-Item|File\.rm_rf|File\.rm|shutil\.rmtree|os\.remove|os\.unlink)\b/i
  @exfil_verb_re ~r/\b(?:curl|wget|Invoke-WebRequest|Invoke-RestMethod|iwr|irm|nc|ncat|scp)\b/i

  @sensitive_home_subdirs ~w(
    Desktop Documents Downloads Pictures Music Videos OneDrive
    .ssh .gnupg .aws .kube .dsh .pcw
  )

  @doc "Inspect a tool call's arguments and environment for static command risk."
  @spec inspect(map(), keyword() | map()) :: assessment()
  def inspect(args, opts \\ [])

  def inspect(%{"code" => code} = args, opts) when is_binary(code) do
    runtime = Map.get(args, "runtime", "shell")

    case runtime do
      rt when rt in ["elixir", "elixir_subprocess"] ->
        ElixirAst.inspect(code, rt, opts)

      "powershell" ->
        case PowerShell.inspect(code, opts) do
          {:ok, assessment} ->
            assessment

          {:error, _reason} ->
            regex_fallback(
              code,
              runtime,
              opts,
              "PowerShell AST parser unavailable; fell back to static regex"
            )
        end

      "python" ->
        case Python.inspect(code, opts) do
          {:ok, assessment} ->
            assessment

          {:error, _reason} ->
            regex_fallback(
              code,
              runtime,
              opts,
              "Python AST parser unavailable; fell back to static regex"
            )
        end

      _other ->
        inspect_regex(code, runtime, opts, :regex)
    end
  end

  def inspect(_args, _opts), do: %{verdict: :ok, risk: :low, reasons: [], analyzer: :regex}

  @doc """
  Inspect a raw shell command string using the regex ruleset (used directly for
  `"shell"` calls and recursively by AST analyzers for embedded shell commands
  passed to `System.cmd/2` or `subprocess.run/1`).
  """
  @spec inspect_shell_text(String.t(), keyword() | map()) :: assessment()
  def inspect_shell_text(code, opts \\ []) when is_binary(code) do
    inspect_regex(code, "shell", opts, :regex)
  end

  defp regex_fallback(code, runtime, opts, fallback_note) do
    base = inspect_regex(code, runtime, opts, :regex_fallback)

    case base.verdict do
      :deny ->
        base

      :ask ->
        %{base | reasons: Enum.uniq(base.reasons ++ [fallback_note])}

      :ok ->
        %{
          verdict: :ask,
          risk: :high,
          reasons: [fallback_note],
          analyzer: :regex_fallback
        }
    end
  end

  defp inspect_regex(code, runtime, opts, analyzer) do
    protected_dirs = opts |> Access.get(:protected_dirs, []) |> List.wrap()
    deny_reasons = deny_reasons(code, runtime, protected_dirs)

    if deny_reasons != [] do
      %{verdict: :deny, risk: :critical, reasons: Enum.uniq(deny_reasons), analyzer: analyzer}
    else
      ask_reasons = ask_reasons(code, runtime)

      if ask_reasons != [] do
        %{verdict: :ask, risk: :high, reasons: Enum.uniq(ask_reasons), analyzer: analyzer}
      else
        %{verdict: :ok, risk: :low, reasons: [], analyzer: analyzer}
      end
    end
  end

  ## Hard-deny rules (unconditional floor)

  defp deny_reasons(code, runtime, protected_dirs) do
    []
    |> check_ps_readonly_vars(code, runtime)
    |> check_root_or_home_wipe(code)
    |> check_disk_or_forkbomb(code)
    |> check_pipe_to_shell(code)
    |> check_sensitive_targets(code, protected_dirs)
    |> Enum.reverse()
  end

  defp check_ps_readonly_vars(reasons, code, runtime) do
    ps? = runtime == "powershell" or Regex.match?(~r/\b(?:pwsh|powershell)\b/i, code)

    assign_re =
      ~r/(?<![\w$`])\$(?:home|pid|pshome|host|shellid|null|true|false)\s*[+\-*\/%]?=/i

    set_var_re =
      ~r/\bSet-Variable\b[^\n]*(?:-Name\s+)?['"]?(?:home|pid|pshome|host|shellid|null|true|false)\b/i

    if ps? and (Regex.match?(assign_re, code) or Regex.match?(set_var_re, code)) do
      [
        "assigning to PowerShell read-only automatic variable ($home/$pid/...) fails and can corrupt subsequent paths"
        | reasons
      ]
    else
      reasons
    end
  end

  defp check_root_or_home_wipe(reasons, code) do
    posix_wipe_re =
      ~r/\brm\b[^\n;|&]*(?:-[^\s]*[rRf][^\s]*|--recursive|--force)[^\n;|&]*\s+(?:\/\*?|~\/?|\$HOME\/?|"\$HOME\/?"|\$\{HOME\}\/?)(?:\s|$|[;&|])/i

    win_wipe_re =
      ~r/\b(?:Remove-Item|ri|rmdir|rd|del|erase)\b[^\n;|&]*(?:[A-Za-z]:[\\\/](?:\*|\s|$|[;&|])|\$env:(?:USERPROFILE|HOME|SystemRoot|ProgramFiles|ProgramData|APPDATA)\b|%USERPROFILE%|%SystemRoot%|%APPDATA%|(?<![\w$])\$HOME(?![\w$])|(?<!\S)~(?:[\\\/]|\s|$|[;&|]))/i

    if Regex.match?(posix_wipe_re, code) or Regex.match?(win_wipe_re, code) do
      ["destructive command targets a filesystem root, OS directory, or user home" | reasons]
    else
      reasons
    end
  end

  defp check_disk_or_forkbomb(reasons, code) do
    disk_re =
      ~r/\b(?:mkfs(?:\.[a-z0-9]+)?|diskpart|fdisk)\b|\bdd\b[^\n]*\bof=\/dev\/|\bformat\s+[A-Za-z]:|\bcipher\s+\/w:/i

    fork_bomb_re = ~r/:\(\)\s*\{\s*:\|:\s*&\s*\}\s*;\s*:/

    reasons =
      if Regex.match?(disk_re, code) do
        ["destructive disk or partition formatting command" | reasons]
      else
        reasons
      end

    if Regex.match?(fork_bomb_re, code) do
      ["fork bomb pattern detected" | reasons]
    else
      reasons
    end
  end

  defp check_pipe_to_shell(reasons, code) do
    sh_pipe = ~r/\b(?:curl|wget)\b[^\n|]*\|\s*(?:sudo\s+)?(?:ba|z|k|da)?sh\b/i

    ps_pipe =
      ~r/\b(?:iwr|Invoke-WebRequest|irm|Invoke-RestMethod)\b[^\n|]*\|\s*(?:iex|Invoke-Expression)\b/i

    if Regex.match?(sh_pipe, code) or Regex.match?(ps_pipe, code) do
      ["piping remote content directly into a shell/interpreter" | reasons]
    else
      reasons
    end
  end

  defp check_sensitive_targets(reasons, code, protected_dirs) do
    destructive? = Regex.match?(@destructive_verb_re, code)
    exfil? = Regex.match?(@exfil_verb_re, code)

    reasons =
      if (destructive? or exfil?) and mentions_credential_dir?(code) do
        [
          "destructive or network operation referencing sensitive user/credential directory"
          | reasons
        ]
      else
        reasons
      end

    reasons =
      if destructive? and mentions_protected_dir?(code, protected_dirs) do
        ["destructive operation referencing protected directory" | reasons]
      else
        reasons
      end

    if destructive? and mentions_exact_user_home?(code) do
      ["destructive operation targeting user home directory" | reasons]
    else
      reasons
    end
  end

  defp mentions_credential_dir?(code) do
    Regex.match?(
      ~r/(?:~\/|[\\\/]|%USERPROFILE%[\\\/]|\$env:USERPROFILE[\\\/]|\$HOME[\\\/])(?:\.ssh|\.gnupg|\.aws|\.kube|\.dsh|\.pcw)(?:\b|[\\\/]|$)/i,
      code
    )
  end

  defp mentions_protected_dir?(code, protected_dirs) do
    normalized_code = normalize_for_match(code)

    Enum.any?(protected_dirs, fn dir ->
      is_binary(dir) and dir != "" and
        Regex.match?(
          ~r/(?:^|[\s"'=])#{Regex.escape(normalize_for_match(dir))}(?:[\/\\\s"'*]|$)/i,
          normalized_code
        )
    end)
  end

  defp mentions_exact_user_home?(code) do
    case System.user_home() do
      nil ->
        false

      home ->
        norm_home = normalize_for_match(home)
        norm_code = normalize_for_match(code)
        escaped = Regex.escape(norm_home)

        exact_home? =
          Regex.match?(~r/(?:^|[\s"'=])#{escaped}(?:\/?\*|\/?(?:[\s"';&|]|$))/i, norm_code)

        sensitive_sub? =
          Enum.any?(@sensitive_home_subdirs, fn sub ->
            sub_re = Regex.escape(norm_home <> "/" <> String.downcase(sub))
            Regex.match?(~r/(?:^|[\s"'=])#{sub_re}(?:[\/\s"';&|*]|$)/i, norm_code)
          end)

        exact_home? or sensitive_sub?
    end
  end

  defp normalize_for_match(text) do
    text |> String.replace("\\", "/") |> String.downcase()
  end

  ## High-risk rules (always escalate to one-shot approval)

  defp ask_reasons(code, runtime) do
    checks = [
      {runtime == "elixir", "in-process Elixir runtime evaluates inside the agent BEAM"},
      {Regex.match?(
         ~r/\brm\b[^\n;|&]*(?:-[^\s]*[rRf][^\s]*|--recursive|--force)|\bRemove-Item\b[^\n;|&]*(?:-Recurse|-Force)|\brmdir\b[^\n;|&]*\/s|\bdel\b[^\n;|&]*\/[sqf]|\b(?:File\.rm_rf|shutil\.rmtree)\b/i,
         code
       ), "recursive or forced file deletion"},
      {Regex.match?(
         ~r/\bgit\s+(?:reset\s+--hard|clean\s+-[^\n]*f|push\s+(?:--force|-f)\b|checkout\s+--\s+\.)/i,
         code
       ), "destructive git operation"},
      {Regex.match?(~r/\b(?:chmod\s+-R|chown\s+-R|icacls|takeown)\b/i, code),
       "recursive permission or ownership change"},
      {Regex.match?(
         ~r/\b(?:curl|wget|Invoke-WebRequest|Invoke-RestMethod|iwr|irm|ssh|scp|rsync|nc|ncat|mix\s+deps\.get|npm\s+install|pnpm\s+(?:add|install)|pip\s+install|cargo\s+install)\b/i,
         code
       ), "network access or package installation"},
      {Regex.match?(
         ~r/\b(?:Invoke-Expression|iex)\b|\b(?:pwsh|powershell)\b[^\n]*(?:-EncodedCommand|-enc)\b|\beval\s+/i,
         code
       ), "dynamic expression evaluation or encoded command"},
      {Regex.match?(
         ~r/\b(?:sudo|runas|Stop-Process|taskkill|systemctl|sc\.exe)\b|\breg\s+(?:add|delete|import)\b|HK(?:LM|CU):/i,
         code
       ), "privileged, process, service, or registry operation"}
    ]

    for {true, reason} <- checks, do: reason
  end
end

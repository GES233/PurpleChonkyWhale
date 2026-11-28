defmodule Noctilucent.Policy.TargetRules do
  @moduledoc """
  Shared target-path classification for `Noctilucent.Policy` static analyzers
  (`ShellLint` and the Elixir / PowerShell / Python AST inspectors).

  Identifies filesystem roots, OS system directories, the host user's home
  directory and sensitive subdirectories/dotfiles, credential stores, and
  composition-configured `:protected_dirs` without falsely flagging ephemeral
  temp directories under `System.tmp_dir!/0`.
  """

  @sensitive_home_subdirs ~w(
    Desktop Documents Downloads Pictures Music Videos OneDrive
    .ssh .gnupg .aws .kube .dsh .pcw
  )

  @credential_dirs ~w(.ssh .gnupg .aws .kube .dsh .pcw)

  @sensitive_home_files ~w(
    .gitconfig .netrc .bashrc .bash_profile .zshrc .zprofile .profile
  )

  @protected_env_vars ~w[
    USERPROFILE HOME SYSTEMROOT WINDIR PROGRAMFILES PROGRAMFILES(X86)
    PROGRAMW6432 PROGRAMDATA APPDATA
  ]

  @posix_system_dirs ~w(/etc /usr /bin /sbin /System /Library)

  @doc "Sensitive subdirectories directly under the user home directory."
  @spec sensitive_home_subdirs() :: [String.t()]
  def sensitive_home_subdirs, do: @sensitive_home_subdirs

  @doc "Credential and harness state directories."
  @spec credential_dirs() :: [String.t()]
  def credential_dirs, do: @credential_dirs

  @doc "Environment variable names that resolve to protected host/user roots."
  @spec protected_env_vars() :: [String.t()]
  def protected_env_vars, do: @protected_env_vars

  @doc "Whether `var_name` (case-insensitive) names a protected host/user root env var."
  @spec protected_env_var?(term()) :: boolean()
  def protected_env_var?(var_name) when is_binary(var_name) do
    String.upcase(String.trim(var_name)) in @protected_env_vars
  end

  def protected_env_var?(_), do: false

  @doc """
  Whether `target` (a path string or symbolic home/env expression extracted from
  an AST) refers to a filesystem root, OS system dir, user home or sensitive
  home subpath, or one of `protected_dirs`.
  """
  @spec dangerous_target?(term(), [String.t()]) :: boolean()
  def dangerous_target?(target, protected_dirs \\ [])

  def dangerous_target?(target, protected_dirs) when is_binary(target) do
    trimmed = target |> String.trim() |> strip_quotes()

    if trimmed == "" do
      false
    else
      norm = normalize(trimmed)

      root_path?(norm) or
        symbolic_home_or_env?(trimmed, norm) or
        system_dir?(norm) or
        user_home_target?(norm) or
        protected_dir_target?(norm, protected_dirs)
    end
  end

  def dangerous_target?(_other, _protected_dirs), do: false

  @doc """
  Whether `target` references a credential/harness store (`.ssh`, `.gnupg`,
  `.aws`, `.kube`, `.dsh`, `.pcw`).
  """
  @spec credential_target?(term()) :: boolean()
  def credential_target?(target) when is_binary(target) do
    norm = target |> String.trim() |> strip_quotes() |> normalize()

    Regex.match?(
      ~r/(?:^|\/|~\/|\$home\/|\$env:userprofile\/|%userprofile%\/|<user_home>\/)(?:\.ssh|\.gnupg|\.aws|\.kube|\.dsh|\.pcw)(?:\/|\*|$)/,
      norm
    )
  end

  def credential_target?(_other), do: false

  @doc "Normalize slashes and lowercase for cross-platform static matching."
  @spec normalize(String.t()) :: String.t()
  def normalize(path) when is_binary(path) do
    path
    |> strip_win_extended_prefix()
    |> String.replace("\\", "/")
    |> String.downcase()
    |> collapse_slashes()
  end

  ## Predicates

  defp root_path?(norm) do
    norm in ["/", "/*"] or Regex.match?(~r/\A[a-z]:\/?\*?\z/, norm)
  end

  defp symbolic_home_or_env?(raw, norm) do
    # Exact symbolic home/env expressions (or wildcards directly on them)
    exact_symbolic? =
      norm in [
        "~",
        "~/",
        "~/*",
        "$home",
        "$home/",
        "$home/*",
        "${home}",
        "${home}/",
        "${home}/*",
        "<user_home>",
        "<user_home>/",
        "<user_home>/*",
        "$env:userprofile",
        "$env:userprofile/",
        "$env:userprofile/*",
        "%userprofile%",
        "%userprofile%/",
        "%userprofile%/*"
      ]

    protected_env_expr? =
      Regex.match?(
        ~r/\A(?:\$env:|%)?(?:systemroot|windir|programfiles(?:\(x86\))?|programw6432|programdata|appdata)%?(?:\/.*)?\z/i,
        norm
      ) or
        Regex.match?(~r/\A<protected_env:[^>]+>(?:\/.*)?\z/i, norm)

    symbolic_sensitive_sub? =
      Enum.any?(
        ["~", "$home", "${home}", "$env:userprofile", "%userprofile%", "<user_home>"],
        fn p ->
          sensitive_child_of?(norm, p)
        end
      )

    exact_symbolic? or protected_env_expr? or symbolic_sensitive_sub? or
      String.starts_with?(String.downcase(String.trim(raw)), "<dangerous:")
  end

  defp system_dir?(norm) do
    win_dirs =
      [
        System.get_env("SystemRoot") || "C:/Windows",
        System.get_env("ProgramFiles") || "C:/Program Files",
        System.get_env("ProgramFiles(x86)") || "C:/Program Files (x86)",
        System.get_env("ProgramData") || "C:/ProgramData"
      ]
      |> Enum.map(&normalize/1)

    posix_dirs = Enum.map(@posix_system_dirs, &normalize/1)

    Enum.any?(win_dirs ++ posix_dirs, &within_norm?(norm, &1))
  end

  defp user_home_target?(norm) do
    case System.user_home() do
      nil ->
        false

      home ->
        norm_home = home |> Path.expand() |> normalize() |> trim_trailing_slash()

        exact_or_wildcard?(norm, norm_home) or
          sensitive_child_of?(norm, norm_home) or
          roaming_appdata_child?(norm, norm_home)
    end
  end

  defp sensitive_child_of?(norm, base) do
    base = trim_trailing_slash(base)

    sub_match? =
      Enum.any?(@sensitive_home_subdirs, fn sub ->
        within_norm?(norm, base <> "/" <> String.downcase(sub))
      end)

    file_match? =
      Enum.any?(@sensitive_home_files, fn file ->
        trim_trailing_slash(norm) == base <> "/" <> String.downcase(file)
      end)

    roaming_match? = within_norm?(norm, base <> "/appdata/roaming")

    sub_match? or file_match? or roaming_match?
  end

  defp roaming_appdata_child?(norm, norm_home) do
    roaming =
      case System.get_env("APPDATA") do
        nil -> norm_home <> "/appdata/roaming"
        dir -> dir |> Path.expand() |> normalize() |> trim_trailing_slash()
      end

    within_norm?(norm, roaming)
  end

  defp protected_dir_target?(norm, protected_dirs) when is_list(protected_dirs) do
    Enum.any?(protected_dirs, fn dir ->
      if is_binary(dir) and String.trim(dir) != "" do
        norm_dir = dir |> normalize() |> trim_trailing_slash()
        within_norm?(norm, norm_dir) or exact_or_wildcard?(norm, norm_dir)
      else
        false
      end
    end)
  end

  defp protected_dir_target?(_norm, _other), do: false

  defp exact_or_wildcard?(norm, base) do
    trimmed = trim_trailing_slash(norm)
    trimmed == base or trimmed == base <> "/*"
  end

  defp within_norm?(norm, root) do
    norm = trim_trailing_slash(norm)
    root = trim_trailing_slash(root)

    cond do
      norm == root -> true
      root == "/" -> String.starts_with?(norm, "/")
      true -> String.starts_with?(norm, root <> "/")
    end
  end

  defp strip_quotes(str) do
    str
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.trim_leading("'")
    |> String.trim_trailing("'")
  end

  defp strip_win_extended_prefix("\\\\?\\" <> rest), do: rest
  defp strip_win_extended_prefix("//?/" <> rest), do: rest
  defp strip_win_extended_prefix(path), do: path

  defp collapse_slashes(str), do: Regex.replace(~r/\/+/, str, "/")

  defp trim_trailing_slash("/"), do: "/"
  defp trim_trailing_slash(<<d::binary-size(1), ":/">>), do: <<d::binary-size(1), ":/">>
  defp trim_trailing_slash(str), do: String.trim_trailing(str, "/")
end

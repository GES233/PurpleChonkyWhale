defmodule PurpleChonkyWhale.Sandbox.Profile do
  @moduledoc """
  Declarative isolation profile for subprocess execution (`Executor.Runner`) and
  stdio MCP servers (`PurpleChonkyWhale.MCP`).

  Fields:

    * `:mode` — `:read_only | :workspace_write | :full_access` (default
      `:workspace_write`)
    * `:cwd` — workspace root path
    * `:writable_roots` — additional writable directories beyond `:cwd`
    * `:readable_roots` — additional readable directories beyond `:cwd`
    * `:network?` — `false | true | :on_grant` (default `false`; `:on_grant`
      keeps network disabled unless the call's `%Security.Grant{}` explicitly
      authorizes `network?: true`)
    * `:fail_open?` — when `false` (the default), an unavailable sandbox
      backend refuses execution rather than running unsandboxed on the host
    * `:env_allowlist` — extra host environment variable names forwarded by
      `Executor.Runner`
  """

  alias PurpleChonkyWhale.Security.Grant

  @type mode :: :read_only | :workspace_write | :full_access
  @type network_policy :: boolean() | :on_grant

  defstruct mode: :workspace_write,
            cwd: nil,
            writable_roots: [],
            readable_roots: [],
            network?: false,
            fail_open?: false,
            env_allowlist: []

  @type t :: %__MODULE__{
          mode: mode(),
          cwd: String.t() | nil,
          writable_roots: [String.t()],
          readable_roots: [String.t()],
          network?: network_policy(),
          fail_open?: boolean(),
          env_allowlist: [String.t()]
        }

  @doc "Build a `%Profile{}` from a keyword list or map."
  @spec new(keyword() | map()) :: t()
  def new(attrs \\ []) do
    map = Map.new(attrs)

    %__MODULE__{
      mode: normalize_mode(Map.get(map, :mode, :workspace_write)),
      cwd: map[:cwd],
      writable_roots: normalize_list(Map.get(map, :writable_roots, [])),
      readable_roots: normalize_list(Map.get(map, :readable_roots, [])),
      network?: normalize_network(Map.get(map, :network?, false)),
      fail_open?: Map.get(map, :fail_open?, false) == true,
      env_allowlist: normalize_list(Map.get(map, :env_allowlist, []))
    }
  end

  @doc """
  Monotonically combine `profile`, tool `env`, and an optional `%Grant{}` so
  the resulting profile never exceeds `profile`'s ceiling.
  """
  @spec merge_env_and_grant(t(), map(), Grant.t() | nil) :: t()
  def merge_env_and_grant(%__MODULE__{} = profile, env, grant \\ nil) when is_map(env) do
    cwd = profile.cwd || env[:cwd]

    writable =
      profile.writable_roots
      |> intersect_if_present(env[:writable_roots])
      |> intersect_if_present(grant && grant.writable_roots)

    readable =
      profile.readable_roots
      |> intersect_if_present(env[:readable_roots])
      |> intersect_if_present(grant && grant.readable_roots)

    network? = resolve_network(profile.network?, grant)

    mode =
      if profile.mode == :read_only do
        :read_only
      else
        profile.mode
      end

    %{
      profile
      | mode: mode,
        cwd: cwd,
        writable_roots: writable,
        readable_roots: readable,
        network?: network?
    }
  end

  @doc "Whether outbound network access is permitted by `profile`."
  @spec network_allowed?(t()) :: boolean()
  def network_allowed?(%__MODULE__{network?: true}), do: true
  def network_allowed?(%__MODULE__{}), do: false

  @doc "Effective writable directories permitted by `profile`."
  @spec effective_writable_roots(t()) :: [String.t()]
  def effective_writable_roots(%__MODULE__{mode: :read_only}), do: []

  def effective_writable_roots(%__MODULE__{cwd: cwd, writable_roots: extra}) do
    Enum.uniq(Enum.filter([cwd | extra], &is_binary/1))
  end

  @doc "Effective readable directories permitted by `profile`."
  @spec effective_readable_roots(t()) :: [String.t()]
  def effective_readable_roots(%__MODULE__{cwd: cwd, readable_roots: extra}) do
    Enum.uniq(Enum.filter([cwd | extra], &is_binary/1))
  end

  defp resolve_network(false, _grant), do: false
  defp resolve_network(:on_grant, %Grant{network?: true}), do: true
  defp resolve_network(:on_grant, _grant), do: false
  defp resolve_network(true, %Grant{network?: false}), do: false
  defp resolve_network(true, _grant), do: true

  defp intersect_if_present(base, nil), do: base

  defp intersect_if_present([], extra) when is_list(extra) do
    normalize_list(extra)
  end

  defp intersect_if_present(base, extra) when is_list(extra) do
    extra_keys = MapSet.new(extra, &path_key/1)
    Enum.filter(base, &MapSet.member?(extra_keys, path_key(&1)))
  end

  defp path_key(path) do
    expanded = path |> to_string() |> Path.expand() |> String.replace("\\", "/")

    case :os.type() do
      {:win32, _} -> String.downcase(expanded)
      _ -> expanded
    end
  end

  defp normalize_mode(mode) when mode in [:read_only, :workspace_write, :full_access], do: mode
  defp normalize_mode(_), do: :workspace_write

  defp normalize_network(net) when net in [true, false, :on_grant], do: net
  defp normalize_network(_), do: false

  defp normalize_list(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp normalize_list(_), do: []
end

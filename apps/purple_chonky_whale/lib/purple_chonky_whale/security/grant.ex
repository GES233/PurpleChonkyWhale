defmodule PurpleChonkyWhale.Security.Grant do
  @moduledoc """
  A structured capability grant authorizing a tool execution within bounded
  scope and lifetime.

  Policies on `:"tools/pre-execute"` return `{:allow, %Grant{}}` (or
  `{:deny, reason}`). `PurpleChonkyWhale.Tools` composes multiple grants
  monotonically via `narrow/2` — a downstream listener can restrict
  capabilities, target tools, paths, runtimes, or TTL, and can never widen an
  earlier grant.
  """

  alias PurpleChonkyWhale.Tool

  @enforce_keys [:capabilities]
  defstruct capabilities: MapSet.new(),
            tools: :any,
            writable_roots: nil,
            readable_roots: nil,
            allowed_runtimes: nil,
            network?: nil,
            expires_at: nil,
            reason: nil,
            source: :policy

  @type t :: %__MODULE__{
          capabilities: MapSet.t(Tool.capability()),
          tools: :any | MapSet.t(String.t()),
          writable_roots: [String.t()] | nil,
          readable_roots: [String.t()] | nil,
          allowed_runtimes: [String.t()] | nil,
          network?: boolean() | nil,
          expires_at: integer() | nil,
          reason: String.t() | nil,
          source: atom()
        }

  @doc """
  Build a `%Grant{}` from a keyword list or map.

  Options:

    * `:capabilities` — enumerable of `Tool.capability()` atoms (required or
      defaults to `[]`)
    * `:tools` — `:any` (default) or an enumerable of permitted tool names
    * `:writable_roots` — optional list of writable root overrides (can only
      narrow `env[:writable_roots]`)
    * `:readable_roots` — optional list of readable root overrides (can only
      narrow `env[:readable_roots]`)
    * `:allowed_runtimes` — optional list of allowed `execute` runtimes (can
      only narrow `env[:allowed_runtimes]`)
    * `:network?` — optional boolean (`true` requests network access when the
      `:sandbox` profile allows `:on_grant`; `false` denies network access)
    * `:ttl_ms` — positive integer TTL relative to `now_ms` (converted to
      `:expires_at` unless `:expires_at` is given directly)
    * `:expires_at` — monotonic millisecond deadline (`System.monotonic_time(:millisecond)`)
    * `:reason` — human-readable audit explanation
    * `:source` — origin tag (default `:policy`)
  """
  @spec new(keyword() | map(), integer()) :: t()
  def new(attrs \\ [], now_ms \\ System.monotonic_time(:millisecond)) do
    map = Map.new(attrs)

    caps =
      map
      |> Map.get(:capabilities, [])
      |> MapSet.new()

    tools =
      case Map.get(map, :tools, :any) do
        :any -> :any
        %MapSet{} = set -> set
        list when is_list(list) -> MapSet.new(list, &to_string/1)
      end

    expires_at =
      cond do
        is_integer(map[:expires_at]) -> map[:expires_at]
        is_integer(map[:ttl_ms]) and map[:ttl_ms] > 0 -> now_ms + map[:ttl_ms]
        true -> nil
      end

    %__MODULE__{
      capabilities: caps,
      tools: tools,
      writable_roots: normalize_string_list(map[:writable_roots]),
      readable_roots: normalize_string_list(map[:readable_roots]),
      allowed_runtimes: normalize_string_list(map[:allowed_runtimes]),
      network?: normalize_network(map[:network?]),
      expires_at: expires_at,
      reason: map[:reason],
      source: Map.get(map, :source, :policy)
    }
  end

  @doc "Whether `grant` has passed its monotonic `:expires_at` deadline."
  @spec expired?(t(), integer()) :: boolean()
  def expired?(%__MODULE__{expires_at: nil}, _now_ms), do: false
  def expired?(%__MODULE__{expires_at: expires_at}, now_ms), do: now_ms >= expires_at

  @doc "Milliseconds remaining on `grant`, or `nil` when it does not expire."
  @spec remaining_ms(t(), integer()) :: non_neg_integer() | nil
  def remaining_ms(grant, now_ms \\ System.monotonic_time(:millisecond))
  def remaining_ms(%__MODULE__{expires_at: nil}, _now_ms), do: nil

  def remaining_ms(%__MODULE__{expires_at: expires_at}, now_ms) do
    max(0, expires_at - now_ms)
  end

  @doc """
  Whether `grant` authorizes invoking `tool_name` requiring `required_caps`
  at `now_ms`.
  """
  @spec allows?(t(), String.t(), [Tool.capability()], integer()) :: boolean()
  def allows?(
        %__MODULE__{} = grant,
        tool_name,
        required_caps,
        now_ms \\ System.monotonic_time(:millisecond)
      )
      when is_binary(tool_name) and is_list(required_caps) do
    not expired?(grant, now_ms) and
      tool_allowed?(grant.tools, tool_name) and
      MapSet.subset?(MapSet.new(required_caps), grant.capabilities)
  end

  @doc """
  Monotonically intersect two grants so the resulting grant permits only what
  both `a` and `b` allow.
  """
  @spec narrow(t(), t()) :: t()
  def narrow(%__MODULE__{} = a, %__MODULE__{} = b) do
    %__MODULE__{
      capabilities: MapSet.intersection(a.capabilities, b.capabilities),
      tools: intersect_tools(a.tools, b.tools),
      writable_roots: intersect_paths(a.writable_roots, b.writable_roots),
      readable_roots: intersect_paths(a.readable_roots, b.readable_roots),
      allowed_runtimes: intersect_lists(a.allowed_runtimes, b.allowed_runtimes),
      network?: intersect_network(a.network?, b.network?),
      expires_at: min_deadline(a.expires_at, b.expires_at),
      reason: merge_reasons(a.reason, b.reason),
      source: if(a.source == b.source, do: a.source, else: :narrowed)
    }
  end

  @doc """
  Apply `grant`'s optional environment restrictions onto `env`. Never widens
  existing environment permissions.
  """
  @spec apply_to_env(t(), map()) :: map()
  def apply_to_env(%__MODULE__{} = grant, env) when is_map(env) do
    env
    |> narrow_env_runtimes(grant.allowed_runtimes)
    |> narrow_env_roots(:writable_roots, grant.writable_roots)
    |> narrow_env_roots(:readable_roots, grant.readable_roots)
    |> Map.put(:grant, grant)
  end

  defp tool_allowed?(:any, _tool_name), do: true
  defp tool_allowed?(%MapSet{} = tools, tool_name), do: MapSet.member?(tools, tool_name)

  defp intersect_tools(:any, other), do: other
  defp intersect_tools(other, :any), do: other
  defp intersect_tools(%MapSet{} = a, %MapSet{} = b), do: MapSet.intersection(a, b)

  defp intersect_lists(nil, other), do: other
  defp intersect_lists(other, nil), do: other
  defp intersect_lists(a, b), do: Enum.filter(a, &(&1 in b))

  defp intersect_paths(nil, other), do: other
  defp intersect_paths(other, nil), do: other

  defp intersect_paths(a, b) do
    b_keys = MapSet.new(b, &path_key/1)
    Enum.filter(a, &MapSet.member?(b_keys, path_key(&1)))
  end

  defp narrow_env_runtimes(env, nil), do: env

  defp narrow_env_runtimes(env, granted) when is_list(granted) do
    base =
      case Map.get(env, :allowed_runtimes) do
        list when is_list(list) -> list
        _ -> PurpleChonkyWhale.Tools.Executor.default_allowed_runtimes()
      end

    Map.put(env, :allowed_runtimes, Enum.filter(base, &(&1 in granted)))
  end

  defp narrow_env_roots(env, _key, nil), do: env

  defp narrow_env_roots(env, key, granted) when is_list(granted) do
    base = env |> Map.get(key, []) |> List.wrap()
    Map.put(env, key, intersect_paths(base, granted))
  end

  defp path_key(path) do
    expanded = path |> Path.expand() |> String.replace("\\", "/")

    case :os.type() do
      {:win32, _} -> String.downcase(expanded)
      _ -> expanded
    end
  end

  defp min_deadline(nil, other), do: other
  defp min_deadline(other, nil), do: other
  defp min_deadline(a, b), do: min(a, b)

  defp merge_reasons(nil, b), do: b
  defp merge_reasons(a, nil), do: a
  defp merge_reasons(a, a), do: a
  defp merge_reasons(a, b), do: "#{a}; #{b}"

  defp normalize_string_list(nil), do: nil

  defp normalize_string_list(list) when is_list(list) do
    Enum.map(list, &to_string/1)
  end

  defp normalize_network(val) when val in [true, false], do: val
  defp normalize_network(_), do: nil

  defp intersect_network(false, _), do: false
  defp intersect_network(_, false), do: false
  defp intersect_network(true, true), do: true
  defp intersect_network(_, _), do: nil
end

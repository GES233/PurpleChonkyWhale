defmodule PurpleChonkyWhale.Sandbox.Host do
  @moduledoc """
  Pass-through host backend for `PurpleChonkyWhale.Sandbox`.

  Provides a zero-dependency runnable implementation of `Sandbox.Backend` while
  keeping the `:sandbox` seam active across `Executor.Runner` and `MCP`:

    * validates the working directory and profile shape;
    * ensures stdio MCP transports carry an explicit `:env` map (so Anubis's
      minimal default-env allowlist applies instead of inheriting every host
      secret) and default `:cwd` from the profile.

  This backend does **not** add OS-level filesystem/network confinement on its
  own — pair it with `PathGuard`, `Executor.Runner`'s host env filtering, and
  `Noctilucent.Policy`, or switch `:backend` to `Sandbox.Docker` (or a future
  platform helper) for kernel-level isolation.
  """

  @behaviour PurpleChonkyWhale.Sandbox.Backend

  alias PurpleChonkyWhale.Sandbox.Profile

  @impl true
  def available?(_opts), do: :ok

  @impl true
  def wrap_plan(plan, ctx, %Profile{} = profile, _opts) do
    cwd = ctx[:cwd] || profile.cwd

    if is_binary(cwd) and not File.dir?(cwd) do
      {:error, "sandbox working directory does not exist: #{cwd}"}
    else
      {:ok, plan}
    end
  end

  @impl true
  def wrap_stdio(stdio_opts, %Profile{} = profile, _opts) do
    case Keyword.get(stdio_opts, :command) do
      cmd when is_binary(cmd) and cmd != "" ->
        opts =
          stdio_opts
          |> Keyword.put_new(:env, %{})
          |> maybe_put_cwd(profile.cwd)

        {:ok, opts}

      _other ->
        {:error, "stdio transport missing required :command"}
    end
  end

  defp maybe_put_cwd(opts, cwd) when is_binary(cwd) do
    Keyword.put_new(opts, :cwd, cwd)
  end

  defp maybe_put_cwd(opts, _cwd), do: opts
end

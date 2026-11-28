defmodule Clearance.Request do
  @moduledoc """
  Builds the request map handed to an asker, so the asker never needs to know
  the shape of a tool call or of the policy state.

  Fields:

    * `:tool`, `:arguments`, `:capabilities` — what the model asked for
    * `:summary` — one-line human description (`execute` gets a code preview)
    * `:warnings` — lint reasons, empty when the call was not linted
    * `:high_risk?` — whether the call bypasses auto-allow and leases
    * `:network_requested?` — the lint flagged network or package installation
    * `:leaseable_capabilities` — capabilities a `{:lease, _}` answer would
      cover; empty for high-risk calls and for `:unknown` / `:mcp`
    * `:default_lease_ms` — the policy's default lease TTL
    * `:session_id`, `:run_id`, `:tool_call_id` — correlation, when present
  """

  @doc "Build the asker request for a pending call."
  @spec build(map(), map(), map()) :: map()
  def build(call, request_ctx, policy) do
    leaseable =
      if request_ctx.high_risk? do
        []
      else
        Enum.reject(request_ctx.caps, &(&1 in [:unknown, :mcp]))
      end

    %{
      tool: request_ctx.name,
      arguments: request_ctx.args,
      capabilities: request_ctx.caps,
      summary: summary(request_ctx.name, request_ctx.args),
      warnings: request_ctx.lint.reasons,
      high_risk?: request_ctx.high_risk?,
      network_requested?: "network access or package installation" in request_ctx.lint.reasons,
      leaseable_capabilities: leaseable,
      default_lease_ms: policy.lease_ttl_ms,
      session_id: Map.get(call, :session_id),
      run_id: Map.get(call, :run_id),
      tool_call_id: Map.get(call, :tool_call_id)
    }
  end

  @doc "One-line human summary of a tool call."
  @spec summary(String.t(), map()) :: String.t()
  def summary("execute", args) do
    runtime = Map.get(args, "runtime", "shell")
    code = args |> Map.get("code", "") |> String.trim()
    preview = if String.length(code) > 160, do: String.slice(code, 0, 160) <> "...", else: code
    "execute (#{runtime}): #{preview}"
  end

  def summary(name, %{"file_path" => path}) when is_binary(path) do
    "#{name} -> #{path}"
  end

  def summary(name, args) do
    "#{name} #{inspect(args)}"
  end
end

defmodule Clearance.Asker do
  @moduledoc """
  The human (or policy stand-in) behind a pending approval.

  An asker receives one request map built by `Clearance.Request.build/3` and
  answers with one of:

    * `:once` — allow this single call
    * `{:lease, ttl_ms}` — allow this call and grant a standing TTL lease for
      its leaseable capabilities (`:unknown` and `:mcp` are never leaseable,
      and high-risk calls can never create a lease)
    * `:deny` — refuse the call
    * `{:allow, %PurpleChonkyWhale.Security.Grant{}}` — a pre-built grant,
      honoured only if it covers the call

  Returning anything else, raising, or exiting counts as `:deny`. The asker
  runs in its own monitored process, so a crashed prompt cannot take the
  policy server down with it.
  """

  alias PurpleChonkyWhale.Security.Grant

  @typedoc "What an asker may answer for one pending call."
  @type choice :: :once | {:lease, pos_integer()} | :deny | {:allow, Grant.t()}

  @typedoc "A one-argument function from a request map to a `t:choice/0`."
  @type asker :: (map() -> choice())

  @callback ask(request :: map()) :: choice()
end

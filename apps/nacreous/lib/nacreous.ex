defmodule Nacreous do
  @moduledoc """
  The work agent application.

  Owns everything that is *policy* for a multi-user, project-oriented agent
  on top of the `PurpleChonkyWhale` harness: member identity and access
  control (hooked on the `tools/pre-execute` waterfall), messaging gateway
  delivery, per-project compositions, and project-progress projections over
  the shared session event logs. The harness stays generic; opinions live
  here.
  """
end

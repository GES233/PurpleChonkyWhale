defmodule Clearance.Asker.DenyAll do
  @moduledoc """
  Headless asker: everything that needs approval is denied.

  This is the safe default for an application with no terminal or UI. It
  keeps the lease semantics intact (`:auto_allow` capabilities still pass,
  programmatic `grant_lease/3` still works), it just never grants anything
  interactively.
  """

  @behaviour Clearance.Asker

  @impl true
  def ask(_request), do: :deny
end

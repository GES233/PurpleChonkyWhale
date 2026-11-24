defmodule NacreousTest do
  use ExUnit.Case, async: true

  test "the harness library is available as a dependency" do
    assert Code.ensure_loaded?(PurpleChonkyWhale.Session)
  end
end

defmodule NoctilucentTest do
  use ExUnit.Case, async: true

  test "the harness library is available as a dependency" do
    assert Code.ensure_loaded?(PurpleChonkyWhale.Session)
  end

  test "persona presets are the application's own policy" do
    assert Noctilucent.Presets.personas() == [:coding, :personal, :tutor]
  end
end

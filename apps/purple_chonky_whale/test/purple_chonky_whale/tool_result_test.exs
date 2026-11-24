defmodule PurpleChonkyWhale.ToolResultTest do
  use ExUnit.Case, async: true

  alias PurpleChonkyWhale.ToolResult

  test "a settled subprocess failure remains a successful tool result" do
    result = ToolResult.from_result("c1", "execute", {:ok, "failed\nexit status 1"}, 123)

    assert result["isError"] == false
    assert result["details"] == %{}
    assert result["timestamp"] == 123
    assert [%{"type" => "text", "text" => "failed\nexit status 1"}] = result["content"]
  end

  test "non-text success is JSON content without duplicate metadata" do
    result = ToolResult.from_result("c1", "calc", {:ok, %{"answer" => 42}})

    assert [%{"type" => "text", "text" => ~s({"answer":42})}] = result["content"]
    assert result["details"] == %{}
    assert result["isError"] == false
  end

  test "errors preserve machine classification and project is_error" do
    result =
      ToolResult.from_result("c1", "read", {:error, %{type: :denied, message: "not allowed"}})

    assert result["isError"] == true
    assert result["details"]["error"] == %{"type" => "denied", "message" => "not allowed"}
    assert [%{"type" => "text", "text" => "not allowed"}] = result["content"]

    projected = ToolResult.to_reqllm(result)
    assert projected.role == :tool
    assert projected.tool_call_id == "c1"
    assert projected.metadata.is_error == true
    assert [%{type: :text, text: "not allowed"}] = projected.content
  end

  test "legacy error wrappers normalize without mistaking other maps for errors" do
    error =
      ToolResult.from_legacy(%{
        "tool_call_id" => "c1",
        "name" => "read",
        "output" => %{"ok" => false, "error" => %{"type" => "crashed", "message" => "boom"}}
      })

    success =
      ToolResult.from_legacy(%{
        "tool_call_id" => "c2",
        "name" => "calc",
        "output" => %{"answer" => 42}
      })

    assert error["isError"] == true
    assert error["details"]["error"]["type"] == "crashed"
    assert success["isError"] == false
    assert [%{"text" => ~s({"answer":42})}] = success["content"]
  end
end

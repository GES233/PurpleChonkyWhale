defmodule Noctilucent.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Noctilucent.CLI

  test "defaults to the personal persona in the launch cwd" do
    assert {:ok, config} = CLI.parse_args([])
    assert config.persona == :personal
    assert config.model == nil
    assert config.session == nil
    assert config.help == false
  end

  test "parses persona, model, session and cwd", %{} do
    assert {:ok, config} =
             CLI.parse_args([
               "-p",
               "tutor",
               "-m",
               "anthropic:kimi-for-coding",
               "-s",
               "s1",
               "-c",
               "/tmp"
             ])

    assert config.persona == :tutor
    assert config.model == "anthropic:kimi-for-coding"
    assert config.session == "s1"
    assert config.cwd == "/tmp"
  end

  test "--help short-circuits" do
    assert {:ok, %{help: true}} = CLI.parse_args(["--help"])
  end

  test "unknown personas and stray args are errors, not crashes" do
    assert {:error, message} = CLI.parse_args(["--persona", "butler"])
    assert message =~ "unknown persona"
    assert message =~ "coding"

    assert {:error, message} = CLI.parse_args(["positional"])
    assert message =~ "unexpected arguments"

    assert {:error, message} = CLI.parse_args(["--bogus"])
    assert message =~ "unknown or invalid"
  end

  describe "build_prompt/3" do
    @moduletag :tmp_dir

    @png <<137, 80, 78, 71, 13, 10, 26, 10, 7, 7, 0, 0, 0, 0, "IEND", 0xAE, 0x42, 0x60, 0x82>>

    test "@image tokens attach image parts; the text keeps the token", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "pic.png"), @png)

      assert {text, [part], [notice]} = CLI.build_prompt("look at @pic.png please", dir)

      assert text == "look at @pic.png please"
      assert %{"type" => "image", "data" => @png, "mediaType" => "image/png"} = part
      assert notice =~ "attached @pic.png"
    end

    test "corrupt or truncated images are skipped with a notice", %{tmp_dir: dir} do
      # PNG signature plus junk, no IEND chunk — like a truncated write.
      File.write!(Path.join(dir, "stub.png"), <<137, 80, 78, 71, 13, 10, 26, 10, 7, 7>>)

      assert {_, [], [notice]} = CLI.build_prompt("see @stub.png", dir)
      assert notice =~ "skipped @stub.png"
      assert notice =~ "corrupt or truncated"
    end

    test "trailing punctuation after a token is not part of the path", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "pic.png"), @png)

      assert {_, [part], [_notice]} = CLI.build_prompt("what is @pic.png?", dir)
      assert %{"type" => "image"} = part
    end

    test "non-image and missing @tokens are left alone", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "notes.txt"), "hi")

      assert {_, [], []} = CLI.build_prompt("read @notes.txt and @missing.png", dir)
    end

    test "vision?: false ignores attachments with a notice", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "pic.png"), @png)

      assert {_, [], [notice]} = CLI.build_prompt("see @pic.png", dir, false)
      assert notice =~ "no image input"
    end
  end

  describe "approval helpers" do
    test "parse_approval_choice/2 handles once, lease, and fail-closed deny" do
      leaseable = %{leaseable_capabilities: [:fs_write], default_lease_ms: 900_000}
      high_risk = %{leaseable_capabilities: [], default_lease_ms: 900_000}

      assert CLI.parse_approval_choice("y", leaseable) == :once
      assert CLI.parse_approval_choice("YES", leaseable) == :once
      assert CLI.parse_approval_choice("l", leaseable) == {:lease, 900_000}
      assert CLI.parse_approval_choice("lease", leaseable) == {:lease, 900_000}
      assert CLI.parse_approval_choice("", leaseable) == :deny
      assert CLI.parse_approval_choice("n", leaseable) == :deny
      assert CLI.parse_approval_choice("bogus", leaseable) == :deny

      # High-risk requests cannot be leased via "l"
      assert CLI.parse_approval_choice("l", high_risk) == :deny
      assert CLI.parse_approval_choice("y", high_risk) == :once
    end

    test "format_approval_prompt/1 and format_leases/1 render warnings and leases" do
      prompt =
        CLI.format_approval_prompt(%{
          tool: "execute",
          summary: "execute (shell): git reset --hard",
          capabilities: [:exec],
          warnings: ["destructive git operation"],
          leaseable_capabilities: [],
          default_lease_ms: 900_000
        })

      assert prompt =~ "[approval required]"
      assert prompt =~ "destructive git operation"
      refute prompt =~ "[l] lease"

      assert CLI.format_leases([]) == "[active leases: none]"

      grant =
        PurpleChonkyWhale.Security.Grant.new(
          capabilities: [:fs_write],
          ttl_ms: 60_000,
          reason: "user lease"
        )

      rendered = CLI.format_leases([grant])
      assert rendered =~ "[active leases (1)]"
      assert rendered =~ "fs_write"
      assert rendered =~ "user lease"
    end
  end

  describe "terminal event loop" do
    test "only an idle wait prints the input prompt" do
      send(self(), {:stdin_line, "/quit"})

      idle_output =
        capture_io(fn ->
          assert {:line, "/quit", [], false} = CLI.next_line([], false)
        end)

      assert idle_output == "\n> "

      queued_output =
        capture_io(fn ->
          assert {:line, "/quit", [], false} = CLI.next_line(["/quit"], false)
          assert :eof = CLI.next_line([], true)
        end)

      assert queued_output == ""
    end

    test "running renders chunks and tools before completion without another prompt" do
      send(self(), {:render, {:llm_chunk, ReqLLM.StreamChunk.text("answer")}})

      send(
        self(),
        {:render, {:tool_result, %{name: "read", result: {:ok, "ok"}, duration_ms: 3}}}
      )

      send(self(), {:run_finished, "run-1", {:ok, "answer"}})

      output =
        capture_io(fn ->
          assert {[], false} = CLI.await_run(self(), "run-1", [], false)
        end)

      assert output ==
               "answer\n[tool read] ok (3ms)\n\n== turn complete (run-1) ==\n"

      refute output =~ "> "
    end

    test "running still queues an ordinary message for the next turn without prompting" do
      send(self(), {:stdin_line, "next turn"})
      send(self(), {:run_finished, "run-2", {:ok, "done"}})

      output =
        capture_io(fn ->
          assert {["next turn"], false} = CLI.await_run(self(), "run-2", [], false)
        end)

      refute output =~ "> "
      assert output =~ "== turn complete (run-2) =="
    end

    test "approval consumes render events without printing the ordinary input prompt" do
      ref = make_ref()

      request = %{
        tool: "write",
        summary: "write -> out.txt",
        capabilities: [:fs_write],
        warnings: [],
        leaseable_capabilities: [:fs_write],
        default_lease_ms: 900_000
      }

      send(self(), {:approval_request, ref, self(), request})
      send(self(), {:render, {:llm_chunk, ReqLLM.StreamChunk.text("working")}})
      send(self(), {:stdin_line, "n"})
      send(self(), {:run_finished, "run-3", {:ok, "done"}})

      output =
        capture_io(fn ->
          assert {[], false} = CLI.await_run(self(), "run-3", [], false)
        end)

      assert_received {:approval_reply, ^ref, :deny}
      assert output =~ "[approval required] write -> out.txt"
      assert output =~ "working"
      assert output =~ "== turn complete (run-3) =="
      refute output =~ "\n> "
    end
  end
end

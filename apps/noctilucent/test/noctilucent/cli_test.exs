defmodule Noctilucent.CLITest do
  use ExUnit.Case, async: true

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

    @png <<137, 80, 78, 71, 13, 10, 26, 10, 7, 7>>

    test "@image tokens attach image parts; the text keeps the token", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "pic.png"), @png)

      assert {text, [part], [notice]} = CLI.build_prompt("look at @pic.png please", dir)

      assert text == "look at @pic.png please"
      assert %{"type" => "image", "data" => @png, "mediaType" => "image/png"} = part
      assert notice =~ "attached @pic.png"
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
end

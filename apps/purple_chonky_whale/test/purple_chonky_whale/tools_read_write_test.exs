defmodule PurpleChonkyWhale.Tools.ReadWriteTest do
  use ExUnit.Case, async: true

  alias PurpleChonkyWhale.Tools.{Read, Write}

  setup do
    dir = Path.join(System.tmp_dir!(), "pcw-rw-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, env: %{cwd: dir}, dir: dir}
  end

  describe "write" do
    test "creates parent directories and writes content", %{env: env, dir: dir} do
      assert {:ok, result} =
               Write.execute(%{"file_path" => "a/b/c.txt", "content" => "x\ny"}, env)

      assert result =~ "wrote 2 lines"
      assert File.read!(Path.join(dir, "a/b/c.txt")) == "x\ny"
    end

    test "overwrites an existing file", %{env: env, dir: dir} do
      path = Path.join(dir, "f.txt")
      File.write!(path, "old")

      assert {:ok, _} = Write.execute(%{"file_path" => "f.txt", "content" => "new"}, env)
      assert File.read!(path) == "new"
    end

    test "accepts absolute paths", %{env: env, dir: dir} do
      path = Path.join(dir, "abs.txt")
      assert {:ok, _} = Write.execute(%{"file_path" => path, "content" => "abs"}, env)
      assert File.read!(path) == "abs"
    end
  end

  describe "read" do
    test "numbers lines", %{env: env, dir: dir} do
      File.write!(Path.join(dir, "n.txt"), "one\ntwo\nthree")

      assert {:ok, "1\tone\n2\ttwo\n3\tthree"} =
               Read.execute(%{"file_path" => "n.txt"}, env)
    end

    test "pages with offset and limit, noting what was shown", %{env: env, dir: dir} do
      File.write!(Path.join(dir, "p.txt"), Enum.map_join(1..10, "\n", &"line#{&1}"))

      assert {:ok, result} =
               Read.execute(%{"file_path" => "p.txt", "offset" => 3, "limit" => 2}, env)

      assert result == "3\tline3\n4\tline4\n... (10 lines total, showing 3-4)"
    end

    test "a non-UTF-8 (e.g. GBK) file reads with replacement chars", %{env: env, dir: dir} do
      File.write!(Path.join(dir, "gbk.txt"), <<186, 72, 10, 76, 97, 10>>)

      assert {:ok, text} = Read.execute(%{"file_path" => "gbk.txt"}, env)
      assert String.valid?(text)
      refute text =~ <<186>>
      assert text =~ "La"
    end

    test "empty file, missing file, and past-the-end offset are plain answers", %{
      env: env,
      dir: dir
    } do
      File.write!(Path.join(dir, "e.txt"), "")
      File.write!(Path.join(dir, "n.txt"), "one\ntwo")

      assert {:ok, "(empty file)"} = Read.execute(%{"file_path" => "e.txt"}, env)
      assert {:error, message} = Read.execute(%{"file_path" => "missing.txt"}, env)
      assert message =~ "file not found"
      assert {:ok, result} = Read.execute(%{"file_path" => "n.txt", "offset" => 99}, env)
      assert result =~ "past the end"
    end
  end

  describe "read (images)" do
    # PNG signature plus filler and a trailing IEND chunk: structurally
    # complete as far as the tool's check is concerned.
    @png <<137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3, 0, 0, 0, 0, "IEND", 0xAE, 0x42, 0x60, 0x82>>
    @jpeg <<0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9>>

    test "image files come back as an image part plus a text note", %{env: env, dir: dir} do
      File.write!(Path.join(dir, "pic.png"), @png)

      assert {:ok, {:parts, [image, note]}} = Read.execute(%{"file_path" => "pic.png"}, env)
      assert %{"type" => "image", "data" => @png, "mediaType" => "image/png"} = image
      assert %{"type" => "text", "text" => text} = note
      assert text =~ "image/png"
      assert text =~ "pic.png"
    end

    test "extensions match case-insensitively", %{env: env, dir: dir} do
      File.write!(Path.join(dir, "PIC.JPEG"), @jpeg)

      assert {:ok, {:parts, [%{"mediaType" => "image/jpeg"} | _]}} =
               Read.execute(%{"file_path" => "PIC.JPEG"}, env)
    end

    test "a corrupt or truncated image degrades to a text description", %{env: env, dir: dir} do
      # PNG signature plus junk, no IEND chunk — like a truncated write.
      File.write!(Path.join(dir, "stub.png"), <<137, 80, 78, 71, 13, 10, 26, 10, 7, 7>>)

      assert {:ok, text} = Read.execute(%{"file_path" => "stub.png"}, env)
      assert text =~ "corrupt or truncated"
      assert text =~ "stub.png"
    end

    test "valid_image_data?/2 checks structure per format" do
      assert Read.valid_image_data?(@png, "image/png")
      refute Read.valid_image_data?(<<137, 80, 78, 71, 13, 10, 26, 10>>, "image/png")
      assert Read.valid_image_data?(@jpeg, "image/jpeg")
      refute Read.valid_image_data?(@png, "image/jpeg")
      assert Read.valid_image_data?(<<"GIF89a", 0, 0, 0x3B>>, "image/gif")
      refute Read.valid_image_data?(<<"GIF89a", 0, 0>>, "image/gif")
      assert Read.valid_image_data?(<<"RIFF", 0, 0, 0, 0, "WEBP", 0>>, "image/webp")
      refute Read.valid_image_data?(<<"RIFF", 0, 0, 0, 0, "AVI ", 0>>, "image/webp")
    end

    test "vision?: false answers with a text description instead of the image", %{
      env: env,
      dir: dir
    } do
      File.write!(Path.join(dir, "pic.png"), @png)

      assert {:ok, text} =
               Read.execute(%{"file_path" => "pic.png"}, Map.put(env, :vision?, false))

      assert text =~ "image/png"
      assert text =~ "pic.png"
    end

    test "images over the byte limit are refused with a downscale hint", %{env: env, dir: dir} do
      File.write!(Path.join(dir, "big.png"), :binary.copy(<<0>>, 6 * 1024 * 1024))

      assert {:error, message} = Read.execute(%{"file_path" => "big.png"}, env)
      assert message =~ "over the 5 MB limit"
      assert message =~ "downscale"
    end

    test "missing image files report like missing text files", %{env: env} do
      assert {:error, message} = Read.execute(%{"file_path" => "missing.png"}, env)
      assert message =~ "file not found"
    end
  end
end

# Image-reading demo: the agent reads a PNG with the `read` tool and
# describes it. Requires a vision-capable model (API key from env or .env).
# Run from the umbrella root so the root .env is picked up:
#
#   mix run apps/noctilucent/examples/image_demo.exs anthropic:claude-sonnet-4-5
#   mix run apps/noctilucent/examples/image_demo.exs openai:gpt-4o path/to/other.png
#   PCW_DEMO_BASE_URL=https://api.kimi.com/coding \
#     mix run apps/noctilucent/examples/image_demo.exs anthropic:kimi-for-coding
#
# Without an image argument the script paints a deterministic test PNG
# (three horizontal stripes: red, green, blue) into tmp and uses that.

alias Noctilucent.Presets
alias PurpleChonkyWhale.{AgentLoop, Session, Sessions}
alias Dexterous.Context

model = System.argv() |> List.first() || raise "usage: mix run examples/image_demo.exs MODEL [image]"
custom_image = Enum.at(System.argv(), 1)

defmodule TestImage do
  def stripes_png(width \\ 240, height \\ 120) do
    rows =
      for y <- 0..(height - 1) do
        rgb =
          cond do
            y < div(height, 3) -> {255, 0, 0}
            y < div(height * 2, 3) -> {0, 200, 0}
            true -> {0, 0, 255}
          end

        [0, :binary.copy(<<elem(rgb, 0), elem(rgb, 1), elem(rgb, 2)>>, width)]
      end

    iodata = [
      <<137, 80, 78, 71, 13, 10, 26, 10>>,
      chunk("IHDR", <<width::32, height::32, 8, 2, 0, 0, 0>>),
      chunk("IDAT", :zlib.compress(IO.iodata_to_binary(rows))),
      chunk("IEND", <<>>)
    ]

    IO.iodata_to_binary(iodata)
  end

  defp chunk(type, data) do
    <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>
  end
end

image_path =
  case custom_image do
    nil ->
      path = Path.join(System.tmp_dir!(), "pcw-demo-stripes.png")
      unless File.exists?(path), do: File.write!(path, TestImage.stripes_png())
      path

    path ->
      Path.expand(path)
  end

ctx = Dexterous.root()

{:ok, _} =
  Context.on(ctx, :"llm/chunk", fn chunk ->
    if chunk.type == :content, do: IO.write(chunk.text)
  end)

{:ok, _} =
  Context.on(ctx, :"tools/post-execute", fn %{name: name, result: result, duration_ms: ms} ->
    note =
      case result do
        {:ok, {:parts, parts}} -> "ok, parts: #{inspect(Enum.map(parts, & &1["type"]))}"
        {:ok, _} -> "ok"
        {:error, error} -> "error: #{inspect(error)}"
      end

    IO.puts("\n[tool #{name}] #{note} (#{ms}ms)")
  end)

home = Path.join(System.tmp_dir!(), "pcw-image-demo")

llm_opts =
  case System.get_env("PCW_DEMO_BASE_URL") do
    nil -> []
    url -> [base_url: url]
  end

{:ok, _loader} =
  DexterousLoader.start_link(
    ctx,
    Presets.entries(:personal, model: model, home: home, llm_opts: llm_opts)
  )

await = fn key ->
  Enum.reduce_while(1..100, nil, fn _, _ ->
    case Context.get(ctx, key) do
      {:ok, value} -> {:halt, value}
      :error -> {:cont, Process.sleep(10)}
    end
  end) || raise "#{key} was not bound in time"
end

llm = await.(:llm)
sessions = await.(:sessions)
_sandbox = await.(:sandbox)
tools = await.(:tools)
_policy = await.(:policy)

{:ok, session} = Sessions.open(sessions, "image-demo-#{System.unique_integer([:positive])}")

{:ok, _} =
  Session.append(session, :"system/message", %{
    "content" => Presets.system_prompt(:personal, cwd: File.cwd!())
  })

{:ok, _} =
  Session.append(session, :"user/message", %{
    "content" => "Read the image at #{image_path} and describe what you see, in one sentence."
  })

IO.puts("model: #{model}\nimage: #{image_path}\n---")

case AgentLoop.run(llm, session, tools) do
  {:ok, _text} -> IO.puts("\n\n== done ==")
  {:error, error} -> IO.puts("\n\n== failed: #{inspect(error)} ==")
end

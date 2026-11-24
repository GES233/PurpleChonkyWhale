defmodule PurpleChonkyWhale.Memory do
  @max_layer_bytes 4_000

  @moduledoc """
  The `:memory` seam provider: layered, file-backed memory.

      %DexterousLoader.Entry{
        id: :memory,
        component: PurpleChonkyWhale.Memory,
        config: [layers: [persona: {"~/.pcw/personal/memory", writable: true},
                          global: {"~/.agents/memory", writable: false}]]
      }

  Layers are ordered from most to least specific. Each layer's memory is a
  single `MEMORY.md` in the layer's directory — plain Markdown, one durable
  note per line, so files stay greppable and hand-editable.

    * `recall/1` concatenates the layers (most specific first), capping each
      at #{@max_layer_bytes} bytes with a truncation note. Callers append the
      result to the session as a `:"system/message"` — model-visible means
      logged, so recalled memory must enter the log, not just the request.
    * `remember/2` appends one dated line to the *innermost writable* layer.
      Layers default to read-only (`writable: false`); a composition with no
      writable layer answers `{:error, %{type: :no_writable_layer}}`.
    * `update_many/2` rewrites lines: every update is `%{match, replacement}`,
      matched as a substring against existing lines; each matching line is
      replaced by one dated replacement line. All matches are validated
      before anything is written — a call with an unmatched `match` fails
      wholesale (`{:error, %{type: :no_match, ...}}`) and changes nothing.
    * `delete/2` removes every line containing `match`.

  Events: `:"memory/recall"`, `:"memory/remember"`, `:"memory/update"` and
  `:"memory/delete"` are emitted on the scope's event bus.
  """

  use Dexterous.Component, provide: [:memory]

  alias Dexterous.Context

  @memory_file "MEMORY.md"

  @typedoc "The memory handle, the value bound to the `:memory` coeffect."
  @type t :: %__MODULE__{scope: Context.scope(), layers: [map()]}

  defstruct [:scope, layers: []]

  ## Component

  @impl true
  def apply(ctx, config) do
    layers =
      config
      |> Keyword.get(:layers, [])
      |> Enum.map(fn {id, dir, opts} ->
        %{id: id, dir: Path.expand(dir), writable: Keyword.get(opts, :writable, false)}
      end)

    Context.set(ctx, :memory, %__MODULE__{scope: ctx.scope, layers: layers})
  end

  ## API

  @doc "Concatenate the layers' memory, most specific first. Empty when no layer has content."
  @spec recall(t()) :: String.t()
  def recall(%__MODULE__{} = memory) do
    sections =
      memory.layers
      |> Enum.map(fn layer -> {layer.id, read_layer(layer.dir)} end)
      |> Enum.reject(fn {_id, content} -> content == "" end)
      |> Enum.map(fn {id, content} -> "## Memory — #{id}\n\n#{content}" end)

    text = Enum.join(sections, "\n\n")

    Context.emit(Context.new(memory.scope), :"memory/recall", %{
      layers: Enum.map(memory.layers, & &1.id),
      bytes: byte_size(text)
    })

    text
  end

  @doc """
  Append one dated line to the innermost writable layer's `MEMORY.md`.
  Returns `{:ok, path}` or `{:error, %{type: :no_writable_layer}}`.
  """
  @spec remember(t(), String.t()) :: {:ok, String.t()} | {:error, map()}
  def remember(%__MODULE__{} = memory, content) when is_binary(content) do
    with {:ok, layer} <- writable_layer(memory) do
      File.mkdir_p!(layer.dir)
      path = memory_path(layer)
      File.write!(path, "- [#{today()}] #{String.trim(content)}\n", [:append])

      Context.emit(Context.new(memory.scope), :"memory/remember", %{layer: layer.id, path: path})

      {:ok, path}
    end
  end

  @doc """
  Replace lines in the innermost writable layer. `updates` is a list of
  `%{match, replacement}` maps: every line containing `match` (substring,
  case-sensitive) is replaced by one dated `replacement` line. Atomic: if any
  `match` finds no line, the whole call fails with
  `{:error, %{type: :no_match, match: ...}}` and nothing is written.
  """
  @spec update_many(t(), [map()]) :: {:ok, map()} | {:error, map()}
  def update_many(%__MODULE__{} = memory, updates) when is_list(updates) do
    with {:ok, layer} <- writable_layer(memory),
         {:ok, lines} <- read_lines(layer),
         :ok <- validate_matches(updates, lines) do
      date = today()

      {lines, changed} =
        Enum.map_reduce(lines, 0, fn line, changed ->
          case Enum.find(updates, &String.contains?(line, &1["match"])) do
            nil -> {line, changed}
            update -> {"- [#{date}] #{String.trim(update["replacement"])}", changed + 1}
          end
        end)

      path = memory_path(layer)
      File.mkdir_p!(layer.dir)
      File.write!(path, Enum.map_join(lines, "\n", & &1) <> newline_if_any(lines))

      Context.emit(Context.new(memory.scope), :"memory/update", %{
        layer: layer.id,
        path: path,
        updated: changed
      })

      {:ok, %{path: path, updated: changed}}
    end
  end

  @doc """
  Remove every line containing `match` from the innermost writable layer.
  No match fails with `{:error, %{type: :no_match, ...}}`.
  """
  @spec delete(t(), String.t()) :: {:ok, map()} | {:error, map()}
  def delete(%__MODULE__{} = memory, match) when is_binary(match) do
    with {:ok, layer} <- writable_layer(memory),
         {:ok, lines} <- read_lines(layer),
         :ok <- validate_matches([%{"match" => match}], lines) do
      {kept, deleted} =
        Enum.reduce(lines, {[], 0}, fn line, {kept, deleted} ->
          if String.contains?(line, match),
            do: {kept, deleted + 1},
            else: {[line | kept], deleted}
        end)

      kept = Enum.reverse(kept)
      path = memory_path(layer)
      File.mkdir_p!(layer.dir)
      File.write!(path, Enum.map_join(kept, "\n", & &1) <> newline_if_any(kept))

      Context.emit(Context.new(memory.scope), :"memory/delete", %{
        layer: layer.id,
        path: path,
        deleted: deleted
      })

      {:ok, %{path: path, deleted: deleted}}
    end
  end

  ## Internal

  defp writable_layer(%__MODULE__{layers: layers}) do
    case Enum.find(layers, & &1.writable) do
      nil ->
        {:error,
         %{type: :no_writable_layer, message: "no writable memory layer in this composition"}}

      layer ->
        {:ok, layer}
    end
  end

  defp memory_path(layer), do: Path.join(layer.dir, @memory_file)

  defp today, do: Date.utc_today() |> Date.to_iso8601()

  defp read_lines(layer) do
    case File.read(memory_path(layer)) do
      {:ok, content} ->
        {:ok, content |> String.split("\n") |> Enum.reject(&(&1 == ""))}

      {:error, :enoent} ->
        {:error, %{type: :no_memory_file, message: "no memory stored yet in layer #{layer.id}"}}

      {:error, reason} ->
        {:error,
         %{type: :read_failed, message: "cannot read memory: #{:file.format_error(reason)}"}}
    end
  end

  defp validate_matches(updates, lines) do
    Enum.find_value(updates, :ok, fn update ->
      match = update["match"]

      if is_binary(match) and match != "" and Enum.any?(lines, &String.contains?(&1, match)) do
        nil
      else
        {:error,
         %{
           type: :no_match,
           match: match,
           message: "no memory line contains #{inspect(match)} — recall or save first"
         }}
      end
    end)
  end

  defp newline_if_any([]), do: ""
  defp newline_if_any(_lines), do: "\n"

  defp read_layer(dir) do
    case File.read(Path.join(dir, @memory_file)) do
      {:ok, content} -> cap(content)
      {:error, _} -> ""
    end
  end

  defp cap(content) do
    if byte_size(content) > @max_layer_bytes do
      String.slice(content, 0, @max_layer_bytes) <> "\n... (memory truncated)"
    else
      String.trim(content)
    end
  end
end

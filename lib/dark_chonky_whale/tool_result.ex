defmodule DarkChonkyWhale.ToolResult do
  @moduledoc """
  Provider-neutral tool results and their ReqLLM projection.

  Tool modules keep the Elixir `{:ok, output}` / `{:error, reason}` contract.
  This module performs the one boundary conversion into the durable message
  shape: model-visible `content`, machine/UI `details`, and an `isError` flag
  that describes tool settlement rather than a subprocess's exit status.

  Legacy flat `tool/result` payloads are normalized in memory during replay;
  their disk representation is not rewritten.
  """

  alias ReqLLM.Message.ContentPart

  @type message :: %{
          String.t() => term()
        }

  @doc "Build a canonical result for one tool call and callback result."
  @spec from_result(String.t(), String.t(), {:ok, term()} | {:error, term()}, integer()) ::
          message()
  def from_result(tool_call_id, tool_name, result, timestamp \\ now()) do
    {is_error, text, details} = normalize(result)

    %{
      "role" => "toolResult",
      "toolCallId" => tool_call_id,
      "toolName" => tool_name,
      "content" => [%{"type" => "text", "text" => text}],
      "details" => details,
      "isError" => is_error,
      "timestamp" => timestamp
    }
  end

  @doc "Normalize a legacy flat `tool/result` payload."
  @spec from_legacy(map(), integer()) :: message()
  def from_legacy(data, timestamp \\ now()) do
    output = data["output"]

    result =
      case legacy_error(output) do
        {:ok, error} -> {:error, error}
        :error -> {:ok, output}
      end

    from_result(data["tool_call_id"], data["name"], result, timestamp)
  end

  @doc "Extract the call identity from either a canonical or legacy event payload."
  @spec call_id(map()) :: String.t() | nil
  def call_id(%{"message" => %{"toolCallId" => id}}), do: id
  def call_id(%{"tool_call_id" => id}), do: id
  def call_id(_data), do: nil

  @doc "Project a canonical result to ReqLLM's tool-role message."
  @spec to_reqllm(message()) :: ReqLLM.Message.t()
  def to_reqllm(message) do
    content =
      Enum.map(message["content"] || [], fn
        %{"type" => "text", "text" => text} -> ContentPart.text(text)
        %{"text" => text} -> ContentPart.text(text)
        other -> ContentPart.text(encode_output(other))
      end)

    ReqLLM.Context.tool_result_message(
      message["toolName"],
      message["toolCallId"],
      content,
      %{is_error: message["isError"]}
    )
  end

  defp normalize({:ok, output}), do: {false, encode_output(output), %{}}

  defp normalize({:error, reason}) do
    {true, error_message(reason), %{"error" => error_record(reason)}}
  end

  defp encode_output(output) when is_binary(output), do: output

  defp encode_output(output) do
    Jason.encode!(output)
  rescue
    _exception -> output |> inspect() |> String.replace_invalid()
  end

  defp error_record(reason) when is_map(reason) do
    type = Map.get(reason, :type) || Map.get(reason, "type") || :tool

    %{
      "type" => to_string(type),
      "message" => error_message(reason)
    }
  end

  defp error_record(reason), do: %{"type" => "tool", "message" => error_message(reason)}

  defp error_message(reason) when is_binary(reason), do: reason

  defp error_message(reason) when is_map(reason) do
    case Map.get(reason, :message) || Map.get(reason, "message") do
      nil -> inspect(reason)
      message -> to_string(message)
    end
  end

  defp error_message(reason), do: inspect(reason)

  defp legacy_error(%{"ok" => false, "error" => error}), do: {:ok, error}
  defp legacy_error(%{ok: false, error: error}), do: {:ok, error}
  defp legacy_error(_output), do: :error

  defp now, do: System.system_time(:millisecond)
end

defmodule DarkChonkyWhale.LLMTest do
  use ExUnit.Case, async: false

  alias DarkChonkyWhale.LLM
  alias DarkChonkyWhale.LLM.Client
  alias Dexterous.Context

  defmodule FakeBackend do
    @moduledoc false

    def stream_text(model, context, opts) do
      send(self(), {:backend_stream, model, context, opts})

      {:ok,
       %ReqLLM.StreamResponse{
         stream: [ReqLLM.StreamChunk.text("hel"), ReqLLM.StreamChunk.text("lo")],
         metadata_handle: nil,
         cancel: fn -> :ok end,
         model: model,
         context: context
       }}
    end

    def generate_text(model, context, opts) do
      send(self(), {:backend_generate, model, context, opts})
      {:ok, %{usage: %{input_tokens: 1, output_tokens: 2}}}
    end
  end

  setup do
    scope = :"llm_test_#{System.unique_integer([:positive])}"
    {:ok, ctx: Context.new(scope), scope: scope}
  end

  test "the component provides a configured :llm client", %{ctx: ctx, scope: scope} do
    {:ok, _fiber} =
      Context.use(ctx, LLM, model: "test:model", temperature: 0.5, backend: FakeBackend)

    client =
      eventually(fn ->
        case Context.get(ctx, :llm) do
          {:ok, client} -> client
          :error -> nil
        end
      end)

    assert %Client{model: "test:model", scope: ^scope, backend: FakeBackend, opts: opts} = client
    assert opts == [temperature: 0.5]
  end

  test "stream/3 runs the request through the llm/request waterfall", %{ctx: ctx, scope: scope} do
    {:ok, _} =
      Context.on(ctx, :"llm/request", fn request, next ->
        next.(%{request | model: "rewritten:model"})
      end)

    client = %Client{scope: scope, model: "orig:model", backend: FakeBackend}
    assert {:ok, _response} = Client.stream(client, "hi")

    assert_received {:backend_stream, "rewritten:model", %ReqLLM.Context{}, []}
  end

  test "stream/3 broadcasts every chunk as an llm/chunk event", %{ctx: ctx, scope: scope} do
    test_pid = self()

    {:ok, _} =
      Context.on(ctx, :"llm/chunk", fn chunk -> send(test_pid, {:chunk, chunk.text}) end)

    client = %Client{scope: scope, model: "test:model", backend: FakeBackend}
    {:ok, response} = Client.stream(client, "hi")

    assert [%{type: :content, text: "hel"}, %{type: :content, text: "lo"}] =
             Enum.to_list(response.stream)

    assert_received {:chunk, "hel"}
    assert_received {:chunk, "lo"}
  end

  test "generate/3 emits the settled usage", %{ctx: ctx, scope: scope} do
    test_pid = self()
    {:ok, _} = Context.on(ctx, :"llm/usage", fn event -> send(test_pid, {:usage, event}) end)

    client = %Client{scope: scope, model: "test:model", backend: FakeBackend}
    assert {:ok, %{usage: %{input_tokens: 1}}} = Client.generate(client, "hi")

    assert_received {:backend_generate, "test:model", %ReqLLM.Context{}, []}
    assert_received {:usage, %{usage: %{input_tokens: 1, output_tokens: 2}}}
  end

  describe "relay and compat normalization" do
    test "anthropic base_url strips trailing /v1 and promotes bearer api_key to oauth access_token" do
      {_model, opts} =
        LLM.normalize_config(
          model: "anthropic:claude-sonnet-4-5",
          base_url: "https://relay.example.com/api/anthropic/v1/",
          api_key: "sk-relay-123",
          auth_mode: :bearer
        )

      assert opts[:base_url] == "https://relay.example.com/api/anthropic"
      assert opts[:auth_mode] == :oauth
      assert opts[:access_token] == "sk-relay-123"
    end

    test "google custom base_url defaults google_auth_header: true for relay compatibility" do
      {_model, opts} =
        LLM.normalize_config(
          model: "google:gemini-2.5-pro",
          base_url: "https://relay.example.com/v1beta/",
          api_key: "sk-google-relay"
        )

      assert opts[:base_url] == "https://relay.example.com/v1beta"
      assert opts[:provider_options][:google_auth_header] == true
    end

    test "google_vertex custom base_url + api_key adapts via access_token, project_id, and on_finch_request" do
      {_model, opts} =
        LLM.normalize_config(
          model: "google_vertex:claude-sonnet-4-5@20250929",
          base_url: "https://vertex-relay.example.com:8443/vertex",
          api_key: "sk-vertex-relay"
        )

      assert opts[:access_token] == "sk-vertex-relay"
      assert opts[:project_id] == "default"
      refute Keyword.has_key?(opts, :base_url)
      assert is_function(opts[:on_finch_request], 1)

      finch_req =
        Finch.build(
          :post,
          "https://aiplatform.googleapis.com/v1/projects/default/locations/global/publishers/anthropic/models/claude-sonnet-4-5@20250929:streamRawPredict",
          [],
          "{}"
        )

      rewritten = opts[:on_finch_request].(finch_req)
      assert rewritten.scheme == :https
      assert rewritten.host == "vertex-relay.example.com"
      assert rewritten.port == 8443

      assert rewritten.path ==
               "/vertex/v1/projects/default/locations/global/publishers/anthropic/models/claude-sonnet-4-5@20250929:streamRawPredict"
    end
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: nil

  defp eventually(fun, attempts) do
    case fun.() do
      nil ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      other ->
        other
    end
  end
end

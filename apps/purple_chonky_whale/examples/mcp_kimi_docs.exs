# Smoke: connect to the Kimi API docs site's public MCP server (no auth)
# over streamable HTTP, then call its search tool through the :tools seam —
# the same path a composition's mcp_servers config takes.
#
#   mix run examples/mcp_kimi_docs.exs ["query"]

alias PurpleChonkyWhale.Tools
alias Dexterous.Context
alias DexterousLoader.Entry

query = List.first(System.argv()) || "Kimi K3 context window"

ctx = Dexterous.root()

{:ok, _loader} =
  DexterousLoader.start_link(ctx, [
    %Entry{
      id: :tools,
      component: Tools,
      config: [
        tools: [],
        mcp_servers: [
          %{
            name: :kimi_docs,
            transport:
              {:streamable_http,
               base_url: "https://platform.kimi.com", mcp_path: "/docs/mcp"},
            timeout: 30_000
          }
        ]
      ]
    }
  ])

tools =
  Enum.reduce_while(1..300, nil, fn _, _ ->
    case Context.get(ctx, :tools) do
      {:ok, value} -> {:halt, value}
      :error -> {:cont, Process.sleep(100)}
    end
  end) || raise ":tools was not bound in time"

schemas = Tools.schemas(tools)

IO.puts("== #{length(schemas)} MCP tools registered ==")

for schema <- schemas do
  IO.puts("  #{schema.name} — #{String.slice(schema.description, 0, 80)}")
end

search =
  Enum.find_value(schemas, fn schema ->
    if schema.name =~ "search", do: schema.name
  end) || raise "no search tool in catalog"

IO.puts("\n== calling #{search} with query #{inspect(query)} ==\n")

case Tools.execute(tools, search, %{"query" => query}) do
  {:ok, text} when is_binary(text) -> IO.puts(text)
  other -> IO.inspect(other, label: "result", limit: :infinity)
end

defmodule DarkChonkyWhale.LLM do
  @moduledoc """
  The `:llm` seam provider: a component whose config selects the model and
  the transport options, and whose provision is a
  `DarkChonkyWhale.LLM.Client` bound to the composition's scope.

      %DexterousLoader.Entry{
        id: :llm,
        component: DarkChonkyWhale.LLM,
        config: [model: "openrouter:anthropic/claude-sonnet-4.5", temperature: 0.7]
      }

  Relay / custom-endpoint examples (`:base_url` + `:api_key`):

      # Anthropic-compatible relay (/v1/messages)
      config: [
        model: "anthropic:claude-sonnet-4-5",
        base_url: "https://relay.example.com/api/anthropic",
        api_key: "sk-..."
      ]

      # Google Gemini relay (:streamGenerateContent; defaults google_auth_header: true)
      config: [
        model: "google:gemini-2.5-pro",
        base_url: "https://relay.example.com/v1beta",
        api_key: "sk-..."
      ]

      # Google Vertex AI relay (:streamRawPredict / :streamGenerateContent)
      config: [
        model: "google_vertex:claude-sonnet-4-5@20250929",
        base_url: "https://relay.example.com",
        api_key: "sk-..."
      ]

  Config:

    * `:model` (required) — a ReqLLM model specification
      (`"provider:model"`, or anything `ReqLLM.model/1` accepts)
    * `:base_url` — optional custom endpoint URL for relays/proxies. Trailing
      slashes are stripped; for `:anthropic` a trailing `"/v1"` is also
      stripped because ReqLLM appends `"/v1/messages"`; for `:google` a custom
      `:base_url` defaults `provider_options: [google_auth_header: true]`
    * `:auth_mode` — `:api_key` (default), `:oauth`, or `:bearer` (alias for
      `:oauth` that promotes `:api_key` to `:access_token` when needed)
    * any other key — passed through to `ReqLLM.stream_text/3` /
      `generate_text/3` as default options (e.g. `:temperature`,
      `:max_tokens`, `:api_key`, `:provider_options`)
    * `:backend` — internal; the module performing the calls, defaults to
      `ReqLLM`. Not part of the public configuration surface.

  Consumers `inject: [:llm]` and call `Client.stream/3` or
  `Client.generate/3`; every call publishes the seam's events (see
  `DarkChonkyWhale.LLM.Client`).
  """

  use Dexterous.Component, provide: [:llm]

  alias DarkChonkyWhale.LLM.Client
  alias Dexterous.Context

  @impl true
  def apply(ctx, config) do
    {model, opts} = normalize_config(config)

    client = %Client{
      scope: ctx.scope,
      model: model,
      opts: opts,
      backend: Keyword.get(config, :backend, ReqLLM)
    }

    Context.set(ctx, :llm, client)
  end

  @doc false
  def normalize_config(config) when is_list(config) do
    model = Keyword.fetch!(config, :model)
    provider = infer_provider(model)

    opts =
      config
      |> Keyword.drop([:model, :backend])
      |> normalize_base_url(provider)
      |> normalize_auth_mode()
      |> maybe_default_google_auth_header(provider)
      |> maybe_adapt_google_vertex_relay(provider)

    {normalize_model_base_url(model, provider), opts}
  end

  defp infer_provider(%{provider: provider}) when is_atom(provider), do: provider

  defp infer_provider(%{"provider" => provider}) when is_binary(provider),
    do: to_provider_atom(provider)

  defp infer_provider({provider, _id}) when is_atom(provider), do: provider
  defp infer_provider({provider, _id, _opts}) when is_atom(provider), do: provider

  defp infer_provider(spec) when is_binary(spec) do
    with nil <- provider_from_colon_prefix(spec),
         nil <- provider_from_at_suffix(spec) do
      nil
    end
  end

  defp infer_provider(_other), do: nil

  defp provider_from_colon_prefix(spec) do
    case String.split(spec, ":", parts: 2) do
      [prefix, _rest] -> to_provider_atom(prefix)
      _ -> nil
    end
  end

  defp provider_from_at_suffix(spec) do
    case String.split(spec, "@") do
      [_ | _] = parts when length(parts) > 1 -> parts |> List.last() |> to_provider_atom()
      _ -> nil
    end
  end

  @known_providers %{
    "anthropic" => :anthropic,
    "google" => :google,
    "google_vertex" => :google_vertex,
    "openai" => :openai,
    "openrouter" => :openrouter,
    "zenmux" => :zenmux,
    "deepseek" => :deepseek,
    "azure" => :azure,
    "amazon_bedrock" => :amazon_bedrock,
    "groq" => :groq,
    "xai" => :xai,
    "ollama" => :ollama,
    "lmstudio" => :lmstudio,
    "minimax" => :minimax,
    "mistral" => :mistral,
    "moonshot_ai" => :moonshot_ai,
    "zai" => :zai,
    "zai_coder" => :zai_coder
  }

  defp to_provider_atom(name) when is_binary(name) do
    normalized = String.replace(name, "-", "_")

    case Map.fetch(@known_providers, normalized) do
      {:ok, atom} ->
        atom

      :error ->
        try do
          String.to_existing_atom(normalized)
        rescue
          ArgumentError -> nil
        end
    end
  end

  defp normalize_base_url(opts, provider) do
    case Keyword.get(opts, :base_url) do
      url when is_binary(url) and url != "" ->
        Keyword.put(opts, :base_url, clean_base_url(url, provider))

      _ ->
        opts
    end
  end

  defp normalize_model_base_url(%{base_url: url} = model, provider)
       when is_binary(url) and url != "" do
    %{model | base_url: clean_base_url(url, provider)}
  end

  defp normalize_model_base_url(model, _provider), do: model

  defp clean_base_url(url, :anthropic) do
    url
    |> String.trim_trailing("/")
    |> String.replace_suffix("/v1", "")
  end

  defp clean_base_url(url, _provider), do: String.trim_trailing(url, "/")

  defp normalize_auth_mode(opts) do
    case Keyword.get(opts, :auth_mode) do
      mode when mode in [:bearer, "bearer", :oauth, "oauth"] ->
        opts = Keyword.put(opts, :auth_mode, :oauth)

        case {Keyword.get(opts, :access_token), Keyword.get(opts, :api_key)} do
          {nil, api_key} when is_binary(api_key) and api_key != "" ->
            Keyword.put(opts, :access_token, api_key)

          _ ->
            opts
        end

      _ ->
        opts
    end
  end

  defp maybe_default_google_auth_header(opts, :google) do
    if Keyword.has_key?(opts, :base_url) do
      provider_opts = Keyword.get(opts, :provider_options, [])

      if is_list(provider_opts) and not Keyword.has_key?(provider_opts, :google_auth_header) do
        Keyword.put(
          opts,
          :provider_options,
          Keyword.put(provider_opts, :google_auth_header, true)
        )
      else
        opts
      end
    else
      opts
    end
  end

  defp maybe_default_google_auth_header(opts, _provider), do: opts

  # `ReqLLM.Providers.GoogleVertex` builds URLs from `region` + `project_id`
  # and authenticates with `:access_token`. When a caller targets a Vertex
  # relay via `:base_url` / `:api_key`, adapt those options using ReqLLM's
  # public `:access_token`, `:project_id` and `:on_finch_request` hooks so
  # `deps/req_llm` stays untouched.
  defp maybe_adapt_google_vertex_relay(opts, :google_vertex) do
    opts
    |> maybe_promote_vertex_api_key()
    |> maybe_rewrite_vertex_base_url()
  end

  defp maybe_adapt_google_vertex_relay(opts, _provider), do: opts

  defp maybe_promote_vertex_api_key(opts) do
    case {Keyword.get(opts, :access_token), Keyword.get(opts, :api_key)} do
      {nil, api_key} when is_binary(api_key) and api_key != "" ->
        Keyword.put(opts, :access_token, api_key)

      _ ->
        opts
    end
  end

  defp maybe_rewrite_vertex_base_url(opts) do
    case Keyword.pop(opts, :base_url) do
      {nil, opts} ->
        opts

      {base_url, opts} when is_binary(base_url) and base_url != "" ->
        uri = URI.parse(base_url)
        existing_hook = Keyword.get(opts, :on_finch_request)

        rewrite = fn %Finch.Request{} = req ->
          req =
            %{
              req
              | scheme: String.to_existing_atom(uri.scheme || "https"),
                host: uri.host || req.host,
                port: uri.port || URI.default_port(uri.scheme || "https"),
                path: join_uri_path(uri.path, req.path)
            }

          if is_function(existing_hook, 1), do: existing_hook.(req), else: req
        end

        opts
        |> Keyword.put_new(:project_id, "default")
        |> Keyword.put(:on_finch_request, rewrite)
    end
  end

  defp join_uri_path(nil, path), do: path
  defp join_uri_path("", path), do: path
  defp join_uri_path("/", path), do: path
  defp join_uri_path(prefix, path), do: String.trim_trailing(prefix, "/") <> path
end

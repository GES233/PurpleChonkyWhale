defmodule Noctilucent.MixProject do
  use Mix.Project

  def project do
    [
      app: :noctilucent,
      version: "0.1.0",
      elixir: "~> 1.20",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Noctilucent.Application, []}
    ]
  end

  defp deps do
    [
      {:purple_chonky_whale, in_umbrella: true}
    ]
  end
end

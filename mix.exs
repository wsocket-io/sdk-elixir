defmodule WSocketIO.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/wsocket-io/sdk-elixir"

  def project do
    [
      app: :wsocket_io,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Official Elixir SDK for wSocket — realtime pub/sub, presence, history, and push notifications.",
      package: package(),
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:websockex, "~> 0.4.3"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.4"}
    ]
  end

  defp package do
    [
      name: "wsocket_io",
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end
end

defmodule Direct.MixProject do
  use Mix.Project

  @version "0.1.0"
  @description "Play a video release in the browser without re-encoding: ffmpeg copies the video into a fragmented MP4 that plays while it is written, audio as AAC, audio tracks as HLS renditions, parts begun mid-film."
  @source_url "https://github.com/alexdont/direct_stream"

  def project do
    [
      app: :direct,
      version: @version,
      description: @description,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:fmp4, "~> 0.1"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.39", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      name: "direct",
      maintainers: ["Alexander Don"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      name: "Direct",
      source_ref: "v#{@version}",
      source_url: @source_url,
      main: "Direct",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"]
    ]
  end
end

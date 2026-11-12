defmodule Direct.Caps do
  @moduledoc """
  What a browser decodes, as it reported on connecting: a map with `:hevc`,
  `:av1`, `:vp9` (and whatever else you carry, such as `:uhd` for 4K). The
  page can learn these with `MediaSource.isTypeSupported` /
  `canPlayType` and send them as connect params:

      {hevc: v.canPlayType('video/mp4; codecs="hvc1.1.6.L120.B0"') !== "",
       av1: MediaSource.isTypeSupported('video/mp4; codecs="av01.0.08M.08"'),
       vp9: MediaSource.isTypeSupported('video/mp4; codecs="vp09.00.10.08"')}
  """

  @keys [:hevc, :av1, :vp9, :uhd, :local]

  @doc """
  The browser's abilities from string-keyed params (`%{"hevc" => true}`) as
  a map of atoms; anything missing is "no". `:keys` adds names beyond
  `hevc av1 vp9 uhd local`.
  """
  @spec from_params(map(), keyword()) :: map()
  def from_params(params, opts \\ [])

  def from_params(params, opts) when is_map(params) do
    for key <- @keys ++ Keyword.get(opts, :keys, []), into: %{} do
      {key, Map.get(params, Atom.to_string(key)) == true}
    end
  end

  def from_params(_, _), do: %{}

  @doc """
  Whether a codec, as a release name or ffprobe says it (`"hevc"`, `"x265"`,
  `"av1"`, …), is one the browser with `caps` decodes itself. H.264 is,
  everywhere.
  """
  @spec decodable?(String.t() | nil, map()) :: boolean()
  def decodable?(codec, caps) when is_binary(codec) and is_map(caps) do
    case String.downcase(codec) do
      c when c in ["h264", "x264", "avc", "avc1"] -> true
      c when c in ["hevc", "h265", "x265"] -> Map.get(caps, :hevc) == true
      "av1" -> Map.get(caps, :av1) == true
      "vp9" -> Map.get(caps, :vp9) == true
      _ -> false
    end
  end

  def decodable?(_codec, _caps), do: false
end

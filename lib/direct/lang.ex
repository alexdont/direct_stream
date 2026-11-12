defmodule Direct.Lang do
  @moduledoc "Language codes as files carry them (`eng`, `fre`, `jpn`) — names and two-letter codes."

  @names %{
    "en" => "English",
    "ja" => "Japanese",
    "fr" => "French",
    "es" => "Spanish",
    "de" => "German",
    "it" => "Italian",
    "pt" => "Portuguese",
    "ru" => "Russian",
    "ko" => "Korean",
    "zh" => "Chinese",
    "ar" => "Arabic",
    "nl" => "Dutch",
    "pl" => "Polish",
    "tr" => "Turkish",
    "sv" => "Swedish",
    "eng" => "English",
    "jpn" => "Japanese",
    "fre" => "French",
    "fra" => "French",
    "spa" => "Spanish",
    "ger" => "German",
    "deu" => "German",
    "ita" => "Italian",
    "por" => "Portuguese",
    "rus" => "Russian",
    "kor" => "Korean",
    "chi" => "Chinese",
    "zho" => "Chinese",
    "ara" => "Arabic",
    "dut" => "Dutch",
    "nld" => "Dutch",
    "pol" => "Polish",
    "tur" => "Turkish",
    "swe" => "Swedish"
  }

  @short %{
    "eng" => "en",
    "jpn" => "ja",
    "fre" => "fr",
    "fra" => "fr",
    "spa" => "es",
    "ger" => "de",
    "deu" => "de",
    "ita" => "it",
    "por" => "pt",
    "rus" => "ru",
    "kor" => "ko",
    "chi" => "zh",
    "zho" => "zh",
    "ara" => "ar",
    "dut" => "nl",
    "nld" => "nl",
    "pol" => "pl",
    "tur" => "tr",
    "swe" => "sv"
  }

  @doc "A language code (`fr`, `fre`, `jpn`) as a name; unknown codes are shown upper-cased."
  @spec name(String.t() | nil) :: String.t()
  def name(code) when is_binary(code) and code != "",
    do: Map.get(@names, String.downcase(code), String.upcase(code))

  def name(_), do: "Unknown"

  @doc "The two-letter code for a language code (`fre` → `fr`), for matching a preference."
  @spec short(String.t() | nil) :: String.t()
  def short(code) when is_binary(code) do
    c = String.downcase(code)
    Map.get(@short, c, String.slice(c, 0, 2))
  end

  def short(_), do: ""
end

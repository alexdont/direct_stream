defmodule Direct.Playlist do
  @moduledoc """
  HLS master playlists: for a multi-audio conversion, for ffmpeg's own
  multi-audio TS output made fit for a player, and subtitle renditions
  added to either.
  """
  alias Direct.Lang

  @doc """
  The master playlist of a multi-audio conversion: every track as a
  switchable rendition of one group. The default is the first track in the
  first preferred language the release has (`:prefer`, a code or a list in
  order), else the first track. Without a CODECS attribute on purpose —
  hls.js on Firefox stops at the HEVC string. The playlists named are those
  of `:part`; `:subs` are listed as subtitle renditions.
  """
  @spec master([map()], pos_integer(), keyword()) :: String.t()
  def master(tracks, bandwidth, opts \\ []) do
    part = Keyword.get(opts, :part, 0)
    subs = Keyword.get(opts, :subs, [])
    chosen = default_track(tracks, Keyword.get(opts, :prefer))
    q = Direct.part_query(part)

    renditions =
      tracks
      |> Enum.with_index()
      |> Enum.map(fn {t, i} ->
        ~s(#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="#{t.name}"#{lang_attr(t.lang)},DEFAULT=#{yes(i == chosen)},AUTOSELECT=YES,URI="#{t.file}.m3u8#{q}")
      end)

    audio = if tracks == [], do: "", else: ~s(,AUDIO="aud")
    subtitles = if subs == [], do: "", else: ~s(,SUBTITLES="subs")

    Enum.join(
      ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"] ++
        renditions ++
        subtitle_renditions(subs, part) ++
        [~s(#EXT-X-STREAM-INF:BANDWIDTH=#{bandwidth}#{audio}#{subtitles}), "video.m3u8#{q}"],
      "\n"
    ) <> "\n"
  end

  @doc "The `#EXT-X-MEDIA` lines for subtitle tracks (of `part`); none shown unless picked."
  def subtitle_renditions(subs, part \\ 0) do
    q = Direct.part_query(part)

    Enum.map(subs, fn t ->
      ~s(#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="#{t.name}"#{lang_attr(t.lang)},DEFAULT=NO,AUTOSELECT=NO,URI="#{t.file}.m3u8#{q}")
    end)
  end

  # The index of the first track in the first preferred language the release has, else 0.
  defp default_track(tracks, prefer) do
    prefer
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.find_value(0, fn p ->
      Enum.find_index(tracks, &(&1.lang != "" and Lang.short(&1.lang) == p))
    end)
  end

  defp lang_attr(""), do: ""
  defp lang_attr(nil), do: ""
  defp lang_attr(lang), do: ~s(,LANGUAGE="#{Lang.short(lang)}")

  defp yes(true), do: "YES"
  defp yes(false), do: "NO"

  @doc """
  ffmpeg's master playlist for a multi-audio TS conversion, made fit for the
  player: ffmpeg names every rendition `audio_N`, and tracks of one language
  can all point at one rendition file, so the list is cut down to one entry
  per file, named by its language, with the preferred language the default.
  Options as `master/3` (`:prefer`, `:subs`).
  """
  @spec tidy_master(String.t(), keyword()) :: String.t()
  def tidy_master(content, opts \\ []) do
    subs = Keyword.get(opts, :subs, [])
    lines = String.split(content, "\n")
    media = Enum.filter(lines, &String.starts_with?(&1, "#EXT-X-MEDIA:TYPE=AUDIO"))

    tracks =
      media
      |> Enum.map(fn line -> %{uri: attr(line, "URI"), lang: attr(line, "LANGUAGE") || ""} end)
      |> Enum.uniq_by(& &1.uri)
      |> Enum.with_index()
      |> Enum.map(fn {t, n} ->
        Map.merge(t, %{index: n, name: Direct.Command.track_name(t.lang, n), file: t.uri})
      end)
      |> Direct.Command.unique_names()

    if tracks == [] do
      with_subtitles(content, subs)
    else
      chosen = default_track(tracks, Keyword.get(opts, :prefer))

      renditions =
        tracks
        |> Enum.with_index()
        |> Enum.map(fn {t, i} ->
          ~s(#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="group_aud",NAME="#{t.name}"#{lang_attr(t.lang)},DEFAULT=#{yes(i == chosen)},AUTOSELECT=YES,URI="#{t.uri}")
        end)

      {before, after_media} =
        Enum.split_while(lines, &(not String.starts_with?(&1, "#EXT-X-MEDIA:TYPE=AUDIO")))

      rest = Enum.reject(after_media, &String.starts_with?(&1, "#EXT-X-MEDIA:TYPE=AUDIO"))
      with_subtitles(Enum.join(before ++ renditions ++ rest, "\n"), subs)
    end
  end

  @doc """
  A master playlist with subtitle renditions added: their `#EXT-X-MEDIA`
  lines before the variant, which gets `SUBTITLES="subs"`. Nothing changes
  without tracks.
  """
  def with_subtitles(master, []), do: master

  def with_subtitles(master, subs) do
    master
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      if String.starts_with?(line, "#EXT-X-STREAM-INF:"),
        do: subtitle_renditions(subs) ++ [line <> ~s(,SUBTITLES="subs")],
        else: [line]
    end)
    |> Enum.join("\n")
  end

  @doc "A single media playlist under a master, so subtitle renditions can ride along."
  def wrap_media(media_name, subs, bandwidth \\ 8_000_000),
    do:
      with_subtitles(
        "#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-STREAM-INF:BANDWIDTH=#{bandwidth}\n#{media_name}\n",
        subs
      )

  defp attr(line, name) do
    case Regex.run(~r/(?:^|,)#{name}="([^"]*)"/, line) do
      [_, v] -> v
      _ -> nil
    end
  end
end

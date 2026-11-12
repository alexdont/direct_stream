defmodule Direct.Command do
  @moduledoc """
  The ffmpeg command line for a conversion: pure, so what is run can be
  read and tested without running it.

  Video copied as it is; audio copied when it is AAC already, else AAC
  stereo (a browser plays stereo regardless, and TrueHD 7.1 cannot be put
  in AAC as it is). Fragments at keyframes, at least two seconds long, in
  the MP4 muxer's own form. One audio track goes into `media.mp4` with the
  video; several each get their own `audioN.mp4`, so the player can switch
  between them as HLS renditions. Text subtitles come out as WebVTT files.

  HEVC goes through MPEG-TS on the way: a release often keeps the parameter
  sets inside the video rather than in the container, and an MP4 written
  straight from it has an empty `hvcC` that nothing decodes. Read back from
  TS, ffmpeg's parser puts them where `hvc1` needs them.

  `delay_moov` holds the header back until the first fragment: the AAC
  decoder configuration comes out of the TS stream with its first packet,
  and a header written before that has none, which Safari refuses to decode
  (ffmpeg plays it anyway, so a local check does not show it).

  A part begun later in the file (`-ss`, which lands on the keyframe
  before) keeps the file's own clock: `-copyts` leaves the times as they
  are and `frag_discont` makes the first fragment carry them, so the video,
  each audio file and the subtitles all agree on where they are — without
  it the MP4 muxer counts each file from its own first packet, and audio
  that begins a second after the keyframe comes out a second early. The TS
  stage would add its usual 1.4 s to everything; `-muxdelay 0` stops it.
  """
  alias Direct.Lang

  @image_subs ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle"]

  @doc "The shell command (one pipeline) converting `url` into `dir`, from `part` seconds in."
  @spec build(String.t(), Path.t(), [Direct.Probe.stream()], non_neg_integer()) :: String.t()
  def build(url, dir, streams, part) do
    audios = audio_tracks(streams)
    subs = subtitle_tracks(streams)
    video = Direct.Probe.codec(streams, "video")
    multi? = length(audios) > 1
    out = fn base, ext -> Path.join(dir, Direct.part_name(base, ext, part)) end

    sub_outputs =
      Enum.flat_map(subs, fn s ->
        [
          "-map",
          "0:#{s.index}",
          "-c:s",
          "webvtt",
          "-flush_packets",
          "1",
          "-f",
          "webvtt",
          out.(s.file, ".vtt")
        ]
      end)

    {seek, copyts, discont, ts_delay} =
      if part > 0,
        do:
          {["-ss", Integer.to_string(part)], ["-copyts"], "+frag_discont",
           ~w(-muxdelay 0 -muxpreload 0)},
        else: {[], [], "", []}

    read =
      ~w(ffmpeg -nostdin -loglevel error -rw_timeout 20000000) ++ seek ++ ["-i", url] ++ copyts

    # The input's audio streams, in order, as `0:a:N`; `audios` lists them in that order.
    audio_maps = Enum.flat_map(0..(length(audios) - 1)//1, &["-map", "0:a:#{&1}"])

    mp4 =
      ["-movflags", "frag_keyframe+empty_moov+default_base_moof+delay_moov" <> discont] ++
        ~w(-min_frag_duration 2000000 -f mp4)

    # A file of audio alone has no keyframes to cut at: cut it every two seconds, or the muxer
    # writes the whole track as one fragment at the end, and nothing of it plays until then.
    audio_mp4 = ~w(-frag_duration 2000000) ++ mp4

    # `-ac` takes the same stream specifier, but `-ac:1` means output stream 1 *of any kind*: with
    # the video mapped first, `-ac:0` lands on the video and the audio stays 5.1, which AAC then
    # writes with an in-band channel layout that browsers cannot decode (a black screen).
    ac_spec = fn
      "" -> ""
      ":" <> n -> ":a:" <> n
    end

    # What makes each audio stream AAC (the Nth output audio stream, or all of them).
    to_aac = fn {a, _n}, spec ->
      if a.codec == "aac",
        do: ["-c:a#{spec}", "copy"],
        else: ["-c:a#{spec}", "aac", "-b:a#{spec}", "192k", "-ac#{ac_spec.(spec)}", "2"]
    end

    if video in ["hevc", "h265"] do
      # The TS carries the video and every audio track; the second ffmpeg splits them out.
      first =
        read ++
          ~w(-map 0:v:0) ++
          audio_maps ++
          ~w(-sn -c:v copy) ++
          Enum.flat_map(Enum.with_index(audios), &to_aac.(&1, ":#{elem(&1, 1)}")) ++
          ts_delay ++ ~w(-f mpegts -) ++ sub_outputs

      second =
        ~w(ffmpeg -nostdin -loglevel error -f mpegts -i -) ++
          copyts ++
          if multi? do
            ~w(-map 0:v:0 -c:v copy -tag:v hvc1) ++
              mp4 ++
              [out.("media", ".mp4")] ++
              Enum.flat_map(Enum.with_index(audios), fn {a, n} ->
                ~w(-map 0:a:#{n} -c:a copy -bsf:a aac_adtstoasc) ++
                  audio_mp4 ++ [out.(a.file, ".mp4")]
              end)
          else
            ~w(-map 0:v:0) ++
              if(audios != [], do: ~w(-map 0:a:0 -bsf:a aac_adtstoasc), else: []) ++
              ~w(-c copy -tag:v hvc1) ++ mp4 ++ [out.("media", ".mp4")]
          end

      shell(first) <> " | " <> shell(second)
    else
      if multi? do
        shell(
          read ++
            ~w(-map 0:v:0 -sn -c:v copy) ++
            mp4 ++
            [out.("media", ".mp4")] ++
            Enum.flat_map(Enum.with_index(audios), fn {a, n} = pair ->
              ~w(-map 0:a:#{n}) ++ to_aac.(pair, "") ++ audio_mp4 ++ [out.(a.file, ".mp4")]
            end) ++ sub_outputs
        )
      else
        audio_args = if audios == [], do: [], else: to_aac.({hd(audios), 0}, "")

        shell(
          read ++
            ~w(-map 0:v:0) ++
            Enum.take(audio_maps, 2) ++
            ~w(-sn -c:v copy) ++ audio_args ++ mp4 ++ [out.("media", ".mp4")] ++ sub_outputs
        )
      end
    end
  end

  defp shell(args),
    do: Enum.map_join(args, " ", &("'" <> String.replace(&1, "'", "'\\''") <> "'"))

  @doc """
  The audio tracks in the file's order, named for the player's menu:
  `[%{index: 1, codec: "eac3", lang: "fre", file: "audio0", name: "French"}]`.
  Two tracks of one language (a commentary, a second mix) are told apart by number.
  """
  def audio_tracks(streams) do
    streams
    |> Enum.filter(&(&1.kind == "audio"))
    |> Enum.with_index()
    |> Enum.map(fn {s, n} ->
      %{
        index: s.index,
        codec: s.codec,
        lang: String.trim(s.lang || ""),
        file: "audio#{n}",
        name: track_name(s.lang, n)
      }
    end)
    |> unique_names()
  end

  @doc "A track's name from its language code, or `Track N` without one."
  def track_name(lang, n) do
    case String.trim(lang || "") do
      "" -> "Track #{n + 1}"
      l -> Lang.name(l)
    end
  end

  @doc "Tracks with the same name numbered apart (`Russian 1`, `Russian 2`), in index order."
  def unique_names(tracks) do
    tracks
    |> Enum.group_by(& &1.name)
    |> Enum.flat_map(fn
      {_name, [one]} ->
        [one]

      {name, same} ->
        Enum.with_index(same, 1) |> Enum.map(fn {t, k} -> %{t | name: "#{name} #{k}"} end)
    end)
    |> Enum.sort_by(& &1.index)
  end

  @doc "The text subtitle streams, as files `subN.vtt` (image subtitles are left out)."
  def subtitle_tracks(streams) do
    streams
    |> Enum.filter(&(&1.kind == "subtitle" and &1.codec not in @image_subs))
    |> Enum.with_index()
    |> Enum.map(fn {s, n} -> %{index: s.index, lang: s.lang, file: "sub#{n}"} end)
  end
end

defmodule Direct do
  @moduledoc """
  A conversion that leaves the video alone.

  A browser that can decode a release's video itself (H.264 everywhere, HEVC
  on anything Apple makes and on a desktop with a hardware decoder, AV1 on
  most) only needs the container changed and the audio put into AAC. So
  ffmpeg copies the video into one **fragmented MP4 that grows while it
  plays**, and the HLS playlist served for it names byte ranges of that file
  (`Fmp4`). That costs a fraction of a core instead of the several a
  re-encode takes — and it is the only form of HEVC Safari plays through
  HLS: it refuses the segments ffmpeg's own HLS muxer makes of the same
  video and plays the MP4 muxer's fragments.

      # the browser said what it decodes when it connected
      caps = Direct.Caps.from_params(params)

      case Direct.start(url, id: id, caps: caps, from: resume_seconds) do
        {:ok, id, part} -> serve the playlist at /stream/id/playlist.m3u8?from=part
        :skip -> this browser cannot decode the video; re-encode instead
        {:error, :unreachable} -> the file could not be read
      end

  Add `Direct.Supervisor` to your supervision tree, and tell it where files
  go (`config :direct, root: "/var/cache/video"`, or `dir: fn id -> path end`).

  ## What is written

  A release with one audio track becomes one file, `media.mp4`. One with
  several becomes a video-only `media.mp4` and one `audioN.mp4` per track,
  and the playlist is then a master naming each track as a rendition the
  player switches between (`video.m3u8`, `audioN.m3u8` are the media
  playlists). Text subtitles inside the release are written out as WebVTT
  (`subN.vtt`), listed in `subs.json`. `streams.json` keeps the probe,
  `audio.json` the audio tracks, and `done` marks a finished conversion.

  ## Parts

  Coming back to a film half-way through should not mean converting the
  half already seen: a conversion can begin at a position (a *part*, named
  by its second: `media-1800.mp4`) and keeps the film's own clock, so its
  fragments carry the real times and a subtitle written for the whole film
  still fits. The playlist of a part lists only what the part has; the
  player learns where it starts (`start_at/2`) and asks for another part
  when the viewer seeks before it. A part from the beginning keeps the
  plain names. Parts closer than `:min_part` seconds (default 60) to the
  beginning are not worth it and start from 0.

  ## Serving

  Everything is files in `dir/1`: serve `media.mp4`/`audioN.mp4` with
  `Fmp4.RangeFile`, `playlist.m3u8` from `playlist/3`, `video.m3u8` and
  `audioN.m3u8` from `media_playlist/3`, and call `touch/1` on every fetch
  — a conversion nobody has fetched for `:idle_ms` (default ten minutes)
  stops, and what it wrote stays as a cache for you to sweep.
  """
  alias Direct.{Caps, Command, Playlist, Probe}

  @registry Direct.Registry
  @supervisor Direct.DynamicSupervisor

  @doc """
  Start converting (or join the conversion of) the file at `url`, from
  `:from` seconds in: `{:ok, id, part}` when its video is one the browser
  with `:caps` decodes — `part` is where the conversion serving it begins
  (0 for the whole file, which is reused when it is there already) —
  `:skip` when it is not, `{:error, :unreachable}` when the file could not
  be probed.

  Options:

    * `:id` — what to file the conversion under (16 lowercase hex characters
      are a good shape for an address). Without one it is derived from
      `:name` and `:size` (`id_for/2`), so the same release maps to the same
      directory.
    * `:caps` — what the browser decodes (`Direct.Caps`); default nothing
      beyond H.264.
    * `:from` — seconds into the film to begin at (default 0).
    * `:streams` — the probe, if you already have it (`Direct.Probe.streams/1`).
  """
  @spec start(String.t(), keyword()) ::
          {:ok, String.t(), non_neg_integer()} | :skip | {:error, term()}
  def start(url, opts \\ []) when is_binary(url) do
    id =
      Keyword.get_lazy(opts, :id, fn ->
        id_for(Keyword.get(opts, :name, url), Keyword.get(opts, :size))
      end)

    caps = Keyword.get(opts, :caps, %{})

    case streams(id, url, Keyword.get(opts, :streams)) do
      [] ->
        {:error, :unreachable}

      streams ->
        if Caps.decodable?(Probe.codec(streams, "video"), caps),
          do: launch(id, url, streams, Keyword.get(opts, :from, 0)),
          else: :skip
    end
  end

  @doc "A stable id for a release, from its name and size: 16 lowercase hex characters."
  @spec id_for(String.t(), term()) :: String.t()
  def id_for(name, size) do
    :sha256
    |> :crypto.hash("direct:v5:#{name}-#{size}")
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp launch(id, url, streams, from) do
    part = part_for(id, from)

    cond do
      running?(id, part) ->
        {:ok, id, part}

      done?(id, part) ->
        File.touch(dir(id))
        {:ok, id, part}

      true ->
        clear_part(id, part)

        spec =
          {Direct.Worker,
           id: id,
           url: url,
           streams: streams,
           dir: dir(id),
           part: part,
           idle_ms: setting(:idle_ms, 10 * 60 * 1000)}

        case DynamicSupervisor.start_child(@supervisor, spec) do
          {:ok, _} -> {:ok, id, part}
          {:error, {:already_started, _}} -> {:ok, id, part}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # The streams of the file, read once and kept beside the conversion: every part needs them,
  # and the probe costs a second or two over the network.
  defp streams(id, url, given) do
    case given || read_json(file(id, "streams.json")) do
      [_ | _] = streams ->
        Enum.map(streams, &%{index: &1.index, kind: &1.kind, codec: &1.codec, lang: &1.lang})

      _ ->
        case Probe.streams(url) do
          [] ->
            []

          streams ->
            File.mkdir_p(dir(id))
            File.write(file(id, "streams.json"), Jason.encode!(streams))
            streams
        end
    end
  end

  # ── where things are ─────────────────────────────────────────────

  @doc """
  Where a conversion's files are: `config :direct, dir: fn id -> path end`
  (or `{module, function}`), else `config :direct, root: path` joined with
  the id (default `direct` under the system's temporary directory).
  """
  @spec dir(String.t()) :: Path.t()
  def dir(id) do
    case Application.get_env(:direct, :dir) do
      f when is_function(f, 1) ->
        f.(id)

      {m, f} ->
        apply(m, f, [id])

      nil ->
        Path.join(
          Application.get_env(:direct, :root) || Path.join(System.tmp_dir!(), "direct"),
          id
        )
    end
  end

  @doc "A file of a conversion, by name."
  def file(id, name), do: Path.join(dir(id), name)

  @doc "The video file of a part (`media.mp4`, `media-1800.mp4`)."
  def media(id, part \\ 0), do: file(id, part_name("media", ".mp4", part))

  @doc "Whether a conversion of this kind exists under `id` (started, at least)."
  def direct?(id), do: File.exists?(file(id, "audio.json"))

  @doc "A part's file name: `media.mp4` for the whole file, `media-1800.mp4` for a part."
  def part_name(base, ext, 0), do: base <> ext
  def part_name(base, ext, part), do: "#{base}-#{part}#{ext}"

  @doc "The query a part's playlists carry (`?from=1800`); nothing for the whole file."
  def part_query(0), do: ""
  def part_query(part), do: "?from=#{part}"

  @doc """
  The audio tracks of a conversion, as written at its start: `[%{file:
  "audio0", lang: "kor", name: "Korean"}]`. One entry (or none) means the
  audio is inside `media.mp4`.
  """
  def tracks(id) do
    case read_json(file(id, "audio.json")) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  @doc "The subtitle tracks written out of the release: `[%{file: \"sub0\", lang: \"fre\", index: 2}]`."
  def subtitles(id) do
    case read_json(file(id, "subs.json")) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp read_json(path) do
    with {:ok, json} <- File.read(path),
         {:ok, data} <- Jason.decode(json, keys: :atoms) do
      data
    else
      _ -> nil
    end
  end

  defp multi?(id), do: length(tracks(id)) > 1

  # ── running conversions ──────────────────────────────────────────

  defp running?(id, part), do: Registry.lookup(@registry, {id, part}) != []
  defp done?(id, part), do: File.exists?(file(id, part_name("done", "", part)))

  @doc "Ids converting right now."
  def running do
    @registry
    |> Registry.select([{{{:"$1", :_}, :_, :_}, [], [:"$1"]}])
    |> Enum.uniq()
  end

  defp workers(id), do: Registry.select(@registry, [{{{id, :_}, :"$1", :_}, [], [:"$1"]}])

  @doc "The stream is being watched: keep converting."
  def touch(id), do: Enum.each(workers(id), &GenServer.cast(&1, :touch))

  @doc "End the conversion, every part of it (what is written stays)."
  def stop(id) when is_binary(id),
    do: Enum.each(workers(id), &DynamicSupervisor.terminate_child(@supervisor, &1))

  def stop(_), do: :ok

  # ── parts ────────────────────────────────────────────────────────

  # The part to serve a play from `from` seconds in: an existing one that has that place
  # already (the earliest, for the most room to seek back in), else a new one from there.
  defp part_for(id, from) do
    if is_integer(from) and from >= setting(:min_part, 60) do
      id
      |> parts()
      |> Enum.filter(&(&1 <= from and covers?(id, &1, from)))
      |> Enum.min(fn -> from end)
    else
      0
    end
  end

  @doc "The starts of the parts on disk, in seconds, earliest first."
  def parts(id) do
    case File.ls(dir(id)) do
      {:ok, names} ->
        names
        |> Enum.flat_map(fn
          "media.mp4" ->
            [0]

          "media-" <> rest ->
            case Integer.parse(rest) do
              {n, ".mp4"} -> [n]
              _ -> []
            end

          _ ->
            []
        end)
        |> Enum.sort()

      _ ->
        []
    end
  end

  # A finished part reaches the end; one still running must be past the place, with room.
  defp covers?(id, part, from) do
    cond do
      done?(id, part) -> true
      running?(id, part) -> reach(id, part) >= from + 10
      true -> false
    end
  end

  # How far into the film a part has been written, in seconds.
  defp reach(id, part) do
    case Fmp4.scan(media(id, part)) do
      {:ok, info} -> Fmp4.reach(info)
      _ -> 0
    end
  end

  @doc "Where a part begins, in seconds of the film: the first fragment's time (0 for the whole file)."
  def start_at(_id, 0), do: 0

  def start_at(id, part) do
    case Fmp4.scan(media(id, part)) do
      {:ok, %{start: start}} -> start
      _ -> part
    end
  end

  # A part begun before and left unfinished is written afresh; the rest of the directory (other
  # parts, other files) stays.
  defp clear_part(id, part) do
    case File.ls(dir(id)) do
      {:ok, names} -> for name <- names, part_of(name) == part, do: File.rm_rf(file(id, name))
      _ -> :ok
    end
  end

  # The part a file belongs to, by its name: `media-1800.mp4` → 1800, `audio0.mp4` → 0, else nil.
  defp part_of(name) do
    case Regex.run(~r/^(?:media|audio\d+|sub\d+|done)(?:-(\d+))?(?:\.mp4|\.vtt)?$/, name) do
      [_] -> 0
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end

  @doc "Enough of a part is written to start playing: two fragments of every file, or all of it."
  def ready?(id, part \\ 0) do
    done?(id, part) or
      (enough?(media(id, part)) and
         (not multi?(id) or
            Enum.all?(tracks(id), &enough?(file(id, part_name(&1.file, ".mp4", part))))))
  end

  defp enough?(path) do
    case Fmp4.scan(path) do
      {:ok, %{fragments: [_, _ | _]}} -> true
      _ -> false
    end
  end

  # ── playlists ────────────────────────────────────────────────────

  @doc """
  What the player loads for a part: the media playlist of `media.mp4` when
  the audio is in it, else a master playlist with the video and one
  rendition per audio track. Options: `:prefer` (languages in order of
  preference, `["en", "ko"]`: the first the release has is the default
  track), `:subs` (subtitle renditions to list, `[%{file: "sub0", lang:
  "fre", name: "French"}]`, each served as `file.m3u8`).
  """
  def playlist(id, part \\ 0, opts \\ []) do
    subs = Keyword.get(opts, :subs, [])
    opts = Keyword.put(opts, :part, part)

    cond do
      multi?(id) -> Playlist.master(tracks(id), bandwidth(id, part), opts)
      subs != [] -> Playlist.master([], bandwidth(id, part), opts)
      true -> media_playlist(id, part, "media")
    end
  end

  # The video's rate so far, plus the audio, for the master playlist's required figure.
  defp bandwidth(id, part) do
    case Fmp4.scan(media(id, part)) do
      {:ok, info} -> (Fmp4.bitrate(info) || 10_000_000) + 256_000
      _ -> 10_000_000
    end
  end

  @doc """
  The HLS media playlist of what is written of one file of a part so far
  (`base` is `"media"` or `"audio1"`): one byte range per fragment
  (`Fmp4.playlist/3`), ended once ffmpeg has finished. It counts from the
  part's start: what the fragments carry says where that is in the film.
  """
  def media_playlist(id, part, base) do
    name = part_name(base, ".mp4", part)

    case Fmp4.scan(file(id, name)) do
      {:ok, info} ->
        Fmp4.playlist(info, name, done: done?(id, part))

      _ ->
        "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:10\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:EVENT\n"
    end
  end

  @doc false
  def command(url, dir, streams, part), do: Command.build(url, dir, streams, part)

  defp setting(key, default), do: Application.get_env(:direct, key, default)
end

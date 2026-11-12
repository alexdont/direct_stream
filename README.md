# Direct

Play a video release in the browser **without re-encoding it**.

A browser that can decode the release's video itself — H.264 everywhere,
HEVC on anything Apple makes and on desktops with a hardware decoder, AV1
on most — only needs the container changed and the audio put into AAC. So
ffmpeg *copies* the video into one fragmented MP4 that grows while it
plays, and the HLS playlist names byte ranges of that file. A fraction of a
core instead of the several a re-encode takes; and it is the only form of
HEVC Safari plays through HLS at all.

```elixir
def deps do
  [{:direct, "~> 0.1"}]
end
```

Needs `ffmpeg` and `ffprobe` on the path. Built on [`fmp4`](https://hex.pm/packages/fmp4).

## Setting up

```elixir
# application.ex
children = [Direct.Supervisor, …]

# config
config :direct, root: "/var/cache/video"   # or dir: fn id -> path end
```

## Starting a play

The page tells the server what its browser decodes when it connects:

```js
const v = document.createElement("video")
socketParams = {
  hevc: v.canPlayType('video/mp4; codecs="hvc1.1.6.L120.B0"') !== "",
  av1: MediaSource.isTypeSupported('video/mp4; codecs="av01.0.08M.08"'),
}
```

```elixir
caps = Direct.Caps.from_params(connect_params)

case Direct.start(url, name: filename, size: filesize, caps: caps, from: resume_seconds) do
  {:ok, id, part} -> # play /stream/#{id}/playlist.m3u8#{Direct.part_query(part)}
  :skip            -> # this browser cannot decode the video: re-encode, or offer an external player
  {:error, :unreachable} -> # the file could not be probed
end
```

`start/2` probes the file once (`streams.json`), and joins a conversion
already running or finished for the same id.

## Serving

Everything is files under `Direct.dir(id)`:

```elixir
# playlist.m3u8 — a media playlist, or a master when there are several audio tracks
Direct.playlist(id, part, prefer: ["ja", "en"], subs: subtitle_tracks)

# video.m3u8, audio0.m3u8 … — the media playlists of a master, byte ranges of what is written
Direct.media_playlist(id, part, "media")
Direct.media_playlist(id, part, "audio0")

# media.mp4, audio0.mp4 … — the files, with Range support for a growing file
Fmp4.RangeFile.send(conn, Direct.file(id, name), "video/mp4")
```

Call `Direct.touch(id)` on each fetch: a conversion nobody has fetched for
ten minutes (`config :direct, idle_ms:`) stops, and what it wrote stays as
a cache for you to sweep. `Direct.running/0` lists the ids converting.

## Parts

Coming back to a film half-way through should not mean converting the
half already seen. `from:` starts a conversion at that second (a *part*,
`media-1800.mp4`), keeping the film's own clock: its fragments carry the
real times, so subtitles for the whole film still fit and the player can
show the real position. `Direct.start_at(id, part)` says where it begins
(ffmpeg lands on the keyframe before); `Direct.parts(id)` lists the parts
on disk. A finished part that covers the place asked for is reused. Parts
within `min_part` seconds (default 60) of the start are not worth it.

## Several audio tracks

A release with one audio track becomes one `media.mp4`. With several, the
video goes alone into `media.mp4` and each track into `audioN.mp4`, listed
in `audio.json` with a name (`"Japanese"`, `"Russian 2"`), and
`playlist/3` returns a master with one rendition per track — the first in
the preferred language the default. `Direct.Playlist.tidy_master/2` does
the same for ffmpeg's own HLS master of a TS conversion.

## Subtitles

Text subtitles inside the release are written out as `subN.vtt` while the
conversion runs (`subs.json` lists them; image subtitles are left out).
Serving them as HLS subtitle renditions — cut to the stream's segments — is
yours to do; pass what you serve as `subs:` and they are listed in the
master.

## License

MIT © Alexander Don

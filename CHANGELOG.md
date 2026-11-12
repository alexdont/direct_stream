# Changelog

## 0.1.0

Initial release.

- `Direct.start/2` — convert (or join the conversion of) a release for a
  browser that decodes its video: ffmpeg copies the video into a fragmented
  MP4 that plays while it is written, audio as AAC, several audio tracks as
  HLS renditions, text subtitles as WebVTT; HEVC through MPEG-TS so Safari
  gets `hvc1` with its parameter sets.
- Parts: a conversion begun part-way through the film that keeps its clock.
- `Direct.playlist/3`, `media_playlist/3`, `Direct.Playlist` (master,
  `tidy_master` for ffmpeg's own TS masters, subtitle renditions).
- `Direct.Caps` (what a browser decodes), `Direct.Probe` (ffprobe),
  `Direct.Command` (the command line, pure), `Direct.Lang`.
- `Direct.Supervisor`; conversions stop when nobody fetches them.

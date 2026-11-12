defmodule Direct.CapsCommandTest do
  use ExUnit.Case, async: true

  alias Direct.{Caps, Command, Lang}

  test "H.264 is decodable everywhere; the rest only where the browser says so" do
    assert Caps.decodable?("h264", %{})
    assert Caps.decodable?("x264", %{hevc: false})
    refute Caps.decodable?("hevc", %{})
    assert Caps.decodable?("hevc", %{hevc: true})
    assert Caps.decodable?("av1", %{av1: true})
    refute Caps.decodable?("mpeg4", %{hevc: true, av1: true})
    refute Caps.decodable?(nil, %{})
  end

  test "caps from connect params" do
    assert Caps.from_params(%{"hevc" => true, "av1" => "yes"}) == %{
             hevc: true,
             av1: false,
             vp9: false,
             uhd: false,
             local: false
           }

    assert Caps.from_params(nil) == %{}
    assert Caps.from_params(%{"dv" => true}, keys: [:dv]).dv
  end

  test "language names and short codes" do
    assert Lang.name("fre") == "French"
    assert Lang.name("xx") == "XX"
    assert Lang.name(nil) == "Unknown"
    assert Lang.short("jpn") == "ja"
    assert Lang.short("pt-BR") == "pt"
  end

  @streams [
    %{index: 0, kind: "video", codec: "hevc", lang: ""},
    %{index: 1, kind: "audio", codec: "eac3", lang: "fre"},
    %{index: 2, kind: "subtitle", codec: "subrip", lang: "eng"},
    %{index: 3, kind: "subtitle", codec: "hdmv_pgs_subtitle", lang: "eng"}
  ]

  test "tracks from the probe" do
    assert [%{file: "audio0", name: "French", codec: "eac3"}] = Command.audio_tracks(@streams)
    assert [%{file: "sub0", index: 2, lang: "eng"}] = Command.subtitle_tracks(@streams)

    two = [
      %{index: 1, kind: "audio", codec: "aac", lang: "rus"},
      %{index: 2, kind: "audio", codec: "ac3", lang: "rus"}
    ]

    assert Enum.map(Command.audio_tracks(two), & &1.name) == ["Russian 1", "Russian 2"]
  end

  # `-ac:0` is output stream 0 of any kind, the video, so the audio stayed 5.1 and a browser could
  # not decode the AAC written for it.
  test "HEVC goes through TS, the audio is mixed down on the audio stream itself" do
    cmd = Command.build("http://x/f.mkv", "/tmp/d", @streams, 0)
    assert cmd =~ "'-f' 'mpegts' '-'"
    assert cmd =~ "| 'ffmpeg'"
    assert cmd =~ "'-tag:v' 'hvc1'"
    assert cmd =~ "'-ac:a:0' '2'"
    refute cmd =~ "'-ac:0'"
    assert cmd =~ "'/tmp/d/sub0.vtt'"
    refute cmd =~ "0:3"
    refute cmd =~ "-ss"
  end

  test "a part begun later keeps the film's clock" do
    cmd = Command.build("http://x/f.mkv", "/tmp/d", @streams, 75)
    assert cmd =~ "'-ss' '75' '-i' 'http://x/f.mkv' '-copyts'"
    assert cmd =~ "+frag_discont"
    assert cmd =~ "'-muxdelay' '0'"
    assert cmd =~ "'/tmp/d/media-75.mp4'"
    assert cmd =~ "'-ac:a:0' '2'"
  end

  test "H.264 with several audio tracks writes one file per track, no TS" do
    streams = [
      %{index: 0, kind: "video", codec: "h264", lang: ""},
      %{index: 1, kind: "audio", codec: "aac", lang: "eng"},
      %{index: 2, kind: "audio", codec: "dts", lang: "jpn"}
    ]

    cmd = Command.build("/f.mkv", "/d", streams, 0)
    refute cmd =~ "mpegts"
    assert cmd =~ "'-map' '0:a:0' '-c:a' 'copy' '-frag_duration'"
    assert cmd =~ "'-map' '0:a:1' '-c:a' 'aac' '-b:a' '192k' '-ac' '2'"
    assert cmd =~ "'/d/audio0.mp4'" and cmd =~ "'/d/audio1.mp4'" and cmd =~ "'/d/media.mp4'"

    # Shell quoting of a name with an apostrophe.
    assert Command.build("/it's.mkv", "/d", streams, 0) =~ "'/it'\\''s.mkv'"
  end
end

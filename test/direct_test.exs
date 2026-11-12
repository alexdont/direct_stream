defmodule DirectTest do
  use ExUnit.Case, async: false

  @moduletag :ffmpeg

  # A 12 s H.264 film with two audio tracks, made once for the module.
  setup_all do
    src = Path.join(Application.get_env(:direct, :root), "source.mkv")
    File.mkdir_p!(Path.dirname(src))

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-v error -y -f lavfi -i testsrc=size=64x64:rate=10:duration=12
        -f lavfi -i sine=frequency=440:sample_rate=8000:duration=12
        -f lavfi -i sine=frequency=880:sample_rate=8000:duration=12
        -map 0:v -map 1:a -map 2:a -c:v libx264 -preset ultrafast -g 20 -keyint_min 20 -sc_threshold 0
        -c:a aac -b:a 16k -metadata:s:a:0 language=eng -metadata:s:a:1 language=jpn) ++ [src]
      )

    %{src: src}
  end

  defp wait(fun, left \\ 100) do
    cond do
      fun.() -> true
      left == 0 -> false
      true -> Process.sleep(100) && wait(fun, left - 1)
    end
  end

  test "a conversion is probed, written, played as byte ranges, and finished", %{src: src} do
    assert {:ok, id, 0} = Direct.start(src, id: "testdirect000001", caps: %{})
    assert id in Direct.running()
    assert Direct.direct?(id)
    assert [%{name: "English"}, %{name: "Japanese"}] = Direct.tracks(id)

    assert wait(fn -> Direct.ready?(id) end)
    master = Direct.playlist(id, 0, prefer: "ja")
    assert master =~ ~s(NAME="Japanese",LANGUAGE="ja",DEFAULT=YES)
    assert master =~ "video.m3u8"
    assert Direct.media_playlist(id, 0, "media") =~ "#EXT-X-BYTERANGE:"
    assert Direct.media_playlist(id, 0, "audio1") =~ ~s(#EXT-X-MAP:URI="audio1.mp4")

    # Joining the same conversion is the same answer.
    assert {:ok, ^id, 0} = Direct.start(src, id: id, caps: %{})

    assert wait(fn -> id not in Direct.running() end)
    assert File.exists?(Direct.file(id, "done"))
    assert Direct.media_playlist(id, 0, "media") =~ "#EXT-X-ENDLIST"
    {:ok, info} = Fmp4.scan(Direct.media(id))
    assert_in_delta Fmp4.reach(info), 12.0, 0.3

    # A finished conversion is reused without a worker.
    assert {:ok, ^id, 0} = Direct.start(src, id: id, caps: %{})
    refute id in Direct.running()
  end

  test "a part begun later keeps the film's clock and is listed", %{src: src} do
    Application.put_env(:direct, :min_part, 2)
    on_exit(fn -> Application.delete_env(:direct, :min_part) end)

    assert {:ok, id, 6} = Direct.start(src, id: "testdirect000002", caps: %{}, from: 6)
    assert wait(fn -> Direct.ready?(id, 6) end)
    assert Direct.parts(id) == [6]
    # `-ss` lands on the keyframe at or before the place (every two seconds here).
    start = Direct.start_at(id, 6)
    assert start >= 3.9 and start <= 6.0
    assert Direct.media_playlist(id, 6, "media") =~ ~s(URI="media-6.mp4")
    assert Direct.playlist(id, 6) =~ "video.m3u8?from=6"

    assert wait(fn -> id not in Direct.running() end)
    assert File.exists?(Direct.file(id, "done-6"))

    # Asking from later in the film reuses the finished part that covers it.
    assert {:ok, ^id, 6} = Direct.start(src, id: id, caps: %{}, from: 9)
  end

  test "a browser that cannot decode the video is told to skip; an unreadable file is unreachable",
       %{src: src} do
    streams = [%{index: 0, kind: "video", codec: "hevc", lang: ""}]
    assert :skip = Direct.start(src, id: "testdirect000003", caps: %{}, streams: streams)
    assert {:error, :unreachable} = Direct.start("/nowhere/none.mkv", id: "testdirect000004")
  end

  test "stop ends a running conversion", %{src: src} do
    assert {:ok, id, 0} = Direct.start(src, id: "testdirect000005", caps: %{})
    assert id in Direct.running()
    Direct.stop(id)
    assert wait(fn -> id not in Direct.running() end)
    refute File.exists?(Direct.file(id, "done"))
  end
end

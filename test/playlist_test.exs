defmodule Direct.PlaylistTest do
  use ExUnit.Case, async: true

  alias Direct.Playlist

  test "a multi-audio master names every track as a rendition, the first the default" do
    tracks = [
      %{file: "audio0", lang: "kor", name: "Korean"},
      %{file: "audio1", lang: "rus", name: "Russian"},
      %{file: "audio2", lang: "", name: "Track 3"}
    ]

    pl = Playlist.master(tracks, 12_000_000)

    assert pl =~ ~s(NAME="Korean",LANGUAGE="ko",DEFAULT=YES,AUTOSELECT=YES,URI="audio0.m3u8")
    assert pl =~ ~s(NAME="Russian",LANGUAGE="ru",DEFAULT=NO,AUTOSELECT=YES,URI="audio1.m3u8")
    assert pl =~ ~s(NAME="Track 3",DEFAULT=NO)
    assert pl =~ ~s(#EXT-X-STREAM-INF:BANDWIDTH=12000000,AUDIO="aud"\nvideo.m3u8)
    refute pl =~ "CODECS"
  end

  test "the preferred language is the default when the release has it" do
    tracks = [
      %{file: "audio0", lang: "rus", name: "Russian"},
      %{file: "audio1", lang: "kor", name: "Korean"}
    ]

    pl = Playlist.master(tracks, 1_000_000, prefer: "ko")
    assert pl =~ ~s(NAME="Russian",LANGUAGE="ru",DEFAULT=NO)
    assert pl =~ ~s(NAME="Korean",LANGUAGE="ko",DEFAULT=YES)

    # A language the release lacks leaves the first track the default.
    assert Playlist.master(tracks, 1_000_000, prefer: "en") =~
             ~s(NAME="Russian",LANGUAGE="ru",DEFAULT=YES)

    # Preferences in order: the viewer's language first, then the title's own.
    assert Playlist.master(tracks, 1_000_000, prefer: ["en", "ko"]) =~
             ~s(NAME="Korean",LANGUAGE="ko",DEFAULT=YES)

    assert Playlist.master(tracks, 1_000_000, prefer: ["ru", "ko"]) =~
             ~s(NAME="Russian",LANGUAGE="ru",DEFAULT=YES)
  end

  test "a part's playlists name the part, its files carry it in their names" do
    tracks = [
      %{file: "audio0", lang: "eng", name: "English"},
      %{file: "audio1", lang: "kor", name: "Korean"}
    ]

    subs = [
      %{file: "sub0", lang: "fre", name: "French"},
      %{file: "ext-en-os12", lang: "en", name: "English (OpenSubtitles)"}
    ]

    pl = Playlist.master(tracks, 1_000_000, prefer: "ko", subs: subs, part: 1800)

    assert pl =~
             ~s(NAME="English",LANGUAGE="en",DEFAULT=NO,AUTOSELECT=YES,URI="audio0.m3u8?from=1800")

    assert pl =~
             ~s(NAME="Korean",LANGUAGE="ko",DEFAULT=YES,AUTOSELECT=YES,URI="audio1.m3u8?from=1800")

    assert pl =~
             ~s(TYPE=SUBTITLES,GROUP-ID="subs",NAME="French",LANGUAGE="fr",DEFAULT=NO,AUTOSELECT=NO,URI="sub0.m3u8?from=1800")

    assert pl =~ ~s(URI="ext-en-os12.m3u8?from=1800")
    assert pl =~ ~s(AUDIO="aud",SUBTITLES="subs"\nvideo.m3u8?from=1800\n)

    plain = Playlist.master(tracks, 1_000_000, prefer: "ko", subs: subs)
    assert plain =~ ~s(URI="audio0.m3u8")
    refute plain =~ "from="
    assert plain =~ "\nvideo.m3u8\n"

    assert Direct.part_name("media", ".mp4", 0) == "media.mp4"
    assert Direct.part_name("media", ".mp4", 1800) == "media-1800.mp4"
    assert Direct.part_name("done", "", 1800) == "done-1800"
    assert Direct.part_query(0) == ""
    assert Direct.part_query(1800) == "?from=1800"
  end

  test "ffmpeg's master is cut to one rendition per file, named by language" do
    master = """
    #EXTM3U
    #EXT-X-VERSION:6
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="group_aud",NAME="audio_1",DEFAULT=YES,LANGUAGE="rus",CHANNELS="2",URI="s_Rus.m3u8"
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="group_aud",NAME="audio_2",DEFAULT=NO,LANGUAGE="rus",CHANNELS="2",URI="s_Rus.m3u8"
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="group_aud",NAME="audio_3",DEFAULT=NO,LANGUAGE="kor",CHANNELS="2",URI="s_Korean.m3u8"
    #EXT-X-STREAM-INF:BANDWIDTH=10280966,CODECS="avc1.640029,mp4a.40.2",AUDIO="group_aud"
    s_0.m3u8
    """

    tidy = Playlist.tidy_master(master, prefer: "ko")
    media = tidy |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "#EXT-X-MEDIA"))
    assert length(media) == 2

    assert String.starts_with?(
             hd(media),
             ~s(#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="group_aud",NAME="Russian")
           )

    assert tidy =~ ~s(NAME="Russian",LANGUAGE="ru",DEFAULT=NO,AUTOSELECT=YES,URI="s_Rus.m3u8")
    assert tidy =~ ~s(NAME="Korean",LANGUAGE="ko",DEFAULT=YES,AUTOSELECT=YES,URI="s_Korean.m3u8")
    assert tidy =~ "#EXT-X-STREAM-INF:BANDWIDTH=10280966"
    assert tidy =~ "s_0.m3u8"
  end

  test "subtitles ride along under a plain media playlist" do
    subs = [%{file: "sub0", lang: "jpn", name: "Japanese"}]
    pl = Playlist.wrap_media("index.m3u8", subs)
    assert pl =~ ~s(TYPE=SUBTITLES,GROUP-ID="subs",NAME="Japanese",LANGUAGE="ja")
    assert pl =~ ~s(#EXT-X-STREAM-INF:BANDWIDTH=8000000,SUBTITLES="subs"\nindex.m3u8)

    assert Playlist.wrap_media("index.m3u8", []) ==
             "#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-STREAM-INF:BANDWIDTH=8000000\nindex.m3u8\n"
  end
end

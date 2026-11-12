defmodule Direct.Probe do
  @moduledoc "What is inside a file, by ffprobe: its streams' kinds, codecs and languages."

  @typedoc "One stream of the file, as `ffprobe -show_streams` reports it."
  @type stream :: %{index: non_neg_integer, kind: String.t(), codec: String.t(), lang: String.t()}

  @doc """
  The streams of the file at `url` (a path or an address), `[]` when it
  cannot be read within `:timeout` ms (default 30 000).
  """
  @spec streams(String.t(), keyword()) :: [stream]
  def streams(url, opts \\ []) do
    task = Task.async(fn -> run(url) end)

    case Task.yield(task, Keyword.get(opts, :timeout, 30_000)) ||
           Task.shutdown(task, :brutal_kill) do
      {:ok, streams} when is_list(streams) -> streams
      _ -> []
    end
  end

  defp run(url) do
    args = [
      "-v",
      "error",
      "-show_entries",
      "stream=index,codec_type,codec_name:stream_tags=language",
      "-of",
      "json",
      url
    ]

    with {out, 0} <- System.cmd("ffprobe", args, stderr_to_stdout: true),
         {:ok, %{"streams" => streams}} when is_list(streams) <- Jason.decode(out) do
      Enum.map(streams, fn s ->
        %{
          index: s["index"],
          kind: s["codec_type"],
          codec: s["codec_name"] || "",
          lang: get_in(s, ["tags", "language"]) || ""
        }
      end)
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  @doc "The codec of the first stream of `kind` (`\"video\"`, `\"audio\"`), `\"\"` when none."
  @spec codec([stream], String.t()) :: String.t()
  def codec(streams, kind),
    do: Enum.find_value(streams, "", fn s -> if s.kind == kind, do: s.codec end)
end

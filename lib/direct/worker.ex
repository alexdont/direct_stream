defmodule Direct.Worker do
  @moduledoc false
  # One conversion of one part: holds the ffmpeg pipeline's port, writes the track manifests
  # beside the output, marks `done` when ffmpeg ends well, and stops after `idle_ms` with no
  # `touch`. Ending the worker ends ffmpeg (and the pipeline's other process).
  use GenServer
  require Logger

  alias Direct.Command

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    part = Keyword.get(opts, :part, 0)
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {Direct.Registry, {id, part}}})
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    dir = Keyword.fetch!(opts, :dir)
    part = Keyword.get(opts, :part, 0)
    File.mkdir_p!(dir)
    streams = Keyword.fetch!(opts, :streams)
    File.write(Path.join(dir, "subs.json"), Jason.encode!(Command.subtitle_tracks(streams)))
    File.write(Path.join(dir, "audio.json"), Jason.encode!(Command.audio_tracks(streams)))

    # One shell runs the pipeline; its children are ended with it.
    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-c", Command.build(Keyword.fetch!(opts, :url), dir, streams, part)]
      ])

    Process.send_after(self(), :idle_check, 60_000)

    {:ok,
     %{
       id: Keyword.fetch!(opts, :id),
       part: part,
       dir: dir,
       port: port,
       idle_ms: Keyword.get(opts, :idle_ms, 10 * 60 * 1000),
       last_error: "",
       touched: System.monotonic_time(:millisecond)
     }}
  end

  @impl true
  def handle_cast(:touch, state),
    do: {:noreply, %{state | touched: System.monotonic_time(:millisecond)}}

  @impl true
  def handle_info({port, {:exit_status, 0}}, %{port: port} = state) do
    File.write(Path.join(state.dir, Direct.part_name("done", "", state.part)), "")
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning(
      "direct #{state.id} (from #{state.part}) ffmpeg exited #{status}: #{state.last_error}"
    )

    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    last = data |> String.split("\n", trim: true) |> List.last()
    {:noreply, %{state | last_error: last || state.last_error}}
  end

  def handle_info(:idle_check, state) do
    if System.monotonic_time(:millisecond) - state.touched > state.idle_ms do
      {:stop, :normal, state}
    else
      Process.send_after(self(), :idle_check, 60_000)
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        System.cmd("pkill", ["-TERM", "-P", Integer.to_string(os_pid)], stderr_to_stdout: true)
        System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)

      _ ->
        :ok
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok
end

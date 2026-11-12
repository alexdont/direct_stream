Application.put_env(
  :direct,
  :root,
  Path.join(System.tmp_dir!(), "direct-test-#{System.unique_integer([:positive])}")
)

{:ok, _} = Direct.Supervisor.start_link()
ExUnit.start(exclude: [ffmpeg: System.find_executable("ffmpeg") == nil])

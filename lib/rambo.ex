defmodule Rambo do
  @moduledoc File.read!("#{__DIR__}/../README.md")
             |> String.split("\n")
             |> Enum.drop(2)
             |> Enum.join("\n")

  defp read_version_from_mix do
    mix_file = File.read!("#{__DIR__}/../mix.exs")
    case Regex.run(~r/@version\s+"([^"]+)"/, mix_file) do
      [_, version] -> version
      _ -> "0.3.15"  # fallback version
    end
  end

  @latest_version read_version_from_mix()

  defstruct status: nil, out: "", err: ""

  @type t :: %__MODULE__{
          status: integer(),
          out: String.t(),
          err: String.t()
        }
  @type args :: String.t() | [iodata()] | nil
  @type result :: {:ok, t()} | {:error, t() | String.t()} | {:killed, t()}

  use Application
  alias __MODULE__
  require Logger

  @doc false
  def start(_, _) do
    if Application.get_env(:rambo, :version_check, true) do
      unless Application.get_env(:rambo, :version) do
        Logger.warning("""
        rambo version is not configured. Please set it in your config files:

            config :rambo, :version, "#{latest_version()}"
        """)
      end

      configured_version = configured_version()

      case bin_version() do
        {:ok, ^configured_version} ->
          :ok

        {:ok, version} ->
          Logger.warning("""
          Outdated rambo version. Expected #{configured_version}, got #{version}. \
          Please run `mix rambo.install` or update the version in your config files.\
          """)

        :error ->
          :ok
      end
    end

    Supervisor.start_link([], strategy: :one_for_one)
  end

  @doc """
  Stop by killing your command.

  Pass the `pid` of the process that called `run/1`. That process will return
  with `{:killed, %Rambo{}}` with results accumulated thus far.

  ## Example

      iex> task = Task.async(fn ->
      ...>   Rambo.run("cat")
      ...> end)
      iex> Rambo.kill(task.pid)
      iex> Task.await(task)
      {:killed, %Rambo{status: nil}}

  """
  @spec kill(pid()) :: {:killed, t()}
  def kill(pid) do
    send(pid, :kill)
  end

  @doc ~S"""
  Runs `command`.

  Executes the `command` and returns `{:ok, %Rambo{}}` or `{:error, reason}`.
  `reason` is a string if the child process failed to start, or a `%Rambo{}`
  struct if the child process started successfully but exited with a non-zero
  status.

  Multiple calls can be chained together with the `|>` pipe operator to
  simulate Unix pipes.

      Rambo.run("ls") |> Rambo.run("sort") |> Rambo.run("head")

  If any command did not exit with `0`, the rest will not be executed and the
  last executed result is returned in an `:error` tuple.

  See `run/2` or `run/3` to pass arguments or options.

  ## Examples

      iex> Rambo.run("echo")
      {:ok, %Rambo{out: "\n", status: 0, err: ""}}

  """
  @spec run(command :: String.t() | result()) :: result()
  def run(command) do
    run(command, nil, [])
  end

  @doc ~S"""
  Runs `command` with arguments or options.

  Arguments can be a string or list of strings. See `run/3` for options.

  ## Examples

      iex> Rambo.run("echo", "john")
      {:ok, %Rambo{out: "john\n", status: 0}}

      iex> Rambo.run("echo", ["-n", "john"])
      {:ok, %Rambo{out: "john", status: 0}}

      iex> Rambo.run("cat", in: "john")
      {:ok, %Rambo{out: "john", status: 0}}

  """
  @spec run(command :: String.t() | result(), args_or_opts :: args() | Keyword.t()) :: result()
  def run(command, args_or_opts) do
    case command do
      {:ok, %{status: 0, out: out}} ->
        command = args_or_opts
        run(command, in: out)

      {:error, reason} ->
        {:error, reason}

      command ->
        if Keyword.keyword?(args_or_opts) do
          run(command, nil, args_or_opts)
        else
          run(command, args_or_opts, [])
        end
    end
  end

  @doc ~S"""
  Runs `command` with arguments and options.

  ## Options

    * `:in` - pipe iodata as standard input
    * `:cd` - the directory to run the command in
    * `:env` - map or list of tuples containing environment key-value as strings
    * `:log` - stream standard output or standard error to console or a
    function. May be `:stdout`, `:stderr`, `true` for both, `false` for
    neither, or a function with one arity. If a function is given, it will be
    passed `{:stdout, output}` or `{:stderr, error}` tuples. Defaults to
    `:stderr`.
    * `:timeout` - kills command after timeout in milliseconds. Defaults to no
    timeout.

  ## Examples

      iex> Rambo.run("/bin/sh", ["-c", "echo $JOHN"], env: %{"JOHN" => "rambo"})
      {:ok, %Rambo{out: "rambo\n", status: 0}}

      iex> Rambo.run("echo", "rambo", log: &IO.inspect/1)
      {:ok, %Rambo{out: "rambo\n", status: 0}}

  """
  @spec run(command :: String.t() | result(), args :: args(), opts :: Keyword.t()) :: result()
  def run(command, args, opts) do
    case command do
      {:ok, %{out: out}} ->
        command = args
        args_or_opts = opts

        if Keyword.keyword?(args_or_opts) do
          run(command, nil, [in: out] ++ args_or_opts)
        else
          run(command, args_or_opts, in: out)
        end

      {:error, reason} ->
        {:error, reason}

      command when byte_size(command) > 0 ->
        {stdin, opts} = Keyword.pop(opts, :in)
        {envs, opts} = Keyword.pop(opts, :env)
        {current_dir, opts} = Keyword.pop(opts, :cd)
        {log, opts} = Keyword.pop(opts, :log, :stderr)
        {timeout, _opts} = Keyword.pop(opts, :timeout)

        log =
          case log do
            log when is_function(log) -> log
            true -> [:stdout, :stderr]
            log -> [log]
          end

        rambo = find_rambo_executable()
        port = Port.open({:spawn, rambo}, [:binary, :exit_status, {:packet, 4}])
        send_command(port, command)

        if args, do: send_arguments(port, args)
        if stdin, do: send_stdin(port, stdin)
        if envs, do: send_envs(port, envs)
        if current_dir, do: send_current_dir(port, current_dir)

        timer_ref =
          if is_integer(timeout) do
            Process.send_after(self(), :kill, timeout)
          end

        run_command(port)

        port
        |> receive_result(%Rambo{}, log)
        |> cancel_timer(timer_ref)
        |> output_to_binary()

      command ->
        raise ArgumentError, message: "invalid command '#{inspect(command)}'"
    end
  end

  @doc false
  @spec run(result :: result(), command :: String.t(), args :: args(), opts :: Keyword.t()) ::
          result()
  def run(result, command, args, opts) do
    case result do
      {:ok, %{out: out}} -> run(command, args, [in: out] ++ opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @messages [
    :command,
    :arg,
    :stdin,
    :env,
    :current_dir,
    :eot,
    :error,
    :stdout,
    :stderr,
    :exit_status
  ]

  for {message, index} <- Enum.with_index(@messages) do
    Module.put_attribute(__MODULE__, message, <<index>>)
  end

  defp send_command(port, command) do
    Port.command(port, [@command, command])
  end

  defp send_arguments(port, args) when is_list(args) do
    for arg <- args do
      send_arguments(port, arg)
    end
  end

  defp send_arguments(port, arg) when is_binary(arg) do
    Port.command(port, [@arg, arg])
  end

  defp send_stdin(port, stdin) do
    Port.command(port, [@stdin, stdin])
  end

  defp send_envs(port, envs) do
    for {name, value} <- envs do
      Port.command(port, [@env, <<byte_size(name)::32>>, name, value])
    end
  end

  defp send_current_dir(port, current_dir) do
    Port.command(port, [@current_dir, current_dir])
  end

  defp run_command(port) do
    Port.command(port, @eot)
  end

  defp receive_result(port, result, log) do
    receive do
      {^port, {:data, @error <> message}} ->
        Port.close(port)
        {:error, message}

      {^port, {:data, @stdout <> stdout}} ->
        maybe_log(:stdout, stdout, log)
        result = Map.update(result, :out, [], &[&1 | stdout])
        receive_result(port, result, log)

      {^port, {:data, @stderr <> stderr}} ->
        maybe_log(:stderr, stderr, log)
        result = Map.update(result, :err, [], &[&1 | stderr])
        receive_result(port, result, log)

      {^port, {:data, @exit_status <> <<exit_status::32>>}} ->
        result = Map.put(result, :status, exit_status)
        receive_result(port, result, log)

      {^port, {:data, @eot}} ->
        Port.close(port)

        if result.status == 0 do
          {:ok, result}
        else
          {:error, result}
        end

      {^port, {:exit_status, exit_status}} ->
        {:error, "rambo exited with #{exit_status}"}

      :kill ->
        Port.close(port)
        {:killed, result}
    end
  end

  defp maybe_log(to, output, log) when is_function(log) do
    log.({to, output})
  end

  defp maybe_log(to, output, log) do
    if to in log do
      device =
        case to do
          :stdout -> :stdio
          :stderr -> :stderr
        end

      IO.binwrite(device, output)
    end
  end

  defp output_to_binary({reason, %Rambo{out: out, err: err} = result}) do
    {reason, %{result | out: to_binary(out), err: to_binary(err)}}
  end

  defp output_to_binary(result) do
    result
  end

  defp to_binary(iodata) when is_list(iodata) do
    IO.iodata_to_binary(iodata)
  end

  defp to_binary(output) do
    output
  end

  defp cancel_timer(result, nil), do: result

  defp cancel_timer(result, timer_ref) do
    Process.cancel_timer(timer_ref)
    result
  end

  @doc """
  Returns the latest known rambo version.
  """
  def latest_version, do: @latest_version

  @doc """
  Returns the configured rambo version.
  """
  def configured_version do
    Application.get_env(:rambo, :version, latest_version())
  end

  @doc """
  Returns the configured rambo target. By default, it is automatically detected.
  """
  def configured_target do
    Application.get_env(:rambo, :target, target())
  end

  @doc """
  Returns the path to the rambo executable.
  """
  def bin_path do
    filename = case configured_target() do
      "windows" -> "rambo.exe"
      target -> "rambo-#{target}"
    end

    Application.get_env(:rambo, :path) ||
      if Code.ensure_loaded?(Mix.Project) do
        Path.join(Path.dirname(Mix.Project.build_path()), filename)
      else
        Path.expand("_build/#{filename}")
      end
  end

  @doc false
  def find_rambo_executable do
    # Try new binary download approach first
    new_path = bin_path()
    if File.exists?(new_path) do
      new_path
    else
      # Fall back to old compile approach
      Mix.Tasks.Compile.Rambo.find_rambo()
    end
  end

  @doc """
  Returns the version of the rambo executable.
  """
  def bin_version do
    path = bin_path()

    with true <- File.exists?(path),
         {out, 0} <- System.cmd(path, ["--version"]),
         [vsn] <- Regex.run(~r/rambo v?([^\s]+)/, out, capture: :all_but_first) do
      {:ok, vsn}
    else
      _ -> :error
    end
  end

  @doc """
  The default URL to install Rambo from.
  """
  def default_base_url do
    # Use the repo URL directly from the module attribute pattern like Tailwind
    "https://github.com/TwistingTwists/rambo/releases/download/v$version/rambo-$target"
  end

  @doc """
  Installs rambo with `configured_version/0`.
  """
  def install(base_url \\ default_base_url()) do
    url = get_url(base_url)
    bin_path = bin_path()
    binary = fetch_body!(url)
    File.mkdir_p!(Path.dirname(bin_path))

    if File.exists?(bin_path) do
      File.rm!(bin_path)
    end

    File.write!(bin_path, binary, [:binary])
    File.chmod(bin_path, 0o755)
  end

  @doc """
  Returns the configuration for the given profile.

  Returns nil if the profile does not exist.
  """
  def config_for!(profile) when is_atom(profile) do
    Application.get_env(:rambo, profile) ||
      raise ArgumentError, """
      unknown rambo profile. Make sure the profile is defined in your config/config.exs file, such as:

          config :rambo,
            version: "#{@latest_version}",
            #{profile}: [
              args: ["echo", "hello"],
              cd: Path.expand("..", __DIR__)
            ]
      """
  end



  @doc """
  Installs, if not available, and then runs `rambo`.

  Returns the same as `run/2`.
  """
  def install_and_run(profile, args) do
    unless File.exists?(bin_path()) do
      install()
    end

    run(profile, args)
  end

  defp target do
    arch_str = :erlang.system_info(:system_architecture)
    target_triple = arch_str |> List.to_string() |> String.split("-")

    {arch, abi} =
      case target_triple do
        [arch, _vendor, _system, abi] -> {arch, abi}
        [arch, _vendor, abi] -> {arch, abi}
        [arch | _] -> {arch, nil}
      end

    case {:os.type(), arch, abi, :erlang.system_info(:wordsize) * 8} do
      {{:win32, _}, _arch, _abi, 64} ->
        "windows"

      {{:unix, :darwin}, arch, _abi, 64} when arch in ~w(arm aarch64) ->
        "macarm"

      {{:unix, :darwin}, "x86_64", _abi, 64} ->
        "mac"

      {{:unix, :linux}, "aarch64", _abi, 64} ->
        "linuxarm"

      {{:unix, _osname}, arch, _abi, 64} when arch in ~w(x86_64 amd64) ->
        "linux"

      {_os, _arch, _abi, _wordsize} ->
        raise "rambo is not available for architecture: #{arch_str}"
    end
  end

  defp fetch_body!(url, retry \\ true) when is_binary(url) do
    scheme = URI.parse(url).scheme
    url = String.to_charlist(url)
    Logger.debug("Downloading rambo from #{url}")

    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    if proxy = proxy_for_scheme(scheme) do
      %{host: host, port: port} = URI.parse(proxy)
      Logger.debug("Using #{String.upcase(scheme)}_PROXY: #{proxy}")
      set_option = if "https" == scheme, do: :https_proxy, else: :proxy
      :httpc.set_options([{set_option, {{String.to_charlist(host), port}, []}}])
    end

    http_options =
      [
        ssl: [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          depth: 2,
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ],
          versions: protocol_versions()
        ]
      ]
      |> maybe_add_proxy_auth(scheme)

    options = [body_format: :binary]

    case {retry, :httpc.request(:get, {url, []}, http_options, options)} do
      {_, {:ok, {{_, 200, _}, _headers, body}}} ->
        body

      {_, {:ok, {{_, 404, _}, _headers, _body}}} ->
        raise """
        The rambo binary couldn't be found at: #{url}

        This could mean that you're trying to install a version that does not support the detected
        target architecture.

        You can see the available files for the configured version at:

        https://github.com/TwistingTwists/rambo/releases/tag/v#{configured_version()}
        """

      {true, {:error, {:failed_connect, [{:to_address, _}, {inet, _, reason}]}}}
      when inet in [:inet, :inet6] and
             reason in [:ehostunreach, :enetunreach, :eprotonosupport, :nxdomain] ->
        :httpc.set_options(ipfamily: fallback(inet))
        fetch_body!(to_string(url), false)

      other ->
        raise """
        Couldn't fetch #{url}: #{inspect(other)}

        This typically means we cannot reach the source or you are behind a proxy.
        You can try again later and, if that does not work, you might:

          1. If behind a proxy, ensure your proxy is configured and that
             your certificates are set via OTP ca certfile overide via SSL configuration.

          2. Manually download the executable from the URL above and
             place it inside "_build/rambo-#{configured_target()}"

          3. Compile rambo from source using the existing compilation process.
        """
    end
  end

  defp fallback(:inet), do: :inet6
  defp fallback(:inet6), do: :inet

  defp proxy_for_scheme("http") do
    System.get_env("HTTP_PROXY") || System.get_env("http_proxy")
  end

  defp proxy_for_scheme("https") do
    System.get_env("HTTPS_PROXY") || System.get_env("https_proxy")
  end

  defp maybe_add_proxy_auth(http_options, scheme) do
    case proxy_auth(scheme) do
      nil -> http_options
      auth -> [{:proxy_auth, auth} | http_options]
    end
  end

  defp proxy_auth(scheme) do
    with proxy when is_binary(proxy) <- proxy_for_scheme(scheme),
         %{userinfo: userinfo} when is_binary(userinfo) <- URI.parse(proxy),
         [username, password] <- String.split(userinfo, ":") do
      {String.to_charlist(username), String.to_charlist(password)}
    else
      _ -> nil
    end
  end

  defp protocol_versions do
    if otp_version() < 25, do: [:"tlsv1.2"], else: [:"tlsv1.2", :"tlsv1.3"]
  end

  defp otp_version do
    :erlang.system_info(:otp_release) |> List.to_integer()
  end

  defp get_url(base_url) do
    base_url
    |> String.replace("$version", configured_version())
    |> String.replace("$target", configured_target())
  end
end

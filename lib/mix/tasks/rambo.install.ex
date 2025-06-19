defmodule Mix.Tasks.Rambo.Install do
  @moduledoc """
  Installs Rambo executable.

      $ mix rambo.install
      $ mix rambo.install --if-missing

  By default, it installs #{Rambo.latest_version()} but you
  can configure it in your config files, such as:

      config :rambo, :version, "#{Rambo.latest_version()}"

  To install the Rambo binary from a custom URL, you can supply a 
  third party path to the binary:

  ```bash
  $ mix rambo.install https://github.com/jayjun/rambo/releases/download/v0.3.4/rambo-linux
  ```

  ## Options

      * `--runtime-config` - load the runtime configuration
        before executing command

      * `--if-missing` - install only if the given version
        does not exist

  """

  @shortdoc "Installs Rambo executable"
  @compile {:no_warn_undefined, Mix}

  use Mix.Task

  @impl true
  def run(args) do
    valid_options = [runtime_config: :boolean, if_missing: :boolean]

    {opts, base_url} =
      case OptionParser.parse_head!(args, strict: valid_options) do
        {opts, []} ->
          {opts, Rambo.default_base_url()}

        {opts, [base_url]} ->
          {opts, base_url}

        {_, _} ->
          Mix.raise("""
          Invalid arguments to rambo.install, expected one of:

              mix rambo.install
              mix rambo.install 'https://github.com/jayjun/rambo/releases/download/v$version/rambo-$target'
              mix rambo.install --runtime-config
              mix rambo.install --if-missing
          """)
      end

    if opts[:runtime_config], do: Mix.Task.run("app.config")

    if opts[:if_missing] && latest_version?() do
      :ok
    else
      if function_exported?(Mix, :ensure_application!, 1) do
        Mix.ensure_application!(:inets)
        Mix.ensure_application!(:ssl)
      end

      Mix.Task.run("loadpaths")
      Rambo.install(base_url)
    end
  end

  defp latest_version?() do
    version = Rambo.configured_version()
    match?({:ok, ^version}, Rambo.bin_version())
  end
end
defmodule Mix.Tasks.Rambo do
  @moduledoc """
  Invokes rambo with the given args.

  Usage:

      $ mix rambo TASK_OPTIONS PROFILE RAMBO_ARGS

  Example:

      $ mix rambo default echo "hello world"

  If Rambo is not installed, it is automatically downloaded.
  Note the arguments given to this task will be appended
  to any configured arguments.

  ## Options

    * `--runtime-config` - load the runtime configuration
      before executing command

  Note flags to control this Mix task must be given before the
  profile:

      $ mix rambo --runtime-config default
  """

  @shortdoc "Invokes rambo with the profile and args"
  @compile {:no_warn_undefined, Mix}

  use Mix.Task

  @impl true
  def run(args) do
    switches = [runtime_config: :boolean]
    {opts, remaining_args} = OptionParser.parse_head!(args, switches: switches)

    if function_exported?(Mix, :ensure_application!, 1) do
      Mix.ensure_application!(:inets)
      Mix.ensure_application!(:ssl)
    end

    if opts[:runtime_config] do
      Mix.Task.run("app.config")
    else
      Mix.Task.run("loadpaths")
      Application.ensure_all_started(:rambo)
    end

    Mix.Task.reenable("rambo")
    install_and_run(remaining_args)
  end

  defp install_and_run([profile | args] = all) do
    case Rambo.install_and_run(String.to_atom(profile), args) do
      0 -> :ok
      status ->
        Mix.raise("`mix rambo #{Enum.join(all, " ")}` exited with #{status}")
        :error
    end
  end

  defp install_and_run([]) do
    Mix.raise("`mix rambo` expects the profile as argument")
    :error
  end
end

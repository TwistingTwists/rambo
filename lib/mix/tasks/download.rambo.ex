defmodule Mix.Tasks.Download.Rambo do
  @moduledoc """
  Downloads the pre-built Rambo binary from GitHub releases.

  ## Examples

      mix download.rambo
      mix download.rambo --version v0.3.4
      mix download.rambo --force

  ## Command line options

    * `--version` - specific version to download (defaults to latest)
    * `--force` - force download even if binary already exists

  """
  use Mix.Task

  @shortdoc "Downloads pre-built Rambo binary from GitHub releases"

  @mix_project Rambo.MixProject.project()
  @repo_url @mix_project[:package][:links]["GitHub"]
  @api_url String.replace(@repo_url, "https://github.com/", "https://api.github.com/repos/")

  # Platform mappings matching compile.rambo.ex
  @platforms %{
    "x86_64-apple-darwin" => "rambo-mac",
    "aarch64-apple-darwin" => "rambo-macarm", 
    "x86_64-unknown-linux-musl" => "rambo-linux",
    "aarch64-unknown-linux-musl" => "rambo-linuxarm",
    "x86_64-pc-windows-gnu" => "rambo.exe"
  }

  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [version: :string, force: :boolean])
    
    version = opts[:version]
    force = opts[:force] || false
    
    case ensure_binary_exists(version, force) do
      :ok ->
        Mix.shell().info("Rambo binary ready")
      {:error, reason} ->
        Mix.shell().error("Failed to download Rambo binary: #{reason}")
        System.halt(1)
    end
  end

  defp ensure_binary_exists(version, force) do
    executable_path = Mix.Tasks.Compile.Rambo.find_rambo()
    
    if File.exists?(executable_path) and not force do
      :ok
    else
      download_binary(version, executable_path)
    end
  end

  defp download_binary(version, executable_path) do
    with {:ok, platform} <- detect_platform(),
         {:ok, download_url} <- get_download_url(version, platform),
         {:ok, binary_data} <- download_file(download_url),
         :ok <- save_binary(binary_data, executable_path) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp detect_platform do
    environment = List.to_string(:erlang.system_info(:system_architecture))
    
    platform = cond do
      String.starts_with?(environment, "x86_64-apple-darwin") ->
        "x86_64-apple-darwin"
      String.starts_with?(environment, "aarch64-apple-darwin") ->
        "aarch64-apple-darwin"
      String.starts_with?(environment, "x86_64") and String.contains?(environment, "linux") ->
        "x86_64-unknown-linux-musl"
      String.starts_with?(environment, "aarch64") and String.contains?(environment, "linux") ->
        "aarch64-unknown-linux-musl"
      environment == "win32" ->
        "x86_64-pc-windows-gnu"
      true ->
        nil
    end

    case platform do
      nil -> {:error, "Unsupported platform: #{environment}"}
      platform -> {:ok, platform}
    end
  end

  defp get_download_url(version, platform) do
    filename = @platforms[platform]
    version_tag = version || get_latest_version()
    
    case version_tag do
      {:ok, tag} ->
        url = "#{@repo_url}/releases/download/#{tag}/#{filename}"
        {:ok, url}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_latest_version do
    Mix.shell().info("Fetching latest release information...")
    
    case http_get("#{@api_url}/releases/latest") do
      {:ok, %{"tag_name" => tag}} ->
        {:ok, tag}
      {:ok, %{"message" => message}} ->
        {:error, "GitHub API error: #{message}"}
      {:error, reason} ->
        {:error, "Failed to fetch release info: #{reason}"}
    end
  end

  defp download_file(url) do
    Mix.shell().info("Downloading binary from #{url}...")
    
    case http_get(url, [], recv_timeout: 30_000) do
      {:ok, binary_data} when is_binary(binary_data) ->
        {:ok, binary_data}
      {:ok, %{"message" => message}} ->
        {:error, "Download failed: #{message}"}
      {:error, reason} ->
        {:error, "Download failed: #{reason}"}
    end
  end

  defp save_binary(binary_data, executable_path) do
    Mix.shell().info("Saving binary to #{executable_path}...")
    
    case File.mkdir_p(Path.dirname(executable_path)) do
      :ok ->
        case File.write(executable_path, binary_data) do
          :ok ->
            File.chmod!(executable_path, 0o755)
            :ok
          {:error, reason} ->
            {:error, "Failed to save binary: #{reason}"}
        end
      {:error, reason} ->
        {:error, "Failed to create directory: #{reason}"}
    end
  end

  defp http_get(url, headers \\ [], opts \\ []) do
    case :httpc.request(:get, {String.to_charlist(url), headers}, opts, []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        case Jason.decode(body) do
          {:ok, json} -> {:ok, json}
          {:error, _} -> {:ok, body}
        end
      {:ok, {{_, status, _}, _headers, body}} ->
        {:error, "HTTP #{status}: #{body}"}
      {:error, reason} ->
        {:error, reason}
    end
  end
end
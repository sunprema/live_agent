defmodule LiveAgent.BaselineStore do
  @moduledoc false
  # Thin, disk-backed store for named screenshot baselines and their diff
  # overlays. Files live under the host app's working directory (where
  # `mix phx.server` runs) so they survive across MCP calls and panel
  # reconnects, and sit next to the project rather than in /tmp:
  #
  #   screenshots/baselines/<name>.png   — the captured baseline
  #   screenshots/diffs/<name>.png       — the most recent diff overlay
  #
  # No GenServer: the filesystem is the state.

  @doc "Absolute path to the baselines directory."
  def baselines_dir, do: Path.join([File.cwd!(), "screenshots", "baselines"])

  @doc "Absolute path to the diffs directory."
  def diffs_dir, do: Path.join([File.cwd!(), "screenshots", "diffs"])

  @doc """
  Validates a baseline name, allowing only filename-safe characters so a name
  can never escape the store directory. Returns `{:ok, name}` or `{:error, msg}`.
  """
  def validate_name(name) when is_binary(name) do
    cond do
      name == "" -> {:error, "name cannot be empty"}
      String.contains?(name, "/") or String.contains?(name, "..") -> {:error, "name may not contain '/' or '..'"}
      not Regex.match?(~r/\A[A-Za-z0-9._-]+\z/, name) -> {:error, "name may only contain letters, digits, '.', '_', '-'"}
      true -> {:ok, name}
    end
  end

  def validate_name(_), do: {:error, "name must be a string"}

  @doc "Absolute path a baseline with `name` would occupy (after validation)."
  def baseline_path(name), do: Path.join(baselines_dir(), name <> ".png")

  @doc "Absolute path a diff overlay for `name` would occupy."
  def diff_path(name), do: Path.join(diffs_dir(), name <> ".png")

  @doc """
  Writes raw PNG bytes as the baseline for `name` (overwriting any existing
  one). Returns `{:ok, path}` or `{:error, reason}`.
  """
  def put(name, png_bytes) when is_binary(png_bytes) do
    with {:ok, name} <- validate_name(name),
         path = baseline_path(name),
         :ok <- File.mkdir_p(baselines_dir()),
         :ok <- File.write(path, png_bytes) do
      {:ok, path}
    end
  end

  @doc "Reads the baseline PNG bytes for `name`. `{:ok, bytes}` or `{:error, :not_found}`."
  def get(name) do
    with {:ok, name} <- validate_name(name) do
      case File.read(baseline_path(name)) do
        {:ok, bytes} -> {:ok, bytes}
        {:error, :enoent} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Writes a diff overlay PNG for `name`. Returns `{:ok, path}` or `{:error, reason}`."
  def put_diff(name, png_bytes) when is_binary(png_bytes) do
    with {:ok, name} <- validate_name(name),
         path = diff_path(name),
         :ok <- File.mkdir_p(diffs_dir()),
         :ok <- File.write(path, png_bytes) do
      {:ok, path}
    end
  end

  @doc "Lists existing baseline names (without the .png extension), sorted."
  def list do
    case File.ls(baselines_dir()) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".png"))
        |> Enum.map(&String.replace_suffix(&1, ".png", ""))
        |> Enum.sort()

      _ ->
        []
    end
  end
end

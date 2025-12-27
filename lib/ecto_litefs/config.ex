defmodule EctoLiteFS.Config do
  @moduledoc """
  Configuration struct for EctoLiteFS instances.

  Validates and holds all configuration options passed to `EctoLiteFS.Supervisor`.

  ## Configuration Options

  * `:repo` - The Ecto Repo module (required, used as the unique identifier)
  * `:primary_file` - Path to LiteFS `.primary` file. Default: `"/litefs/.primary"`
  * `:poll_interval` - Filesystem poll interval in ms. Default: `30_000`
  * `:event_stream_url` - LiteFS HTTP events endpoint. Default: `"http://localhost:20202/events"`
  * `:table_name` - Database table for primary tracking. Default: `"_ecto_litefs_primary"`
  * `:cache_ttl` - Cache TTL in ms. Default: `5_000`
  * `:refresh_grace_period` - Grace period in ms to skip redundant cache refreshes. Default: `100`
  """

  @enforce_keys [:repo]
  defstruct [
    :repo,
    primary_file: "/litefs/.primary",
    poll_interval: 30_000,
    event_stream_url: "http://localhost:20202/events",
    table_name: "_ecto_litefs_primary",
    cache_ttl: 5_000,
    refresh_grace_period: 100
  ]

  @type t :: %__MODULE__{
          repo: module(),
          primary_file: String.t(),
          poll_interval: pos_integer(),
          event_stream_url: String.t(),
          table_name: String.t(),
          cache_ttl: pos_integer(),
          refresh_grace_period: pos_integer()
        }

  @doc """
  Creates a new Config struct from the given options.

  Raises `ArgumentError` if required options are missing or invalid.

  ## Required Options

  * `:repo` - The Ecto Repo module (also serves as the unique identifier)

  ## Optional Options

  * `:primary_file` - Path to LiteFS `.primary` file. Default: `"/litefs/.primary"`
  * `:poll_interval` - Filesystem poll interval in ms. Default: `30_000`
  * `:event_stream_url` - LiteFS HTTP events endpoint. Default: `"http://localhost:20202/events"`
  * `:table_name` - Database table for primary tracking. Default: `"_ecto_litefs_primary"`
  * `:cache_ttl` - Cache TTL in ms. Default: `5_000`
  * `:refresh_grace_period` - Grace period in ms to skip redundant cache refreshes. Default: `100`

  ## Examples

      iex> EctoLiteFS.Config.new!(repo: MyApp.Repo)
      %EctoLiteFS.Config{repo: MyApp.Repo, ...}

      iex> EctoLiteFS.Config.new!([])
      ** (ArgumentError) EctoLiteFS.Config requires :repo option

  """
  @spec new!(keyword()) :: t()
  def new!(opts) when is_list(opts) do
    opts
    |> validate_required!(:repo)
    |> validate_atom!(:repo)
    |> validate_positive_integer!(:poll_interval)
    |> validate_positive_integer!(:cache_ttl)
    |> validate_positive_integer!(:refresh_grace_period)
    |> validate_non_empty_string!(:primary_file)
    |> validate_non_empty_string!(:event_stream_url)
    |> validate_table_name!()
    |> build_struct()
  end

  defp validate_required!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, _value} -> opts
      :error -> raise ArgumentError, "EctoLiteFS.Config requires :#{key} option"
    end
  end

  defp validate_atom!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_atom(value) -> opts
      {:ok, _value} -> raise ArgumentError, "EctoLiteFS.Config :#{key} must be an atom"
      :error -> opts
    end
  end

  defp validate_positive_integer!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) and value > 0 ->
        opts

      {:ok, value} ->
        raise ArgumentError,
              "EctoLiteFS.Config :#{key} must be a positive integer, got: #{inspect(value)}"

      :error ->
        opts
    end
  end

  defp validate_non_empty_string!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        opts

      {:ok, value} ->
        raise ArgumentError,
              "EctoLiteFS.Config :#{key} must be a non-empty string, got: #{inspect(value)}"

      :error ->
        opts
    end
  end

  defp validate_table_name!(opts) do
    cond do
      not Keyword.has_key?(opts, :table_name) ->
        opts

      not is_binary(opts[:table_name]) ->
        raise ArgumentError,
              "EctoLiteFS.Config :table_name must be a string, got: #{inspect(opts[:table_name])}"

      not Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*$/, opts[:table_name]) ->
        raise ArgumentError,
              "EctoLiteFS.Config :table_name must be a valid SQL identifier (alphanumeric and underscores, starting with letter or underscore), got: #{inspect(opts[:table_name])}"

      true ->
        opts
    end
  end

  defp build_struct(opts) do
    struct!(__MODULE__, opts)
  end
end

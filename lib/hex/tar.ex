defmodule Hex.Tar do
  @moduledoc false

  # TODO: convert strings to atoms when unpacking
  #
  # @type metadata() :: %{
  #         name: String.t(),
  #         version: String.t(),
  #         app: String.t(),
  #         description: String.t(),
  #         files: String.t(),
  #         licenses: String.t(),
  #         requirements: [requirement()],
  #         build_tools: list(String.t()),
  #         elixir: version_requirement(),
  #         maintainers: list(String.t()),
  #         links: map()
  #       }
  #
  # @type requirement() :: %{
  #         app: String.t(),
  #         optional: boolean(),
  #         requirement: version_requirement(),
  #         repository: String.t()
  #       }

  @type metadata() :: map()

  @type file() :: Path.t() | {Path.t(), binary()}

  @type checksum :: binary()

  @type tar :: binary()

  @supported ["3"]
  @version "3"
  @required_files ~w(VERSION CHECKSUM metadata.config contents.tar.gz)c
  @tar_max_size 8 * 1024 * 1024

  @doc """
  Creates a package tarball.

  ## Examples

      iex> {:ok, {tar, checksum}} = Hex.Tar.create(%{app: :ecto, version: "2.0.0"}, ["lib/ecto.ex"], "deps/")
      # creates deps/ecto-2.0.0.tar

      iex> {:ok, {tar, checksum}} = Hex.Tar.create(%{app: :ecto, version: "2.0.0"}, [{"lib/ecto.ex", "defmodule Ecto"}], ".")
      # creates ./ecto-2.0.0.tar

      iex> {:ok, {tar, checksum}} = Hex.Tar.create(%{app: :ecto, version: "2.0.0"}, [{"ecto.ex", "defmodule Ecto"}], :memory)
      # nothing is saved to disk

  """
  @spec create(metadata(), [file()], output :: Path.t() | :memory) ::
          {:ok, {tar(), checksum()}} | {:error, term()}
  def create(meta, files, output) do
    contents = create_tar(:memory, files, [:compressed])

    meta_string = encode_term(meta)
    blob = @version <> meta_string <> contents
    checksum = :crypto.hash(:sha256, blob)

    files = [
      {"VERSION", @version},
      {"CHECKSUM", Base.encode16(checksum)},
      {"metadata.config", meta_string},
      {"contents.tar.gz", contents}
    ]

    tar = create_tar(output, files, [])

    if byte_size(tar) > @tar_max_size do
      {:error, {:tarball, :too_big}}
    else
      {:ok, {tar, checksum}}
    end
  end

  def create_tar(path, files, opts) when is_binary(path) do
    File.mkdir_p!(Path.dirname(path))
    {:ok, tar} = :hex_erl_tar.open(string_to_charlist(path), opts ++ [:write])

    try do
      add_files(tar, files)
    after
      :hex_erl_tar.close(tar)
    end

    File.read!(path)
  end

  def create_tar(:memory, files, opts) do
    compressed? = :compressed in opts
    {:ok, fd} = :file.open([], [:ram, :read, :write, :binary])
    {:ok, tar} = :hex_erl_tar.init(fd, :write, &file_op/2)

    binary =
      try do
        try do
          add_files(tar, files)
        after
          :ok = :hex_erl_tar.close(tar)
        end

        {:ok, size} = :file.position(fd, :cur)
        {:ok, binary} = :file.pread(fd, 0, size)
        binary
      after
        :ok = :file.close(fd)
      end

    if compressed? do
      gzip(binary)
    else
      binary
    end
  end

  # Reproducible gzip by not setting mtime and OS
  #
  # From https://tools.ietf.org/html/rfc1952
  #
  # +---+---+---+---+---+---+---+---+---+---+
  # |ID1|ID2|CM |FLG|     MTIME     |XFL|OS | (more-->)
  # +---+---+---+---+---+---+---+---+---+---+
  #
  # +=======================+
  # |...compressed blocks...| (more-->)
  # +=======================+
  #
  # +---+---+---+---+---+---+---+---+
  # |     CRC32     |     ISIZE     |
  # +---+---+---+---+---+---+---+---+
  def gzip(uncompressed) do
    compressed = gzip_no_header(uncompressed)
    header = <<31, 139, 8, 0, 0, 0, 0, 0, 0, 0>>
    crc = :erlang.crc32(uncompressed)
    size = byte_size(uncompressed)
    trailer = <<crc::integer-32-little, size::integer-32-little>>
    IO.iodata_to_binary([header, compressed, trailer])
  end

  defp gzip_no_header(uncompressed) do
    zstream = :zlib.open()

    try do
      :zlib.deflateInit(zstream, :default, :deflated, -15, 8, :default)
      compressed = :zlib.deflate(zstream, uncompressed, :finish)
      :zlib.deflateEnd(zstream)
      IO.iodata_to_binary(compressed)
    after
      :zlib.close(zstream)
    end
  end

  defp file_op(:write, {fd, data}), do: :file.write(fd, data)
  defp file_op(:position, {fd, pos}), do: :file.position(fd, pos)
  defp file_op(:read2, {fd, size}), do: :file.read(fd, size)
  defp file_op(:close, _fd), do: :ok

  unix_epoch = :calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})
  y2k = :calendar.datetime_to_gregorian_seconds({{2000, 1, 1}, {0, 0, 0}})
  epoch = y2k - unix_epoch

  @tar_opts [atime: epoch, mtime: epoch, ctime: epoch, uid: 0, gid: 0]

  defp add_files(tar, files) do
    Enum.each(files, fn
      {name, contents, mode} ->
        :ok = :hex_erl_tar.add(tar, contents, string_to_charlist(name), mode, @tar_opts)

      {name, contents} ->
        :ok = :hex_erl_tar.add(tar, contents, string_to_charlist(name), @tar_opts)

      name ->
        case file_lstat(name) do
          {:ok, %File.Stat{type: type}} when type in [:directory, :symlink] ->
            :ok = :hex_erl_tar.add(tar, string_to_charlist(name), @tar_opts)

          _stat ->
            contents = File.read!(name)
            mode = File.stat!(name).mode
            :ok = :hex_erl_tar.add(tar, contents, string_to_charlist(name), mode, @tar_opts)
        end
    end)
  end

  @doc """
  Unpacks a package tarball.

  ## Examples

      iex> {:ok, {metadata, checksum}} = Hex.Tar.unpack("ecto-2.0.0.tar", "deps/")
      # unpacks to deps/ecto-2.0.0/

      iex> {:ok, {metadata, checksum, files}} = Hex.Tar.unpack({:binary, tar}, :memory)
      iex> files
      [{"lib/ecto.ex", "defmodule Ecto ..."}, ...]

  """
  @spec unpack(file :: Path.t() | {:binary, binary()}, output :: Path.t()) ::
          {:ok, {metadata(), checksum()}} | {:error, term()}
  @spec unpack(file :: Path.t() | {:binary, binary()}, output :: :memory) ::
          {:ok, {metadata(), checksum(), files :: [{Path.t(), binary()}]}} | {:error, term()}
  def unpack({:binary, tar}, _dest) when byte_size(tar) > @tar_max_size do
    {:error, {:tarball, :too_big}}
  end

  def unpack(tar, dest) do
    case :hex_erl_tar.extract(tar, [:memory]) do
      {:ok, files} when files != [] ->
        files = Enum.into(files, %{})

        %{checksum: nil, files: files, metadata: nil, contents: nil}
        |> check_files()
        |> check_version()
        |> check_checksum()
        |> copy_metadata(dest)
        |> decode_metadata()
        |> normalize_metadata()
        |> extract_contents(dest)

      {:ok, []} ->
        {:error, {:tarball, :empty}}

      {:error, reason} ->
        {:error, {:tarball, reason}}
    end
  end

  defp check_version({:error, _} = error), do: error

  defp check_version(state) do
    version = state.files['VERSION']

    if version in @supported do
      state
    else
      {:error, {:tarball, {:bad_version, version}}}
    end
  end

  defp check_files({:error, _} = error), do: error

  defp check_files(state) do
    case diff_keys(state.files, @required_files, []) do
      :ok ->
        state

      {:error, {:missing_keys, missing_files}} ->
        {:error, {:tarball, {:missing_files, missing_files}}}

      {:error, {:unknown_keys, invalid_files}} ->
        {:error, {:tarball, {:invalid_files, invalid_files}}}
    end
  end

  defp check_checksum({:error, _} = error), do: error

  defp check_checksum(state) do
    checksum_base16 = state.files['CHECKSUM']

    case Base.decode16(checksum_base16, case: :mixed) do
      {:ok, expected_checksum} ->
        meta = state.files['metadata.config']
        blob = state.files['VERSION'] <> meta <> state.files['contents.tar.gz']
        actual_checksum = :crypto.hash(:sha256, blob)

        if expected_checksum == actual_checksum do
          %{state | checksum: expected_checksum}
        else
          {:error, {:checksum_mismatch, expected_checksum, actual_checksum}}
        end

      :error ->
        {:error, :invalid_checksum}
    end
  end

  defp decode_metadata({:error, _} = error), do: error

  defp decode_metadata(state) do
    string = safe_to_charlist(state.files['metadata.config'])

    case :safe_erl_term.string(string) do
      {:ok, tokens, _line} ->
        try do
          terms = :safe_erl_term.terms(tokens)
          %{state | metadata: Enum.into(terms, %{})}
        rescue
          FunctionClauseError ->
            {:error, {:metadata, :invalid_terms}}

          ArgumentError ->
            {:error, {:metadata, :not_key_value}}
        end

      {:error, {_line, :safe_erl_term, reason}, _line2} ->
        {:error, {:metadata, reason}}
    end
  end

  defp normalize_metadata({:error, _} = error), do: error

  defp normalize_metadata(state) do
    Map.update!(state, :metadata, fn metadata ->
      metadata
      |> guess_build_tools()
      |> try_update("requirements", &normalize_requirements/1)
      |> try_update("links", &try_into_map/1)
      |> try_update("extra", &try_into_map/1)
    end)
  end

  @build_tools [
    {"mix.exs", "mix"},
    {"rebar.config", "rebar"},
    {"rebar", "rebar"},
    {"Makefile", "make"},
    {"Makefile.win", "make"}
  ]

  defp guess_build_tools(%{"build_tools" => _} = meta) do
    meta
  end

  defp guess_build_tools(meta) do
    base_files =
      (meta["files"] || [])
      |> Enum.filter(&(Path.dirname(&1) == "."))
      |> Enum.uniq()

    build_tools =
      Enum.flat_map(@build_tools, fn {file, tool} ->
        if file in base_files,
          do: [tool],
          else: []
      end)
      |> Enum.uniq()

    if build_tools != [] do
      Map.put(meta, "build_tools", build_tools)
    else
      meta
    end
  end

  defp normalize_requirements(requirements) do
    if is_list(requirements) and is_list(List.first(requirements)) do
      # TODO: deprecate this shape of requirements
      Enum.into(requirements, %{}, fn requirement ->
        map = Enum.into(requirement, %{})
        {Map.fetch!(map, "name"), Map.delete(map, "name")}
      end)
    else
      try_into_map(requirements, fn {key, value} ->
        {key, try_into_map(value)}
      end)
    end
  end

  defp try_update(map, key, fun) do
    case Map.fetch(map, key) do
      {:ok, value} -> Map.put(map, key, fun.(value))
      :error -> map
    end
  end

  defp try_into_map(input, fun \\ fn x -> x end) do
    if is_list(input) and Enum.all?(input, &(is_tuple(&1) and tuple_size(&1) == 2)) do
      Enum.into(input, %{}, fun)
    else
      input
    end
  end

  defp copy_metadata({:error, _} = error, _dest), do: error

  defp copy_metadata(state, :memory) do
    state
  end

  defp copy_metadata(state, dest) do
    File.mkdir_p!(dest)
    file_name = "hex_metadata.config"
    path = Path.join(dest, file_name)
    File.write!(path, state.files['metadata.config'])
    state
  end

  defp extract_contents({:error, _} = error, _dest), do: error

  defp extract_contents(state, dest) do
    case do_extract_contents(state.files['contents.tar.gz'], dest) do
      :ok ->
        {:ok, {state.metadata, state.checksum}}

      {:ok, files} ->
        files = for {path, contents} <- files, do: {List.to_string(path), contents}
        {:ok, {state.metadata, state.checksum, files}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_extract_contents(binary, :memory) do
    case :hex_erl_tar.extract({:binary, binary}, [:compressed, :memory]) do
      {:ok, files} ->
        {:ok, files}

      {:error, reason} ->
        {:error, {:inner_tarball, reason}}
    end
  end

  defp do_extract_contents(binary, dest) do
    case :hex_erl_tar.extract({:binary, binary}, [:compressed, cwd: dest]) do
      :ok ->
        Path.join(dest, "**")
        |> Path.wildcard()
        |> Enum.each(&File.touch!/1)

        :ok

      {:error, reason} ->
        {:error, {:inner_tarball, reason}}
    end
  end

  defp encode_term(list) do
    list
    |> binarify(maps: false)
    |> Enum.map(&[:io_lib_pretty.print(&1, encoding: :utf8) | ".\n"])
    |> IO.chardata_to_string()
  end

  @inner_error "inner tarball error, "
  @metadata_error "error reading package metadata, "

  def format_error({:tarball, :empty}), do: "empty tarball"
  def format_error({:tarball, :too_big}), do: "tarball is too big"
  def format_error({:tarball, {:missing_files, files}}), do: "missing files: #{inspect(files)}"
  def format_error({:tarball, {:invalid_files, files}}), do: "invalid files: #{inspect(files)}"
  def format_error({:tarball, {:bad_version, vsn}}), do: "unsupported version: #{inspect(vsn)}"
  def format_error({:tarball, reason}), do: format_tarball_error(reason)
  def format_error({:inner_tarball, reason}), do: @inner_error <> format_tarball_error(reason)
  def format_error({:metadata, :invalid_terms}), do: @metadata_error <> "invalid terms"
  def format_error({:metadata, :not_key_value}), do: @metadata_error <> "not in key-value format"
  def format_error({:metadata, reason}), do: @metadata_error <> format_metadata_error(reason)
  def format_error(:invalid_checksum), do: "invalid tarball checksum"

  def format_error({:checksum_mismatch, expected_checksum, actual_checksum}) do
    "tarball checksum mismatch\n\n" <>
      "Expected (base16-encoded): #{Base.encode16(expected_checksum)}\n" <>
      "Actual   (base16-encoded): #{Base.encode16(actual_checksum)}"
  end

  defp format_tarball_error(reason) do
    reason |> :hex_erl_tar.format_error() |> List.to_string()
  end

  defp format_metadata_error(reason) do
    reason |> :safe_erl_term.format_error() |> List.to_string()
  end

  # Utils

  defp diff_keys(map, required_keys, optional_keys) do
    keys = Map.keys(map)
    missing_keys = required_keys -- keys
    unknown_keys = keys -- (required_keys ++ optional_keys)

    case {missing_keys, unknown_keys} do
      {[], []} ->
        :ok

      {_, [_ | _]} ->
        {:error, {:unknown_keys, unknown_keys}}

      {_, _} ->
        {:error, {:missing_keys, missing_keys}}
    end
  end

  # Some older packages have invalid unicode
  defp safe_to_charlist(string) do
    try do
      string_to_charlist(string)
    rescue
      UnicodeConversionError ->
        :erlang.binary_to_list(string)
    end
  end

  if Version.compare(System.version(), "1.3.0") == :lt do
    defp string_to_charlist(string), do: String.to_char_list(string)
  else
    defp string_to_charlist(string), do: String.to_charlist(string)
  end

  defp binarify(binary, _opts) when is_binary(binary) do
    binary
  end

  defp binarify(number, _opts) when is_number(number) do
    number
  end

  defp binarify(atom, _opts) when is_nil(atom) or is_boolean(atom) do
    atom
  end

  defp binarify(atom, _opts) when is_atom(atom) do
    Atom.to_string(atom)
  end

  defp binarify(list, opts) when is_list(list) do
    for(elem <- list, do: binarify(elem, opts))
  end

  defp binarify(tuple, opts) when is_tuple(tuple) do
    for(elem <- Tuple.to_list(tuple), do: binarify(elem, opts))
    |> List.to_tuple()
  end

  defp binarify(map, opts) when is_map(map) do
    if Keyword.get(opts, :maps, true) do
      for(elem <- map, into: %{}, do: binarify(elem, opts))
    else
      for(elem <- map, do: binarify(elem, opts))
    end
  end

  defp file_lstat(path, opts \\ []) do
    opts = Keyword.put_new(opts, :time, :universal)

    case :file.read_link_info(IO.chardata_to_string(path), opts) do
      {:ok, fileinfo} ->
        {:ok, File.Stat.from_record(fileinfo)}

      error ->
        error
    end
  end
end

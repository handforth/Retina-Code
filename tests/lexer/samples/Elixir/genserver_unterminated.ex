# Second Elixir sample: GenServer, protocols, and an unterminated heredoc at EOF.
# Elixir has no block comments, so the file ends inside a heredoc and a sigil instead.
defmodule Stress.Counter do
  use GenServer
  require Logger
  alias Stress.Counter.{State, Event}
  import Kernel, except: [inspect: 1]

  @typedoc "Internal state"
  @type t :: %__MODULE__{count: non_neg_integer(), history: [integer()], name: String.t() | nil}
  defstruct count: 0, history: [], name: nil

  @timeout :timer.seconds(5)
  @max 0xFFFF

  ## Client API

  @doc """
  Starts the counter.

  Options:
    * `:name` - registered name (default: `#{__MODULE__}`)
    * `:initial` - initial value
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def increment(server \\ __MODULE__, by \\ 1) when is_integer(by) and by > 0 do
    GenServer.call(server, {:increment, by}, @timeout)
  end

  def value(server \\ __MODULE__), do: GenServer.call(server, :value)
  def reset(server \\ __MODULE__), do: GenServer.cast(server, :reset)

  ## Server callbacks

  @impl true
  def init(opts) do
    initial = Keyword.get(opts, :initial, 0)
    Process.flag(:trap_exit, true)
    Logger.info("starting counter at #{initial} (max #{@max})")
    {:ok, %__MODULE__{count: initial, name: opts[:label]}, {:continue, :warmup}}
  end

  @impl true
  def handle_continue(:warmup, state) do
    send(self(), :tick)
    {:noreply, state}
  end

  @impl true
  def handle_call({:increment, by}, _from, %{count: c} = state) when c + by <= @max do
    new = %{state | count: c + by, history: [c | Enum.take(state.history, 9)]}
    {:reply, {:ok, new.count}, new}
  end

  def handle_call({:increment, _by}, _from, state) do
    {:reply, {:error, :overflow}, state}
  end

  def handle_call(:value, _from, state), do: {:reply, state.count, state}

  @impl true
  def handle_cast(:reset, state), do: {:noreply, %{state | count: 0, history: []}}

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, 1_000)
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    Logger.warning("linked process #{inspect(pid)} exited: #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug(fn -> "unexpected message: #{inspect(msg, pretty: true)}" end)
    {:noreply, state}
  end

  @impl true
  def terminate(reason, %{count: c}) do
    Logger.info(~s(terminating with count=#{c} reason="#{inspect(reason)}"))
    :ok
  end

  defp inspect(term, opts \\ []), do: Kernel.inspect(term, opts)
end

defprotocol Stress.Describe do
  @fallback_to_any true
  @spec describe(t) :: String.t()
  def describe(value)
end

defimpl Stress.Describe, for: Integer do
  def describe(n) when n < 0, do: "negative integer #{n}"
  def describe(n), do: "integer #{n} (0x#{Integer.to_string(n, 16)})"
end

defimpl Stress.Describe, for: BitString do
  def describe(s) when is_binary(s), do: ~s(binary "#{s}" of #{byte_size(s)} bytes)
  def describe(bits), do: "bitstring of #{bit_size(bits)} bits"
end

defimpl Stress.Describe, for: Any do
  def describe(%{__struct__: mod}), do: "struct #{inspect(mod)}"
  def describe(other), do: "something: #{inspect(other)}"
end

defmodule Stress.Parser do
  @moduledoc false

  @spec parse_kv(String.t()) :: map()
  def parse_kv(input) do
    ~r/(?<key>\w+)\s*=\s*(?:"(?<quoted>[^"]*)"|(?<plain>\S+))/
    |> Regex.scan(input, capture: :all_names)
    |> Enum.into(%{}, fn [key, plain, quoted] -> {key, if(quoted != "", do: quoted, else: plain)} end)
  end

  def binaries do
    <<1, 2, 3>> <> <<"abc"::binary, 0xFF::8, -1::signed-integer-size(16)-big>>
  end

  def numbers, do: [1_0, 0x1_F, 0b1_1, 0o7_7, 1.0e-1_0, ?\t, ?\x41, ?A, ?é]

  def sigil_edge_cases do
    [
      ~s(nested (parens (deep)) closes),
      ~s{nested {braces {deep}} closes},
      ~s[nested [brackets] closes],
      ~s<nested <angles> closes>,
      ~r/escaped \/ slash/,
      ~w(a b c)c,
      ~S"literal \" escape keeps backslash"
    ]
  end
end

defmodule Stress.Unterminated do
  def docs do
    ~S"""
    This sigil heredoc has no closing delimiter.
    #{not interpolated because of ~S}
    def not_code, do: :ok
    "quotes" inside
    ''' a charlist heredoc delimiter inside, not a closer
  end
end

# Elixir lexer stress: interpolation, sigils, heredocs, charlists, atoms
defmodule Stress.Sigils do
  @moduledoc """
  Module doc heredoc with "quotes", #{"interpolation"} and `code`.

      iex> Stress.Sigils.hello("World")
      "Hello, World!"
  """

  @doc ~S"""
  Doc with ~S so #{not_interpolated} and \n are literal.
  """
  @spec hello(String.t()) :: String.t()
  def hello(name), do: "Hello, #{name}!"

  @attr "module attribute"
  @compile {:inline, hello: 1}
  @derive [Jason.Encoder]
  defstruct name: nil, age: 0, tags: []

  # Strings and interpolation
  def strings do
    name = "World"
    s1 = "double \"quoted\" with \\ and \n and \t and \e"
    s2 = "interp: #{name} and #{1 + 2} and #{String.upcase(name)}"
    s3 = "nested: #{"inner #{name <> "#{"deep"}"}"}"
    s4 = "escapes: \x41 A \u{1F600} \0 \a \b \d \f \r \s \v"
    s5 = "trailing backslash \\"
    s6 = "multi-line
string with #{name}
spanning lines"
    s7 = "hash not interp: # and \#{escaped}"
    s8 = "interp with braces: #{%{a: 1}[:a]} and #{"}"}"
    s9 = "unterminated string at end of line
    s10 = "after"
    charlist = 'single quotes are charlists with #{name}'
    charlist2 = ~c"sigil charlist #{name}"
    {s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, charlist, charlist2}
  end

  # Heredocs
  def heredocs do
    """
    Double-quoted heredoc with "quotes" and #{inspect(:atom)}
      indented line
    \""" escaped triple
    """
  end

  def charlist_heredoc do
    '''
    Charlist heredoc with 'single' quotes
    '''
  end

  # Sigils with every delimiter
  def sigils do
    [
      ~s(parens with #{1} and \) escaped),
      ~s[brackets],
      ~s{braces {nested} content},
      ~s<angles>,
      ~s|pipes|,
      ~s/slashes/,
      ~s"double quotes",
      ~s'single quotes',
      ~S(uppercase: no #{interp} and \n literal),
      ~w(word list of atoms)a,
      ~w[word list strings]s,
      ~r/regex\s+\d+/i,
      ~r{regex with / slash}x,
      ~r"regex in quotes"u,
      ~R/uppercase regex #{no_interp}/,
      ~D[2024-01-01],
      ~T[12:34:56.789],
      ~N[2024-01-01 12:00:00],
      ~U[2024-01-01 12:00:00Z],
      ~c(charlist sigil),
      ~CUSTOM"multi-letter sigil",
      ~s"""
      Heredoc sigil with #{1 + 1}
      """,
      ~S'''
      Uppercase charlist-delimited heredoc sigil #{nope}
      '''
    ]
  end

  # Atoms
  def atoms do
    [:ok, :error, :"quoted atom", :'single quoted atom', :"interp #{1}",
     :+, :-, :*, :/, :==, :!==, :<<>>, :%{}, :{}, :..., :"Elixir.Module",
     true, false, nil, Foo.Bar, :foo?, :bar!, :@, :&&, :|>]
  end

  # Numbers
  def numbers do
    [1_000_000, 0xFF_FF, 0b1010, 0o17, 1.5e-3, 1.0E10, -0.5, ?a, ?\n, ?\s, ?\\, ?", ?', ?#]
  end

  # Maps, keyword lists, structs
  def data do
    map = %{"string_key" => 1, atom_key: 2, "spaced key": 3}
    kw = [a: 1, b: 2, "quoted key": 3]
    struct = %__MODULE__{name: "x", age: 1}
    updated = %{map | "string_key" => 10}
    nested = %{a: %{b: %{c: [1, 2, {3, 4}]}}}
    get_in(nested, [:a, :b, :c])
    {map, kw, struct, updated}
  end

  # Pattern matching, guards, pipes
  def classify(x) when is_integer(x) and x > 0, do: :positive
  def classify(0), do: :zero
  def classify(x) when is_integer(x), do: :negative
  def classify(<<"prefix:", rest::binary>>), do: {:prefixed, rest}
  def classify(<<a::8, b::size(16)-little, _::bits>>), do: {a, b}
  def classify(_), do: :unknown

  def pipeline(list) do
    list
    |> Enum.map(&(&1 * 2))
    |> Enum.filter(fn x -> rem(x, 3) != 0 end)
    |> Enum.reduce(0, &+/2)
    |> then(&{:ok, &1})
  end

  def control(x) do
    result =
      case x do
        {:ok, value} when value > 10 -> "big #{value}"
        {:ok, value} -> "small #{value}"
        {:error, reason} -> "error: #{inspect(reason)}"
        _ -> "unknown"
      end

    cond do
      String.length(result) > 10 -> :long
      true -> :short
    end

    with {:ok, a} <- fetch(:a),
         {:ok, b} <- fetch(:b) do
      a + b
    else
      :error -> 0
    end
  end

  defp fetch(key), do: {:ok, key |> Atom.to_string() |> String.length()}

  def comprehension do
    for x <- 1..10, y <- 1..x//2, rem(x + y, 2) == 0, into: %{} do
      {x, y}
    end
  end

  def anonymous do
    add = fn a, b -> a + b end
    mul = &(&1 * &2)
    capture = &String.upcase/1
    {add.(1, 2), mul.(3, 4), capture.("x")}
  end

  def try_rescue do
    try do
      raise ArgumentError, message: "bad #{"arg"}"
    rescue
      e in ArgumentError -> {:rescued, e.message}
    catch
      :throw, value -> {:caught, value}
    after
      IO.puts("after")
    end
  end

  defmacro unless_(cond, do: block) do
    quote do
      if !unquote(cond), do: unquote(block)
    end
  end

  def ops, do: {1 <> "", [1] ++ [2], [1, 2] -- [1], 1..10, 1 in [1], not true, 5 div 2, 1 ||| 2, a ~> b}
end

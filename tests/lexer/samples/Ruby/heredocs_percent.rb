# frozen_string_literal: true
# encoding: utf-8
# Ruby lexer stress: heredocs, percent literals, interpolation, regex, symbols

=begin
This is an embedded document (block comment).
It contains "strings" and #{interpolation} and /regexes/
that must all be treated as comment text.
=end

require 'json'
require_relative "lib/helpers"

name = "World"
count = 3

# Strings and interpolation
s1 = 'single \'quoted\' with \\ and no #{interp}'
s2 = "double \"quoted\" with #{name} and \t\n\e\s\0 and \x41 é \u{1F600 1F601} \101"
s3 = "nested: #{"inner #{name + "#{"deep"}"}"} done"
s4 = "expression: #{count * 2} and method: #{name.upcase} and ternary: #{count > 2 ? "many" : 'few'}"
s5 = "instance/global/class vars: #@ivar #$gvar #@@cvar"
s6 = "trailing backslash \\"
s7 = "multi-line
double-quoted string with #{name}
spanning lines"
s8 = "hash without brace # is literal, \#{escaped} too"
s9 = "unterminated at end of line
s10 = "after"
s11 = ?a + ?\n + ?\s + ?\\
s12 = "adjacent " 'literal ' "concatenation"
s13 = "braces in interp #{ { a: 1 }[:a] } and #{"}"}"

# Percent literals
p1 = %q(single-quoted with (nested) parens and #{no_interp})
p2 = %Q{double-quoted with {nested} braces and #{name}}
p3 = %(bare percent is %Q with #{name})
p4 = %w[word list without interpolation #{name}]
p5 = %W[word list with #{name} interpolation and escaped\ space]
p6 = %i(symbol list of atoms)
p7 = %I[symbol list #{name}]
p8 = %s(symbol)
p9 = %x(ls -la #{dir})
p10 = %q<angle brackets <nested> ok>
p11 = %q|pipes as delimiters|
p12 = %q!bangs as delimiters!
p13 = %Q/slashes as delimiters #{name}/
p14 = %w(
  multi-line
  word list
)

# Regex literals
r1 = /a\/b[\/]c/i
r2 = /#{name}\s+\d+/x
r3 = %r{path/with/slashes/#{name}}m
r4 = %r[brackets]
r5 = /(?<year>\d{4})-(?<month>\d{2})/
r6 = /extended
  \d+   # comment inside extended regex
  \s*
/x
r7 = /[a-z]/ =~ "abc"
r8 = "abc" =~ /b/

# Division vs regex
d1 = 10 / 2 / 5
d2 = count / 2
d3 = (count + 1) / 3
d4 = foo /bar/   # ambiguous: method call with regex argument
d5 = foo / bar / baz
d6 = a.size / b.size

# Heredocs
h1 = <<EOS
Plain heredoc with #{name} interpolation
and "quotes" and 'apostrophes'
EOS

h2 = <<-INDENTED
    Dash heredoc allows indented terminator #{count}
    INDENTED

h3 = <<~SQUIGGLY
  Squiggly heredoc strips common indentation
    this line keeps two extra spaces
  and interpolates #{name.downcase}
SQUIGGLY

h4 = <<~'RAW'
  Single-quoted heredoc: no #{interp} and \n is literal
RAW

h5 = <<~"QUOTED"
  Double-quoted label: #{name}
QUOTED

h6 = <<~`CMD`
  echo "backtick heredoc runs a command #{name}"
CMD

sql = <<~SQL.strip.gsub(/\s+/, " ")
  SELECT *
  FROM users
  WHERE name = '#{name}' -- not a ruby comment
SQL

two_heredocs = [<<~ONE, <<~TWO]
  first heredoc body
ONE
  second heredoc body
TWO

method_call(<<-A, <<-B, "regular arg")
  arg one
  A
  arg two
  B

nested_interp_heredoc = <<~OUTER
  Outer #{<<~INNER.strip} continues
    inner heredoc inside interpolation
  INNER
  end of outer
OUTER

# Symbols
syms = [:simple, :"quoted symbol", :'single quoted', :"interp #{name}", :+, :[], :[]=, :<=>, :!, :a?, :b!, :c=]
hash = { key: 1, "string key": 2, 'single': 3, :old => 4, "#{name}": 5 }
kwargs = method(a: 1, b: :sym, c: "str")

# Numbers
nums = [1_000_000, 0xFF_FF, 0b1010, 0o17, 017, 1.5e-3, 1E10, 3r, 2i, 1.5ri, -0.5, 1_0.0_1, 0d99]

# Blocks, procs, lambdas
squares = (1..10).map { |x| x * x }.select(&:even?)
add = ->(a, b = 2) { a + b }
mul = lambda do |a, b|
  a * b
end
pr = proc { |*args, **opts, &blk| [args, opts, blk] }
numbered = [1, 2].map { _1 * 2 }
it_param = [1, 2].map { it + 1 }

# Classes and modules
module Greeter
  DEFAULT = "Hello".freeze

  def self.included(base)
    base.extend(ClassMethods)
  end

  module ClassMethods
    def greeting = DEFAULT
  end

  def greet(who = "World") = "#{self.class.greeting}, #{who}!"
end

class Person
  include Greeter
  include Comparable
  attr_accessor :name, :age
  @@count = 0
  $global_people = []

  def initialize(name, age: 0)
    @name, @age = name, age
    @@count += 1
  end

  def <=>(other) = age <=> other.age
  def to_s = "#{@name} (#{@age})"
  def [](key) = instance_variable_get("@#{key}")

  private

  def secret? = true
end

case [1, [2, 3]]
in [Integer => a, [b, *rest]] if a > 0
  puts "matched #{a} #{b} #{rest}"
in { name: String => nm }
  puts nm
else
  puts "no match"
end

puts(<<~END) if __FILE__ == $0
  Script finished with #{Person.class_variable_get(:@@count)} people
END

__END__
Everything after __END__ is data, not code: "strings" #{interp} /regex/ =begin

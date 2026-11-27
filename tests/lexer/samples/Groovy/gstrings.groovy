#!/usr/bin/env groovy
// Groovy lexer stress: GStrings, closures in GStrings, slashy and dollar-slashy strings

/* Groovy block comments do NOT nest: /* inner opener is text */
def afterComment = 'visible'

/**
 * Groovydoc with {@code List<String>} and @param x description
 */
@groovy.transform.CompileStatic
class Person {
    String name
    int age
    List<String> tags = []

    String toString() { "Person(name: $name, age: ${age})" }
}

def name = "World"
def map = [key: 'value', nested: [deep: 42]]
def person = new Person(name: "Ada", age: 36)

// String forms
def single = 'single \'quoted\' no $interp here'
def double = "double \"quoted\" with $name"
def dotted = "dotted path: $person.name and $map.nested.deep"
def braced = "braced: ${person.name.toUpperCase()} and ${1 + 2}"
def nested = "outer ${"middle ${"inner $name"}"} outer"
def closureInGString = "lazy: ${-> name} and ${ w -> w << 'written' }"
def dollarEsc = "price: \$5 and \${notInterp}"
def escapes = "tab\t nl\n cr\r bs\\ dq\" sq\' uniA é dollar\$ formfeed\f"
def trailing = "ends with backslash \\"
def unterminated = "no closing quote
def afterUnterminated = 1

def tripleSingle = '''
Triple single-quoted: no $interp,
"quotes" and 'single' fine,
backslash \n is an escape here
'''

def tripleDouble = """
Triple double: $name and ${map.key}
"quoted" and ""two"" and \""" escaped
line continuation \
joined
"""

def slashy = /slashy string: \d+\.\d+ and $name interp and \/ escaped slash/
def slashyMulti = /multi-line
slashy string with ${1 + 1}
/
def dollarSlashy = $/
    Dollar-slashy: $name and ${map.key}
    / slashes and \ backslashes are literal
    $$ is a dollar, $/ is a slash
/$

// Slashy vs division ambiguity
def a = 10, b = 2, c = 5
def division = a / b / c
def division2 = (a + 1) / 2
def regexMatch = "abc123" ==~ /[a-z]+\d+/
def regexFind = "x=1, y=2" =~ /(\w)=(\d)/
def pattern = ~/^\s*#/
def afterParen = (a) / b

// Characters
char ch = 'c'
def ch2 = 'x' as char
def chEsc = '\n' as char

// Numbers
def i1 = 1_000_000
def i2 = 0xFF_FF
def i3 = 0b1010
def i4 = 017
def l1 = 5L
def l2 = 123l
def bi = 123G
def bd = 1.5G
def f1 = 3.0f
def d1 = 1.5e-3d
def d2 = 1e10D
def neg = -0x7F

// Closures
def square = { it * it }
def add = { x, y -> x + y }
def noArgs = { -> "no args" }
def typed = { String s, int n = 2 -> s * n }
def curried = add.curry(1)
def composed = square >> { it + 1 } << { it * 2 }
def methodRef = this.&println
def methodPointer = String::toUpperCase

// Collections
def list = [1, 2, 3, *[4, 5]]
def range = 1..10
def exclusive = 1..<10
def emptyMap = [:]
def spread = person*.name
def safeNav = person?.name?.length()
def elvis = person.nickname ?: 'none'
def spaceship = a <=> b
def membership = 2 in list
def asType = '42' as Integer

// Generics and annotations
class Repo<T extends Comparable<T>> {
    private final Map<String, List<T>> store = [:].withDefault { [] }

    @Override
    String toString() { "Repo(${store.size()})" }

    def <R> R transform(Closure<R> fn) { fn.call(store) }
}

@Grab(group = 'org.apache.commons', module = 'commons-lang3', version = '3.12.0')
import org.apache.commons.lang3.StringUtils

@groovy.transform.ToString(includeNames = true)
@groovy.transform.EqualsAndHashCode
class Point {
    double x, y
}

trait Greeter {
    String greet(String who) { "Hello, $who from ${this.class.simpleName}" }
}

enum Planet {
    MERCURY(3.303e+23), EARTH(5.976e+24)
    final double mass
    Planet(double m) { mass = m }
}

// Control flow
for (i in 0..<3) {
    println "i=$i"
}
list.eachWithIndex { v, idx -> println "$idx: $v" }
switch (name) {
    case 'World': println 'matched string'; break
    case ~/W.*/: println 'matched regex'; break
    case [1, 2, 3]: println 'in list'; break
    case Integer: println 'type'; break
    case { it.size() > 3 }: println 'closure case'; break
    default: println "default"
}
try {
    throw new IllegalStateException("boom: ${name}")
} catch (IllegalStateException | IllegalArgumentException e) {
    println "caught ${e.message}"
} finally {
    println 'finally'
}

// Builders
def writer = new StringWriter()
new groovy.xml.MarkupBuilder(writer).html {
    head { title("It's a \"title\"") }
    body(class: 'main') {
        p "Paragraph with $name"
        a(href: 'http://example.com/?a=1&b=2', 'link')
    }
}

def json = new groovy.json.JsonBuilder()
json.person {
    name person.name
    age person.age
    tags 'a', 'b'
}

assert square(3) == 9 : "square failed: ${square(3)}"
println """Result: ${json.toPrettyString()}"""

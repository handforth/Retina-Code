// Scala lexer stress: s/f/raw interpolators, triple quotes, nested comments, generics
package com.example.lexer

import scala.collection.mutable
import scala.concurrent.{ExecutionContext, Future}
import scala.util.{Try, Success => Ok, Failure as Err}
import java.time.*

/* Scala block comments nest: /* inner /* deeper */ */ still outer */
val afterNested = "visible"

/** Scaladoc with [[Foo]] links, `code`, and {{{ code blocks }}}
  * @tparam T the type
  * @param x the value
  */
final case class Box[+T](x: T)

object Interpolators:
  val name = "World"
  val n = 42
  val pi = 3.14159

  val plain = "double \"quoted\" with \\ and \t \n \u0041 \u00e9"
  val trailing = "ends with backslash \\"
  val sInterp = s"Hello, $name! You are ${n + 1} years and ${if (n > 0) "positive" else "negative"}"
  val nestedInterp = s"outer ${s"middle ${s"inner $name"} middle"} outer"
  val dollarEsc = s"cost: $$5 and $$$n and $${notInterp}"
  val fInterp = f"$name%s has $n%05d and pi is $pi%.2f and ${pi * 2}%10.4f"
  val rawInterp = raw"C:\Users\$name\no\escapes \n here"
  val quoteEsc = s"quote: $" and more"   // Scala 3.6 $" escape
  val custom = sql"SELECT * FROM users WHERE id = $n AND name = ${name}"
  val unterminated = "never closed
  val afterUnterminated = 1

  val triple = """
    |Triple-quoted: "quotes" and ""two"" are fine,
    |backslashes \n are literal, and so is $name.
    |""".stripMargin

  val tripleInterp = s"""
    |Triple interp: $name and ${n * 2}
    |"quoted ${"nested"}" here
    |""".stripMargin

  val tripleEndsQuotes = """ends with extra quotes"""""
  val tripleEmpty = """"""
  val tripleRaw = raw"""raw triple \d+ $n"""
  val fTriple = f"""$n%d
    |next line""".stripMargin

  // Chars and symbols
  val c1 = 'a'
  val c2 = '\''
  val c3 = '\\'
  val c4 = '\n'
  val c5 = '\u0041'
  val sym = Symbol("legacy")

  // Numbers
  val i1 = 1_000_000
  val i2 = 0xFF_FF
  val i3 = 0b1010     // Scala 3 binary literal
  val l1 = 5L
  val l2 = 0xFFFFFFFFL
  val f1 = 3.0f
  val f2 = 1e10F
  val d1 = 1.5e-3
  val d2 = .5
  val d3 = 1d
  val big = BigInt("123456789012345678901234567890")

trait Monoid[A]:
  def empty: A
  extension (x: A) def combine(y: A): A

given Monoid[Int] with
  def empty = 0
  extension (x: Int) def combine(y: Int) = x + y

given stringMonoid: Monoid[String] with
  def empty = ""
  extension (x: String) def combine(y: String) = x + y

def combineAll[A: Monoid](xs: List[A]): A =
  xs.foldLeft(summon[Monoid[A]].empty)(_ combine _)

enum Color(val rgb: Int):
  case Red extends Color(0xFF0000)
  case Green extends Color(0x00FF00)
  case Blue extends Color(0x0000FF)
  case Mix(r: Int, g: Int, b: Int) extends Color((r << 16) | (g << 8) | b)

sealed trait Expr[T]
case class Num(v: Int) extends Expr[Int]
case class Add(a: Expr[Int], b: Expr[Int]) extends Expr[Int]
case class Eq[A](a: Expr[A], b: Expr[A]) extends Expr[Boolean]

def eval[T](e: Expr[T]): T = e match
  case Num(v)      => v
  case Add(a, b)   => eval(a) + eval(b)
  case Eq(a, b)    => eval(a) == eval(b)

class Container[F[_], +A, -B <: AnyRef, C >: Null](val f: F[A]):
  type Out = Map[String, List[Option[A]]]
  def map[R](g: A => R)(using ec: ExecutionContext): Future[R] = ???
  def <:<(other: Any): Boolean = false

type Lambda = [X] =>> Map[String, X]
type Match[T] = T match
  case String => Char
  case Array[t] => t
  case _ => Any

def comparisons(a: Int, b: Int) = a < b && b > a || a <= b
def shifts(a: Int) = (a << 2) >> 1 >>> 3
val generic: Map[String, List[Set[Int]]] = Map.empty
val func: (Int, String) => Boolean = (i, s) => s.length > i
val partial: PartialFunction[Any, String] = { case i: Int if i > 0 => "pos"; case s: String => s }
val placeholder = List(1, 2, 3).map(_ * 2).filter(_ > 2).reduce(_ + _)
val tuple = (1, "two", 3.0)
val (a, b, _) = tuple
val xml = <div class="legacy">{name}</div>  // Scala 2 XML literal

@main def run(args: String*): Unit =
  import Interpolators.*
  val buf = mutable.ArrayBuffer.empty[Int]
  for
    i <- 1 to 10
    if i % 2 == 0
    j <- i until 20 by 3
  do buf += i * j
  val sum = buf.sum
  println(s"sum=$sum avg=${sum.toDouble / buf.size}")
  Try(1 / 0) match
    case Ok(v)  => println(v)
    case Err(e) => println(s"error: ${e.getMessage}")
  val res = while buf.nonEmpty do buf.remove(0)
  val opt: Option[String] = Some("x")
  opt.foreach(println)
  val `type` = "backtick identifier"
  val `with spaces` = 1
  println(`type` + `with spaces`)

@deprecated("use other", since = "2.0")
@inline final def old(x: Int): Int = x
@annotation.tailrec
def loop(n: Int, acc: Long = 1L): Long = if n <= 1 then acc else loop(n - 1, acc * n)

object Legacy {
  implicit class RichInt(val i: Int) extends AnyVal {
    def squared: Int = i * i
  }
  implicit val ord: Ordering[Box[Int]] = Ordering.by(_.x)
  def apply[T <: Comparable[T]](xs: T*): Seq[T] = xs.sorted
}

/* final nested /* comment */ closes */ val last = 'z'

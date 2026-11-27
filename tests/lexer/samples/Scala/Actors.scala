/*
 * Second Scala sample: Scala 2 style braces, actors, implicits, and an unterminated
 * nested comment at EOF.
 */
package com.example.actors

import scala.concurrent.duration._
import scala.concurrent.{Await, Future, Promise}
import scala.language.{higherKinds, implicitConversions}
import scala.collection.immutable.{Queue => ImmQueue}

sealed abstract class Message extends Product with Serializable
final case class Deposit(amount: BigDecimal) extends Message
final case class Withdraw(amount: BigDecimal, replyTo: Promise[Either[String, BigDecimal]]) extends Message
case object Shutdown extends Message

trait Actor[-M] {
  def receive: PartialFunction[M, Unit]
  protected def log(msg: => String): Unit = println(s"[${getClass.getSimpleName}] $msg")
}

class Account(initial: BigDecimal = BigDecimal(0)) extends Actor[Message] {
  private[this] var balance: BigDecimal = initial
  @volatile private var running = true

  override def receive: PartialFunction[Message, Unit] = {
    case Deposit(amount) if amount > 0 =>
      balance += amount
      log(f"deposited $amount%.2f, balance $balance%.2f")
    case Deposit(amount) =>
      log(s"rejected non-positive deposit: $amount")
    case Withdraw(amount, reply) =>
      if (amount <= balance) {
        balance -= amount
        reply.success(Right(balance))
      } else {
        reply.success(Left(s"insufficient funds: need ${amount - balance} more"))
      }
    case Shutdown =>
      running = false
      log("shutting down")
  }
}

object Mailbox {
  def apply[M](actor: Actor[M]): Mailbox[M] = new Mailbox(actor)
}

final class Mailbox[M] private (actor: Actor[M]) {
  private var queue = ImmQueue.empty[M]
  def !(m: M): Unit = synchronized { queue = queue.enqueue(m) }
  def drain(): Int = synchronized {
    var n = 0
    while (queue.nonEmpty) {
      val (m, rest) = queue.dequeue
      queue = rest
      if (actor.receive.isDefinedAt(m)) actor.receive(m)
      n += 1
    }
    n
  }
}

trait Functor[F[_]] {
  def map[A, B](fa: F[A])(f: A => B): F[B]
}

object Functor {
  def apply[F[_]](implicit ev: Functor[F]): Functor[F] = ev

  implicit val listFunctor: Functor[List] = new Functor[List] {
    def map[A, B](fa: List[A])(f: A => B): List[B] = fa map f
  }

  implicit def optionFunctor: Functor[Option] = new Functor[Option] {
    override def map[A, B](fa: Option[A])(f: A => B): Option[B] = fa.map(f)
  }

  implicit class FunctorOps[F[_]: Functor, A](fa: F[A]) {
    def fmap[B](f: A => B): F[B] = Functor[F].map(fa)(f)
  }
}

object Main extends App {
  import Functor._
  implicit val timeout: FiniteDuration = 2.seconds

  val acct = new Account(BigDecimal("100.50"))
  val box = Mailbox(acct)
  box ! Deposit(BigDecimal(25))
  box ! Deposit(-1)
  val p = Promise[Either[String, BigDecimal]]()
  box ! Withdraw(BigDecimal("500"), p)
  box ! Shutdown
  println(s"processed ${box.drain()} messages")
  println(Await.result(p.future, timeout).fold(err => s"Error: $err", ok => s"OK: $ok"))

  println(List(1, 2, 3).fmap(_ + 1))
  println(Option("x").fmap(_.toUpperCase))

  val sql =
    s"""SELECT *
       |FROM accounts
       |WHERE balance > ${100}
       |  AND name LIKE '%${"o'neil".replace("'", "''")}%' -- sql comment
       |""".stripMargin

  val json = raw"""{"pattern": "\d+", "path": "C:\temp"}"""
  val interpolatedBraces = s"${"{"}braces${"}"}"
  val dollarDollar = s"$$${1 + 1}"
  val objInterp = s"${Map("k" -> "v")("k")}"
  val methodInterp = s"$acct.toString is not a call but ${acct.toString} is"

  val futures = (1 to 5).map(i => Future(i * i)(scala.concurrent.ExecutionContext.global))
  val all = Future.sequence(futures)(implicitly, scala.concurrent.ExecutionContext.global)
  println(Await.result(all, 1.second).sum / 5.0)

  val symbolicOps = Seq(1 :: Nil, 1 +: Seq(2), Seq(1) :+ 2, Seq(1) ++ Seq(2), Set(1) -- Set(1), 3 /: Nil)
  val arrows = Map(1 -> "a", 2 → "b")
  val forArrow = for { x <- List(1, 2); y ← List(3) } yield x * y
  val lambdaCase: Int => String = { case 0 => "zero"; case n if n < 0 => "neg"; case _ => "pos" }
  val nums = Seq(0x1F, 0XAbC, 1e3, 1.5E-2, 2f, 3d, 4L, 5l, .5, 1_000)

  def typeLambda[F[_, _]]: Unit = ()
  typeLambda[({ type L[A, B] = Either[A, B] })#L]
  val existential: List[_ <: AnyVal] = List(1, 2.0)
  val viewBound = implicitly[Ordering[Int]]
  val byName: (=> Int) => Int = x => x + x
}

object EdgeCases {
  // Interpolators at line boundaries
  val multi = s"line one ${
    1 + 1
  } line two"
  val tripleNested = s"""outer ${s"""inner ${"x"}"""} outer"""
  val fWidth = f"${3.14159}%8.3f|${"s"}%-5s|${42}%x"
  val charsAndSymbols = ('\'', '"', '\\', 'a')
  val operatorsWithSlashes = Seq(1 / 2, 4 /: Nil)  // division, not comments
  val commentInString = "/* not a comment */ // nor this"
  val stringInComment = 0 /* "string" in comment */ + 1
  val nestedCommentInline = 2 /* a /* b */ c */ + 3
  val backquoted = Map(`type` -> 1)
  private val `type` = "t"
  val xmlWithBraces = <a href={"/x"}>{1 + 1}</a>
  val unicodeOps = List(1 → 2, 3 ← 4)
}

/* Unterminated nested comment follows:
   /* inner opened
      /* and deeper, closed */
   inner still open
   object NotCode { val s = "in comment" }
   The outer comment and the inner comment are both still open at EOF.

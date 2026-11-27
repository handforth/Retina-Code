@file:Suppress("UNUSED_VARIABLE", "unused")
@file:JvmName("InterpolationKt")

package com.example.lexer

import kotlin.math.*
import kotlinx.coroutines.flow.Flow as KFlow

/* Kotlin block comments nest: /* inner /* deeper */ still inner */ still outer
   and this line is still a comment */
val afterNested = "visible"

/**
 * KDoc with [Foo.bar] links and `code` and a sample:
 * ```
 * val x = "inside kdoc code fence"
 * ```
 * @param T the type
 * @return nothing
 */
class Box<out T : Any>(val value: T)

val name = "world"
val simple = "Hello, $name!"
val dollarExpr = "Length: ${name.length}"
val nestedInterp = "${a + "${b}"}"
val deepNested = "outer ${ "middle ${ "inner ${name}" } middle" } outer"
val dollarLiteral = "price: \$5 and $ alone and $1 digit and ${'$'}"
val escapes = "tab\t nl\n cr\r bs\\ quote\" apos\' dollar\$ unicodeA 😀"
val trailingBackslash = "ends with \\"
val charLit = 'a'
val charEscapes = listOf('\n', '\'', '\\', 'é', '"', '$')
val unterminated = "this one has no end
val afterUnterminated = 1

val raw = """
    Raw string: no \n escapes here, backslash \ is literal
    But $name and ${name.uppercase()} still interpolate
    "quotes" and ""two"" are fine
    ${'"'}${'"'}${'"'} produces three quotes
""".trimIndent()

val rawWithMargin = """
    |first line
    |second ${"nested \"quoted\" in raw"} line
    |third with $$ and ${'$'}{notInterpolated}
    """.trimMargin()

val rawEndingQuotes = """ends with four quotes""""
val rawEmpty = """"""
val rawNestedInterp = """outer ${ """inner ${name}""" } outer"""

val multiDollar = $$"""
    {"$schema": "json", "value": "$$name"}
"""

// Numbers
val i = 1_000_000
val hex = 0xFF_FF
val bin = 0b1010_1010
val l = 5L
val f = 3.0f
val f2 = 1e10F
val d = 1.5e-3
val d2 = .5
val ui = 10u
val ul = 0xFFFF_FFFFuL
val ub: UByte = 255u
val neg = -0x80

// Generics, nullable types, annotations
@Target(AnnotationTarget.CLASS, AnnotationTarget.FUNCTION)
@Retention(AnnotationRetention.SOURCE)
annotation class Marker(val value: String = "")

@Marker("x")
@Suppress("x")
sealed class Result<out T, out E : Throwable> {
    data class Ok<T>(val value: T) : Result<T, Nothing>()
    data class Err<E : Throwable>(val error: E) : Result<Nothing, E>()
    object Pending : Result<Nothing, Nothing>()
}

inline fun <reified T : Any> typeName(): String = T::class.simpleName ?: "?"

fun <K, V> Map<out K, List<V>>.flatValues(): List<V> where K : Comparable<K>, V : Any =
    this.values.flatten()

suspend fun fetch(url: String): Result<String, Exception> = try {
    Result.Ok("data from $url")
} catch (e: Exception) {
    Result.Err(e)
}

fun comparisons(a: Int, b: Int) = a < b && b > a
fun shifts(a: Int) = (a shl 2) shr 1 ushr 3
val genericCall = listOf<Map<String, List<Int>>>()
val lambda: (Int, Int) -> Int = { x, y -> x + y }
val receiver: String.() -> Int = { length }
val ref = String::length
val ranges = listOf(1..10, 1 until 10, 10 downTo 1 step 2, 'a'..'z', 1..<5)
val elvis = nullable?.length ?: -1
val notNull = nullable!!.length
val safeCall = a?.b?.c?.let { it * 2 }
val backticked = `when`.`fun name with spaces`()
val `weird name` = 1

enum class Dir(val dx: Int, val dy: Int) {
    UP(0, -1), DOWN(0, 1), LEFT(-1, 0), RIGHT(1, 0);
    fun turn(): Dir = when (this) {
        UP -> RIGHT
        RIGHT -> DOWN
        DOWN -> LEFT
        LEFT -> UP
    }
}

value class Meters(val v: Double)

interface Repo<in K, out V> {
    operator fun get(key: K): V?
    infix fun has(key: K): Boolean
}

object Registry : Repo<String, Int> {
    private val map = mutableMapOf("a" to 1, "b" to 2)
    override fun get(key: String) = map[key]
    override infix fun has(key: String) = key in map
    const val VERSION = "1.0.${0x1}"
    @JvmStatic lateinit var late: String
}

fun main(args: Array<String>) {
    val list = mutableListOf<Int>()
    for (i in 0 until 10) list += i * i
    val (evens, odds) = list.partition { it % 2 == 0 }
    println("evens=$evens odds=$odds sum=${evens.sum() / 2}")
    when {
        evens.size > odds.size -> println("more evens")
        evens.isEmpty() -> println("no evens: ${"none"}")
        else -> println("""raw ${list.joinToString(separator = "\n")}""")
    }
    label@ for (x in list) {
        list.forEach inner@{ if (it > x) return@inner }
        if (x > 5) break@label
    }
    val s = buildString {
        append("a")
        appendLine('b')
    }
    val regex = Regex("""\d+\.\d+""")
    val regex2 = "[a-z]+".toRegex()
    println("${regex.matches("1.5")} ${s.length / 2}")
}

class Outer {
    inner class Inner { fun outer() = this@Outer }
    companion object Factory { fun create() = Outer() }
}

typealias Handler<T> = suspend (T) -> Unit
expect fun platform(): String
fun interface Fn { fun invoke(): Unit }

/* trailing nested comment /* inner */ outer still */ val finalValue = 'z'

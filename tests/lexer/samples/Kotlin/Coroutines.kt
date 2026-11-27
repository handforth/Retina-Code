package com.example.async

import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.*

// Second Kotlin sample: coroutines, DSLs, and an unterminated nested comment at EOF.

@DslMarker
annotation class HtmlDsl

@HtmlDsl
class Tag(val name: String) {
    private val children = mutableListOf<Tag>()
    private val attrs = linkedMapOf<String, String>()
    var text: String = ""

    operator fun String.unaryPlus() { text += this }
    fun attr(k: String, v: Any?) { attrs[k] = "$v" }
    fun tag(n: String, block: Tag.() -> Unit = {}) { children += Tag(n).apply(block) }

    override fun toString(): String = buildString {
        append("<$name")
        attrs.forEach { (k, v) -> append(" $k=\"${v.replace("\"", "&quot;")}\"") }
        append(">")
        append(text)
        children.forEach { append(it) }
        append("</$name>")
    }
}

fun html(block: Tag.() -> Unit): Tag = Tag("html").apply(block)

val page = html {
    tag("head") { tag("title") { +"It's a \"title\" with \$dollars" } }
    tag("body") {
        attr("class", "main")
        tag("p") { +"Paragraph ${1 + 1} with ${"nested ${"deeper"}"}" }
        tag("pre") {
            +"""
                code block: val x = "${'$'}{y}"
                /* not a comment */ // nor this
            """.trimIndent()
        }
    }
}

class Worker(private val scope: CoroutineScope) {
    private val channel = Channel<Pair<Int, String>>(capacity = Channel.BUFFERED)

    fun start(): Job = scope.launch(Dispatchers.Default + CoroutineName("worker")) {
        for ((id, payload) in channel) {
            val result = withTimeoutOrNull(1_500L) {
                delay(10)
                payload.reversed()
            } ?: "timeout:$id"
            println("[$id] => $result (${result.length / 2})")
        }
    }

    suspend fun submit(id: Int, payload: String) = channel.send(id to payload)

    fun numbers(): Flow<Int> = flow {
        var n = 0
        while (true) {
            emit(n++)
            if (n >= 0x10) break
        }
    }.map { it * it }
        .filter { it % 3 != 0 }
        .onEach { check(it >= 0) { "negative: $it" } }
        .catch { e -> emit(-1).also { println("error ${e.message}") } }
}

suspend fun <T> retry(times: Int = 3, initial: Long = 100, block: suspend () -> T): T {
    var current = initial
    repeat(times - 1) {
        try {
            return block()
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
        }
        delay(current)
        current = (current * 2).coerceAtMost(1_000)
    }
    return block()
}

data class Point(val x: Double, val y: Double) {
    operator fun plus(o: Point) = Point(x + o.x, y + o.y)
    operator fun times(k: Double) = Point(x * k, y * k)
    operator fun get(i: Int) = if (i == 0) x else y
    infix fun dot(o: Point) = x * o.x + y * o.y
    override fun toString() = "($x, $y)"
}

val origin = Point(0.0, 0.0)
val p = Point(1.5e2, -2.0E-1) + origin * 3.0
val dot = p dot origin
val first = p[0]

fun classify(x: Any?): String = when (x) {
    null -> "null"
    is Int -> if (x < 0) "neg" else "pos"
    is String -> "str(${x.length})"
    is List<*> -> "list of ${x.size}"
    in 1..10 -> "range"
    !is Number -> "not a number: $x"
    else -> "number"
}

val chars = charArrayOf('\t', '\b', '\n', '\r', '\'', '\"', '\\', '\$', '￿')
val longString = "a" + 'b' + "c${'d'}e" + """f""" + "g\"h" + "\\"

val stringTemplateEdge1 = "$"
val stringTemplateEdge2 = "${""}"
val stringTemplateEdge3 = "${ { "lambda" }() }"
val stringTemplateEdge4 = "${ if (true) "}" else "{" }"
val stringTemplateEdge5 = "$name.length is not a call, ${name}.length is"
val stringTemplateEdge6 = "${'}'}"

// Annotated lambdas, use-site targets, and context receivers
class Annotated(
    @field:JvmField val a: Int = 0x1,
    @param:Suppress("x") val b: String = "b",
    @get:JvmName("getCee") val c: Long = 3L,
)

fun higher(block: suspend CoroutineScope.(Int) -> String): Unit = Unit

val anonymous = object : Comparator<String> {
    override fun compare(a: String, b: String): Int = a.length - b.length
}

val sortedWords = listOf("kiwi", "fig", "banana").sortedWith(anonymous)
val grouped = sortedWords.groupBy { it.first() }.mapValues { (_, v) -> v.size }

private tailrec fun gcd(a: Long, b: Long): Long = if (b == 0L) a else gcd(b, a % b)

@Volatile private var flag = false
@Throws(IllegalStateException::class)
fun mustBeSet() = check(flag) { "flag not set" }

fun main() = runBlocking {
    val w = Worker(this)
    val job = w.start()
    (1..5).forEach { w.submit(it, "payload-$it") }
    val collected = w.numbers().toList()
    println("collected=$collected gcd=${gcd(48, 18)}")
    println(page)
    job.cancelAndJoin()
}

/* This nested block comment never closes:
   /* level two
      /* level three */
   back at level two
   val notCode = "string"
*/
still level one because the inner levels consumed closers
fun notAFunction() {}

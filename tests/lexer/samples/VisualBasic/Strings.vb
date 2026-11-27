' Visual Basic .NET lexer stress: strings, interpolation, XML literals, dates, line continuations
REM REM-style comment line
Option Strict On
Option Explicit On
Option Infer On

Imports System
Imports System.Collections.Generic
Imports System.Linq
Imports System.Text
Imports <xmlns:ns="http://example.com/ns">
Imports Alias1 = System.Collections.Generic.Dictionary(Of String, Integer)

#Const DEBUG_MODE = True
#Region "Constants"

''' <summary>
''' XML doc comment with <c>code</c> and "quotes".
''' </summary>
''' <typeparam name="T">The type.</typeparam>
Public Module StringsModule

    Public Const Simple As String = "double ""doubled"" quotes, no backslash escapes \n here"
    Public Const Empty As String = ""
    Public Const OnlyQuote As String = """"
    Public Const Apostrophe As String = "it's not a comment inside a string"
    Public Const Backslash As String = "C:\Users\path\"
    Public Const CharLit As Char = "A"c
    Public Const QuoteChar As Char = """"c
    Public Const Unterminated As String = "this string never closes
    Public Const AfterUnterminated As Integer = 1
    Public ReadOnly MultiLine As String = "VB 14 allows
multi-line string literals
with ""quotes"" too"

#End Region

#Region "Numbers"
    Public ReadOnly Ints() As Integer = {42, -42, &HFF, &H7FFF_FFFF, &O17, &B1010_1010, 1_000_000}
    Public ReadOnly Longs() As Long = {42L, &HFFL, 9_223_372_036_854_775_807L}
    Public ReadOnly Shorts() As Short = {42S, &H7FS}
    Public ReadOnly UInts() As UInteger = {42UI, 42UL, 42US}
    Public ReadOnly Floats() As Single = {3.14F, 1.5E-3F, 2!}
    Public ReadOnly Doubles() As Double = {3.14R, 1.5E+10, 2#, .5, 5.0}
    Public ReadOnly Decimals() As Decimal = {1.5D, 10@, 99.99D}
    Public ReadOnly Dates() As Date = {#1/1/2024#, #2024-01-01#, #12:30:00 PM#, #1/1/2024 23:59:59#}
#End Region

    Public Function Interpolations(name As String, count As Integer) As String
        Dim a = $"Hello, {name}! You have {count} items."
        Dim b = $"Formatted: {count:D5} and {Math.PI:F2} and {DateTime.Now:yyyy-MM-dd}"
        Dim c = $"Aligned: |{name,10}| |{name,-10}|"
        Dim d = $"Escaped braces {{literal}} and doubled ""quotes"" and {name}"
        Dim e = $"Nested: {If(count > 1, $"{count} items", "one item")}"
        Dim f = $"Method: {name.ToUpper()} and index: {name(0)}"
        Dim g = $"Multi-line interpolated
string with {count}
lines"
        Return a & b & c & d & e & f & g
    End Function

    Public Function Continuations(x As Integer,
                                  y As Integer,
                                  Optional z As Integer = 0) As Integer
        Dim total = x _
                  + y _
                  + z ' comment after continuation-joined line
        Dim implicit = x +
                       y +
                       z
        Dim query = From n In Enumerable.Range(1, 100)
                    Where n Mod 3 = 0 AndAlso n Mod 5 <> 0
                    Order By n Descending
                    Select n * 2
                    Take 10
        Return total + implicit + query.Sum()
    End Function

    Public Function XmlLiterals(items As IEnumerable(Of String)) As XElement
        Dim title = "Report's ""title"""
        Dim doc = <?xml version="1.0" encoding="utf-8"?>
                  <root>
                      <!-- XML comment, not VB -->
                      <title><%= title %></title>
                      <items count=<%= items.Count() %>>
                          <%= From i In items Select <item name=<%= i %>>value of <%= i %></item> %>
                      </items>
                      <ns:element attr='single'>text with ' apostrophe</ns:element>
                      <![CDATA[ raw <cdata> & "stuff" ]]>
                  </root>
        Dim el = doc.Root.<items>.<item>.FirstOrDefault()
        Dim attr = el?.@name
        Dim desc = doc...<item>.Count()
        Return doc.Root
    End Function

End Module

<Serializable>
<Obsolete("Use NewWidget", False)>
Public Class Widget(Of T As {Class, IComparable(Of T), New})
    Implements IDisposable, IEquatable(Of Widget(Of T))

    Private ReadOnly _items As New List(Of Dictionary(Of String, List(Of T)))()
    Private _disposed As Boolean = False
    Public Event Changed As EventHandler(Of EventArgs)
    Public Property Name As String = "default"
    Public ReadOnly Property Count As Integer
        Get
            Return _items.Count
        End Get
    End Property

    Default Public Property Item(index As Integer) As T
        Get
            Return Nothing
        End Get
        Set(value As T)
            RaiseEvent Changed(Me, EventArgs.Empty)
        End Set
    End Property

    Public Sub New()
        MyBase.New()
    End Sub

    Public Overloads Function Equals(other As Widget(Of T)) As Boolean Implements IEquatable(Of Widget(Of T)).Equals
        Return other IsNot Nothing AndAlso Name = other.Name
    End Function

    Public Shared Operator +(a As Widget(Of T), b As Widget(Of T)) As Widget(Of T)
        Return a
    End Operator

    Public Async Function LoadAsync() As Task(Of Integer)
        Await Task.Delay(10)
        Dim result = Await Task.Run(Function() 42)
        Return result
    End Function

    Public Iterator Function Evens() As IEnumerable(Of Integer)
        For i = 0 To 10 Step 2
            Yield i
        Next
    End Function

    Public Sub ControlFlow(value As Object)
        Select Case value
            Case Is Nothing
                Console.WriteLine("nothing")
            Case 1 To 5, 7
                Console.WriteLine("small")
            Case Is > 100
                Console.WriteLine("big")
            Case Else
                Console.WriteLine($"other: {value}")
        End Select

        If TypeOf value Is String AndAlso CStr(value).Length > 0 Then
            Console.WriteLine("string")
        ElseIf value Is Nothing OrElse Not IsNumeric(value) Then
            Console.WriteLine("not numeric")
        Else
            Console.WriteLine("numeric")
        End If

        Dim i As Integer = 0
        Do While i < 3
            i += 1
        Loop
        Do
            i -= 1
        Loop Until i <= 0
        While i < 2 : i += 1 : End While
        For Each s As String In {"a", "b", "c"}
            If s = "b" Then Continue For
            If s = "c" Then Exit For
        Next s

        Try
            Throw New InvalidOperationException("boom ""quoted""")
        Catch ex As InvalidOperationException When ex.Message.Contains("boom")
            Console.WriteLine(ex.Message)
        Finally
            Console.WriteLine("finally")
        End Try

        Using sb As New IO.StringWriter()
            sb.Write("disposed")
        End Using

        SyncLock _items
            _items.Clear()
        End SyncLock

        Dim lambda = Function(x As Integer) x * 2
        Dim multiLambda = Sub(msg As String)
                              Console.WriteLine(msg)
                          End Sub
        Dim ops = (1 + 2 - 3 * 4 / 5 \ 6 Mod 7 ^ 2, "a" & "b", 1 << 2, 8 >> 1, True And False, True Or False, True Xor False, Not True)
        Dim cmp = (1 = 1, 1 <> 2, 1 < 2, 1 <= 2, 1 > 0, 1 >= 0, "a" Like "[a-z]", Me Is Nothing, Me IsNot Nothing)
        Dim [Class] = "escaped identifier"
        Dim typeChars% = 1, money@ = 1.5D, text$ = "s", dbl# = 1.0, sng! = 1.0F, lng& = 1L
    End Sub

    Public Sub Dispose() Implements IDisposable.Dispose
        If Not _disposed Then _disposed = True
        GC.SuppressFinalize(Me)
    End Sub
End Class

#If DEBUG_MODE Then
Module DebugHelpers
    Sub Trace(msg As String)
        Debug.WriteLine(msg)
    End Sub
End Module
#ElseIf RELEASE Then
' release only
#Else
' other
#End If

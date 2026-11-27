' Legacy_unterminated.vb — second Visual Basic sample.
' VB has no block comments, so the file ends inside an unterminated string
' and an unterminated XML literal instead.
Imports System.IO
Imports System.Data
Imports System.Runtime.InteropServices
Imports Microsoft.VisualBasic

Namespace Contoso.Legacy

    <StructLayout(LayoutKind.Sequential, CharSet:=CharSet.Unicode)>
    Public Structure RECT
        Public Left As Integer
        Public Top As Integer
        Public Right As Integer
        Public Bottom As Integer
    End Structure

    Public Enum FileMode As Byte
        None = 0
        Read = &H1
        Write = &H2
        ReadWrite = Read Or Write
        Append = &B100
    End Enum

    <Flags>
    Public Enum Permissions
        None = 0
        Execute = 1 << 0
        Write = 1 << 1
        Read = 1 << 2
    End Enum

    Public Interface IReport
        ReadOnly Property Title As String
        Function Render(Optional format As String = "text") As String
        Event Rendered(sender As Object, length As Integer)
    End Interface

    Friend NotInheritable Class NativeMethods
        Private Sub New()
        End Sub

        <DllImport("user32.dll", SetLastError:=True)>
        Friend Shared Function GetWindowRect(hWnd As IntPtr, ByRef lpRect As RECT) As <MarshalAs(UnmanagedType.Bool)> Boolean
        End Function

        Declare Auto Function MessageBox Lib "user32.dll" (hWnd As IntPtr, text As String, caption As String, type As UInteger) As Integer
        Declare Ansi Sub Sleep Lib "kernel32" Alias "Sleep" (ByVal ms As Integer)
    End Class

    Public MustInherit Class ReportBase
        Implements IReport

        Protected Shared ReadOnly NewLine As String = vbCrLf
        Private ReadOnly _created As Date = Now

        Public Event Rendered(sender As Object, length As Integer) Implements IReport.Rendered
        Public MustOverride ReadOnly Property Title As String Implements IReport.Title
        Protected MustOverride Function Body() As IEnumerable(Of String)

        Public Overridable Function Render(Optional format As String = "text") As String Implements IReport.Render
            Dim sb As New Text.StringBuilder()
            Select Case format.ToLowerInvariant()
                Case "text"
                    sb.AppendLine(Title)
                    sb.AppendLine(New String("="c, Title.Length))
                    For Each line In Body()
                        sb.AppendLine("  " & line)
                    Next
                Case "csv"
                    sb.AppendLine("""Title"",""Created""")
                    sb.AppendFormat("""{0}"",""{1:yyyy-MM-dd}""{2}", Title.Replace("""", """"""), _created, NewLine)
                Case "html"
                    Dim html = <html>
                                   <body>
                                       <h1><%= Title %></h1>
                                       <ul>
                                           <%= From l In Body() Select <li><%= l %></li> %>
                                       </ul>
                                   </body>
                               </html>
                    sb.Append(html.ToString())
                Case Else
                    Throw New ArgumentException($"Unknown format ""{format}""", NameOf(format))
            End Select
            Dim result = sb.ToString()
            RaiseEvent Rendered(Me, result.Length)
            Return result
        End Function
    End Class

    Public Class SalesReport
        Inherits ReportBase

        Private ReadOnly _rows As New List(Of (Region As String, Amount As Decimal))

        Public Overrides ReadOnly Property Title As String
            Get
                Return "Sales Report — " & Today.ToString("MMMM yyyy")
            End Get
        End Property

        Public Sub Add(region As String, amount As Decimal)
            _rows.Add((region, amount))
        End Sub

        Protected Overrides Iterator Function Body() As IEnumerable(Of String)
            Dim total As Decimal = 0D
            For Each r In _rows.OrderByDescending(Function(x) x.Amount)
                total += r.Amount
                Yield String.Format("{0,-12}{1,12:C2}", r.Region, r.Amount)
            Next
            Yield $"{"TOTAL",-12}{total,12:C2}"
        End Function
    End Class

    Module Program
        Private WithEvents _report As New SalesReport()

        Private Sub OnRendered(sender As Object, length As Integer) Handles _report.Rendered
            Console.WriteLine($"[rendered {length} chars]")
        End Sub

        Sub Main(args As String())
            On Error Resume Next
            _report.Add("North", 1234.5D)
            _report.Add("South", 987.25D)
            _report.Add("East's ""best""", 5000@)
            Console.WriteLine(_report.Render())
            Console.WriteLine(_report.Render("csv"))
            Dim path = IO.Path.Combine(My.Computer.FileSystem.SpecialDirectories.Temp, "report.html")
            File.WriteAllText(path, _report.Render("html"))
            Dim legacyArr(10) As Integer
            ReDim Preserve legacyArr(20)
            Dim s As String = Mid("Hello World", 7, 5) & Left("abc", 1) & Chr(65) & ChrW(&H263A)
            Dim n As Integer = Val("42abc") + CInt("7") + CType("8", Integer) + DirectCast(9, Integer)
            Dim t As Object = TryCast(s, String)
            Dim dt As Date = #3/14/2025 1:59:26 PM#
            GoTo Done
Skipped:
            Console.WriteLine("never")
Done:
            Console.WriteLine("Exit code " & Err.Number.ToString())
            Dim tail = "this final string is never closed, so everything after is part of it
            Dim notCode = <xml>also inside the string
        End Sub
    End Module

End Namespace

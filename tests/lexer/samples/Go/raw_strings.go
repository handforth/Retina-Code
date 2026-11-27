//go:build linux && (amd64 || arm64) && !purego
// +build linux
// +build amd64 arm64

// Package stress exercises Go lexing: raw strings, runes, struct tags, generics.
package stress

import (
	"context"
	"encoding/json"
	"fmt"
	_ "embed"
	str "strings"
	. "math"
)

//go:generate stringer -type=Kind -trimprefix=Kind
//go:embed testdata/*.txt
var testdata string

//go:noinline
func noinline() {}

/* Go block comments do not nest: /* this opener is text */
var afterComment = "visible"

const (
	simple     = "double \"quoted\" with \\ and \t and \n"
	hexEsc     = "\x41\x42\xFF"
	octEsc     = "\101\102\377"
	uniEsc     = "\u00e9\U0001F600"
	trailing   = "ends with backslash \\"
	commentish = "// not a comment /* nor this */"
	rawSimple  = `raw string with "quotes" and \n literal backslash`
	rawMulti   = `first line
second line with 'single' and "double"
	tabbed third line
/* not a comment */ // nor this
last line`
	rawEmpty     = ``
	rawBackslash = `C:\path\to\file\`
)

const unterminated = "missing close quote
var afterUnterminated = 1

var runes = []rune{'a', '\'', '\\', '\n', '\x41', '\101', '\u00e9', '\U0001F600', '"', '本'}

// Numeric literals
const (
	dec     = 1_000_000
	hex     = 0xFF_FF
	hexUp   = 0XCAFE
	bin     = 0b1010_1010
	oct     = 0o17
	oldOct  = 0755
	flt     = 1.5e-3
	flt2    = .5
	flt3    = 5.
	hexFlt  = 0x1.8p1
	hexFlt2 = 0X_1FFFP-16
	imag    = 2i
	imag2   = 1.5e3i
	imag3   = 0x10i
)

type Kind int

const (
	KindNone Kind = iota
	KindA
	KindB = 1 << iota
	KindC
)

// Struct tags are raw or interpreted strings
type User struct {
	ID        int64             `json:"id,string" db:"user_id" validate:"required,min=1"`
	Name      string            `json:"name" xml:"name,attr"`
	Email     string            "json:\"email\" yaml:\"email,omitempty\""
	Tags      map[string]string `json:"tags,omitempty"`
	Embedded                    // embedded type
	*Pointer                    `json:"-"`
	private   chan<- struct{}
	recv      <-chan int
	fn        func(int, ...string) (bool, error)
	arr       [4]byte
	slice     []map[string][]*User
}

type Embedded struct{}
type Pointer struct{}

// Generics
type Number interface {
	~int | ~int8 | ~int16 | ~int32 | ~int64 | ~float32 | ~float64
}

type Pair[K comparable, V any] struct {
	Key K
	Val V
}

type List[T any] struct {
	head *node[T]
	size int
}

type node[T any] struct {
	val  T
	next *node[T]
}

func Map[T, U any](xs []T, f func(T) U) []U {
	out := make([]U, 0, len(xs))
	for _, x := range xs {
		out = append(out, f(x))
	}
	return out
}

func Sum[N Number](xs ...N) (total N) {
	for i := range xs {
		total += xs[i]
	}
	return
}

func (l *List[T]) Push(v T) {
	l.head = &node[T]{val: v, next: l.head}
	l.size++
}

func comparisons(a, b int) bool { return a < b && b > a || a <= b && b >= a }
func shifts(a uint) uint       { return a<<2 | a>>1 &^ 0xF }

func process(ctx context.Context, in <-chan Pair[string, int]) (map[string]int, error) {
	result := map[string]int{}
	for {
		select {
		case <-ctx.Done():
			return nil, fmt.Errorf("cancelled: %w", ctx.Err())
		case p, ok := <-in:
			if !ok {
				return result, nil
			}
			result[p.Key] += p.Val
		default:
		}
	}
}

func main() {
	u := User{ID: 1, Name: "a", Email: `b@c.d`}
	b, err := json.MarshalIndent(&u, "", "  ")
	if err != nil {
		panic(err)
	}
	fmt.Printf("%s\n%v %+v %#v %q %x\n", b, u, u, u, "q", 255)
	fmt.Println(str.Repeat("=", 10), Pi, Sqrt(2))
	ints := Map([]string{"1", "22", "333"}, func(s string) int { return len(s) })
	fmt.Println(Sum(ints...) / 2)
	var x interface{} = 1.5
	switch v := x.(type) {
	case int, int64:
		fmt.Println("int", v)
	case float64:
		fmt.Println("float", v)
	case nil:
	default:
		_ = v
	}
	defer func() {
		if r := recover(); r != nil {
			fmt.Println("recovered:", r)
		}
	}()
	go func(ch chan int) { ch <- 1 }(make(chan int, 1))
outer:
	for i := 0; i < 3; i++ {
		for j := range 10 {
			if j > i {
				continue outer
			}
			if i*j > 4 {
				break outer
			}
			goto done
		}
	}
done:
	fmt.Println(`done`, rawMulti)
}

var regexpLike = `^\d+\.\d+$`
var sqlQuery = `
	SELECT "id", 'name'
	FROM users -- sql comment inside Go raw string
	WHERE id = $1
`

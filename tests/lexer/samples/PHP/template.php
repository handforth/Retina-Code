<!DOCTYPE html>
<?php
declare(strict_types=1);
// PHP lexer stress: HTML mixing, heredoc/nowdoc, interpolation
namespace App\View;

use App\Models\{User, Post};
use function App\Helpers\e;
use const App\Config\DEBUG;

$title = 'It\'s a "page"';
$user = new User(['name' => "O'Brien", 'roles' => ['admin', 'editor']]);
$items = [1, 2, 3];
?>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title><?= htmlspecialchars($title, ENT_QUOTES) ?></title>
  <style>
    body { font-family: "Helvetica Neue", sans-serif; margin: 0; }
    .user::before { content: '<?php echo "not really css"; ?>'; }
    /* css comment with ?> inside */
    @media (max-width: 600px) { .nav { display: none; } }
  </style>
  <script>
    // JS comment containing ?> which ends PHP only in PHP mode
    const config = <?= json_encode(['debug' => DEBUG, 'user' => $user->name]) ?>;
    const re = /<\/script>/i;
    function greet(name) { return `Hello, ${name}! It's ${new Date()}`; }
    if (config.debug && 1 < 2) { console.log("debug \"on\""); }
  </script>
</head>
<body class="<?php echo $user->isAdmin() ? 'admin' : 'guest'; ?>">
  <!-- HTML comment with <?php echo 'php inside html comment'; ?> -->
  <h1>Welcome, <?= e($user->name) ?>!</h1>
  <?php if (count($items) > 0): ?>
    <ul>
      <?php foreach ($items as $i => $item): ?>
        <li data-index="<?= $i ?>" class='item <?= $i % 2 ? "odd" : "even" ?>'><?= $item * 2 ?></li>
      <?php endforeach; ?>
    </ul>
  <?php elseif ($user === null): ?>
    <p>No user, it's empty</p>
  <?php else: ?>
    <p>Nothing to show.</p>
  <?php endif ?>
  <a href="/profile?id=<?= urlencode((string)$user->id) ?>&amp;tab=posts">Profile</a>
  <input type="text" value="<?= $user->email ?? '' ?>" <?= $user->locked ? 'disabled' : '' ?>>
<?php
$name = "World";
$arr = ['key' => 'value', 'nested' => ['deep' => 42]];
$obj = new \stdClass();
$obj->prop = "property";
$obj->inner = new \stdClass();
$obj->inner->x = 'x';

// Interpolation forms
echo "Simple: $name\n";
echo "Array: $arr[key] and {$arr['nested']['deep']}\n";
echo "Object: $obj->prop and {$obj->inner->x}\n";
echo "Method: {$user->getName()} and static: {${'name'}}\n";
echo "Dollar brace: ${name}\n";
echo "Escapes: \t \n \r \v \e \f \\ \$ \" \x41 \101 \u{1F600}\n";
echo 'Single: no $interp here, only \' and \\ escapes, \n is literal';
echo "Trailing backslash \\";
echo "Unterminated string on this line
echo "next line";
echo `ls -la $dir`;  // backtick shell exec with interpolation

// Heredoc with interpolation
$html = <<<HTML
<div class="card">
  <h2>{$user->name}</h2>
  <p>Email: $user->email</p>
  <p>Roles: {$arr['nested']['deep']} and "quotes" and 'apostrophes'</p>
  <p>Escaped \$dollar and \{brace}</p>
</div>
HTML;

// Nowdoc (no interpolation)
$raw = <<<'RAW'
No $interpolation {$here} at all.
Backslashes \n \t are literal.
RAW;

// Indented closing marker (PHP 7.3+)
$sql = <<<SQL
    SELECT *
    FROM "users"
    WHERE name = '{$name}' -- not a php comment
    SQL;

// Heredoc with quoted label
$quoted = <<<"EOT"
  Double-quoted heredoc label: $name
  EOT;

// Heredoc used as a function argument, closed mid-line
$result = sprintf(<<<FMT
    Hello %s, you have %d messages
    FMT, $name, 5);

/* Block comment with "strings" and ?> inside — does ?> end PHP here? It does not in comments */
# Hash-style comment
#[Attribute(Attribute::TARGET_CLASS)]
final class Route
{
    public function __construct(
        public readonly string $path,
        public readonly array $methods = ['GET'],
    ) {}
}

#[Route('/posts/{id}', methods: ['GET', 'POST'])]
class PostController extends BaseController implements \JsonSerializable
{
    private const MAX = 0x7FFF_FFFF;
    protected static ?self $instance = null;
    public int|float $ratio = 1.5e-3;

    public function show(int $id): ?Post
    {
        $post = Post::find($id) ?? throw new \RuntimeException("Post #$id not found");
        $fn = fn($x) => $x * 2 / 3;
        $match = match (true) {
            $id < 0 => 'negative',
            $id === 0 => "zero",
            default => 'positive',
        };
        return $post?->author?->name ? $post : null;
    }

    public function jsonSerialize(): mixed
    {
        return ['max' => self::MAX, 'bin' => 0b1010, 'oct' => 0o17, 'old' => 017, 'f' => .5];
    }
}

enum Suit: string
{
    case Hearts = 'H';
    case Spades = 'S';
    public function color(): string { return $this === self::Hearts ? 'Red' : 'Black'; }
}

$closure = function (array &$list, string ...$rest) use ($name): void {
    $list[] = "$name: " . implode(', ', $rest);
};
list('a' => $a, 'b' => $b) = ['a' => 1, 'b' => 2];
[$x, [$y, $z]] = [1, [2, 3]];
$x <=> $y;
$x ??= 'default';
$s = $a . $b . "{$x}" . '$y';
$nullsafe = $obj?->inner?->x;
$instance = new class(10) extends \ArrayObject { public function __construct(public int $n) {} };
?>
  <footer>&copy; <?= date('Y') ?> — <?php /* inline comment */ echo "Company's site"; ?></footer>
</body>
</html>
<?php
// File ends in PHP mode without a closing tag, which is legal
$final = "done";

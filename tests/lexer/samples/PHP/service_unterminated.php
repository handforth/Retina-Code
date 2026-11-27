<?php

/**
 * Second PHP sample: pure PHP service class, tricky strings, unterminated comment at EOF.
 *
 * @package App\Service
 * @author  Someone <someone@example.com>
 * @see     https://example.com/docs?a=1&b=2
 */

declare(strict_types=1);

namespace App\Service;

use DateTimeImmutable as Date;
use InvalidArgumentException;
use Psr\Log\LoggerInterface;

interface Cache
{
    public function get(string $key, mixed $default = null): mixed;
    public function set(string $key, mixed $value, int $ttl = 3600): bool;
}

trait Loggable
{
    protected ?LoggerInterface $logger = null;

    protected function log(string $level, string $message, array $context = []): void
    {
        $this->logger?->log($level, "[{$this->name()}] $message", $context);
    }

    abstract protected function name(): string;
}

abstract class AbstractService
{
    use Loggable {
        log as protected traitLog;
    }

    public function __construct(
        protected readonly Cache $cache,
        protected readonly string $prefix = 'svc:',
    ) {}
}

final class UserService extends AbstractService
{
    public const string VERSION = '2.1.0';
    private const array DEFAULTS = [
        'limit' => 50,
        'order' => 'desc',
        'regex' => '/^[a-z0-9_\-]+$/i',
        'path'  => 'C:\\Users\\name\\',
        "dq"    => "tab\tnewline\n",
    ];

    protected function name(): string
    {
        return static::class;
    }

    public function find(int|string $id): ?array
    {
        if (!is_numeric($id) && !preg_match('~^[A-Z]{2}\d{4}$~', (string) $id)) {
            throw new InvalidArgumentException(sprintf('Invalid id "%s"', $id));
        }
        $key = "{$this->prefix}user:{$id}";
        $hit = $this->cache->get($key);
        if ($hit !== null) {
            $this->log('debug', "cache hit for $key");
            return $hit;
        }
        $row = $this->query(<<<SQL
            SELECT id, name, email
            FROM users
            WHERE id = :id AND deleted_at IS NULL -- SQL comment
            LIMIT 1
            SQL, ['id' => $id]);
        $this->cache->set($key, $row, ttl: 60 * 5);
        return $row ?: null;
    }

    private function query(string $sql, array $params = []): array
    {
        $this->log('info', 'query: ' . preg_replace('/\s+/', ' ', trim($sql)));
        return ['sql' => $sql, 'params' => $params];
    }

    public function render(array $user): string
    {
        $name = htmlspecialchars($user['name'] ?? '', ENT_QUOTES | ENT_HTML5);
        $created = (new Date($user['created'] ?? 'now'))->format('Y-m-d\TH:i:sP');
        return <<<HTML
            <article data-id="{$user['id']}">
              <h3>$name</h3>
              <time datetime="$created">{$created}</time>
              <p>Literal braces: { not interp } and \{$name} escaped</p>
              <p>Method call: {$this->name()}</p>
            </article>
            HTML;
    }

    public function template(): string
    {
        return <<<'TPL'
            {{ name }} and $notVar and {$notInterp}
            <?php echo 'not executed'; ?>
            TPL;
    }

    public static function numbers(): array
    {
        return [
            0, -1, 1_000_000, 0x1A_2B, 0X1a, 0b1111_0000, 0B11, 0o777, 0O7, 0777,
            1.5, .5, 5., 1e10, 1E-10, 1.5e+3, PHP_INT_MAX, PHP_FLOAT_EPSILON,
        ];
    }

    public function strings(): void
    {
        $a = 'single \' quote \\ backslash \n literal';
        $b = "double \" quote \\ backslash \n newline \$ dollar";
        $c = "complex {$a} and ${b} and $a[0] and {$a[1]}";
        $d = "unicode \u{00e9} \u{1F600} hex \x7f oct \177";
        $e = 'multi-line
single-quoted string
spanning three lines';
        $f = "multi-line
double-quoted with $a
interp";
        $g = "comment markers: // # /* */ inside string";
        $h = '?> in a single-quoted string does not end php';
        $i = "?> in a double-quoted string either";
        $j = `echo "shell $a"`;
        $k = "nested \"{$this->name()}\" call";
    }

    public function closures(): \Closure
    {
        $mult = 3;
        $static = static fn(int $x): int => $x * $mult;
        $classic = function (int $x) use (&$mult): int {
            return $x / $mult;
        };
        return \Closure::fromCallable([$this, 'name']);
    }

    public function __get(string $prop): mixed { return $this->$prop ?? $this->{'get' . ucfirst($prop)}(); }
    public function __call(string $m, array $a): mixed { return static::$m(...$a); }
}

function helper(string $s = "default \"value\""): string
{
    global $config;
    static $calls = 0;
    $calls++;
    return $s . $calls . ($config['suffix'] ?? '');
}

$svc = new UserService(new class implements Cache {
    private array $data = [];
    public function get(string $key, mixed $default = null): mixed { return $this->data[$key] ?? $default; }
    public function set(string $key, mixed $value, int $ttl = 3600): bool { $this->data[$key] = $value; return true; }
});

goto end;
echo "skipped";
end:
echo helper(), PHP_EOL;
print("printed\n");
die('done');

/* This block comment is never terminated.
 * $variable = "not code";
 * echo <<<EOT
 * heredoc inside comment
 * EOT;
 * ?>  <!-- does ?> end PHP inside an unterminated block comment? It must not. -->
 * <html> should not appear as markup either

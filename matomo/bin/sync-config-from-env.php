<?php
/**
 * Synchronise config/config.ini.php [database] depuis les variables MATOMO_DATABASE_*.
 * Usage (conteneur) : php /var/www/html/misc/wise-eat/sync-config-from-env.php
 */
declare(strict_types=1);

$file = '/var/www/html/config/config.ini.php';

$host = getenv('MATOMO_DATABASE_HOST') ?: 'matomo-db';
$user = getenv('MATOMO_DATABASE_USERNAME') ?: 'matomo';
$pass = getenv('MATOMO_DATABASE_PASSWORD') ?: '';
$db = getenv('MATOMO_DATABASE_DBNAME') ?: 'matomo';
$prefix = getenv('MATOMO_DATABASE_TABLES_PREFIX') ?: 'matomo_';
$adapter = getenv('MATOMO_DATABASE_ADAPTER') ?: 'PDO\\MYSQL';

if (!is_file($file)) {
    fwrite(STDOUT, "NO_CONFIG\n");
    exit(0);
}

$content = file_get_contents($file);
if ($content === false) {
    fwrite(STDERR, "READ_FAIL\n");
    exit(1);
}

$updates = [
    'host' => $host,
    'username' => $user,
    'password' => $pass,
    'dbname' => $db,
    'tables_prefix' => $prefix,
    'adapter' => $adapter,
];

foreach ($updates as $key => $value) {
    $escaped = str_replace('"', '\\"', $value);
    $line = $key . ' = "' . $escaped . '"';
    if (preg_match('/^' . preg_quote($key, '/') . ' = .*$/m', $content)) {
        $content = preg_replace('/^' . preg_quote($key, '/') . ' = .*$/m', $line, $content);
    } elseif (preg_match('/^\[database\]/m', $content)) {
        $content = preg_replace('/^\[database\]\s*$/m', "[database]\n{$line}", $content, 1);
    }
}

if (file_put_contents($file, $content) === false) {
    fwrite(STDERR, "WRITE_FAIL\n");
    exit(1);
}

try {
    $pdo = new PDO("mysql:host={$host};dbname={$db};charset=utf8mb4", $user, $pass, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    ]);
    $pdo->query('SELECT 1');
    fwrite(STDOUT, "OK\n");
} catch (Throwable $e) {
    fwrite(STDERR, 'PDO_FAIL: ' . $e->getMessage() . "\n");
    exit(2);
}

<?php
/**
 * Diagnostic Matomo — affiche l'exception PHP au boot (HTTP 500).
 */
declare(strict_types=1);

$_SERVER['HTTP_HOST'] = getenv('MATOMO_DIAG_HOST') ?: 'analytics.wise-eat.com';
$_SERVER['HTTPS'] = 'on';
$_SERVER['SERVER_PORT'] = '443';
$_SERVER['REQUEST_URI'] = '/';
$_SERVER['REQUEST_METHOD'] = 'GET';
$_SERVER['REMOTE_ADDR'] = '127.0.0.1';
$_SERVER['HTTP_X_FORWARDED_PROTO'] = 'https';
$_SERVER['HTTP_X_FORWARDED_FOR'] = '127.0.0.1';

error_reporting(E_ALL);
ini_set('display_errors', '1');

try {
    if (!is_file('/var/www/html/index.php')) {
        throw new RuntimeException('index.php absent');
    }
    if (!is_file('/var/www/html/config/config.ini.php')) {
        throw new RuntimeException('config.ini.php absent — assistant installation requis');
    }
    ob_start();
    include '/var/www/html/index.php';
    $out = ob_get_clean();
    $snippet = substr(trim(strip_tags($out)), 0, 200);
    fwrite(STDOUT, "BOOT_OK len=" . strlen($out) . " snippet=" . $snippet . "\n");
} catch (Throwable $e) {
    fwrite(STDERR, 'BOOT_FAIL: ' . get_class($e) . ': ' . $e->getMessage() . "\n");
    fwrite(STDERR, $e->getFile() . ':' . $e->getLine() . "\n");
    exit(1);
}

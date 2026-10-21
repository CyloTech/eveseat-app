<?php

$root = getenv('SEAT_RELEASE_DIR') ?: '/opt/seat-preinstall/seat';
$path = $root . '/vendor/eveseat/eveapi/src/Commands/Eve/Update/Sde.php';
$source = file_get_contents($path);
if (str_contains($source, 'new AppboxSdeUpdater')) {
    exit(0);
}
$replacement = <<<'PHP'
public function handle()
    {
        return (new AppboxSdeUpdater())->run($this);
    }

    public function legacyHandle()
PHP;
$patched = str_replace('public function handle()', $replacement, $source, $count);
if ($count !== 1) {
    fwrite(STDERR, "Unexpected upstream SeAT SDE command; refusing to patch.\n");
    exit(1);
}
if (file_put_contents($path, $patched) === false) {
    exit(1);
}

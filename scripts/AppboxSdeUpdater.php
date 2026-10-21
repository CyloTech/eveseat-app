<?php

namespace Seat\Eveapi\Commands\Eve\Update;

use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Seat\Services\Settings\Seat;
use RuntimeException;

/** Keep the existing SeAT command and schedule while refreshing CCP reference data. */
final class AppboxSdeUpdater
{
    private const TABLES = [
        'invTypes', 'dgmTypeAttributes', 'dgmTypeEffects', 'chrFactions',
        'invCategories', 'invContrabandTypes', 'invControlTowerResources',
        'invGroups', 'invMarketGroups', 'invMetaGroups',
    ];
    private const LOCATIONS = ['regions', 'constellations', 'solar_systems', 'mapDenormalize', 'staStations'];

    public function run(Sde $command): int
    {
        $lock = fopen(storage_path('app/appbox-sde.lock'), 'c');
        if ($lock === false || ! flock($lock, LOCK_EX | LOCK_NB)) {
            $command->error('An EVE static-data update is already running, or its lock is unavailable.');
            return 1;
        }

        try {
            // The CCP seeder does not supply SeAT's legacy location tables.
            // Only bootstrap these when absent; never overwrite current CCP types on a refresh.
            if (! $this->tablesReady(self::LOCATIONS)) {
                $command->info('Bootstrapping the legacy EVE location tables.');
                if ($command->legacyHandle() !== 0 || ! $this->tablesReady(self::LOCATIONS)) {
                    throw new RuntimeException('Legacy EVE location import did not complete.');
                }
            }

            if ($command->option('local')) {
                $build = $this->validBuild(config('eveapi.config.sde.version'));
            } else {
                $response = $command->getGuzzle()->request('GET',
                    'https://developers.eveonline.com/static-data/tranquility/latest.jsonl',
                    ['connect_timeout' => 15, 'timeout' => 60]);
                $build = self::latestBuild((string) $response->getBody());
            }

            $installed = Seat::get('appbox_installed_ccp_sde', false);
            if (! $command->option('force') && (string) $installed === $build && $this->tablesReady(self::TABLES)) {
                $command->info('CCP EVE static data is current (build ' . $build . ').');
                return 0;
            }

            $command->info('Importing CCP EVE static data build ' . $build . '.');
            // Assign at runtime: Laravel's cached configuration must not freeze the latest build.
            config(['eveapi.config.sde.version' => $build]);
            $result = $command->call('db:seed', [
                '--class' => 'Seat\\Eveapi\\Database\\Seeders\\CcpSdeSeeder',
                '--force' => true,
                '--no-interaction' => true,
            ]);
            if ($result !== 0 || ! $this->tablesReady(self::TABLES)) {
                throw new RuntimeException('CCP EVE static-data import did not populate all required tables.');
            }

            $typeCount = self::countTypes(storage_path('sde/types.jsonl'));
            if ($typeCount !== (int) DB::table('invTypes')->count()) {
                throw new RuntimeException('Imported EVE type count does not match the CCP source.');
            }
            // Record completion only after import and independent database verification.
            Seat::set('appbox_installed_ccp_sde', $build);
            $command->info('CCP EVE static data verified: build ' . $build . ', ' . $typeCount . ' types.');
            return 0;
        } catch (\Throwable $error) {
            // Database exceptions may include SQL values. Do not publish customer data in cron logs.
            $command->error('EVE static-data update failed (' . get_class($error) . '); completion was not recorded.');
            return 1;
        } finally {
            flock($lock, LOCK_UN);
            fclose($lock);
        }
    }

    private function tablesReady(array $tables): bool
    {
        foreach ($tables as $table) {
            if (! Schema::hasTable($table) || ! DB::table($table)->exists()) {
                return false;
            }
        }
        return true;
    }

    public static function latestBuild(string $jsonl): string
    {
        $builds = [];
        foreach (preg_split('/\R/', trim($jsonl)) as $line) {
            if (trim($line) === '') {
                continue;
            }
            $record = json_decode($line, true, 512, JSON_THROW_ON_ERROR);
            if (($record['_key'] ?? null) === 'sde') {
                $builds[] = self::validBuild($record['buildNumber'] ?? null);
            }
        }
        if (count($builds) !== 1) {
            throw new RuntimeException('CCP metadata must contain exactly one SDE build.');
        }
        return $builds[0];
    }

    private static function validBuild($build): string
    {
        if ((! is_string($build) && ! is_int($build)) || ! preg_match('/^[1-9][0-9]{0,9}$/D', (string) $build)) {
            throw new RuntimeException('Invalid CCP SDE build number.');
        }
        return (string) $build;
    }

    public static function countTypes(string $path): int
    {
        $file = fopen($path, 'r');
        if ($file === false) {
            throw new RuntimeException('CCP types source is unavailable.');
        }
        $count = 0;
        try {
            while (($line = fgets($file)) !== false) {
                if (trim($line) === '') {
                    continue;
                }
                $type = json_decode($line, true, 512, JSON_THROW_ON_ERROR);
                if (! is_int($type['_key'] ?? null) || ! is_string($type['name']['en'] ?? null)) {
                    throw new RuntimeException('Invalid CCP type record.');
                }
                $count++;
            }
            if (! feof($file) || $count === 0) {
                throw new RuntimeException('Incomplete CCP types source.');
            }
            return $count;
        } finally {
            fclose($file);
        }
    }
}

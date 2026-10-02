<?php
/**
 * 第三方组件分发辅助：GitHub release 抓取 + 模块包解析。
 * update.php（写清单）与 fetch_packages.php（抓上游）共用。
 */

require_once __DIR__ . '/sources.php';

/** 从模块 zip 里读 module.prop（多层路径取最短，兼容嵌套一层目录的打包方式） */
function pkg_read_module_prop(string $zipPath): ?array {
    if (!class_exists('ZipArchive')) return null;
    $zip = new ZipArchive();
    if ($zip->open($zipPath) !== true) return null;
    $best = null;
    for ($i = 0; $i < $zip->numFiles; $i++) {
        $st = $zip->statIndex($i);
        $p = str_replace('\\', '/', (string)($st['name'] ?? ''));
        if (basename($p) === 'module.prop' && ($best === null || strlen($p) < strlen($best['path']))) {
            $best = ['path' => $p, 'body' => $zip->getFromIndex($i)];
        }
    }
    $zip->close();
    if ($best === null || !is_string($best['body'])) return null;
    $out = [];
    foreach (preg_split('/\r?\n/', $best['body']) as $line) {
        if (preg_match('/^(id|name|version|versionCode)=(.*)$/', trim($line), $m)) {
            $out[$m[1]] = trim($m[2]);
        }
    }
    return empty($out['id']) ? null : $out;
}

/** 查 GitHub 仓库最新 release，返回 ['tag'=>..., 'assets'=>[['name','url','size']...]]，失败 null */
function pkg_github_latest(string $repo, string $accel, int $timeout = 20): ?array {
    if (!preg_match('#^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$#', $repo)) return null;
    $body = http_get("https://api.github.com/repos/$repo/releases/latest", $accel, $timeout, 2);
    if (!is_string($body) || $body === '') return null;
    $j = json_decode($body, true);
    if (!is_array($j) || empty($j['tag_name'])) return null;
    $assets = [];
    foreach (($j['assets'] ?? []) as $a) {
        if (!empty($a['name']) && !empty($a['browser_download_url'])) {
            $assets[] = [
                'name' => (string)$a['name'],
                'url'  => (string)$a['browser_download_url'],
                'size' => (int)($a['size'] ?? 0),
            ];
        }
    }
    return ['tag' => (string)$j['tag_name'], 'assets' => $assets];
}

/** 读 package/sources.json（抓取源定义），没有返回空数组 */
function pkg_load_sources(string $packageDir): array {
    $f = rtrim($packageDir, '/') . '/sources.json';
    if (!is_file($f)) return [];
    $j = json_decode((string)@file_get_contents($f), true);
    return is_array($j) ? $j : [];
}

# ============================================================
#  公共模块：配置读写 / 自动找游戏目录
#  被 mod-manager.ps1 引用；配置文件和战报工具共用同一个 config.json
# ============================================================

$script:CFG_PATH = Join-Path $PSScriptRoot "config.json"

function Read-UiConfig {
    $cfg = [ordered]@{ gameDir = ""; outDir = "" }
    if (Test-Path -LiteralPath $script:CFG_PATH) {
        try {
            $raw = Get-Content -LiteralPath $script:CFG_PATH -Raw -Encoding UTF8
            if ($raw) { $raw = $raw.TrimStart([char]0xFEFF) }
            $o = $raw | ConvertFrom-Json
            foreach ($p in $o.PSObject.Properties) {
                if ($cfg.Contains($p.Name)) { $cfg[$p.Name] = [string]$p.Value }
            }
        } catch { }
    }
    return $cfg
}

function Save-UiConfig($cfg) {
    try {
        $obj = [ordered]@{}
        foreach ($k in $cfg.Keys) { $obj[$k] = $cfg[$k] }
        $json = $obj | ConvertTo-Json
        # 带 BOM：和战报工具写出来的格式保持一致，两边谁先写都能被对方读对
        [System.IO.File]::WriteAllText($script:CFG_PATH, $json, (New-Object System.Text.UTF8Encoding($true)))
    } catch { }
}

function Test-IsaacGameDir([string]$dir) {
    if ([string]::IsNullOrWhiteSpace($dir)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $dir "isaac-ng.exe"))
}

function Get-ModsDir($cfg) {
    $g = [string]$cfg["gameDir"]
    if ([string]::IsNullOrWhiteSpace($g)) { return "" }
    return (Join-Path $g "mods")
}

# 自动找游戏目录：注册表 → Steam 库文件夹 → 常见盘符
function Find-IsaacGameDir {
    $roots = @()
    try {
        $sp = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
        if ($sp) { $roots += ($sp -replace '/', '\') }
    } catch { }
    try {
        $ip = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction SilentlyContinue).InstallPath
        if ($ip) { $roots += $ip }
    } catch { }

    $libs = @()
    foreach ($r in $roots) {
        if (Test-Path -LiteralPath $r) { $libs += $r }
        $vdf = Join-Path $r "steamapps\libraryfolders.vdf"
        if (Test-Path -LiteralPath $vdf) {
            try {
                $txt = Get-Content -LiteralPath $vdf -Raw
                foreach ($m in [regex]::Matches($txt, '"path"\s*"([^"]+)"')) {
                    $libs += ($m.Groups[1].Value -replace '\\\\', '\')
                }
            } catch { }
        }
    }

    # 兜底：各盘符下的常见库目录
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        foreach ($sub in @("SteamLibrary", "STEAM", "Steam", "Program Files (x86)\Steam")) {
            $guess = Join-Path $d.Root $sub
            if (Test-Path -LiteralPath $guess) { $libs += $guess }
        }
    }

    foreach ($l in ($libs | Select-Object -Unique)) {
        $p = Join-Path $l "steamapps\common\The Binding of Isaac Rebirth"
        if (Test-Path -LiteralPath (Join-Path $p "isaac-ng.exe")) { return $p }
    }
    return ""
}

# 最终生效的配置：配置里的值 > 自动识别 > 默认
function Resolve-UiConfig {
    $cfg = Read-UiConfig
    $changed = $false

    if (-not (Test-IsaacGameDir $cfg["gameDir"])) {
        $found = Find-IsaacGameDir
        if ($found -ne "") { $cfg["gameDir"] = $found; $changed = $true }
    }
    if ([string]::IsNullOrWhiteSpace($cfg["outDir"])) {
        $cfg["outDir"] = Join-Path ([Environment]::GetFolderPath('Desktop')) "以撒战报"
        $changed = $true
    }
    if ($changed) { Save-UiConfig $cfg }
    return $cfg
}

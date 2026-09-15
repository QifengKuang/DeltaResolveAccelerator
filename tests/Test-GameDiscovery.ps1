#requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
$work = Join-Path $PSScriptRoot ('output/discovery-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $work -Force
$junctionTarget = Join-Path $work 'junction-target'
$junctionSearch = Join-Path $work 'junction-search'
$null = New-Item -ItemType Directory -Path $junctionTarget,$junctionSearch -Force
[IO.File]::WriteAllBytes((Join-Path $junctionTarget 'DeltaForceClient-Win64-Shipping.exe'), [byte[]]@(0,1,2))
$null = New-Item -ItemType Junction -Path (Join-Path $junctionSearch 'linked-game') -Target $junctionTarget
$source = [IO.File]::ReadAllText((Join-Path $repository 'src/GameDiscovery.cs'))
$harness = @'
namespace DeltaResolveAccelerator {
    public static class DiscoveryTestHarness {
        public static string[] Run(string root) {
            var passed = new System.Collections.Generic.List<string>();
            System.Action<bool,string> check = (ok,name) => { if (!ok) throw new System.Exception(name); passed.Add(name); };
            string exeName = GameDiscovery.ExecutableName;
            string chinese = System.IO.Path.Combine(root, "游戏 安装 (测试)");
            string bin = System.IO.Path.Combine(chinese, @"Game\DeltaForce\Binaries\Win64");
            System.IO.Directory.CreateDirectory(bin);
            string executable = System.IO.Path.Combine(bin, exeName);
            System.IO.File.WriteAllBytes(executable, new byte[] { 0, 1, 2 });
            check(GameDiscovery.IsGameExecutable(executable), "Exact executable accepted without executing it");
            check(!GameDiscovery.IsGameExecutable(System.IO.Path.Combine(bin, "missing.exe")), "Missing executable rejected");
            string impostor = System.IO.Path.Combine(bin, "DeltaForce.exe");
            System.IO.File.WriteAllBytes(impostor, new byte[] { 0 });
            check(!GameDiscovery.IsGameExecutable(impostor), "Similar executable name rejected");
            var found = GameDiscovery.FindInFolder(chinese, "WeGame");
            check(found.Count == 1 && found[0].Path == executable && found[0].Platform == "WeGame", "Known subtree with Chinese spaces and parentheses");
            check(GameDiscovery.FindInFolder(bin, "").Count == 1, "Direct executable folder");
            check(GameDiscovery.FindInFolder(System.IO.Path.GetPathRoot(root), "").Count == 0, "Drive root never scanned");
            check(GameDiscovery.FindInFolder(System.IO.Path.Combine(root,"missing"), "").Count == 0, "Missing selected folder is harmless");
            check(GameDiscovery.FindInFolder(System.IO.Path.Combine(root,"junction-search"), "").Count == 0, "Directory junction is not traversed");
            check(GameDiscovery.FindInFolder(System.IO.Path.Combine(root,@"junction-search\linked-game"), "").Count == 0, "Selected junction root is rejected");
            string second = System.IO.Path.Combine(chinese, @"second\Binaries\Win64");
            System.IO.Directory.CreateDirectory(second);
            System.IO.File.WriteAllBytes(System.IO.Path.Combine(second, exeName), new byte[] {0});
            check(GameDiscovery.FindInFolder(chinese, "WeGame").Count == 2, "Ambiguous folder returns candidates instead of guessing");
            string deep = System.IO.Path.Combine(root, @"deep\1\2\3\4\5\6");
            System.IO.Directory.CreateDirectory(deep);
            System.IO.File.WriteAllBytes(System.IO.Path.Combine(deep, exeName), new byte[] {0});
            check(GameDiscovery.FindInFolder(System.IO.Path.Combine(root, "deep"), "").Count == 0, "Traversal depth is bounded");
            var libraries = GameDiscovery.ParseLibraryFolders("\"libraryfolders\" { \"0\" { \"path\" \"D:\\\\SteamLibrary\" } \"1\" \"E:\\\\游戏库\" \"2\" { \"path\" \"d:\\\\SteamLibrary\" } }");
            check(libraries.Count == 2 && libraries[0] == @"D:\SteamLibrary" && libraries[1] == @"E:\游戏库", "Modern and legacy VDF paths deduplicated");
            check(GameDiscovery.ParseLibraryFolders("\"path\" \"relative\\\\path\"").Count == 0, "Relative VDF paths rejected");
            check(GameDiscovery.ParseLibraryFolders(new string('a', 1048577)).Count == 0, "Oversize VDF bounded");
            check(GameDiscovery.ParseInstallDirectory("\"installdir\" \"Delta Force\"") == "Delta Force", "Steam manifest install directory");
            check(GameDiscovery.ParseInstallDirectory("\"installdir\" \"..\\\\outside\"") == "", "Steam manifest traversal rejected");
            check(GameDiscovery.ParseInstallDirectory("\"installdir\" \"D:\\\\outside\"") == "", "Absolute manifest path rejected");
            check(GameDiscovery.DetectPlatform(@"D:\SteamLibrary\steamapps\common\Delta Force\game.exe") == "Steam", "Steam classification requires library structure");
            check(GameDiscovery.DetectPlatform(@"D:\WeGameApps\三角洲行动\game.exe") == "WeGame", "WeGame classification");
            check(GameDiscovery.DetectPlatform(@"D:\Games\三角洲行动\game.exe") == "", "Legacy unknown platform remains unclassified");
            return passed.ToArray();
        }
    }
}
'@
Add-Type -TypeDefinition ($source + [Environment]::NewLine + $harness) -Language CSharp
$checks = [DeltaResolveAccelerator.DiscoveryTestHarness]::Run($work)
$report = [pscustomobject]@{ passed = $true; checks = $checks.Count; results = $checks; networkStarted = $false; realSettingsRead = $false; gameExecuted = $false }
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $work 'result.json') -Encoding utf8
$report | Select-Object passed,checks,networkStarted,realSettingsRead,gameExecuted | ConvertTo-Json

<#
.SYNOPSIS
  Builds the WireTunnels MSI for one or both architectures: publish, add wireguard.dll, sign, package, sign the MSI,
  and (with -Appcast) sign it for the updater and add the item to the Windows appcast.
.EXAMPLE
  .\release.ps1 -Arch x64,arm64 -SigntoolArgs '/sha1 <thumbprint> /fd sha256 /tr http://timestamp.digicert.com /td sha256'
  # Azure Trusted Signing: -SigntoolArgs '/dlib Azure.CodeSigning.Dlib.dll /dmdf metadata.json /fd sha256 /tr http://timestamp.acs.microsoft.com /td sha256'
#>
param(
    [string[]] $Arch = @('x64', 'arm64'),
    [string] $SigntoolArgs,                  # without it the binaries are not signed (local test builds only)
    [string] $Signtool = 'signtool.exe',
    [string] $Appcast,                       # path of appcast-windows.xml to update (needs WIRETUNNELS_ED25519_KEY)
    [string] $DownloadBase,                  # where the MSIs will be hosted, e.g. https://github.com/FMDigitech/WireTunnels/releases/download/win-v1.0.0
    [string] $NotesFile
)
$ErrorActionPreference = 'Stop'
$Arch = $Arch -split ','   # -File passes 'x64,arm64' as one string
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'artifacts'
$version = ([xml](Get-Content (Join-Path $root 'Directory.Build.props'))).Project.PropertyGroup.Version
$wgZip = 'https://download.wireguard.com/wireguard-nt/wireguard-nt-1.1.zip'
$wgHash = 'dceb30a9bc4be48cce0f74160fc88a585a2c2627366e8f846fc6658f9038dace'

function Invoke-Native { & $args[0] $args[1..($args.Length - 1)]; if ($LASTEXITCODE) { throw "$($args[0]) failed ($LASTEXITCODE)" } }
function Sign-Files($files) {
    if (-not $SigntoolArgs) { return }
    foreach ($f in $files) { Invoke-Native $Signtool sign @($SigntoolArgs -split ' ') $f }
}

# wireguard-nt, pinned by hash; the service also verifies its Authenticode signature (WireGuard LLC) before loading it.
New-Item -ItemType Directory -Force $out | Out-Null
$zip = Join-Path $out 'wireguard-nt.zip'
if (-not (Test-Path $zip)) { Invoke-WebRequest $wgZip -OutFile $zip }
if ((Get-FileHash $zip -Algorithm SHA256).Hash -ne $wgHash.ToUpper()) { Remove-Item $zip; throw 'wireguard-nt download does not match the pinned SHA-256' }
$wg = Join-Path $out 'wireguard-nt'
if (-not (Test-Path $wg)) { Expand-Archive $zip $out -Force }

Invoke-Native dotnet test (Join-Path $root 'WireTunnels.Windows.sln') -c Release --nologo -v q

foreach ($a in $Arch) {
    $rid = "win-$a"
    $stage = Join-Path $out "stage-$a"
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    foreach ($p in 'WireTunnels.Service', 'WireTunnels.Cli', 'WireTunnels.App') {
        Invoke-Native dotnet publish (Join-Path $root "src\$p") -c Release -r $rid --self-contained -p:Platform=$a -o $stage --nologo -v q
    }
    Copy-Item (Join-Path $wg "bin\$(if ($a -eq 'x64') { 'amd64' } else { $a })\wireguard.dll") $stage
    Sign-Files (Get-ChildItem $stage -Recurse -Include 'WireTunnels*.exe', 'WireTunnels*.dll', 'wiretunnels.exe', 'wiretunnels.dll')

    Invoke-Native dotnet build (Join-Path $PSScriptRoot 'WireTunnels.Installer.wixproj') -c Release "-p:InstallerPlatform=$a" "-p:StageDir=$stage" --nologo -v q
    $msi = Join-Path $PSScriptRoot "bin\$a\WireTunnels-$version-$a.msi"
    Sign-Files @($msi)
    Copy-Item $msi $out -Force
    $final = Join-Path $out (Split-Path $msi -Leaf)

    if ($Appcast) {
        $args = @('appcast', $Appcast, $final, $version, "windows-$a", "$DownloadBase/$(Split-Path $final -Leaf)")
        if ($NotesFile) { $args += $NotesFile }
        Invoke-Native dotnet run --project (Join-Path $root 'tools\WireTunnels.SignUpdate') -c Release -- @args
    }
    Write-Host "Built $final"
}

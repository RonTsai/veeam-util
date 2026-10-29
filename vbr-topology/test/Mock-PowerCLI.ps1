# Mock VMware PowerCLI cmdlets (offline tests of Get-VBRTopology.ps1 -UsePowerCLI only).
# Load after Mock-VeeamCmdlets.ps1. Includes a VM without a host (disconnected / orphaned)
# and rejects the password "bad" for vCenter logins.
function Get-Module {
    param([switch]$ListAvailable, [Parameter(Position = 0)]$Name)
    if ("$Name" -like "VMware*") { [pscustomobject]@{ Name = "$Name"; Version = "13.3.0" } }
    else { Microsoft.PowerShell.Core\Get-Module @PSBoundParameters }
}
function Import-Module { param([Parameter(Position = 0)]$Name) if ("$Name" -notlike "VMware*") { Microsoft.PowerShell.Core\Import-Module @PSBoundParameters } }
function Set-PowerCLIConfiguration { }
function Get-Credential {
    param($Message, $UserName)
    Write-Host ">> Get-Credential: $Message (user: $UserName)"
    [pscredential]::new($(if ($UserName) { $UserName } else { "ro@vsphere.local" }), (ConvertTo-SecureString "good" -AsPlainText -Force))
}
function Connect-VIServer {
    param([Parameter(Position = 0)]$Server, $Credential)
    if ($Credential -and $Credential.GetNetworkCredential().Password -eq "bad") {
        throw "$(Get-Date) Connect-VIServer Cannot complete login due to an incorrect user name or password."
    }
    [pscustomobject]@{ Name = $Server }
}
function Disconnect-VIServer { }
function Get-VM {
    param($Server)
    $h = { param($n) [pscustomobject]@{ Name = $n } }
    [pscustomobject]@{ Name = "VBR-Server"; VMHost = (& $h "esx01.corp.local"); Guest = [pscustomobject]@{ HostName = "vbr01.corp.local"; IPAddress = @("10.0.0.10") } }
    [pscustomobject]@{ Name = "proxy-a"; VMHost = (& $h "esx02.corp.local"); Guest = [pscustomobject]@{ HostName = $null; IPAddress = @("10.0.0.11") } }
    # A VM whose host is disconnected: VMHost is empty, and its guest name matches a real component
    [pscustomobject]@{ Name = "vbrpx02"; VMHost = $null; Guest = [pscustomobject]@{ HostName = "vbrpx02.corp.local"; IPAddress = @() } }
}

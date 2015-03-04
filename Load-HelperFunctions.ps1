Function Update-Console([String]$Message,[String]$Sender="PowerPlex")
{
	Write-Output ("{0} $($Sender): $Message" -f (Get-Date -Format "HH:mm:ss")) 
}

[Console]::TreatControlCAsInput = $true

# Confirm running as Administrator
$CurrentPrincipal = New-Object Security.Principal.WindowsPrincipal( [Security.Principal.WindowsIdentity]::GetCurrent())
if ( -not ($CurrentPrincipal.IsInRole( [Security.Principal.WindowsBuiltInRole]::Administrator ))) {
    Write-Error "This script must be executed from an elevated PowerShell session" -ErrorAction Stop
} 
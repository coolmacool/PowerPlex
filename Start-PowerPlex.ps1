Clear-Host

[Console]::TreatControlCAsInput = $true

$PowerPlex = [hashtable]::Synchronized(@{})

$PowerPlex.ScriptDirectory = (Split-Path $MyInvocation.MyCommand.Definition -Parent)
$PowerPlex.Script = $MyInvocation.MyCommand.Name
$PowerPlex.AssetsDirectory = $PowerPlex.ScriptDirectory + '\Assets'
$PowerPlex.HostName = 'trailers.apple.com'
$PowerPlex.Listener = New-Object Net.HttpListener

Get-ChildItem (Join-Path $PowerPlex.ScriptDirectory *.ps1) | 
? { $_.Name -ne $PowerPlex.Script } | 
% { 
    . $_.FullName
    Write-Output "Loading $($_.FullName)" 
}

Test-ElevatedPowerShell

Update-Console '***'
Update-Console 'PowerPlex'
Update-Console 'Press CTRL-C to shutdown.'
Update-Console '***'

Try
{
    Invoke-WebServer
}
catch 
{ 
    Write-Warning -Message 'An error occurred' 
    Write-Warning -Message $_.Exception.Message    
}
finally 
{ 
    $PowerPlex.Listener.Stop() 
}
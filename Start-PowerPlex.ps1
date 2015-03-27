Clear-Host

[Console]::TreatControlCAsInput = $true

$PowerPlex = @{ ScriptDirectory = (Split-Path $MyInvocation.MyCommand.Definition -Parent); Script = $MyInvocation.MyCommand.Name }
$PowerPlex.AssetsDirectory = $PowerPlex.ScriptDirectory + '\Assets'

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

$Listener = New-Object Net.HttpListener

Try
{
    Invoke-WebServer -Listener $Listener
}
catch 
{ 
    Write-Warning -Message 'An error occurred' 
    Write-Warning -Message $_.Exception.Message    
}
finally 
{ 
    $Listener.Stop() 
}
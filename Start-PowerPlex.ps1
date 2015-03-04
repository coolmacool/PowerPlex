Clear-Host

$Script:PowerPlex = @{ ScriptDirectory = (Split-Path $MyInvocation.MyCommand.Path -Parent) }
$Script:PowerPlex.AssetsDirectory = $Script:PowerPlex.ScriptDirectory + "\Assets"

Get-ChildItem (Join-Path $Script:PowerPlex.ScriptDirectory *.ps1) | ? { $_.FullName -ne $MyInvocation.MyCommand.Path} | % { . $_.FullName;Write-Output "Loading $($_.FullName)"; }


Update-Console "***"
Update-Console "PowerPlex"
Update-Console "Press CTRL-C to shutdown."
Update-Console "***"

$Listener = New-Object Net.HttpListener

Try
{
    Invoke-WebServer -Listener $Listener
}
catch 
{ 
    Write-Warning -Message "An error occurred" 
    Write-Warning -Message $_.Exception.Message    
}
finally 
{ 
    $Listener.Stop() 
}
Function Update-Console 
{
    Param(
        [Parameter(Mandatory=$true,Position=0)]
        [String]$Message,

        [Parameter(Mandatory=$false,Position=1)]
        [STring]$Sender="PowerPlex" 
    )

	Write-Output ("{0} $($Sender): $Message" -f (Get-Date -Format "HH:mm:ss")) 
}

Function Invoke-HTTPListenerRunspace 
{
    Param(
        [Parameter( Mandatory=$True,
                    Position=1)]
        [Net.HttpListener]$Listener,

        [Parameter( Mandatory=$True,
                    Position=2)]
        [ScriptBlock]$RequestCallback,

        [Parameter( Mandatory=$False)]
        [Int]$Port=8080,

        [Parameter( Mandatory=$False)]
        [Int]$MaxThreads        
    )
    
    Begin
    {

        if (-not $MaxThreads)
        {
            $MaxThreads = ((Get-WmiObject Win32_Processor) | 
                            Measure-Object -Sum -Property NumberOfLogicalProcessors).Sum
        }

        $SessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
 
        $Pool = [RunspaceFactory]::CreateRunspacePool(1, $MaxThreads, $SessionState, $Host)
        $Pool.ApartmentState  = "STA"
        $Pool.Open()

        $Listener.Prefixes.Add("http://+:$Port/")
        $Listener.Start()

        $Jobs = New-Object 'Collections.Generic.List[PSCustomObject]'
    }

    Process
    {

        # Queue "threads", limit number to MaxThreads value 
        for ($i = 1 ; $i -le $MaxThreads ; $i++) 
        {
            $Pipeline = [PowerShell]::Create()
            $Pipeline.RunspacePool = $Pool
            [void]$Pipeline.AddScript($RequestCallback)

            $Params =   @{ 
                ThreadID = $i 
                Listener = $Listener
            }
        
            [void]$Pipeline.AddParameters($Params)
 
            $Job = $Pipeline.BeginInvoke()

            $Jobs.Add((New-Object -TypeName PSObject -Property @{
                Pipeline = $Pipeline
                Job      = $Job
            }))
            
        }
        
        Update-Console -Message "Starting Listener Threads: $($Jobs.Count)" -Sender "WebServer"
		
        while ($Jobs.Count -gt 0) 
        {   
            $AwaitingRequest = $true
		    while ($AwaitingRequest)
		    {                
		        if ([Console]::KeyAvailable) 
                {
                    $Key = [Console]::readkey($true)
                    if (($Key.modifiers -band [consolemodifiers]"control") -and ($Key.key -eq "C"))
                    {
                        Write-Warning -Message "Server terminating..."

                        exit
                    }
                } 	    
        
                $Jobs | ForEach-Object {
                    if ($_.Job.IsCompleted)
				    {
                        $AwaitingRequest = $False

                        $JobIndex = $Jobs.IndexOf($_)
                        $Job = $_.Job
                        $Pipeline = $_.Pipeline

                        break
				    }
                }
		    }

            $Results = $Pipeline.EndInvoke($Job)

            # Process returned data    
            if ($Pipeline.HadErrors) #Thread errors
            {
                $Pipeline.Streams.Error.ReadAll() | ForEach-Object { Write-Error $_ }
            }
            else 
            {
                $Results | ForEach-Object { 
                    Update-Console -Message $_.Url -Sender "WebServer" 
                }
            }

            $Jobs.RemoveAt($JobIndex)

            $Pipeline.Dispose()

            # Requeue a new "thread"
            $Pipeline = [PowerShell]::Create()
            $Pipeline.RunspacePool = $Pool
            $Pipeline.AddScript($RequestCallback) | Out-Null
 
            $Params =  @{ 
                ThreadID = ($JobIndex + 1) 
                Listener = $Listener
            }
 
            $Pipeline.AddParameters($Params) | Out-Null
 
            $Job = $Pipeline.BeginInvoke()

            $Jobs.Insert($JobIndex, (New-Object -TypeName PSObject -Property @{
                Pipeline = $Pipeline
                Job      = $Job
            }))

        }
    }

    End
    {
        $pool.Close()
    }

}


$ProcessRequest =
{
    param($ThreadID, $Listener)

        $ReturnData = New-Object -TypeName psobject -Property @{
            ThreadID = $ThreadID
            Url = ""
            ConsoleOutput = ""
            StatusCode = 200
        }
                        
        $Context    = $Listener.GetContext()
        $Request    = $Context.Request

        $ReturnData.Url = $Request.Url.LocalPath
        $ReturnData.ConsoleOutput = "TestOutput"

        $ResponseData = "<html><body>Hello World!</body><html>"

        if (-not $ResponseData) { $ResponseData = [String]::Empty }
        
        $Buffer = ([System.Text.Encoding]::UTF8).GetBytes($ResponseData)
        
        $Response = $Context.Response
        $Response.StatusCode = $ReturnData.StatusCode
        $Response.ContentLength64 = $Buffer.Length
        
        $Output = $Response.OutputStream
        $Output.Write($Buffer, 0, $Buffer.Length)
        $Output.Close()
        $Response.Close()

        return $ReturnData
}


#######################################  
#             MAIN
#######################################

[Console]::TreatControlCAsInput = $true

# Confirm running as Administrator
$CurrentPrincipal = New-Object Security.Principal.WindowsPrincipal( [Security.Principal.WindowsIdentity]::GetCurrent())
if ( -not ($CurrentPrincipal.IsInRole( [Security.Principal.WindowsBuiltInRole]::Administrator ))) {
    Write-Error "This script must be executed from an elevated PowerShell session" -ErrorAction Stop
} 

Clear-Host
Update-Console "***"
Update-Console "PowerPlex"
Update-Console "Press CTRL-C to shutdown."
Update-Console "***"

$Listener = New-Object Net.HttpListener

Try
{
    Invoke-HTTPListenerRunspace -Listener $Listener -RequestCallback $ProcessRequest
}
catch 
{ 
    "An error occurred" 
    $_.Exception.Message    
}
finally 
{ 
    $Listener.Stop() 
}
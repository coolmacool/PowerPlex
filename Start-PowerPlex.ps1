Function Invoke-HTTPListenerRunspace {
 
    [CmdletBinding()]
    Param(
        [Parameter(
                    Mandatory=$True,
                    Position=1)]
        [Net.HttpListener]$Listener,

        [Parameter(
                    Mandatory=$True,
                    Position=2)]
        [ScriptBlock]$RequestCallback,

        [Parameter(
                    Mandatory=$False,
                    Position=3)]
        [Int]$MaxThreads
    )

    if (-not $MaxThreads)
    {
        $MaxThreads = ((Get-WmiObject Win32_Processor) | 
                        Measure-Object -Sum -Property NumberOfLogicalProcessors).Sum
    }
 
    $SessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
 
    $Pool = [RunspaceFactory]::CreateRunspacePool(1, $MaxThreads, $SessionState, $Host)
    $Pool.ApartmentState  = "STA"
    $Pool.Open()

    $Listener.Start()
 
    $Jobs = New-Object 'Collections.Generic.List[PSCustomObject]'

    # Queue "threads", limit number to MaxThreads value 
    for ($i = 1 ; $i -le $MaxThreads ; $i++) 
    {
        $Pipeline = [PowerShell]::Create()
        $Pipeline.RunspacePool = $Pool
        $Pipeline.AddScript($RequestCallback) | Out-Null

        $Params = 
        @{ 
            ThreadID = $i 
            Listener = $Listener
        }
        
        $Pipeline.AddParameters($Params) | Out-Null
 
        $Job = $Pipeline.BeginInvoke()

        $Jobs.Add((New-Object -TypeName PSObject -Property @{
            Pipeline = $Pipeline
            Job      = $Job
        }))

    }
 
    Write-Output "Starting Listener Count: $($Jobs.Count)"

    while ($Jobs.Count -gt 0) 
    {   
        $AwaitingRequest = $true
		While ($AwaitingRequest)
		{
			foreach ($j in $Jobs)
			{
				if ($j.Job.IsCompleted)
				{
					#Can cancel now with Control+C
                    $AwaitingRequest = $False

                    $JobIndex = $Jobs.IndexOf($j)
                    $Job = $j.Job
                    $Pipeline = $j.Pipeline

                    break
				}
			}
		}

        $Result   = $Pipeline.EndInvoke($Job)
        
        # Process returned data    
        if ($Pipeline.HadErrors) 
        {
            $Pipeline.Streams.Error.ReadAll() | ForEach-Object { Write-Error $_ }
        }
        else 
        {
            Write-Output ("{0}: Served {1} by thread: {2}" -f ((Get-date -Format HH:mm:ss),$result[1],($JobIndex+1)))
        }

        $Jobs.RemoveAt($JobIndex)

        $Pipeline.Dispose()

        # Requeue a new "thread"
        $Pipeline = [PowerShell]::Create()
        $Pipeline.RunspacePool = $Pool
        $Pipeline.AddScript($RequestCallback) | Out-Null
 
        $Params = 
        @{ 
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
    
    $pool.Close()

}


$ProcessRequest =
{
    param($ThreadID, $Listener)
    
        $Context  = $Listener.GetContext()
        $Request  = $Context.Request
        $Response = $Context.Response
    
        $ResponseString = "<HTML><BODY> Hello world from PowerShell! Request processed by thread: $ThreadID</BODY></HTML>"

        ###############################################
        # Simultaneous command testing
        if ($Request.Url -clike '*/test1') 
        { 
            
            Start-Sleep -Seconds 10
            $ResponseString = "Done waiting 10 seconds"
        }

        if ($Request.Url -clike '*/test2') 
        { 
                    
            $ResponseString = "$(Get-Process)"
        }
        ###############################################


        $Buffer = ([System.Text.Encoding]::UTF8).GetBytes($ResponseString)
        
        $Response.ContentLength64 = $Buffer.Length
        
        $Output = $Response.OutputStream
        $Output.Write($Buffer, 0, $Buffer.Length)
        
        $Output.Close()
        $Response.Close()
        
        # Return data to main thread
        $ThreadID
        $Request.Url.LocalPath
}


    
$Listener = New-Object Net.HttpListener
$Listener.Prefixes.Add("http://+:8080/")

Try
{
    Invoke-HTTPListenerRunspace -Listener $Listener -RequestCallback $ProcessRequest
    Write-Output "Server done."

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

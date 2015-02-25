Function Invoke-HTTPListenerRunspace {
 
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True,
                   Position=1)]
        [ScriptBlock]$ThreadBlock,
 
        [Parameter(Mandatory=$False,
                   Position=2)]
        [HashTable]$ThreadParams,

        [Parameter(Mandatory=$False,
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
 
    $Jobs      = New-Object 'Collections.Generic.List[System.IAsyncResult]'
    $Pipelines = New-Object 'Collections.Generic.List[System.Management.Automation.PowerShell]'
    $Handles   = New-Object 'Collections.Generic.List[System.Threading.WaitHandle]'
 
    # Queue "threads", limit number to MaxThreads value 
    for ($i = 1 ; $i -le $MaxThreads ; $i++) {
 
        $Pipeline = [PowerShell]::Create()
        $Pipeline.RunspacePool = $Pool
        $Pipeline.AddScript($ThreadBlock) | Out-Null
 
        $Params = @{ 'ThreadID' = $i }
 
        if ($ThreadParams) { $Params += $ThreadParams }
 
        $Pipeline.AddParameters($Params) | Out-Null
 
        $Pipelines.Add($Pipeline)
        $Job = $Pipeline.BeginInvoke()
        $Jobs.Add($job)
 
        $Handles.Add($Job.AsyncWaitHandle)

    }
 
    Write-Output "Starting Listener Count: $($Jobs.Count)"

    while ($Pipelines.Count -gt 0) {
        
        $AwaitingRequest = $true
		While ($AwaitingRequest)
		{
			foreach ($j in $jobs)
			{
				if ($j.IsCompleted)
				{
					#Can cancel now with Control+C
                    $AwaitingRequest = $False
                    $JobIndex = $jobs.IndexOf($j)
                    break
				}
			}
		}
		
        $Handle   = $handles.Item($JobIndex)
        $Job      = $jobs.Item($JobIndex)
        $Pipeline = $Pipelines.Item($JobIndex)
 
        $Result   = $Pipeline.EndInvoke($job)
        
        
        # Process returned data    
        if ($Pipeline.HadErrors) 
        {
            $Pipeline.Streams.Error.ReadAll() | ForEach-Object { Write-Error $_ }
        }
        else 
        {
            Write-Output ("{0}: Served {1} by thread: {2}" -f ((Get-date -Format HH:mm:ss),$result[1],($JobIndex+1)))
        }
 
        $Handles.RemoveAt($JobIndex)
        $Jobs.RemoveAt($JobIndex)
        $Pipelines.RemoveAt($JobIndex)
 
        $Handle.Close()
        $Pipeline.Dispose()

        # Requeue a new "thread"
        $Pipeline = [PowerShell]::Create()
        $Pipeline.RunspacePool = $Pool
        $Pipeline.AddScript($ThreadBlock) | Out-Null
 
        $Params = @{ 'threadId' = $JobIndex + 1 } #convert from zero index
 
        if ($ThreadParams) { $Params += $ThreadParams }
 
        $pipeline.AddParameters($params) | Out-Null
        $pipelines.Insert($JobIndex, $pipeline)
 
        $job = $pipeline.BeginInvoke()
        $jobs.Insert($JobIndex, $Job)

        $handles.Insert($JobIndex, $job.AsyncWaitHandle)
    }
    
    $pool.Close()

}


$ScriptBlock =
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
$Listener.Start()

$args = @{
    Listener = $Listener
}


Try
{
    Invoke-HTTPListenerRunspace -ThreadBlock $ScriptBlock -ThreadParams $args -Verbose
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

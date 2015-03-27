Function Invoke-WebServer
{
    Param(
        [Parameter( Mandatory=$True,
                    Position=1)]
        [Net.HttpListener]$Listener,

        [Parameter( Mandatory=$False)]
        [Int]$Port=8080,
        
        [Parameter( Mandatory=$False)]
        [Int]$SSLPort=8443,

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

        $SessionState = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
 
        $Pool = [RunspaceFactory]::CreateRunspacePool(1, $MaxThreads, $SessionState, $Host)
        $Pool.ApartmentState  = 'STA'
        $Pool.Open()

        $Listener.Prefixes.Add("http://trailers.apple.com:$Port/")       
        $Listener.Prefixes.Add("https://trailers.apple.com:$SSLPort/")   
        $Listener.Start()

        try
        {
            $Certificate = (Get-ChildItem -Path Cert:\LocalMachine\My | ? { $_.Subject -eq 'CN=trailers.apple.com' })
            $CertificateThumbprint = $Certificate.Thumbprint

            # Windows XP/Server 2003 will need httpcfg.exe instead of netsh
            [void](netsh http delete sslcert ipport='127.0.0.1:8443')
            [void](netsh http add sslcert ipport='127.0.0.1:8443' certhash="$CertificateThumbprint" appid='{00112233-4455-6677-8899-AABBCCDDEEFF}')
        }
        catch
        {
            Write-Error -Message "Error binding to SSL Port`r`n$($_.Exception.Message)" -ErrorAction Stop
        }

        $Jobs = New-Object -TypeName 'Collections.Generic.List[PSCustomObject]'

        $RequestCallback = 
        { param($ThreadID, $Listener, $AssetsDirectory)
            
            #region Request Processing Functions
            Function Convert-JavaScript
            {
                Param(
                    [Parameter( 
                        Mandatory=$false,
                        Position=0)]
                    [string]$FileName,

                    [Parameter(
                        Mandatory=$false,
                        Position=1)]
                    [string]$Options
                )

                $JS = Get-Content $FileName  | 
                % { 
                    If ($_ -match '\{\{URL\((.*?)\)\}\}') { $_.Replace($Matches[0],'https://trailers.apple.com' + $Matches[1]) }
                    Else { $_ }
                }

                $JS
            }
            #endregion

            $ReturnData = New-Object -TypeName psobject -Property @{
                ThreadID = $ThreadID
                Url = ''
                ConsoleOutput = ''
                StatusCode = 200
            }
            
            $EnableGzip = $false            

            $Context    = $Listener.GetContext()
            $Request    = $Context.Request
            $Response   = $Context.Response
            $Response.Headers.Add('Server','PowerPlex')
            $Response.Headers.Add('X-Powered-By','Microsoft PowerShell')

            #if (-not $ResponseData) { $ResponseData = [String]::Empty }
            
            # JS FILES
            $RequestedFile          = $Request.Url.LocalPath -replace '/','\'
            $RequestedFileDirectory = Split-Path -Path $RequestedFile -Parent
            $RequestedFileBasename  = Split-Path -Path $RequestedFile -Leaf
            $ResponseData = $RequestedFileBasename
            
            if ((($RequestedFileBasename -split '\.')[1] -eq 'js') -and ($RequestedFileDirectory -eq '\js'))
            {             
                <#if ($RequestedFileBasename -in ('application.js', 'main.js', 'javascript-packed.js', 'bootstrap.js'))
                {
                    $RequestedFile = '\js\application.js'
                }
               #>
                #$ResponseData = Convert-JavaScript -FileName "$AssetsDirectory$RequestFile"
            }
            
            $Buffer = [Text.Encoding]::UTF8.GetBytes($ResponseData)
        
            $ATVAcceptEncoding = $Request.Headers['Accept-Encoding'] -split ',' | % { $_.Trim() }
            if (-not [String]::IsNullOrEmpty($ATVAcceptEncoding) -and 
                ($ATVAcceptEncoding -contains 'gzip') -and
                ($EnableGzip))
            {
                $Response.AppendHeader('Content-Encoding','gzip')                
                $Response.AppendHeader('Content-Type', 'text/plain')
                $Response.AppendHeader('Vary', 'Accept-Encoding')
        
                try 
                {
 
                    $Output = $Response.OutputStream
                    $gzipStream = New-Object IO.Compression.GzipStream ($Output, [IO.Compression.CompressionMode]::Compress, $false)
                    $gzipStream.Write($Buffer, 0, $Buffer.Length)
                    $gzipStream.Close()
 
                }
                catch
                {
                    $ReturnData.ConsoleOutput += "`r`nERROR`r`n$($_.Exception.Message)`r`n$($_.Exception.Source)`r`n$($_.Exception.StackTrace)`r`n$($_.Exception.TargetSite)"
                }
                finally 
                {
                    $Output.Close()
                }
            } 
            else
            {
                $Response.ContentLength64 = $Buffer.Length
                $Output = $Response.OutputStream
                $Output.Write($Buffer, 0, $Buffer.Length)
                $Output.Close()
            }

            $Response.StatusCode = $ReturnData.StatusCode
            $Response.Close()

            $ReturnData.Url = $Request.Url.LocalPath
            $ReturnData.ConsoleOutput = 'Test console output'

            return $ReturnData
        }
    }

    Process
    {

        for ($i = 0 ; $i -lt $MaxThreads ; $i++) 
        {
            $Pipeline = [PowerShell]::Create()
            $Pipeline.RunspacePool = $Pool
            [void]$Pipeline.AddScript($RequestCallback)

            $Params =   @{ 
                ThreadID        = $i 
                Listener        = $Listener
                AssetsDirectory = $PowerPlex.AssetsDirectory
            }
        
            [void]$Pipeline.AddParameters($Params)

            $Jobs.Add((New-Object -TypeName psobject -Property @{
                Pipeline = $Pipeline
                Job      = $Pipeline.BeginInvoke()
            }))
            
        }
        
        Update-Console -Message "Starting Listener Threads: $($Jobs.Count)" -Sender 'WebServer'
		
        while ($Jobs.Count -gt 0) 
        {   
            $AwaitingRequest = $true
		    while ($AwaitingRequest)
		    {                
		        if ([Console]::KeyAvailable) 
                {
                    $Key = [Console]::ReadKey($true)
                    if (($Key.Modifiers -band [ConsoleModifiers]'control') -and ($Key.Key -eq 'C'))
                    {
                        Write-Warning -Message 'Server terminating...'

                        exit
                    }
                } 	    
        
                $Jobs | % {
                    if ($_.Job.IsCompleted)
				    {
                        $AwaitingRequest = $False
                        $JobIndex = $Jobs.IndexOf($_)
       
                        break
				    }
                }
		    }

            $Results = $Jobs.Item($JobIndex).Pipeline.EndInvoke($Jobs.Item($JobIndex).Job)

            if ($Pipeline.HadErrors)
            {
                $Pipeline.Streams.Error.ReadAll() | % { Write-Error $_ }
            }
            else 
            {
                $Results | % { 
                    Update-Console -Message "Served - $($_.Url) - $($_.ConsoleOutput)" -Sender 'WebServer' 
                }
            }

            $Jobs.Item($JobIndex).Pipeline.Dispose()
            $Jobs.RemoveAt($JobIndex)

            $Pipeline = [PowerShell]::Create()
            $Pipeline.RunspacePool = $Pool
            [void]$Pipeline.AddScript($RequestCallback)
 
            $Params =   @{ 
                ThreadID        = $i 
                Listener        = $Listener
                AssetsDirectory = $PowerPlex.AssetsDirectory
            }
 
            [void]$Pipeline.AddParameters($Params)

            $Jobs.Insert($JobIndex, (New-Object -TypeName psobject -Property @{
                Pipeline = $Pipeline
                Job      = $Pipeline.BeginInvoke()
            }))

        }
    }

    End
    {
        $pool.Close()
    }

}
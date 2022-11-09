function Invoke-PSBuster {
    <#
    .SYNOPSIS
        Template function for multithreading
    .DESCRIPTION
        Parallel iteration function which uses CreateRunspacePool to execute code and return values
    .PARAMETER Array
        [string[]]
        Array of which should be iterated through
    .PARAMETER Arg2
        [string]
        Placeholder parameter to express functionality
    .PARAMETER Timeout
        [int]
        The timeout amount, in milliseconds, before the thread gets discarded
    .OUTPUTS
        [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]
    .EXAMPLE
        $result = Invoke-Parallel -Array (1..10) -Arg2 "asd" -Timeout 120000
#>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        #[ValidateNotNullOrEmpty()]
        [array]
        $DirectoryArray,

        [Parameter(Mandatory = $true)]
        [uri]
        $BaseUri,

        [Parameter(Mandatory = $false)]
        [int]
        $Timeout = 6000
    )

    begin {
        $Parameters = [System.Collections.Concurrent.ConcurrentDictionary[[string], [array]]]::new()
        $jobsList = [System.Collections.Concurrent.ConcurrentBag[System.Collections.Concurrent.ConcurrentDictionary[[string], [object]]]]::new()
        $ResultList = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()

        $RunspacePool = [RunspaceFactory]::CreateRunspacePool(
            [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        )
        [void]$RunspacePool.SetMaxRunspaces([System.Environment]::ProcessorCount)

        # The Thread will create and enter a multithreaded apartment.
        # DCOM communication requires STA ApartmentState!
        $RunspacePool.ApartmentState = [System.Threading.ApartmentState]::MTA
        # UseNewThread for local Runspace, ReuseThread for local RunspacePool, server settings for remote Runspace and RunspacePool
        $RunspacePool.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::Default
        $RunspacePool.Open()

        $httpClient = [System.Net.Http.HttpClient]::new()
        $httpClient.Timeout = [timespan]::FromSeconds(5)
        $httpClient.DefaultRequestVersion = [System.Net.HttpVersion]::Version30
        $httpClient.DefaultVersionPolicy = [System.Net.Http.HttpVersionPolicy]::RequestVersionOrLower
        # "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/107.0.0.0 Safari/537.36"
        $httpClient.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:106.0) Gecko/20100101 Firefox/106.0")
        $httpClient.DefaultRequestHeaders.Accept.Add([System.Net.Http.Headers.MediaTypeWithQualityHeaderValue]::new("application/json"))
        $httpClient.DefaultRequestHeaders.Accept.Add([System.Net.Http.Headers.MediaTypeWithQualityHeaderValue]::new("text/html"))
        $httpClient.DefaultRequestHeaders.Accept.Add([System.Net.Http.Headers.MediaTypeWithQualityHeaderValue]::new("application/xhtml+xml"))
        $httpClient.DefaultRequestHeaders.AcceptEncoding.Add("gzip")
        $httpClient.DefaultRequestHeaders.AcceptEncoding.Add("deflate")
        $httpClient.DefaultRequestHeaders.AcceptEncoding.Add("br")
        #[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls
    }

    process {
        try {
            $count = 0
            $arrayLength = $DirectoryArray.Length
            foreach ($Item in $DirectoryArray) {
                $count++
                [System.Console]::Write("`rProcessing: $count/$arrayLength")
                $Parameters.Pipeline = @($Item, $BaseUri, $httpClient)
                $PowerShell = [PowerShell]::Create()
                $PowerShell.RunspacePool = $RunspacePool

                [void]$PowerShell.AddScript({
                        Param (
                            $Pipeline
                        )
                        try {
                            # Insert some code here and return desired result as a PSCustomObject
                            $fullUri = [uri]::new($Pipeline[1], $Pipeline[0])
                            $request = $Pipeline[2].GetAsync($fullUri)
                            while (! $request.AsyncWaitHandle.WaitOne(100)) {}
                            $result = $request.GetAwaiter().GetResult()
                            return [PSCustomObject]@{
                                Uri    = $fullUri.AbsoluteUri
                                Status = $result.StatusCode
                            }
                        }
                        catch {
                            # Handle errors here
                            return [PSCustomObject]@{
                                Uri          = $fullUri.AbsoluteUri
                                Status       = 'UNKNOWN'
                                ErrorMessage = $_.Exception.Message
                            }
                        }
                        finally {
                            # Handle object disposal here
                        }
                    }, $true) #Setting UseLocalScope to $true fixes scope creep with variables in RunspacePool
                [void]$PowerShell.AddParameters($Parameters)
                $jobDictionary = [System.Collections.Concurrent.ConcurrentDictionary[[string], [object]]]::new()
                $cancellationTokenSource = [System.Threading.CancellationTokenSource]::new($Timeout)
                [void]$jobDictionary.TryAdd('PowerShell', $PowerShell)
                [void]$jobDictionary.TryAdd('Handle', $PowerShell.BeginInvoke())
                [void]$jobDictionary.TryAdd('CancellationToken', $cancellationTokenSource.Token)
                [void]$jobsList.Add($jobDictionary)
            }
        }
        catch {
            throw
        }
    }

    end {
        try {
            while ($true) {
                # This will require a threadsafe collection
                [System.Linq.Enumerable]::Where(
                    $jobsList,
                    [Func[System.Collections.Concurrent.ConcurrentDictionary[[string], [object]], bool]] {
                        param($job) $job.Handle.IsCompleted -eq $true
                    }).ForEach({
                        # Adding the output from scriptblock into $ResultList
                        [void]$ResultList.Add($_.PowerShell.EndInvoke($_.Handle))
                        $_.PowerShell.Dispose()
                        # Clear the dictionary entry.
                        # A better way would be to completely remove it from the list, but ConcurrentBag...
                        [void]$_.Clear()
                    })

                [System.Linq.Enumerable]::Where(
                    $jobsList,
                    [Func[System.Collections.Concurrent.ConcurrentDictionary[[string], [object]], bool]] {
                        param($job) $job.CancellationToken.IsCancellationRequested -eq $true -and $job.Handle.IsCompleted -ne $true
                    }).ForEach({
                        # If calling dispose() on the thread while stopping it.
                        # Will either throw an error or lock up the thread while waiting for the underlying process to finish
                        [void]$_.PowerShell.StopAsync($null, $_.Handle)
                        # Clear the dictionary entry.
                        # A better way would be to completely remove it from the list, but ConcurrentBag...
                        [void]$_.Clear()

                    })

                if ($jobsList.Keys.Count -eq 0) {
                    # Breaks out of the loop to start cleanup
                    break
                }
            }
            return $ResultList
        }
        catch {
            throw
        }
        finally {
            $httpClient.Dispose()
            $cancellationTokenSource.Dispose()
            $jobDictionary.Clear()
            $RunspacePool.Close()
            $RunspacePool.Dispose()
            $jobsList.clear()
            $Parameters.Clear()
            [System.GC]::Collect()
            [System.GC]::WaitForPendingFinalizers()
            [System.GC]::Collect()
        }
    }
}

# big list will throw out of memory exception
$directoryArray = [System.IO.File]::ReadAllLines([System.IO.Path]::Combine($PSScriptRoot, 'directory-list-2.3-big.txt'))
$baseUri = [uri]::new('https://example.com/')
$result = Invoke-PSBuster -DirectoryArray $directoryArray -BaseUri $baseUri
$result | Where-Object {$_.Status -eq [System.Net.HttpStatusCode]::OK}

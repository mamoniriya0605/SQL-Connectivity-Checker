## Copyright (c) Microsoft Corporation.
#Licensed under the MIT license.

#Azure SQL Connectivity Checker

#THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
#WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

using namespace System
using namespace System.Net
using namespace System.net.Sockets
using namespace System.Collections.Generic
using namespace System.Diagnostics

# Parameter region for when script is run directly
# Supports Single, Elastic Pools and Managed Instance (please provide FQDN, MI public endpoint is supported)
# Supports Azure Synapse / Azure SQL Data Warehouse (*.sql.azuresynapse.net / *.database.windows.net)
# Supports Public Cloud (*.database.windows.net), Azure China (*.database.chinacloudapi.cn), Azure Germany (*.database.cloudapi.de) and Azure Government (*.database.usgovcloudapi.net)
$Server = '.database.windows.net' # or any other supported FQDN
$Database = ''  # Set the name of the database you wish to test, 'master' will be used by default if nothing is set
$User = ''  # Set the login username you wish to use, 'AzSQLConnCheckerUser' will be used by default if nothing is set
$Password = ''  # Set the login password you wish to use, 'AzSQLConnCheckerPassword' will be used by default if nothing is set
# In case you want to hide the password (like during a remote session), uncomment the 2 lines below (by removing leading #) and password will be asked during execution
# $Credentials = Get-Credential -Message "Credentials to test connections to the database (optional)" -User $User
# $Password = $Credentials.GetNetworkCredential().password

# Optional parameters (default values will be used if omitted)
$SendAnonymousUsageData = $true  # Set as $true (default) or $false
$RunAdvancedConnectivityPolicyTests = $true  # Set as $true (default) or $false#Set as $true (default) or $false, this will download library needed for running advanced connectivity policy tests
$CollectNetworkTrace = $true  # Set as $true (default) or $false
#EncryptionProtocol = ''  # Supported values: 'Tls 1.0', 'Tls 1.1', 'Tls 1.2'; Without this parameter operating system will choose the best protocol to use

# Parameter region when Invoke-Command -ScriptBlock is used
$parameters = $args[0]
if ($null -ne $parameters) {
    $Server = $parameters['Server']
    $Database = $parameters['Database']
    $User = $parameters['User']
    $Password = $parameters['Password']
    if ($null -ne $parameters['SendAnonymousUsageData']) {
        $SendAnonymousUsageData = $parameters['SendAnonymousUsageData']
    }
    if ($null -ne $parameters['RunAdvancedConnectivityPolicyTests']) {
        $RunAdvancedConnectivityPolicyTests = $parameters['RunAdvancedConnectivityPolicyTests']
    }
    if ($null -ne $parameters['CollectNetworkTrace']) {
        $CollectNetworkTrace = $parameters['CollectNetworkTrace']
    }
    $EncryptionProtocol = $parameters['EncryptionProtocol']
    if ($null -ne $parameters['Local']) {
        $Local = $parameters['Local']
    }
    if ($null -ne $parameters['LocalPath']) {
        $LocalPath = $parameters['LocalPath']
    }
    if ($null -ne $parameters['RepositoryBranch']) {
        $RepositoryBranch = $parameters['RepositoryBranch']
    }
}

$Server = $Server.Trim()
$Server = $Server.Replace('tcp:', '')
$Server = $Server.Replace(',1433', '')
$Server = $Server.Replace(',3342', '')
$Server = $Server.Replace(';', '')

if ($null -eq $User -or '' -eq $User) {
    $User = 'AzSQLConnCheckerUser'
}

if ($null -eq $Password -or '' -eq $Password) {
    $Password = 'AzSQLConnCheckerPassword'
}

if ($null -eq $Database -or '' -eq $Database) {
    $Database = 'master'
}

if ($null -eq $Local) {
    $Local = $false
}

if ($null -eq $RepositoryBranch) {
    $RepositoryBranch = 'master'
}

$CustomerRunningInElevatedMode = $false
if ($PSVersionTable.Platform -eq 'Unix') {
    if ((id -u) -eq 0) {
        $CustomerRunningInElevatedMode = $true
    }
} else {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if ($currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $CustomerRunningInElevatedMode = $true
    }
}

$SQLDBGateways = @(
    New-Object PSObject -Property @{Region = "Australia Central"; Gateways = ("20.36.105.0"); Affected20191014 = $false; TRs = ('tr1', 'tr2', 'tr3'); Cluster = 'australiacentral1-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "Australia Central2"; Gateways = ("20.36.113.0"); Affected20191014 = $false; TRs = ('tr1', 'tr2', 'tr3'); Cluster = 'australiacentral2-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "Australia East"; Gateways = ("13.75.149.87", "40.79.161.1"); Affected20191014 = $false; TRs = ('tr2', 'tr3', 'tr4'); Cluster = 'australiaeast1-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "Australia South East"; Gateways = ("13.73.109.251"); Affected20191014 = $false; TRs = ('tr2', 'tr3', 'tr4'); Cluster = 'australiasoutheast1-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "Brazil South"; Gateways = ("104.41.11.5", "191.233.200.14"); Affected20191014 = $true; TRs = ('tr11', 'tr12', 'tr15'); Cluster = 'brazilsouth1-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "Canada Central"; Gateways = ("40.85.224.249"); Affected20191014 = $false; TRs = ('tr1', 'tr2', 'tr3'); Cluster = 'canadacentral1-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "Canada East"; Gateways = ("40.86.226.166"); Affected20191014 = $false; TRs = ('tr1', 'tr2', 'tr3'); Cluster = 'canadaeast1-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "Central US"; Gateways = ("23.99.160.139", "13.67.215.62", "52.182.137.15", "104.208.21.1"); Affected20191014 = $true; TRs = ('tr4', 'tr8', 'tr9'); Cluster = 'centralus1-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "China East"; Gateways = ("139.219.130.35"); Affected20191014 = $false; TRs = ('tr2', 'tr3'); Cluster = 'chinaeast1-a.worker.database.chinacloudapi.cn'; }
    New-Object PSObject -Property @{Region = "China East 2"; Gateways = ("40.73.82.1"); Affected20191014 = $false; TRs = ('tr1', 'tr5', 'tr11'); Cluster = 'chinaeast2-a.worker.database.chinacloudapi.cn'; }
    New-Object PSObject -Property @{Region = "China North"; Gateways = ("139.219.15.17"); Affected20191014 = $false; TRs = ('tr2', 'tr3'); Cluster = 'chinanorth1-a.worker.database.chinacloudapi.cn'; }
    New-Object PSObject -Property @{Region = "China North 2"; Gateways = ("40.73.50.0"); Affected20191014 = $false; TRs = ('tr1', 'tr67', 'tr119'); Cluster = 'chinanorth2-a.worker.database.chinacloudapi.cn'; }
    New-Object PSObject -Property @{Region = "East Asia"; Gateways = ("191.234.2.139", "52.175.33.150", "13.75.32.4"); Affected20191014 = $true; TRs = ('tr4', 'tr8', 'tr9'); Cluster = 'eastasia1-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "East US"; Gateways = ("191.238.6.43", "40.121.158.30", "40.79.153.12", "40.78.225.32"); Affected20191014 = $true; TRs = ('tr7', 'tr8', 'tr9'); Cluster = 'eastus1-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "East US 2"; Gateways = ("191.239.224.107", "40.79.84.180", "52.177.185.181", "52.167.104.0", "104.208.150.3"); Affected20191014 = $true; TRs = ('tr10', 'tr8', 'tr9'); Cluster = 'eastus2-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "France Central"; Gateways = ("40.79.137.0", "40.79.129.1"); Affected20191014 = $false; TRs = ('tr1', 'tr7', 'tr8'); Cluster = 'francecentral1-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "Germany Central"; Gateways = ("51.4.144.100"); Affected20191014 = $false; TRs = ('tr1', 'tr2', 'tr3'); Cluster = 'germanycentral1-a.worker.database.cloudapi.de'; }
    New-Object PSObject -Property @{Region = "Germany North East"; Gateways = ("51.5.144.179"); Affected20191014 = $false; TRs = ('tr1', 'tr2', 'tr3'); Cluster = 'germanynortheast1-a.worker.database.cloudapi.de'; }
    New-Object PSObject -Property @{Region = "Germany North"; Gateways = ("51.116.56.0"); Affected20191014 = $false; TRs = ('tr1', 'tr3', 'tr4'); Cluster = 'germanynorth1-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "Germany West Central"; Gateways = ("51.116.152.0"); Affected20191014 = $false; TRs = ('tr1', 'tr3', 'tr4'); Cluster = 'germanywestcentral1-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "India Central"; Gateways = ("104.211.96.159"); Affected20191014 = $false; TRs = ('tr1', 'tr3', 'tr16'); Cluster = 'indiacentral1-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "India South"; Gateways = ("104.211.224.146"); Affected20191014 = $false; TRs = ('tr1', 'tr2', 'tr5'); Cluster = 'indiasouth1-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "India West"; Gateways = ("104.211.160.80"); Affected20191014 = $false; TRs = ('tr41', 'tr42', 'tr54'); Cluster = 'indiawest1-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "Japan East"; Gateways = ("191.237.240.43", "13.78.61.196", "40.79.184.8", "40.79.192.5"); Affected20191014 = $true; TRs = ('tr4', 'tr5', 'tr9'); Cluster = 'japaneast1-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "Japan West"; Gateways = ("191.238.68.11", "104.214.148.156", "40.74.97.10"); Affected20191014 = $true; TRs = ('tr11', 'tr12', 'tr13'); Cluster = 'japanwest1-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "Korea Central"; Gateways = ("52.231.32.42"); Affected20191014 = $false; TRs = ('tr1', 'tr10', 'tr118'); Cluster = 'koreacentral1-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "Korea South"; Gateways = ("52.231.200.86"); Affected20191014 = $false; TRs = ('tr1', 'tr3', 'tr75'); Cluster = 'koreasouth1-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "North Central US"; Gateways = ("23.98.55.75", "23.96.178.199", "52.162.104.33"); Affected20191014 = $true; TRs = ('tr7', 'tr8', 'tr9'); Cluster = 'northcentralus1-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "North Europe"; Gateways = ("191.235.193.75", "40.113.93.91", "52.138.224.1"); Affected20191014 = $true; TRs = ('tr7', 'tr8', 'tr9'); Cluster = 'northeurope1-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "South Africa North"; Gateways = ("102.133.152.0"); Affected20191014 = $false; TRs = ('tr1', 'tr2', 'tr4'); Cluster = 'southafricanorth1-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "South Africa West"; Gateways = ("102.133.24.0"); Affected20191014 = $false; TRs = ('tr1', 'tr2', 'tr3'); Cluster = 'southafricawest1-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "South Central US"; Gateways = ("23.98.162.75", "13.66.62.124", "104.214.16.32"); Affected20191014 = $true; TRs = ('tr10', 'tr8', 'tr9'); Cluster = 'southcentralus1-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "South East Asia"; Gateways = ("23.100.117.95", "104.43.15.0", "40.78.232.3"); Affected20191014 = $true; TRs = ('tr7', 'tr8', 'tr4'); Cluster = 'southeastasia1-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "UAE Central"; Gateways = ("20.37.72.64"); Affected20191014 = $false; TRs = ('tr1', 'tr4'); Cluster = 'uaecentral1-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "UAE North"; Gateways = ("65.52.248.0"); Affected20191014 = $false; TRs = ('tr1', 'tr4', 'tr9'); Cluster = 'uaenorth1-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "UK South"; Gateways = ("51.140.184.11"); Affected20191014 = $false; TRs = ('tr1', 'tr2', 'tr3'); Cluster = 'uksouth1-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "UK West"; Gateways = ("51.141.8.11"); Affected20191014 = $false; TRs = ('tr1', 'tr2', 'tr4'); Cluster = 'ukwest1-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "West Central US"; Gateways = ("13.78.145.25"); Affected20191014 = $false; TRs = ('tr1', 'tr2', 'tr3'); Cluster = 'westcentralus1-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "West Europe"; Gateways = ("191.237.232.75", "40.68.37.158", "104.40.168.105"); Affected20191014 = $true; TRs = ('tr7', 'tr8', 'tr9'); Cluster = 'westeurope1-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "West US"; Gateways = ("23.99.34.75", "104.42.238.205", "13.86.216.196"); Affected20191014 = $true; TRs = ('tr1', 'tr2', 'tr3'); Cluster = 'westus1-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "West US 2"; Gateways = ("13.66.226.202"); Affected20191014 = $false; TRs = ('tr1', 'tr2', 'tr3'); Cluster = 'westus2-a.worker.database.windows.net'; }
    New-Object PSObject -Property @{Region = "US DoD East"; Gateways = ("52.181.160.27"); TRs = ('tr3', 'tr4', 'tr5'); Cluster = 'usdodeast1-a.worker.database.usgovcloudapi.net'; }
    New-Object PSObject -Property @{Region = "US DoD Central"; Gateways = ("52.182.88.34"); TRs = ('tr1', 'tr4', 'tr7'); Cluster = 'usdodcentral1-a.worker.database.usgovcloudapi.net'; }
    New-Object PSObject -Property @{Region = "US Gov Iowa"; Gateways = ("13.72.189.52"); TRs = ('tr1'); Cluster = 'usgovcentral1-a.worker.database.usgovcloudapi.net'; }
    New-Object PSObject -Property @{Region = "US Gov Texas"; Gateways = ("52.238.116.32"); TRs = ('tr1', 'tr2', 'tr29'); Cluster = 'usgovsouthcentral1-a.worker.database.usgovcloudapi.net'; }
    New-Object PSObject -Property @{Region = "US Gov Arizona"; Gateways = ("52.244.48.33"); TRs = ('tr1', 'tr4', 'tr13'); Cluster = 'usgovsouthwest1-a.worker.database.usgovcloudapi.net'; }
    New-Object PSObject -Property @{Region = "US Gov Virginia"; Gateways = ("13.72.48.140"); TRs = ('tr1', 'tr3', 'tr5'); Cluster = 'usgoveast1-a.worker.database.usgovcloudapi.net'; }
)

$TRPorts = @('11000', '11001', '11003', '11005', '11006')

$networkingIssueMessage = ' This issue indicates a problem with the networking configuration. If this is related with on-premises resources, the networking team from customer side should be engaged. If this is between Azure resources, Azure Networking team should be engaged.'


# PowerShell Container Image Support Start

if (!$(Get-Command 'Test-NetConnection' -errorAction SilentlyContinue)) {
    function Test-NetConnection {
        param(
            [Parameter(Position = 0, Mandatory = $true)] $HostName,
            [Parameter(Mandatory = $true)] $Port
        );
        process {
            $client = [TcpClient]::new()
            
            try {
                $client.Connect($HostName, $Port)
                $result = @{TcpTestSucceeded = $true; InterfaceAlias = 'Unsupported' }
            }
            catch {
                $result = @{TcpTestSucceeded = $false; InterfaceAlias = 'Unsupported' }
            }

            $client.Dispose()

            return $result
        }
    }
}

if (!$(Get-Command 'Resolve-DnsName' -errorAction SilentlyContinue)) {
    function Resolve-DnsName {
        param(
            [Parameter(Position = 0)] $Name,
            [Parameter()] $Server,
            [switch] $CacheOnly,
            [switch] $DnsOnly,
            [switch] $NoHostsFile
        );
        process {
            # ToDo: Add support
            Write-Host "WARNING: Current environment doesn't support multiple DNS sources."
            return @{ IPAddress = [Dns]::GetHostAddresses($Name).IPAddressToString };
        }
    }
}

if (!$(Get-Command 'Get-NetAdapter' -errorAction SilentlyContinue)) {
    function Get-NetAdapter {
        param(
            [Parameter(Position = 0, Mandatory = $true)] $HostName,
            [Parameter(Mandatory = $true)] $Port
        );
        process {
            Write-Host 'Unsupported'
        }
    }
}

if (!$(Get-Command 'netsh' -errorAction SilentlyContinue) -and $CollectNetworkTrace) {
    Write-Host "WARNING: Current environment doesn't support network trace capture. This option is now disabled!"
    $CollectNetworkTrace = $false
}


# PowerShell Container Image Support End

function PrintDNSResults($dnsResult, [string] $dnsSource) {
    if ($dnsResult) {
        Write-Host ' Found DNS record in' $dnsSource '(IP Address:'$dnsResult.IPAddress')'
    }
    else {
        Write-Host ' Could not find DNS record in' $dnsSource
    }
}

function ValidateDNS([String] $Server) {
    Try {
        Write-Host 'Validating DNS record for' $Server -ForegroundColor Green

        $DNSfromHosts = Resolve-DnsName -Name $Server -CacheOnly -ErrorAction SilentlyContinue
        PrintDNSResults $DNSfromHosts 'hosts file'

        $DNSfromCache = Resolve-DnsName -Name $Server -NoHostsFile -CacheOnly -ErrorAction SilentlyContinue
        PrintDNSResults $DNSfromCache 'cache'

        $DNSfromCustomerServer = Resolve-DnsName -Name $Server -DnsOnly -ErrorAction SilentlyContinue
        PrintDNSResults $DNSfromCustomerServer 'DNS server'

        $DNSfromAzureDNS = Resolve-DnsName -Name $Server -DnsOnly -Server 208.67.222.222 -ErrorAction SilentlyContinue
        PrintDNSResults $DNSfromAzureDNS 'Open DNS'
    }
    Catch {
        Write-Host "Error at ValidateDNS" -Foreground Red
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function IsManagedInstance([String] $Server) {
    return [bool]((($Server.ToCharArray() | Where-Object { $_ -eq '.' } | Measure-Object).Count) -ge 4)
}

function IsSqlOnDemand([String] $Server) {
    return [bool]($Server -match '-ondemand.')
}

function IsManagedInstancePublicEndpoint([String] $Server) {
    return [bool]((IsManagedInstance $Server) -and ($Server -match '.public.'))
}

function SanitizeString([String] $param) {
    return ($param.Replace('\', '_').Replace('/', '_').Replace("[", "").Replace("]", "").Replace('.', '_').Replace(':', '_').Replace(',', '_'))
}

function FilterTranscript() {
    Try {
        if ($canWriteFiles) {
            $lineNumber = (Select-String -Path $file -Pattern '..TranscriptStart..').LineNumber
            if ($lineNumber) {
                (Get-Content $file | Select-Object -Skip $lineNumber) | Set-Content $file
            }
        }
    }
    Catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function TestConnectionToDatabase($Server, $gatewayPort, $Database, $User, $Password) {
    Write-Host
    Write-Host ([string]::Format("Testing connecting to {0} database:", $Database)) -ForegroundColor Green
    Try {
        $masterDbConnection = [System.Data.SqlClient.SQLConnection]::new()
        $masterDbConnection.ConnectionString = [string]::Format("Server=tcp:{0},{1};Initial Catalog={2};Persist Security Info=False;User ID={3};Password={4};MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;",
            $Server, $gatewayPort, $Database, $User, $Password)
        $masterDbConnection.Open()
        Write-Host ([string]::Format(" The connection attempt succeeded", $Database))
        return $true
    }
    catch [System.Data.SqlClient.SqlException] {
        if ($_.Exception.Number -eq 18456) {
            if ($User -eq 'AzSQLConnCheckerUser') {
                if ($Database -eq 'master') {
                    Write-Host ([string]::Format(" Dummy login attempt reached '{0}' database, login failed as expected.", $Database))
                }
                else {
                    Write-Host ([string]::Format(" Dummy login attempt on '{0}' database resulted in login failure.", $Database))
                    Write-Host ' This was either expected due to dummy credentials being used, or database does not exist, which also results in login failed.'
                }
            }
            else {
                Write-Host ([string]::Format(" Login attempt reached '{0}' database but login failed for user '{1}'", $Database, $User)) -ForegroundColor Yellow
            }
        }
        else {
            Write-Host ' Error: '$_.Exception.Number 'State:'$_.Exception.State ':' $_.Exception.Message -ForegroundColor Yellow
            if ($_.Exception.Number -eq 40532 -and $gatewayPort -eq 3342) {
                Write-Host ' You seem to be trying to connect to MI with Public Endpoint disabled' -ForegroundColor Red
                Write-Host ' Learn how to configure public endpoint at https://docs.microsoft.com/en-us/azure/sql-database/sql-database-managed-instance-public-endpoint-configure' -ForegroundColor Red
            }
        }
        return $false
    }
    Catch {
        Write-Host $_.Exception.Message -ForegroundColor Yellow
        return $false
    }
}

function PrintLocalNetworkConfiguration() {
    if (![System.Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()) {
        Write-Host "There's no network connection available!" -ForegroundColor Red
        throw
    }

    $computerProperties = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
    $networkInterfaces = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()

    Write-Host 'Interface information for '$computerProperties.HostName'.'$networkInterfaces.DomainName -ForegroundColor Green

    foreach ($networkInterface in $networkInterfaces) {
        if ($networkInterface.NetworkInterfaceType -eq 'Loopback') {
            continue
        }

        $properties = $networkInterface.GetIPProperties()

        Write-Host ' Interface name: ' $networkInterface.Name
        Write-Host ' Interface description: ' $networkInterface.Description
        Write-Host ' Interface type: ' $networkInterface.NetworkInterfaceType
        Write-Host ' Operational status: ' $networkInterface.OperationalStatus

        Write-Host ' Unicast address list:'
        Write-Host $('  ' + [String]::Join([Environment]::NewLine + '  ', [System.Linq.Enumerable]::Select($properties.UnicastAddresses, [Func[System.Net.NetworkInformation.UnicastIPAddressInformation, IPAddress]] { $args[0].Address })))

        Write-Host ' DNS server address list:'
        Write-Host $('  ' + [String]::Join([Environment]::NewLine + '  ', $properties.DnsAddresses))

        Write-Host
    }
}

function CheckAffected20191014($gateway) {
    $isCR1 = $CRaddress -eq $gateway.Gateways[0]
    if ($gateway.Affected20191014) {
        Write-Host 'This region WILL be affected by the Gateway migration starting at Oct 14 2019!' -ForegroundColor Yellow
        if ($isCR1) {
            Write-Host 'and this server is running on one of the affected Gateways' -ForegroundColor Red
        }
        else {
            Write-Host 'but this server is NOT running on one of the affected Gateways (never was or already migrated)' -ForegroundColor Green
            Write-Host 'Please check other servers you may have in the region' -ForegroundColor Yellow
        }
    }
    else {
        Write-Host 'This region will NOT be affected by the Oct 14 2019 Gateway migration!' -ForegroundColor Green
    }
    Write-Host
}

function RunSqlMIPublicEndpointConnectivityTests($resolvedAddress) {
    Try {
        Write-Host 'Detected as Managed Instance using Public Endpoint' -ForegroundColor Yellow

        Write-Host 'Public Endpoint connectivity test:' -ForegroundColor Green
        $testResult = Test-NetConnection $resolvedAddress -Port 3342 -WarningAction SilentlyContinue

        if ($testResult.TcpTestSucceeded) {
            Write-Host ' -> TCP test succeed' -ForegroundColor Green

            PrintAverageConnectionTime $resolvedAddress 3342
        }
        else {
            Write-Host ' -> TCP test FAILED' -ForegroundColor Red
            Write-Host ' Please make sure you fix the connectivity from this machine to' $resolvedAddress':3342' -ForegroundColor Red
            Write-Host $networkingIssueMessage -ForegroundColor Yellow
        }
    }
    Catch {
        Write-Host "Error at RunSqlMIPublicEndpointConnectivityTests" -Foreground Red
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function RunSqlMIVNetConnectivityTests($resolvedAddress) {
    Try {
        Write-Host 'Detected as Managed Instance' -ForegroundColor Yellow
        Write-Host
        Write-Host 'Gateway connectivity tests:' -ForegroundColor Green
        $testResult = Test-NetConnection $resolvedAddress -Port 1433 -WarningAction SilentlyContinue

        if ($testResult.TcpTestSucceeded) {
            Write-Host ' -> TCP test succeed' -ForegroundColor Green
            PrintAverageConnectionTime $resolvedAddress 1433
            return $true
        }
        else {
            Write-Host ' -> TCP test FAILED' -ForegroundColor Red
            Write-Host ' Please make sure you fix the connectivity from this machine to' $resolvedAddress':1433' -ForegroundColor Red
            Write-Host ' See more about connectivity architecture at https://docs.microsoft.com/en-us/azure/sql-database/sql-database-managed-instance-connectivity-architecture' -ForegroundColor Red
            Write-Host $networkingIssueMessage -ForegroundColor Yellow
            Write-Host
            Write-Host ' Trying to get IP routes for interface:' $testResult.InterfaceAlias
            Get-NetAdapter $testResult.InterfaceAlias -ErrorAction SilentlyContinue -ErrorVariable ProcessError | Get-NetRoute
            If ($ProcessError) {
                Write-Host '  Could not to get IP routes for this interface'
            }
            Write-Host
            return $false
        }
    }
    Catch {
        Write-Host "Error at RunSqlMIVNetConnectivityTests" -Foreground Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        return $false
    }
}

function PrintAverageConnectionTime($addressList, $port) {
    Write-Host 'Printing average connection times for 5 connection attempts:' -ForegroundColor Green
    $stopwatch = [StopWatch]::new()

    foreach ($ipAddress in $addressList) {
        [double]$sum = 0
        [int]$numFailed = 0
        [int]$numSuccessful = 0

        for ($i = 0; $i -lt 5; $i++) {
            $client = [TcpClient]::new()
            try {
                $stopwatch.Restart()
                $client.Connect($ipAddress, $port)
                $stopwatch.Stop()

                $sum += $stopwatch.ElapsedMilliseconds

                $numSuccessful++
            }
            catch {
                $numFailed++
            }
            $client.Dispose()
        }

        $avg = 0
        if ($numSuccessful -ne 0) {
            $avg = $sum / $numSuccessful
        }

        $ilb = ''
        if ((IsManagedInstance $Server) -and !(IsManagedInstancePublicEndpoint $Server) -and ($ipAddress -eq $resolvedAddress)) {
            $ilb = ' [ilb]'
        }

        Write-Host '  IP Address:'$ipAddress'  Port:'$port'  Successful connections:'$numSuccessful'  Failed connections:'$numFailed'  Average response time:'$avg' ms '$ilb
    }
}

function RunSqlDBConnectivityTests($resolvedAddress) {

    if (IsSqlOnDemand $Server) {
        Write-Host 'Detected as SQL on-demand endpoint' -ForegroundColor Yellow
    }
    else {
        Write-Host 'Detected as SQL DB/DW Server' -ForegroundColor Yellow
    }

    $gateway = $SQLDBGateways | Where-Object { $_.Gateways -eq $resolvedAddress }
    if (!$gateway) {
        Write-Host ' ERROR:' $resolvedAddress 'is not a valid gateway address' -ForegroundColor Red
        Write-Host ' Please review your DNS configuration, it should resolve to a valid gateway address' -ForegroundColor Red
        Write-Host ' See the valid gateway addresses at https://docs.microsoft.com/en-us/azure/sql-database/sql-database-connectivity-architecture#azure-sql-database-gateway-ip-addresses' -ForegroundColor Red
        Write-Error '' -ErrorAction Stop
    }
    Write-Host ' The server' $Server 'is running on ' -ForegroundColor White -NoNewline
    Write-Host $gateway.Region -ForegroundColor Yellow

    Write-Host
    Write-Host 'Gateway connectivity tests:' -ForegroundColor Green
    foreach ($gatewayAddress in $gateway.Gateways) {
        Write-Host ' Testing (gateway) connectivity to' $gatewayAddress':'1433 -ForegroundColor White -NoNewline
        $testResult = Test-NetConnection $gatewayAddress -Port 1433 -WarningAction SilentlyContinue

        if ($testResult.TcpTestSucceeded) {
            Write-Host ' -> TCP test succeed' -ForegroundColor Green

            PrintAverageConnectionTime $gatewayAddress 1433
        }
        else {
            Write-Host ' -> TCP test FAILED' -ForegroundColor Red
            Write-Host ' Please make sure you fix the connectivity from this machine to' $gatewayAddress':1433 to avoid issues!' -ForegroundColor Red
            Write-Host $networkingIssueMessage -ForegroundColor Yellow
            Write-Host
            Write-Host ' IP routes for interface:' $testResult.InterfaceAlias
            Get-NetAdapter $testResult.InterfaceAlias | Get-NetRoute
            tracert -h 10 $Server
        }
    }

    if ($gateway.TRs -and $gateway.Cluster -and $gateway.Cluster.Length -gt 0 ) {
        Write-Host
        Write-Host 'Redirect Policy related tests:' -ForegroundColor Green
        $redirectSucceeded = 0
        $redirectTests = 0
        foreach ($tr in $gateway.TRs | Where-Object { $_ -ne '' }) {
            foreach ($port in $TRPorts) {
                $addr = [string]::Format("{0}.{1}", $tr, $gateway.Cluster)
                Write-Host ' Tested (redirect) connectivity to' $addr':'$port -ForegroundColor White -NoNewline
                $testRedirectResults = Test-NetConnection $addr -Port $port -WarningAction SilentlyContinue
                if ($testRedirectResults.TcpTestSucceeded) {
                    $redirectTests += 1
                    $redirectSucceeded += 1
                    Write-Host ' -> TCP test succeeded' -ForegroundColor Green
                }
                else {
                    $redirectTests += 1
                    Write-Host ' -> TCP test FAILED' -ForegroundColor Red
                }
            }
        }
        Write-Host ' Tested (redirect) connectivity' $redirectTests 'times and' $redirectSucceeded 'of them succeeded' -ForegroundColor Yellow
        if ($redirectTests -gt 0) {
            Write-Host ' Please note this was just some tests to check connectivity using the 11000-11999 port range, not your database' -ForegroundColor Yellow
            if (IsSqlOnDemand $Server) {
                Write-Host ' Some tests may even fail and not be a problem since ports tested here are static and SQL on-demand is a dynamic serverless environment.' -ForegroundColor Yellow
            }
            else {
                Write-Host ' Some tests may even fail and not be a problem since ports tested here are static and SQL DB is a dynamic environment.' -ForegroundColor Yellow
            }
            if ($redirectSucceeded / $redirectTests -ge 0.5 ) {
                Write-Host ' Based on the result it is likely the Redirect Policy will work from this machine' -ForegroundColor Green
            }
            else {
                Write-Host ' Based on the result the Redirect Policy MAY NOT work from this machine, this can be expected for connections from outside Azure' -ForegroundColor Red
            }
        }
        Write-Host ' Please check more about Azure SQL Connectivity Architecture at https://docs.microsoft.com/en-us/azure/sql-database/sql-database-connectivity-architecture' -ForegroundColor Yellow
    }
}

function RunConnectivityPolicyTests($port) {
    Write-Host
    Write-Host 'Advanced connectivity policy tests:' -ForegroundColor Green

    # Check removed
    #if (!$CustomerRunningInElevatedMode) {
    #    Write-Host ' Powershell must be run as an administrator to run advanced connectivity policy tests!' -ForegroundColor Yellow
    #    return
    #}

    if ($(Get-ExecutionPolicy) -eq 'Restricted') {
        Write-Host ' Advanced connectivity policy tests cannot be run because of current execution policy (Restricted)!' -ForegroundColor Yellow
        Write-Host ' Please use Set-ExecutionPolicy to allow scripts to run on this system!' -ForegroundColor Yellow
        return
    }

    $jobParameters = @{
        Server             = $Server
        Database           = $Database
        Port               = $port
        User               = $User
        Password           = $Password
        EncryptionProtocol = $EncryptionProtocol
        RepositoryBranch   = $RepositoryBranch
        Local              = $Local
        LocalPath          = $LocalPath
    }

    if (Test-Path "$env:TEMP\AzureSQLConnectivityChecker\") {
        Remove-Item $env:TEMP\AzureSQLConnectivityChecker -Recurse -Force
    }

    New-Item "$env:TEMP\AzureSQLConnectivityChecker\" -ItemType directory | Out-Null

    if ($Local) {
        Copy-Item -Path $($LocalPath + './AdvancedConnectivityPolicyTests.ps1') -Destination "$env:TEMP\AzureSQLConnectivityChecker\AdvancedConnectivityPolicyTests.ps1"
    }
    else {
        Invoke-WebRequest -Uri $('https://raw.githubusercontent.com/Azure/SQL-Connectivity-Checker/' + $RepositoryBranch + '/AdvancedConnectivityPolicyTests.ps1') -OutFile "$env:TEMP\AzureSQLConnectivityChecker\AdvancedConnectivityPolicyTests.ps1" -UseBasicParsing
    }

    $job = Start-Job -ArgumentList $jobParameters -FilePath "$env:TEMP\AzureSQLConnectivityChecker\AdvancedConnectivityPolicyTests.ps1"
    Wait-Job $job | Out-Null
    Receive-Job -Job $job
    Remove-Item $env:TEMP\AzureSQLConnectivityChecker -Recurse -Force
}

function SendAnonymousUsageData {
    try {
        #Despite computername and username will be used to calculate a hash string, this will keep you anonymous but allow us to identify multiple runs from the same user
        $StringBuilderHash = [System.Text.StringBuilder]::new()
        
        $text = $env:computername + $env:username
        if ([string]::IsNullOrEmpty($text)) {
            $text = $Host.InstanceId
        }
        
        [System.Security.Cryptography.HashAlgorithm]::Create("MD5").ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text)) | ForEach-Object {
            [Void]$StringBuilderHash.Append($_.ToString("x2"))
        }

        $body = New-Object PSObject `
        | Add-Member -PassThru NoteProperty name 'Microsoft.ApplicationInsights.Event' `
        | Add-Member -PassThru NoteProperty time $([System.dateTime]::UtcNow.ToString('o')) `
        | Add-Member -PassThru NoteProperty iKey "a75c333b-14cb-4906-aab1-036b31f0ce8a" `
        | Add-Member -PassThru NoteProperty tags (New-Object PSObject | Add-Member -PassThru NoteProperty 'ai.user.id' $StringBuilderHash.ToString()) `
        | Add-Member -PassThru NoteProperty data (New-Object PSObject `
            | Add-Member -PassThru NoteProperty baseType 'EventData' `
            | Add-Member -PassThru NoteProperty baseData (New-Object PSObject `
                | Add-Member -PassThru NoteProperty ver 2 `
                | Add-Member -PassThru NoteProperty name '1.4'));

        $body = $body | ConvertTo-JSON -depth 5;
        Invoke-WebRequest -Uri 'https://dc.services.visualstudio.com/v2/track' -Method 'POST' -UseBasicParsing -body $body > $null
    }
    catch {
        Write-Host 'Error sending anonymous usage data:'
        Write-Host $_.Exception.Message
    }
}

$ProgressPreference = "SilentlyContinue";

if ([string]::IsNullOrEmpty($env:TEMP)) {
    $env:TEMP = '/tmp';
}

try {
    Clear-Host
    $canWriteFiles = $true
    try {
        $logsFolderName = 'AzureSQLConnectivityCheckerResults'
        Set-Location -Path $env:TEMP
        If (!(Test-Path $logsFolderName)) {
            New-Item $logsFolderName -ItemType directory | Out-Null
            Write-Host 'The folder' $logsFolderName 'was created'
        }
        else {
            Write-Host 'The folder' $logsFolderName 'already exists'
        }
        Set-Location $logsFolderName
        $outFolderName = [System.DateTime]::Now.ToString('yyyyMMddTHHmmss')
        New-Item $outFolderName -ItemType directory | Out-Null
        Set-Location $outFolderName

        $file = '.\Log_' + (SanitizeString ($Server.Replace('.database.windows.net', ''))) + '_' + (SanitizeString $Database) + '_' + [System.DateTime]::Now.ToString('yyyyMMddTHHmmss') + '.txt'
        Start-Transcript -Path $file
        Write-Host '..TranscriptStart..'
    }
    catch {
        $canWriteFiles = $false
        Write-Host Warning: Cannot write log file -ForegroundColor Yellow
    }

    if ($SendAnonymousUsageData) {
        SendAnonymousUsageData
    }

    try {
        Write-Host '******************************************' -ForegroundColor Green
        Write-Host '  Azure SQL Connectivity Checker v1.5  ' -ForegroundColor Green
        Write-Host '******************************************' -ForegroundColor Green
        Write-Host
        Write-Host 'Parameters' -ForegroundColor Yellow
        Write-Host ' Server:' $Server -ForegroundColor Yellow
        if ($null -ne $Database) {
            Write-Host ' Database:' $Database -ForegroundColor Yellow
        }
        if ($null -ne $RunAdvancedConnectivityPolicyTests) {
            Write-Host ' RunAdvancedConnectivityPolicyTests:' $RunAdvancedConnectivityPolicyTests -ForegroundColor Yellow
        }
        if ($null -ne $CollectNetworkTrace) {
            Write-Host ' CollectNetworkTrace:' $CollectNetworkTrace -ForegroundColor Yellow
        }
        if ($null -ne $EncryptionProtocol) {
            Write-Host ' EncryptionProtocol:' $EncryptionProtocol -ForegroundColor Yellow
        }
        Write-Host

        if (!$Server -or $Server.Length -eq 0) {
            Write-Host 'The $Server parameter is empty' -ForegroundColor Red -BackgroundColor Yellow
            Write-Host 'Please see more details about how to use this tool at https://github.com/Azure/SQL-Connectivity-Checker' -ForegroundColor Red -BackgroundColor Yellow
            Write-Host
            throw
        }

        if (!$Server.EndsWith('.database.windows.net') `
                -and !$Server.EndsWith('.database.cloudapi.de') `
                -and !$Server.EndsWith('.database.chinacloudapi.cn') `
                -and !$Server.EndsWith('.database.usgovcloudapi.net') `
                -and !$Server.EndsWith('.sql.azuresynapse.net')) {
            $Server = $Server + '.database.windows.net'
        }

        #Print local network configuration
        PrintLocalNetworkConfiguration

        if ($canWriteFiles -and $CollectNetworkTrace) {
            if (!$CustomerRunningInElevatedMode) {
                Write-Host ' Powershell must be run as an administrator in order to collect network trace!' -ForegroundColor Yellow
                $netWorkTraceStarted = $false
            }
            else {
                $traceFileName = (Get-Location).Path + '\NetworkTrace_' + [System.DateTime]::Now.ToString('yyyyMMddTHHmmss') + '.etl'
                $startNetworkTrace = "netsh trace start persistent=yes capture=yes tracefile=$traceFileName"
                Invoke-Expression $startNetworkTrace
                $netWorkTraceStarted = $true
            }
        }

        ValidateDNS $Server

        try {
            $dnsResult = [System.Net.DNS]::GetHostEntry($Server)
        }
        catch {
            Write-Host ' ERROR: Name resolution of' $Server 'failed' -ForegroundColor Red
            Write-Host ' Please make sure the server name FQDN is correct and that your machine can resolve it.' -ForegroundColor Red
            Write-Host ' Failure to resolve domain name for your logical server is almost always the result of specifying an invalid/misspelled server name,' -ForegroundColor Red
            Write-Host ' or a client-side networking issue that you will need to pursue with your local network administrator.' -ForegroundColor Red
            Write-Error '' -ErrorAction Stop
        }
        $resolvedAddress = $dnsResult.AddressList[0].IPAddressToString
        $dbPort = 1433

        #Run connectivity tests
        Write-Host
        if (IsManagedInstance $Server) {
            if (IsManagedInstancePublicEndpoint $Server) {
                RunSqlMIPublicEndpointConnectivityTests $resolvedAddress
                $dbPort = 3342
            }
            else {
                if (!(RunSqlMIVNetConnectivityTests $resolvedAddress)) {
                    throw
                }
            }
        }
        else {
            RunSqlDBConnectivityTests $resolvedAddress
        }

        #Test connection policy
        if ($RunAdvancedConnectivityPolicyTests) {
            RunConnectivityPolicyTests $dbPort
        }

        $customDatabaseNameWasSet = $Database -and $Database.Length -gt 0 -and $Database -ne 'master'

        #Test master database
        $canConnectToMaster = TestConnectionToDatabase $Server $dbPort 'master' $User $Password

        if ($customDatabaseNameWasSet) {
            if ($canConnectToMaster) {
                Write-Host ' Checking if' $Database 'exist in sys.databases:' -ForegroundColor White
                $masterDbConnection = [System.Data.SqlClient.SQLConnection]::new()
                $masterDbConnection.ConnectionString = [string]::Format("Server=tcp:{0},{1};Initial Catalog='master';Persist Security Info=False;User ID={2};Password={3};MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;",
                    $Server, $dbPort, $User, $Password)
                $masterDbConnection.Open()

                $masterDbCommand = New-Object System.Data.SQLClient.SQLCommand
                $masterDbCommand.Connection = $masterDbConnection

                $masterDbCommand.CommandText = "select count(*) C from sys.databases where name = '" + $Database + "'"
                $masterDbResult = $masterDbCommand.ExecuteReader()
                $masterDbResultDataTable = new-object 'System.Data.DataTable'
                $masterDbResultDataTable.Load($masterDbResult)

                if ($masterDbResultDataTable.Rows[0].C -eq 0) {
                    Write-Host ' ERROR:' $Database 'was not found in sys.databases!' -ForegroundColor Red
                    Write-Host ' Please confirm the database name is correct and/or look at the operation logs to see if the database has been dropped by another user.' -ForegroundColor Red
                }
                else {
                    Write-Host ' ' $Database was found in sys.databases of master database -ForegroundColor Green

                    #Test database from parameter
                    if ($customDatabaseNameWasSet) {
                        TestConnectionToDatabase $Server $dbPort $Database $User $Password | Out-Null
                    }
                }
            }
            else {
                #Test database from parameter anyway
                if ($customDatabaseNameWasSet) {
                    TestConnectionToDatabase $Server $dbPort $Database $User $Password | Out-Null
                }
            }
        }

        Write-Host
        Write-Host 'Test endpoints for AAD Password and Integrated Authentication:' -ForegroundColor Green
        Write-Host ' Tested connectivity to login.windows.net:443' -ForegroundColor White -NoNewline
        $testResults = Test-NetConnection 'login.windows.net' -Port 443 -WarningAction SilentlyContinue
        if ($testResults.TcpTestSucceeded) {
            Write-Host ' -> TCP test succeeded' -ForegroundColor Green
        }
        else {
            Write-Host ' -> TCP test FAILED' -ForegroundColor Red
        }

        Write-Host
        Write-Host 'Test endpoints for Universal with MFA authentication:' -ForegroundColor Green
        Write-Host ' Tested connectivity to login.microsoftonline.com:443' -ForegroundColor White -NoNewline
        $testResults = Test-NetConnection 'login.microsoftonline.com' -Port 443 -WarningAction SilentlyContinue
        if ($testResults.TcpTestSucceeded) {
            Write-Host ' -> TCP test succeeded' -ForegroundColor Green
        }
        else {
            Write-Host ' -> TCP test FAILED' -ForegroundColor Red
        }

        Write-Host ' Tested connectivity to secure.aadcdn.microsoftonline-p.com:443' -ForegroundColor White -NoNewline
        $testResults = Test-NetConnection 'secure.aadcdn.microsoftonline-p.com' -Port 443 -WarningAction SilentlyContinue
        if ($testResults.TcpTestSucceeded) {
            Write-Host ' -> TCP test succeeded' -ForegroundColor Green
        }
        else {
            Write-Host ' -> TCP test FAILED' -ForegroundColor Red
        }

        Write-Host
        Write-Host 'All tests are now done!' -ForegroundColor Green
    }
    catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        Write-Host 'Exception thrown while testing, stopping execution...' -ForegroundColor Yellow
    }
    finally {
        if ($netWorkTraceStarted) {
            Write-Host 'Stopping network trace.... please wait, this may take a few minutes' -ForegroundColor Yellow
            $stopNetworkTrace = "netsh trace stop"
            Invoke-Expression $stopNetworkTrace
            $netWorkTraceStarted = $false
        }
        if ($canWriteFiles) {
            try {
                Stop-Transcript | Out-Null
            }
            catch [System.InvalidOperationException] { }

            FilterTranscript
        }
    }
}
finally {
    if ($canWriteFiles) {
        Write-Host Log file can be found at (Get-Location).Path
        if ($PSVersionTable.PSVersion.Major -ge 5) {
            $destAllFiles = (Get-Location).Path + '/AllFiles.zip'
            Compress-Archive -Path (Get-Location).Path -DestinationPath $destAllFiles -Force
            Write-Host 'A zip file with all the files can be found at' $destAllFiles -ForegroundColor Green
        }

        if ($PSVersionTable.Platform -eq 'Unix') {
            Get-ChildItem
        } else {
            Invoke-Item (Get-Location).Path
        }
    }
}

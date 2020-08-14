param (
  [Parameter(Mandatory=$true)]$octopusServerUrl,
  [Parameter(Mandatory=$true)]$registerInEnvironments,
  $tentacleDownloadPath = "http://octopusdeploy.com/downloads/latest/OctopusTentacle64",
  $registerInRoles = "web-server",
  $tentacleListenPort = 10933,
  $tentacleHomeDirectory = "C:\Octopus",
  $tentacleAppDirectory = "C:\Octopus\Applications",
  $tentacleConfigFile = "C\Octopus\Tentacle\Tentacle.config"
)

# because we don't want to continue if the build fails
$ErrorActionPreference = "Stop"

# Function to securely retrieve secrets from AWS Secrets Manager
function get-secret(){
  param ($secret)
  $secretValue = Get-SECSecretValue -SecretId $secret
  # values are returned in format: {"key":"value"}
  $splitValue = $secretValue.SecretString -Split '"'
  $cleanedSecret = $splitValue[3]
  return $cleanedSecret
}

# Installing Octopus Tentacle
# More about this script:
# https://gist.github.com/PaulStovell/7747107#file-provision-ps1

$octopusServerThumbprint = Get-Secret -secret "OCTOPUS_THUMBPRINT"
$yourApiKey = Get-Secret -secret "OCTOPUS_APIKEY"

# More about this script:
# https://gist.github.com/PaulStovell/7747107#file-provision-ps1

function Download-File 
{
  param (
    [string]$url,
    [string]$saveAs
  )
 
  Write-Output "    Downloading $url to $saveAs"
  $downloader = new-object System.Net.WebClient
  $downloader.DownloadFile($url, $saveAs)
}

# We're going to use Tentacle in Listening mode, so we need to tell Octopus what its IP address is. Since my Octopus server
# is hosted somewhere else, I need to know the public-facing IP address. 
function Get-MyPublicIPAddress
{
  Write-Output "    Getting public IP address"
  $downloader = new-object System.Net.WebClient
  $ip = $downloader.DownloadString("http://ifconfig.me/ip")
  return $ip
}

function Install-Tentacle 
{
  param (
     [Parameter(Mandatory=$True)]
     [string]$apiKey,
     [Parameter(Mandatory=$True)]
     [System.Uri]$octopusServerUrl,
     [Parameter(Mandatory=$True)]
     [string]$environment,
     [Parameter(Mandatory=$True)]
     [string]$role
  )

  Write-Output "  Beginning Tentacle installation"

  Write-Output "    Downloading latest Octopus Tentacle MSI..."

  $tentaclePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(".\Tentacle.msi")
  if ((test-path $tentaclePath) -ne $true) {
    Download-File $tentacleDownloadPath $tentaclePath
  }
  
  Write-Output "    Installing MSI"
  $msiExitCode = (Start-Process -FilePath "msiexec.exe" -ArgumentList "/i Tentacle.msi /quiet" -Wait -Passthru).ExitCode
  Write-Output "    Tentacle MSI installer returned exit code $msiExitCode"
  if ($msiExitCode -ne 0) {
    throw "Installation aborted"
  }

  Write-Output "    Open port $tentacleListenPort on Windows Firewall"
  & netsh.exe firewall add portopening TCP $tentacleListenPort "Octopus Tentacle"
  if ($lastExitCode -ne 0) {
    throw "Installation failed when modifying firewall rules"
  }
  
  $ipAddress = Get-MyPublicIPAddress
  $ipAddress = $ipAddress.Trim()

  Write-Output "    Public IP address: " + $ipAddress
 
  Write-Output "    Configuring and registering Tentacle"
  
  Set-Location "${env:ProgramFiles}\Octopus Deploy\Tentacle"

  & .\tentacle.exe create-instance --instance "Tentacle" --config $tentacleConfigFile --console | Write-Output
  if ($lastExitCode -ne 0) {
    throw "Installation failed on create-instance"
  }
  & .\tentacle.exe configure --instance "Tentacle" --home $tentacleHomeDirectory --console | Write-Output
  if ($lastExitCode -ne 0) {
    throw "Installation failed on configure"
  }
  & .\tentacle.exe configure --instance "Tentacle" --app $tentacleAppDirectory --console | Write-Output
  if ($lastExitCode -ne 0) {
    throw "Installation failed on configure"
  }
  & .\tentacle.exe configure --instance "Tentacle" --port $tentacleListenPort --console | Write-Output
  if ($lastExitCode -ne 0) {
    throw "Installation failed on configure"
  }
  & .\tentacle.exe new-certificate --instance "Tentacle" --console | Write-Output
  if ($lastExitCode -ne 0) {
    throw "Installation failed on creating new certificate"
  }
  & .\tentacle.exe configure --instance "Tentacle" --trust $octopusServerThumbprint --console  | Write-output
  if ($lastExitCode -ne 0) {
    throw "Installation failed on configure"
  }
  & .\tentacle.exe register-with --instance "Tentacle" --server $octopusServerUrl --environment $environment --role $role --name $env:COMPUTERNAME --publicHostName $ipAddress --apiKey $apiKey --comms-style TentaclePassive --force --console | Write-Output
  if ($lastExitCode -ne 0) {
    throw "Installation failed on register-with"
  }
 
  & .\tentacle.exe service --instance "Tentacle" --install --start --console | Write-Output
  if ($lastExitCode -ne 0) {
    throw "Installation failed on service install"
  }
 
  Write-Output "  Tentacle commands complete"
}

# Installing the Octopus Tentacle
Install-Tentacle -apikey $yourApiKey -octopusServerUrl $octopusServerUrl -environment $registerInEnvironments -role $registerInRoles
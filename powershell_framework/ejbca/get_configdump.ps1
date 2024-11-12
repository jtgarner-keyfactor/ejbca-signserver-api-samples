<# 
Example 1:
Retrieves REST credential and exports Configdump file in JSON format. 

- Prevents the export from failing on any configuration validation errors with the use of the 'IgnoreErrors' switch.
- Configuration items: Internal Key Bindings and OCSP Responders are not include.

$RestCredential = Get-RestCredential  -SerialNumber '6A160D4F7530FFD29B8B277D4A291E51226D159E'
Get-Configdump -IgnoreErrors -Defaults `
                -Hostname 'it-ca01.pkihosted-dev.c2company.com' `
                -Certificate $RestCredential `
                -Format "JSON" `
                -ExcludedItems "KEYBINDING","OCSPCONFIG"  


Example 2:
Retrieves REST credential and exports Configdump file in ZIP format. 

- Prevents the export from failing on any configuration validation errors with the use of the 'IgnoreErrors' switch.
- Configuration items: Only CAs will be included in the exported configuration

$RestCredential = Get-RestCredential  -SerialNumber '6A160D4F7530FFD29B8B277D4A291E51226D159E'
Get-Configdump -IgnoreErrors -Defaults `
                -Hostname 'it-ca01.pkihosted-dev.c2company.com' `
                -Certificate $RestCredential `
                -Format "ZIP" `
                -IncludedItems "CA"

#>

function Get-RestCredential {
    <#
    .DESCRIPTION
        Retrieves client authentication certificate from the Cert:\CurrentUser\My store.

    .PARAMETER SerialNumber
        Serial number of certificate to retrieve from the credential store.
        Note:
        This skips a selection prompt and returns the ceritifcate object if found. 

    .OUTPUTS
        X509Certificate Object.

    .EXAMPLE
        Get-RestCredential -SerialNumber 6A160D4F7530FFD29B8B277D4A291E51226D159E
    #>
    param(
        [Parameter(Mandatory=$false)][String]$SerialNumber=""
    )
    
    # retrieve single client authentication certificate
    $MatchSingleCertificate = (Get-ChildItem -Path Cert:\CurrentUser\My).where({$_.EnhancedKeyUsageList.ObjectId -contains "1.3.6.1.5.5.7.3.2" -and $_.SerialNumber -eq $SerialNumber})
    if($MatchSingleCertificate){
         return $MatchSingleCertificate
    }

    # only get client authentication certificates
    $Certificates = (Get-ChildItem -Path Cert:\CurrentUser\My).where({$_.EnhancedKeyUsageList.ObjectId -contains "1.3.6.1.5.5.7.3.2"})
    if($Certificates.Count -eq 1){
        return $Certificates
    } else {
        $CertificateChoices = @(
            $Certificates | ForEach-Object {$Choice = 1}{
                [pscustomobject]@{
                    Choice = "[$Choice]"
                    FriendlyName = $_.FriendlyName
                    Issuer = ($_.Issuer.Split(',') | where{$_ -match '(CN=)'}).Trim().Split('=')[1]
                    SerialNumber = $_.SerialNumber
                    Certificate = $_
                }
                $Choice++
            }
        )
        if(-not $CertificateChoices.Count){
            throw "No valid client certificates are available for selection. Install a valid client certificate before running the script again."
        }
        # Prompt for selection if more than one Client Authentication Certificate exists
        Write-Host "`n$(($CertificateChoices | Format-Table 'Choice','FriendlyName','Issuer','SerialNumber' -AutoSize | Out-String).Trim())"
        while($true){
            $Selection = Read-Host "`nEnter the Option to select the certificate for EJBCA REST authentication"
            $Selection = $Selection -as [Int]
            if($Selection -in 1..$CertificateChoices.Count){
                return $CertificateChoices.where({$_.Choice -match $Selection}).Certificate
            }
            else {
                Write-Host "Invalid selection. Select an certifictate listed above." -ForegroundColor Yellow
            }
        }
    }
} 

function Get-Configdump {
    <#
    .DESCRIPTION
        Returns the configdump data for provided configuration in the requested output format

    .PARAMETER Hostname
        Hostname of the EJBCA Rest Endpoint

    .PARAMETER Certificate
        X509Certificate object for authenticating to endpoint

    .PARAMETER Outfile
        Path for output file containing exported configuration data.

    .PARAMETER Format
        Export format. Either JSON or ZIP.

    .PARAMETER IgnoreErrors
        Print a warning instead of aborting and throwing an exception on errors.

    .PARAMETER Defaults
        Also include fields having the default value.

    .PARAMETER ExternalCas
        Enables export of external CAs (i.e. CAs where there's only a certificate and nothing else)

    .PARAMETER ExcludedItems
        Names of items to exclude in the export.
        Note:
        This parameter cannot be used with IncludedItems and will be ignored if IncludedItems is defined

    .PARAMETER IncludedItems
        Names of items to include in the export. The syntax is identical to that of exclude.
        Note:
        All other categories and the ExcludedItems parameter will be ignored if this parameter is defined

    .OUTPUTS
        X509Certificate Object.

    .EXAMPLE
        Get-RestCredential -SerialNumber 6A160D4F7530FFD29B8B277D4A291E51226D159E
    #>
	param(
        [Parameter(Mandatory)][String]$Hostname,
        [Parameter(Mandatory)][Object]$Certificate,
        [Parameter(Mandatory=$false)][String]$Outfile,
        [Parameter(Mandatory=$false)][ValidateSet("JSON","ZIP")][String]$Format="JSON",

        # Optional Switches
        [Parameter(Mandatory=$false)][Switch]$IgnoreErrors,
        [Parameter(Mandatory=$false)][Switch]$Defaults,
        [Parameter(Mandatory=$false)][Switch]$ExternalCas,

        # Exclude and Include configurations
        [Parameter(Mandatory=$false)][String[]]$ExcludedItems,
        [Parameter(Mandatory=$false)][String[]]$IncludedItems
    )

    $Method = "GET"
    $UriBuilder = [System.Text.StringBuilder]::New("https://$Hostname/ejbca/ejbca-rest-api/v1/configdump")

    # Check status of endpoint
    $EndpointStatus = $UriBuilder.ToString() + '/status'
    try {
        Invoke-RestMethod $EndpointStatus -Method $Method -Certificate $Certificate | ConvertTo-Json | Out-Null
    } catch {
        if($_.Exception.Response.StatusCode.value__){
            Write-Host "The Configdump REST endpoint is not enabled in the System Configuration in EJBCA Admin Web. Enable protocol 'REST Configdump' and try again." -ForegroundColor Red
        } else {
            Write-Host $_.Exception
        }
        exit
    }
    
    # set default outfile path if one not provided
    if(-not $Outfile){
        $Outfile = "$PSScriptRoot\configdump"
    }
    
    # created array with switch values, convert booleans to lower case strings, and join with &
    $Headers = @(
        "ignoreerrors=$($IgnoreErrors)",
        "defaults=$($Defaults)",
        "externalcas=$($ExternalCas)"
    )
    $UrlParameters = [System.Text.StringBuilder]::New("?$($Headers.ToLower() -Join '&')")
    
    if($IncludedItems){
        # exclude all configurations
        [void]$UrlParameters.Append("&exclude=$([System.Web.HttpUtility]::UrlEncode('*:*'))")
        
        # build encoded string for included configurations and add back in
        $IncludedItemsString = $IncludedItems | foreach{ "include=$([System.Web.HttpUtility]::UrlEncode($_ + ':*'))" }
        [void]$UrlParameters.Append("&$($IncludedItemsString -Join '&')")
        

    } elseif($ExcludedItems){
        # build encoded string for excluded configurations and add back in
        $ExcludedItemsString = $ExcludedItems | foreach{ "exclude=$([System.Web.HttpUtility]::UrlEncode($_ + ':*'))" }
        [void]$UrlParameters.Append("&$($ExcludedItemsString -Join '&')")
    }

    #Write-Host $EndpointDump

    try {
        switch ($Format){
            'JSON' {
                $EndpointDump = $UriBuilder.ToString() + $UrlParameters.ToString()
                Invoke-RestMethod $EndpointDump -Method $Method -Certificate $Certificate -OutFile $($Outfile + '.json')
            }
            'ZIP' {
                $EndpointDump = $UriBuilder.Append('/configdump.zip').ToString() + $UrlParameters.ToString()
                $Headers = @{
                    "Content-Type" = "application/zip"
                }
                Write-Host $EndpointDump
                Invoke-RestMethod $EndpointDump -Method $Method -Headers $Headers -Certificate $Certificate  -OutFile $($Outfile + '.zip')
            }
        }

        return $Outfile

    } catch {
        Write-Host $($_.Exception.Message) -ForegroundColor Red
    }     
}

$RestCredential = Get-RestCredential  -SerialNumber '6A160D4F7530FFD29B8B277D4A291E51226D159E'
# Get-Configdump -IgnoreErrors -Defaults `
#                 -Hostname 'it-ca01.pkihosted-dev.c2company.com' `
#                 -Certificate $RestCredential `
#                 -Format "JSON" `
#                 -ExcludedItems "KEYBINDING","OCSPCONFIG"  

Get-Configdump -IgnoreErrors -Defaults `
                -Hostname 'it-ca01.pkihosted-dev.c2company.com' `
                -Certificate $RestCredential `
                -Format "ZIP" `
                -IncludedItems "CA"
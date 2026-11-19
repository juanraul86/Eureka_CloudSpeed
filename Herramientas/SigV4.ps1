# SigV4.ps1 - URL prefirmadas de Amazon S3 con Signature Version 4 (parámetros de consulta).
# AWS CLI solo prefirma GET; el test de subida necesita PUT, así que se firma aquí siguiendo
# https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-query-string-auth.html

function Get-SigV4Hash([byte[]]$Data) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Data)) -replace '-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}

function Get-SigV4Hmac([byte[]]$Key, [string]$Text) {
    $h = New-Object Security.Cryptography.HMACSHA256 (, $Key)
    try { return $h.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) } finally { $h.Dispose() }
}

function ConvertTo-SigV4Uri([string]$s, [switch]$KeepSlash) {
    # RFC 3986: solo A-Z a-z 0-9 - _ . ~ sin codificar (y '/' en la ruta)
    $sb = New-Object Text.StringBuilder
    foreach ($b in [Text.Encoding]::UTF8.GetBytes($s)) {
        $c = [char]$b
        if (($c -ge 'A' -and $c -le 'Z') -or ($c -ge 'a' -and $c -le 'z') -or ($c -ge '0' -and $c -le '9') -or ($c -in @('-', '_', '.', '~')) -or ($KeepSlash -and $c -eq '/')) { [void]$sb.Append($c) }
        else { [void]$sb.Append(('%{0:X2}' -f $b)) }
    }
    $sb.ToString()
}

function New-S3PresignedUrl {
    param(
        [ValidateSet('GET', 'PUT')][string]$Method = 'GET',
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Region,
        [Parameter(Mandatory)][string]$AccessKey,
        [Parameter(Mandatory)][string]$SecretKey,
        [string]$SessionToken,
        [ValidateRange(1, 604800)][int]$ExpiresSeconds = 604800,
        [datetime]$Now = [datetime]::UtcNow
    )
    $amzDate = $Now.ToString('yyyyMMddTHHmmssZ', [Globalization.CultureInfo]::InvariantCulture)
    $day = $Now.ToString('yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture)
    $scope = "$day/$Region/s3/aws4_request"
    $q = [ordered]@{
        'X-Amz-Algorithm'     = 'AWS4-HMAC-SHA256'
        'X-Amz-Credential'    = "$AccessKey/$scope"
        'X-Amz-Date'          = $amzDate
        'X-Amz-Expires'       = "$ExpiresSeconds"
        'X-Amz-SignedHeaders' = 'host'
    }
    if ($SessionToken) { $q['X-Amz-Security-Token'] = $SessionToken }
    $query = (($q.Keys | Sort-Object -CaseSensitive) | ForEach-Object { (ConvertTo-SigV4Uri $_) + '=' + (ConvertTo-SigV4Uri $q[$_]) }) -join '&'
    $path = '/' + (ConvertTo-SigV4Uri $Key.TrimStart('/') -KeepSlash)
    $canonical = "$Method`n$path`n$query`nhost:$HostName`n`nhost`nUNSIGNED-PAYLOAD"
    $toSign = "AWS4-HMAC-SHA256`n$amzDate`n$scope`n" + (Get-SigV4Hash ([Text.Encoding]::UTF8.GetBytes($canonical)))
    $k = Get-SigV4Hmac ([Text.Encoding]::UTF8.GetBytes("AWS4$SecretKey")) $day
    $k = Get-SigV4Hmac $k $Region
    $k = Get-SigV4Hmac $k 's3'
    $k = Get-SigV4Hmac $k 'aws4_request'
    $sig = ([BitConverter]::ToString((Get-SigV4Hmac $k $toSign)) -replace '-', '').ToLowerInvariant()
    "https://$HostName$path`?$query&X-Amz-Signature=$sig"
}

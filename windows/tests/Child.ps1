param([string]$Mode)
$Values = @($args)
switch ($Mode) {
    'exit' { [Console]::Out.Write('out'); [Console]::Error.Write('err'); exit 7 }
    'flood' {
        $text = 'x' * 8192
        for ($i = 0; $i -lt 256; $i++) { [Console]::Out.Write($text); [Console]::Error.Write($text) }
    }
    'sleep' { Start-Sleep -Seconds 20 }
    'args' { ConvertTo-Json -InputObject @($Values) -Compress }
    default { throw 'Unknown child mode.' }
}

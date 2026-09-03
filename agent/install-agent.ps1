# ===========================================================================
#  Enroll de agente de logs -> OpenSearch  (Windows)
#
#  Instalar    (PowerShell como Administrador):
#    irm http://192.168.1.73/install-agent.ps1 | iex
#
#  Desinstalar (PowerShell como Administrador):
#    & ([scriptblock]::Create((irm http://192.168.1.73/install-agent.ps1))) -Uninstall
#
#  Agente: Fluent Bit (build oficial para Windows)
#  Destino: indice logs-<hostname> no OpenSearch
# ===========================================================================
[CmdletBinding()]
param(
    [switch] $Uninstall,
    [string] $OsHost      = "192.168.1.73",
    [int]    $OsPort      = 9200,
    [string] $OsUser      = "agent-ingest",
    [string] $OsPass      = 'Ag3nt!Ingest2026#Log',
    [string] $IndexPrefix = "logs",
    [string] $FbVersion   = "3.2.10"
)

$ErrorActionPreference = "Stop"
$InstallDir = "C:\opt\fluent-bit"
$ConfFile   = Join-Path $InstallDir "conf\fluent-bit.conf"
$SvcName    = "fluent-bit"

function Log  ($m) { Write-Host "[+] $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Die  ($m) { Write-Host "[x] $m" -ForegroundColor Red; exit 1 }

# --------------------------- checa privilegio -------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Die "Execute o PowerShell como Administrador." }

# =========================== DESINSTALACAO =================================
if ($Uninstall) {
    Log "Parando servico $SvcName"
    if (Get-Service -Name $SvcName -ErrorAction SilentlyContinue) {
        Stop-Service  -Name $SvcName -Force -ErrorAction SilentlyContinue
        sc.exe delete $SvcName | Out-Null
    }
    Log "Removendo $InstallDir"
    if (Test-Path $InstallDir) { Remove-Item -Recurse -Force $InstallDir }
    Log "Agente removido deste host ($env:COMPUTERNAME)."
    exit 0
}

# =========================== INSTALACAO ====================================
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$HostN = $env:COMPUTERNAME.ToLower() -replace '[^a-z0-9-]','-'
Log "Host: $HostN  |  Destino: ${OsHost}:${OsPort}"

# --------------------------- download / extracao ----------------------------
if (-not (Test-Path "$InstallDir\bin\fluent-bit.exe")) {
    $zipName = "fluent-bit-$FbVersion-win64.zip"
    $url     = "https://packages.fluentbit.io/windows/$zipName"
    $tmpZip  = Join-Path $env:TEMP $zipName
    $tmpDir  = Join-Path $env:TEMP "fb-extract-$(Get-Random)"

    Log "Baixando Fluent Bit $FbVersion"
    Invoke-WebRequest -Uri $url -OutFile $tmpZip -UseBasicParsing

    Log "Extraindo para $InstallDir"
    Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force
    $src = (Get-ChildItem $tmpDir -Directory | Select-Object -First 1).FullName
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Copy-Item "$src\*" $InstallDir -Recurse -Force
    Remove-Item $tmpZip, $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Log "Fluent Bit ja instalado - seguindo para configuracao"
}

# --------------------------- configuracao ----------------------------------
Log "Gerando $ConfFile"
New-Item -ItemType Directory -Path (Split-Path $ConfFile) -Force | Out-Null
New-Item -ItemType Directory -Path "$InstallDir\state"      -Force | Out-Null

$conf = @"
[SERVICE]
    Flush         5
    Daemon        Off
    Log_Level     info
    Log_File      $InstallDir\fluent-bit.log
    storage.path  $InstallDir\state\
    storage.sync  normal

# ------------------------------- ENTRADAS ---------------------------------
[INPUT]
    Name          winlog
    Tag           host.winlog
    Channels      Setup,Windows PowerShell,System,Application,Security
    Interval_Sec  10
    DB            $InstallDir\state\winlog.db

[INPUT]
    Name          windows_exporter_metrics
    Tag           host.metrics
    scrape_interval 30

# ------------------------------- FILTROS ----------------------------------
[FILTER]
    Name          record_modifier
    Match         *
    Record        agent_hostname $HostN
    Record        agent_type     fluent-bit
    Record        agent_os       windows

# ------------------------------- SAIDA ------------------------------------
[OUTPUT]
    Name                opensearch
    Match               *
    Host                $OsHost
    Port                $OsPort
    HTTP_User           $OsUser
    HTTP_Passwd         $OsPass
    tls                 On
    tls.verify          Off
    Index               $IndexPrefix-$HostN
    Suppress_Type_Name  On
    Logstash_Format     Off
    Trace_Error         On
    Retry_Limit         5
    storage.total_limit_size 200M
"@
Set-Content -Path $ConfFile -Value $conf -Encoding ASCII

# Restringe a leitura do arquivo (contem senha) a Administradores e SYSTEM
icacls $ConfFile /inheritance:r /grant:r "Administrators:(R,W)" "SYSTEM:(R,W)" | Out-Null

# --------------------------- teste de conectividade -------------------------
Log "Testando conectividade com o OpenSearch"
add-type @"
using System.Net; using System.Security.Cryptography.X509Certificates;
public class TrustAll : ICertificatePolicy {
  public bool CheckValidationResult(ServicePoint s, X509Certificate c, WebRequest w, int p) { return true; }
}
"@ -ErrorAction SilentlyContinue
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAll

$cred = "${OsUser}:${OsPass}"
$b64  = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($cred))
try {
    $r = Invoke-WebRequest -Uri "https://${OsHost}:${OsPort}/_cluster/health" `
         -Headers @{ Authorization = "Basic $b64" } -UseBasicParsing -TimeoutSec 15
    Log "Conectividade e credenciais OK (HTTP $($r.StatusCode))"
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -eq 401 -or $code -eq 403) { Die "Credenciais recusadas (HTTP $code)." }
    Die "Falha ao conectar em ${OsHost}:${OsPort} - $($_.Exception.Message)"
}

# --------------------------- servico do Windows -----------------------------
Log "Registrando o servico do Windows '$SvcName'"
if (Get-Service -Name $SvcName -ErrorAction SilentlyContinue) {
    Stop-Service -Name $SvcName -Force -ErrorAction SilentlyContinue
    sc.exe delete $SvcName | Out-Null
    Start-Sleep -Seconds 2
}
sc.exe create $SvcName `
    binPath= "$InstallDir\bin\fluent-bit.exe -c $ConfFile" `
    start= auto DisplayName= "Fluent Bit (OpenSearch agent)" | Out-Null
sc.exe description $SvcName "Coleta logs e metricas do host e envia ao OpenSearch." | Out-Null
sc.exe failure $SvcName reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null

Start-Service -Name $SvcName
Start-Sleep -Seconds 3
$svc = Get-Service -Name $SvcName
if ($svc.Status -ne 'Running') {
    Warn "Servico nao subiu. Verifique $InstallDir\fluent-bit.log"
    exit 1
}

Write-Host @"

===========================================================================
 Agente instalado com sucesso
---------------------------------------------------------------------------
 Host             : $HostN
 Indice destino   : $IndexPrefix-$HostN
 OpenSearch       : https://${OsHost}:${OsPort}
 Config           : $ConfFile

 Verificar status : Get-Service $SvcName
 Ver logs         : Get-Content '$InstallDir\fluent-bit.log' -Tail 50 -Wait

 Desinstalar:
   & ([scriptblock]::Create((irm http://${OsHost}/install-agent.ps1))) -Uninstall
===========================================================================
"@ -ForegroundColor Cyan

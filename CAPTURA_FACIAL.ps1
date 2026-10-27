# Ferramenta de suporte: video ao vivo do facial + captura de foto remota (Bio-T / Intelbras)  -  versao 3 (com log)
# v3.4 (27/10/2026): botao "Atualizar" passa a se chamar "Verificar novas versoes" (versao de teste da atualizacao pelo site).
# v3 (27/10/2026): botao "Buscar IP..." (acha os equipamentos, modelo, se e Bio-T, troca de IP, estado e comandos de porta)
#                  e a captura tenta de novo quando o facial responde 400 (captura anterior ainda ativa nele).
# Fluxo: Conectar -> Ativar captura -> cliente toca em "enviar foto" no facial -> foto salva na pasta do PC.
# A tela principal NAO altera configuracao do equipamento; so o Buscador de IP altera, e sempre pedindo confirmacao.
# A senha NUNCA e gravada no log.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Net.ServicePointManager]::DefaultConnectionLimit = 20
[System.Net.ServicePointManager]::Expect100Continue = $false

# ---------------------------------------------------------------- LOG
$script:LogFile = $null
$script:TravaLog = New-Object object   # o video e o buscador escrevem no log por tarefas de segundo plano
$script:ContRep = @{}
function IniciarLog {
    $raiz = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    foreach ($d in @((Join-Path $raiz 'logs'), (Join-Path $env:LOCALAPPDATA 'CapturaFacial\logs'))) {
        try {
            New-Item -ItemType Directory -Force -Path $d | Out-Null
            $p = Join-Path $d ('log_{0}.txt' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
            Set-Content -Path $p -Value 'LOG - Captura Facial' -Encoding UTF8
            $script:LogFile = $p; return
        } catch {}
    }
}
function Log($msg, $nivel = 'INFO') {
    if (-not $script:LogFile) { return }
    $linha = ('{0} [{1}] {2}' -f (Get-Date -Format 'dd/MM HH:mm:ss.fff'), $nivel, $msg) + [Environment]::NewLine
    [System.Threading.Monitor]::Enter($script:TravaLog)
    try { [System.IO.File]::AppendAllText($script:LogFile, $linha, [System.Text.Encoding]::UTF8) } catch {} finally { [System.Threading.Monitor]::Exit($script:TravaLog) }
}
# registra o mesmo erro so na 1a vez e a cada 20 repeticoes (evita log gigante)
function LogRep($chave, $msg, $nivel = 'ERRO') {
    $n = 1 + [int]$script:ContRep[$chave]; $script:ContRep[$chave] = $n
    if ($n -eq 1 -or ($n % 20) -eq 0) { Log ("{0} (ocorrencia {1})" -f $msg, $n) $nivel }
}
function Resumo($t, $max = 300) {
    if ($null -eq $t) { return '(vazio)' }
    $t = ($t -replace '[\r\n]+', ' | ')
    if ($t.Length -gt $max) { return $t.Substring(0, $max) + '...' }
    return $t
}
function LogExcecao($contexto, $ex) {
    $m = "$contexto -> $($ex.GetType().FullName): $($ex.Message)"
    if ($ex -is [System.Net.WebException] -and $ex.Response) { $m += " | HTTP $([int]$ex.Response.StatusCode) $($ex.Response.StatusDescription)" }
    if ($ex.InnerException) { $m += " | interno: $($ex.InnerException.Message)" }
    Log $m 'ERRO'
}
IniciarLog
Log '=== Captura Facial - versao 3.4 ==='
Log ("Windows: {0} | 64bit: {1}" -f [Environment]::OSVersion.VersionString, [Environment]::Is64BitOperatingSystem)
Log ("PowerShell: {0} | CLR: {1}" -f $PSVersionTable.PSVersion, $PSVersionTable.CLRVersion)
Log ("Usuario: {0}\{1} | Computador: {2}" -f $env:USERDOMAIN, $env:USERNAME, $env:COMPUTERNAME)
Log ("Script: {0}" -f $PSCommandPath)
Log ("Arquivo de log: {0}" -f $script:LogFile)
[System.Windows.Forms.Application]::add_ThreadException({ param($s, $e) Log ("Excecao nao tratada na interface: " + $e.Exception.ToString()) 'ERRO' })

# ---------------------------------------------------------------- configuracao salva
$cfgDir  = Join-Path $env:LOCALAPPDATA 'CapturaFacial'
$cfgFile = Join-Path $cfgDir 'config.txt'
$script:Pasta = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'FotosFacial'
$cfg = @{ ip = ''; porta = '80'; usuario = 'admin'; segundos = '60' }
if (Test-Path $cfgFile) {
    foreach ($l in Get-Content $cfgFile -Encoding UTF8) {
        if ($l -match '^(\w+)=(.*)$') {
            if ($Matches[1] -eq 'pasta') { if ($Matches[2]) { $script:Pasta = $Matches[2] } } else { $cfg[$Matches[1]] = $Matches[2] }
        }
    }
}
Log ("Pasta das fotos: {0}" -f $script:Pasta)
function SalvarCfg {
    try {
        New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
        Set-Content -Path $cfgFile -Encoding UTF8 -Value @("ip=$($txtIp.Text)", "porta=$($txtPorta.Text)", "usuario=$($txtUser.Text)", "segundos=$($numSeg.Value)", "pasta=$($script:Pasta)")
    } catch { Log "Nao foi possivel salvar a configuracao: $($_.Exception.Message)" 'AVISO' }
}

# ---------------------------------------------------------------- comunicacao com o facial
$script:Base = $null; $script:Cache = $null; $script:UrlQuadro = $null
$script:Capturando = $false; $script:EmTick = $false; $script:Falhas = 0; $script:Quadros = 0
$latin1 = [System.Text.Encoding]::GetEncoding(28591)

function Abrir($caminho, $timeout = 15000, $rw = 60000) {
    $req = [System.Net.HttpWebRequest]::Create($script:Base + $caminho)
    $req.Proxy = $null          # ignora proxy do Windows (equipamento esta na rede local)
    $req.Credentials = $script:Cache; $req.Timeout = $timeout; $req.ReadWriteTimeout = $rw; $req.KeepAlive = $false
    return $req.GetResponse()
}
function Texto($caminho) {
    try {
        $r = Abrir $caminho; $t = (New-Object System.IO.StreamReader($r.GetResponseStream())).ReadToEnd(); $r.Close(); $t = $t.Trim()
        Log ("GET {0} -> {1}" -f $caminho, (Resumo $t)); return $t
    } catch {
        LogExcecao "GET $caminho" $_.Exception
        return "ERRO: $($_.Exception.Message)"
    }
}
function BytesDe($caminho, $timeout) {
    $r = Abrir $caminho $timeout $timeout
    try { $ms = New-Object System.IO.MemoryStream; $r.GetResponseStream().CopyTo($ms); return $ms.ToArray() } finally { $r.Close() }
}
function EhJpeg($b) { return ($b -and $b.Length -gt 1000 -and $b[0] -eq 0xFF -and $b[1] -eq 0xD8) }
function QuadroMjpg {
    $r = Abrir '/cgi-bin/mjpg/video.cgi?channel=1&subtype=1' 4000 4000
    try {
        $s = $r.GetResponseStream(); $ms = New-Object System.IO.MemoryStream; $buf = New-Object byte[] 32768
        $fim = (Get-Date).AddSeconds(4)
        $ini = ([string][char]0xFF) + ([string][char]0xD8); $fimJ = ([string][char]0xFF) + ([string][char]0xD9)
        while ((Get-Date) -lt $fim -and $ms.Length -lt 2000000) {
            $q = $s.Read($buf, 0, $buf.Length); if ($q -le 0) { break }
            $ms.Write($buf, 0, $q)
            $a = $ms.ToArray(); $t = $latin1.GetString($a)
            $i = $t.IndexOf($ini); if ($i -ge 0) { $z = $t.IndexOf($fimJ, $i + 2); if ($z -gt $i) { return [byte[]]$a[$i..($z + 1)] } }
        }
    } finally { $r.Close() }
    return $null
}
function ObterQuadro {
    $tentativas = if ($script:UrlQuadro) { @($script:UrlQuadro) } else { @('/cgi-bin/snapshot.cgi?channel=1', '/cgi-bin/snapshot.cgi', 'MJPG') }
    foreach ($u in $tentativas) {
        try {
            $b = if ($u -eq 'MJPG') { QuadroMjpg } else { BytesDe $u 3000 }
            if (EhJpeg $b) {
                if ($script:UrlQuadro -ne $u) { Log ("Fonte de video funcionando: {0} (1o quadro: {1} bytes)" -f $u, $b.Length) }
                $script:UrlQuadro = $u; return $b
            } else { LogRep "quadro:$u" ("Fonte de video {0} respondeu, mas nao e uma imagem JPEG valida ({1} bytes)" -f $u, $(if ($b) { $b.Length } else { 0 })) 'AVISO' }
        } catch { LogRep "quadro:$u" ("Falha ao obter video de {0}: {1}" -f $u, $_.Exception.Message) 'AVISO' }
    }
    return $null
}
function ParaImagem($bytes) {
    $ms = New-Object System.IO.MemoryStream(, $bytes)
    $img = [System.Drawing.Image]::FromStream($ms); $bmp = New-Object System.Drawing.Bitmap($img)
    $img.Dispose(); $ms.Dispose(); return $bmp
}
function TrocarImagem($pic, $bmp) { $old = $pic.Image; $pic.Image = $bmp; if ($old) { $old.Dispose() } }

# ---------------------------------------------------------------- captura remota
function EncerrarCaptura($motivo) {
    Log "Captura encerrada: $motivo"
    $script:Capturando = $false
    try { if ($script:SnResp) { $script:SnResp.Close() } } catch {}
    $script:SnResp = $null
    $btnCap.Text = 'ATIVAR CAPTURA'; $btnCap.BackColor = [System.Drawing.Color]::FromArgb(0, 140, 70)
}
function IniciarCaptura {
    $seg = [int]$numSeg.Value
    Log "=== INICIANDO CAPTURA (tempo limite ${seg}s) ==="
    $script:Chunks = 0; $script:TotalBytes = 0; $script:AvisouMarcador = $false
    Log 'Abrindo canal de eventos: snapManager.cgi attachFileProc (CitizenPictureCompare)'
    $script:SnResp = Abrir '/cgi-bin/snapManager.cgi?action=attachFileProc&Flags[0]=Event&Events=[CitizenPictureCompare]&heartbeat=5' 15000 ($seg * 1000 + 60000)
    Log ("Canal aberto: HTTP {0} | Content-Type: {1}" -f [int]$script:SnResp.StatusCode, $script:SnResp.ContentType)
    $script:SnS = $script:SnResp.GetResponseStream()
    $script:SnBuf = New-Object byte[] 65536; $script:SnMs = New-Object System.IO.MemoryStream
    $script:SnT = $script:SnS.ReadAsync($script:SnBuf, 0, $script:SnBuf.Length)
    Start-Sleep -Milliseconds 1200
    $r = Texto "/cgi-bin/accessControl.cgi?action=captureCmd&type=1&heartbeat=5&timeout=$seg"
    if ($r -like '*(400)*') {
        # 400 = o facial ainda esta com a captura anterior aberta (ex.: cancelou e ativou logo em seguida). Espera e tenta de novo.
        Log 'captureCmd respondeu 400 (captura anterior ainda ativa no facial); nova tentativa em 3 s' 'AVISO'
        $lblStatus.Text = 'O facial ainda estava com a captura anterior. Tentando de novo...'; $f.Refresh()
        for ($k = 0; $k -lt 30; $k++) { Start-Sleep -Milliseconds 100; [System.Windows.Forms.Application]::DoEvents() }
        $r = Texto "/cgi-bin/accessControl.cgi?action=captureCmd&type=1&heartbeat=5&timeout=$seg"
    }
    if ($r -like 'ERRO*') { EncerrarCaptura 'captureCmd recusado pelo facial'; throw "O facial recusou o comando de captura: $r" }
    $script:CapInicio = Get-Date; $script:Capturando = $true
    $btnCap.Text = 'CANCELAR CAPTURA'; $btnCap.BackColor = [System.Drawing.Color]::FromArgb(190, 60, 30)
    Log 'Captura ativa. Aguardando o cliente tocar em "enviar foto" no facial...'
}
function VerificarCaptura {
    $lim = [int]$numSeg.Value
    $decorrido = ((Get-Date) - $script:CapInicio).TotalSeconds
    if ($decorrido -gt ($lim + 5)) {
        EncerrarCaptura ("tempo esgotado ({0:N0}s) - nenhuma foto recebida; bytes recebidos no canal: {1}" -f $decorrido, $script:TotalBytes)
        $lblStatus.Text = 'Tempo esgotado: o cliente não enviou a foto. Clique em ATIVAR CAPTURA para tentar de novo.'; return
    }
    $lblStatus.Text = ('Captura ativa: peça ao cliente para tocar em "enviar foto" no facial... ({0:N0}s)' -f ($lim - $decorrido))
    while ($script:SnT.IsCompleted) {
        if ($script:SnT.IsFaulted) {
            $msg = if ($script:SnT.Exception) { $script:SnT.Exception.GetBaseException().Message } else { 'desconhecido' }
            Log "Erro de leitura no canal de captura: $msg" 'ERRO'
            EncerrarCaptura 'erro no canal'; $lblStatus.Text = 'Erro no canal de captura (veja o log).'; return
        }
        $q = $script:SnT.Result
        if ($q -le 0) { EncerrarCaptura ("canal fechado pelo facial apos {0:N1}s (bytes recebidos: {1})" -f $decorrido, $script:TotalBytes); $lblStatus.Text = 'Conexão de captura encerrada pelo facial.'; return }
        $script:Chunks++; $script:TotalBytes += $q
        if ($script:Chunks -le 15 -or ($script:Chunks % 20) -eq 0) {
            $prev = ($latin1.GetString($script:SnBuf, 0, [math]::Min($q, 200)) -replace '[^\x20-\x7E]', '.')
            Log ("Recebido pacote #{0}: {1} bytes (total {2}) em {3:N1}s | inicio: {4}" -f $script:Chunks, $q, $script:TotalBytes, $decorrido, $prev) 'DADOS'
        }
        $script:SnMs.Write($script:SnBuf, 0, $q)
        $dados = $script:SnMs.ToArray(); $txt = $latin1.GetString($dados)
        $i = $txt.IndexOf('CitizenPictureCompare')
        if ($i -ge 0) {
            if (-not $script:AvisouMarcador) { Log ("Evento CitizenPictureCompare detectado em {0:N1}s (o cliente enviou a foto)" -f $decorrido); $script:AvisouMarcador = $true }
            $a = $txt.IndexOf(([string][char]0xFF) + ([string][char]0xD8), $i)
            $z = if ($a -ge 0) { $txt.IndexOf(([string][char]0xFF) + ([string][char]0xD9), $a) } else { -1 }
            if ($z -gt $a) {
                $foto = [byte[]]$dados[$a..($z + 1)]
                New-Item -ItemType Directory -Force -Path $script:Pasta | Out-Null
                $nome = 'foto_{0}.jpg' -f (Get-Date -Format 'yyyyMMdd_HHmmss')
                $caminho = Join-Path $script:Pasta $nome
                [System.IO.File]::WriteAllBytes($caminho, $foto)
                $bmp = ParaImagem $foto
                Log ("FOTO RECEBIDA: {0} bytes, {1}x{2}, salva em {3}" -f $foto.Length, $bmp.Width, $bmp.Height, $caminho)
                $lblFoto.Text = "$nome  ($($bmp.Width)x$($bmp.Height), $([math]::Round($foto.Length/1KB)) KB)"
                TrocarImagem $picFoto $bmp
                EncerrarCaptura 'foto recebida com sucesso'
                $lblStatus.Text = "FOTO RECEBIDA e salva em: $caminho"
                [System.Media.SystemSounds]::Asterisk.Play()
                return
            }
        }
        $script:SnT = $script:SnS.ReadAsync($script:SnBuf, 0, $script:SnBuf.Length)
    }
}

# ---------------------------------------------------------------- interface
$f = New-Object System.Windows.Forms.Form
$f.Text = 'Captura de foto do facial - Suporte'; $f.Size = New-Object System.Drawing.Size(980, 700); $f.StartPosition = 'CenterScreen'
$f.MinimumSize = New-Object System.Drawing.Size(860, 600); $f.Font = New-Object System.Drawing.Font('Segoe UI', 10)

function NovoLabel($t, $x, $y) { $l = New-Object System.Windows.Forms.Label; $l.Text = $t; $l.Location = New-Object System.Drawing.Point($x, $y); $l.AutoSize = $true; $f.Controls.Add($l); return $l }
function NovoTexto($x, $y, $w, $v) { $t = New-Object System.Windows.Forms.TextBox; $t.Location = New-Object System.Drawing.Point($x, $y); $t.Width = $w; $t.Text = $v; $f.Controls.Add($t); return $t }
function NovoBotao($t, $x, $y, $w) { $b = New-Object System.Windows.Forms.Button; $b.Text = $t; $b.Location = New-Object System.Drawing.Point($x, $y); $b.Size = New-Object System.Drawing.Size($w, 30); $b.Anchor = 'Left,Bottom'; $f.Controls.Add($b); return $b }

NovoLabel 'IP do facial' 12 14 | Out-Null;  $txtIp = NovoTexto 100 10 130 $cfg.ip
NovoLabel 'Porta' 240 14 | Out-Null;        $txtPorta = NovoTexto 285 10 55 $cfg.porta
NovoLabel 'Usuário' 350 14 | Out-Null;      $txtUser = NovoTexto 410 10 100 $cfg.usuario
NovoLabel 'Senha' 520 14 | Out-Null;        $txtSenha = NovoTexto 570 10 130 ''; $txtSenha.UseSystemPasswordChar = $true
$btnCon = New-Object System.Windows.Forms.Button; $btnCon.Text = 'Conectar'; $btnCon.Location = New-Object System.Drawing.Point(715, 8); $btnCon.Size = New-Object System.Drawing.Size(110, 30); $f.Controls.Add($btnCon)
$btnBusca = New-Object System.Windows.Forms.Button; $btnBusca.Text = 'Buscar IP...'; $btnBusca.Location = New-Object System.Drawing.Point(833, 8); $btnBusca.Size = New-Object System.Drawing.Size(117, 30); $f.Controls.Add($btnBusca)

$lblV = NovoLabel 'Vídeo ao vivo do facial' 12 50; $lblV.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$lblF = NovoLabel 'Última foto recebida' 500 50; $lblF.Font = $lblV.Font
$picVideo = New-Object System.Windows.Forms.PictureBox; $picVideo.Location = New-Object System.Drawing.Point(12, 75); $picVideo.Size = New-Object System.Drawing.Size(470, 480)
$picVideo.SizeMode = 'Zoom'; $picVideo.BackColor = [System.Drawing.Color]::Black; $picVideo.Anchor = 'Top,Left,Bottom'; $f.Controls.Add($picVideo)
$picFoto = New-Object System.Windows.Forms.PictureBox; $picFoto.Location = New-Object System.Drawing.Point(500, 75); $picFoto.Size = New-Object System.Drawing.Size(450, 480)
$picFoto.SizeMode = 'Zoom'; $picFoto.BackColor = [System.Drawing.Color]::FromArgb(235, 235, 235); $picFoto.Anchor = 'Top,Left,Right,Bottom'; $f.Controls.Add($picFoto)
$lblFoto = NovoLabel '' 500 558; $lblFoto.Anchor = 'Left,Bottom'

$btnCap = New-Object System.Windows.Forms.Button; $btnCap.Text = 'ATIVAR CAPTURA'; $btnCap.Location = New-Object System.Drawing.Point(12, 585); $btnCap.Size = New-Object System.Drawing.Size(230, 48)
$btnCap.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold); $btnCap.BackColor = [System.Drawing.Color]::FromArgb(0, 140, 70); $btnCap.ForeColor = [System.Drawing.Color]::White
$btnCap.FlatStyle = 'Flat'; $btnCap.Enabled = $false; $btnCap.Anchor = 'Left,Bottom'; $f.Controls.Add($btnCap)
$l1 = NovoLabel 'Tempo (s)' 255 590; $l1.Anchor = 'Left,Bottom'
$numSeg = New-Object System.Windows.Forms.NumericUpDown; $numSeg.Location = New-Object System.Drawing.Point(330, 586); $numSeg.Width = 60; $numSeg.Minimum = 10; $numSeg.Maximum = 300; $numSeg.Value = [decimal]$cfg.segundos; $numSeg.Anchor = 'Left,Bottom'; $f.Controls.Add($numSeg)
$btnAbrir = NovoBotao 'Abrir pasta das fotos' 410 585 160
$btnPasta = NovoBotao 'Trocar pasta...' 580 585 120
$btnLog   = NovoBotao 'Abrir LOG' 710 585 100
$btnAtu   = NovoBotao 'Verificar novas versões' 815 585 150; $btnAtu.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$lblStatus = NovoLabel 'Informe o IP, usuário e senha do facial e clique em Conectar.' 12 640; $lblStatus.Anchor = 'Left,Bottom'; $lblStatus.AutoSize = $false; $lblStatus.Width = 930; $lblStatus.Height = 24

$timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 50

# ---------------------------------------------------------------- tarefas de segundo plano (v3.1, 27/10/2026)
# O video e a busca rodam fora da janela (a janela nunca trava). Elas usam as mesmas funcoes do script,
# copiadas para dentro de cada tarefa, e escrevem no mesmo log.
function Bombear { [System.Windows.Forms.Application]::DoEvents() }
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
public class OrdemPorNome : System.Collections.IComparer {
    public int Compare(object a, object b) { return string.CompareOrdinal(((System.Windows.Forms.ListViewItem)a).Name, ((System.Windows.Forms.ListViewItem)b).Name); }
}
'@
$script:FuncsBg = @('Resumo', 'ReqEquip', 'Tabela', 'IpValido', 'IpNum', 'NumIp', 'CapsSemSenha', 'SondaSemSenha', 'Identificar', 'VarrerFaixa', 'BuscarMulticast')
$script:Pool = $null
function PreambuloBg {
    $t = "function Log(`$msg, `$nivel = 'INFO') { `$l = ('{0} [{1}] {2}' -f (Get-Date -Format 'dd/MM HH:mm:ss.fff'), `$nivel, `$msg) + [Environment]::NewLine; [System.Threading.Monitor]::Enter(`$script:Trava); try { [System.IO.File]::AppendAllText(`$script:ArqLog, `$l, [System.Text.Encoding]::UTF8) } catch {} finally { [System.Threading.Monitor]::Exit(`$script:Trava) } }`n"
    $t += "function Bombear { }`n"
    foreach ($n in $script:FuncsBg) { $t += "function $n {`n" + (Get-Item "function:$n").Definition + "`n}`n" }
    return $t
}
function IniciarBg([string]$corpo, $dados) {
    if (-not $script:Pool) {
        $script:Pool = [runspacefactory]::CreateRunspacePool(1, 24); $script:Pool.ApartmentState = 'MTA'; $script:Pool.Open()
        $script:Preambulo = PreambuloBg
    }
    $ps = [powershell]::Create(); $ps.RunspacePool = $script:Pool
    [void]$ps.AddScript("param(`$D, `$ArqLog, `$Trava)`n`$script:ArqLog = `$ArqLog; `$script:Trava = `$Trava`n" + $script:Preambulo + "`n" + $corpo)
    [void]$ps.AddArgument($dados).AddArgument($script:LogFile).AddArgument($script:TravaLog)
    return [pscustomobject]@{ PS = $ps; H = $ps.BeginInvoke() }
}
function FimBg($t) { try { if ($t.H.IsCompleted) { [void]$t.PS.EndInvoke($t.H) } else { $t.PS.Stop() } } catch {}; try { $t.PS.Dispose() } catch {} }

# ---- VIDEO: tres tarefas buscam fotos uma atras da outra, o mais rapido que a rede deixar (no maximo 10 por segundo);
#      a janela so mostra a mais nova. Com MJPG (fluxo continuo) basta uma tarefa.
$script:Vid = [hashtable]::Synchronized(@{ Run = $false; Frame = $null; Seq = 0; Url = ''; Base = ''; User = ''; Pass = ''; Erro = ''; MaxFps = 10 })
$script:VidTarefas = @(); $script:VidVisto = 0; $script:VidMarcas = New-Object System.Collections.Generic.Queue[datetime]; $script:VidUltimo = Get-Date; $script:VidTentou = [datetime]::MinValue
$script:CorpoVideo = @'
$V = $D; $n = [int]$V.Workers
$cache = New-Object System.Net.CredentialCache; $cache.Add([Uri]$V.Base, 'Digest', (New-Object System.Net.NetworkCredential($V.User, $V.Pass)))
$intervalo = 1000.0 * $n / $V.MaxFps          # cada tarefa busca a sua parte das 10 fotos/s
$ini = ([string][char]0xFF) + ([string][char]0xD8); $fimJ = ([string][char]0xFF) + ([string][char]0xD9); $l1 = [System.Text.Encoding]::GetEncoding(28591)
function Abrir($u, $to) { $q = [System.Net.HttpWebRequest]::Create($V.Base + $u); $q.Proxy = $null; $q.Credentials = $cache; $q.PreAuthenticate = $true; $q.KeepAlive = $true; $q.Timeout = $to; $q.ReadWriteTimeout = $to; return $q.GetResponse() }
function Novo($b) { $V.Frame = $b; $V.Seq = $V.Seq + 1; $V.Erro = '' }
$falhas = 0
while ($V.Run) {
    $t0 = Get-Date
    try {
        if ($V.Url -eq 'MJPG') {
            $r = Abrir '/cgi-bin/mjpg/video.cgi?channel=1&subtype=1' 5000
            try {
                $s = $r.GetResponseStream(); $ms = New-Object System.IO.MemoryStream; $buf = New-Object byte[] 65536
                while ($V.Run) {
                    $q = $s.Read($buf, 0, $buf.Length); if ($q -le 0) { break }
                    $ms.Write($buf, 0, $q); $a = $ms.ToArray(); $t = $l1.GetString($a)
                    $i = $t.IndexOf($ini)
                    if ($i -ge 0) { $z = $t.IndexOf($fimJ, $i + 2)
                        if ($z -gt $i) { Novo ([byte[]]$a[$i..($z + 1)]); $ms = New-Object System.IO.MemoryStream; if ($z + 2 -lt $a.Length) { $ms.Write($a, $z + 2, $a.Length - $z - 2) } } }
                    if ($ms.Length -gt 4000000) { $ms = New-Object System.IO.MemoryStream }
                }
            } finally { $r.Close() }
        } else {
            $r = Abrir $V.Url 4000
            try { $ms = New-Object System.IO.MemoryStream; $r.GetResponseStream().CopyTo($ms); $b = $ms.ToArray() } finally { $r.Close() }
            if ($b.Length -gt 1000 -and $b[0] -eq 0xFF -and $b[1] -eq 0xD8) { Novo $b; $falhas = 0 } else { $V.Erro = "quadro invalido ($($b.Length) bytes)" }
        }
    } catch {
        $falhas++; $V.Erro = $_.Exception.GetBaseException().Message
        if ($falhas -eq 1 -or ($falhas % 50) -eq 0) { Log ("Video (tarefa {0}): falha {1}: {2}" -f $V.Id, $falhas, $V.Erro) 'AVISO' }
        Start-Sleep -Milliseconds 400
    }
    $gasto = ((Get-Date) - $t0).TotalMilliseconds
    if ($gasto -lt $intervalo) { Start-Sleep -Milliseconds ([int]($intervalo - $gasto)) }
}
'@
function PararVideo {
    $script:Vid.Run = $false
    $script:VidAntigas += $script:VidTarefas; $script:VidTarefas = @()
    # limpa as que ja terminaram
    $script:VidAntigas = @($script:VidAntigas | Where-Object { if ($_.H.IsCompleted) { FimBg $_; $false } else { $true } })
}
$script:VidAntigas = @()
function IniciarVideo {
    PararVideo
    # cada inicio tem a sua tabela: tarefas antigas param sozinhas (veem Run=false na tabela delas)
    $n = if ($script:UrlQuadro -eq 'MJPG') { 1 } else { 3 }   # 3 em paralelo: rede lenta tambem chega perto de 10/s; o total nunca passa de 10/s
    $script:Vid = [hashtable]::Synchronized(@{ Run = $true; Frame = $null; Seq = 0; Url = $script:UrlQuadro; Base = $script:Base; User = $txtUser.Text.Trim(); Pass = $txtSenha.Text; Erro = ''; MaxFps = 10; Workers = $n; Id = 0 })
    $script:VidVisto = 0
    for ($k = 1; $k -le $n; $k++) {
        $d = $script:Vid
        $script:VidTarefas += IniciarBg $script:CorpoVideo $d
        Start-Sleep -Milliseconds 40   # desencontra as duas tarefas
    }
    Log ("Video em segundo plano: {0} tarefa(s), fonte {1}, no maximo {2} fotos/s" -f $n, $script:UrlQuadro, 10)
}

function MostrarErro($titulo, $ex) {
    LogExcecao $titulo $ex
    $lblStatus.Text = "$titulo (veja o log)."
    [System.Windows.Forms.MessageBox]::Show("$($ex.Message)`n`nLog: $($script:LogFile)", $titulo, 'OK', 'Error') | Out-Null
}

$btnCon.Add_Click({
    try {
        $ip = ($txtIp.Text -replace '^https?://', '' -replace '/.*$', '').Trim(); $porta = $txtPorta.Text.Trim(); if (-not $porta) { $porta = '80' }
        Log ("--- Clique em CONECTAR: ip={0} porta={1} usuario={2} senha={3}" -f $ip, $porta, $txtUser.Text.Trim(), $(if ($txtSenha.Text) { 'informada' } else { 'VAZIA' }))
        if (-not $ip) { throw 'Informe o IP do facial.' }
        $timer.Stop(); PararVideo; $script:VidTentou = [datetime]::MinValue; if ($script:Capturando) { EncerrarCaptura 'nova conexao' }
        $script:Base = "http://${ip}:$porta"; $script:UrlQuadro = $null; $script:Falhas = 0; $script:Quadros = 0; $script:ContRep = @{}
        $cred = New-Object System.Net.NetworkCredential($txtUser.Text.Trim(), $txtSenha.Text)
        $script:Cache = New-Object System.Net.CredentialCache; $script:Cache.Add([Uri]$script:Base, 'Digest', $cred)
        $lblStatus.Text = 'Conectando...'; $f.Refresh()
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $ok = $tcp.ConnectAsync($ip, [int]$porta).Wait(3000)
            Log ("Teste de rede (TCP {0}:{1}): {2}" -f $ip, $porta, $(if ($ok -and $tcp.Connected) { 'porta alcancavel' } else { 'SEM RESPOSTA em 3s (equipamento desligado, IP/porta errados ou bloqueio de rede/firewall)' })) $(if ($ok -and $tcp.Connected) { 'INFO' } else { 'ERRO' })
            $tcp.Close()
        } catch { Log ("Teste de rede (TCP) falhou: {0}" -f $_.Exception.GetBaseException().Message) 'ERRO' }
        $v = Texto '/cgi-bin/magicBox.cgi?action=getSoftwareVersion'
        if ($v -like 'ERRO*') { throw "Não foi possível conectar. Confira IP, porta, usuário e senha (401 = usuário/senha incorretos).`n`n$v" }
        Log "Conectado. Firmware: $v"
        SalvarCfg
        $btnCap.Enabled = $true; $lblStatus.Text = "Conectado ($v). Aguardando vídeo..."; $timer.Start()
    } catch { MostrarErro 'Falha na conexão' $_.Exception }
})
$script:IgnorarCliqueAte = [datetime]::MinValue
$btnCap.Add_Click({
    # 27/10: ativar leva ~3 s; um clique dado nesse tempo (ou clique duplo) ficava na fila e CANCELAVA a captura
    # logo depois de ativar. Agora o botao fica desligado enquanto ativa e cliques que chegam logo em seguida sao ignorados.
    if ((Get-Date) -lt $script:IgnorarCliqueAte) { Log 'Clique em ATIVAR/CANCELAR ignorado (chegou durante a ativacao)' 'AVISO'; return }
    try {
        if ($script:Capturando) { Log 'Usuario clicou em CANCELAR CAPTURA'; EncerrarCaptura 'cancelada pelo usuario'; $lblStatus.Text = 'Captura cancelada.' }
        else {
            Log 'Usuario clicou em ATIVAR CAPTURA'
            $btnCap.Enabled = $false; $btnCap.Text = 'ATIVANDO...'; $f.Refresh()
            try { IniciarCaptura; SalvarCfg }
            finally {
                [System.Windows.Forms.Application]::DoEvents()          # descarta os cliques que ficaram na fila
                $script:IgnorarCliqueAte = (Get-Date).AddMilliseconds(800)
                $btnCap.Enabled = $true
                if (-not $script:Capturando) { $btnCap.Text = 'ATIVAR CAPTURA' }
            }
        }
    } catch { MostrarErro 'Erro ao ativar a captura' $_.Exception }
})
$btnAbrir.Add_Click({ New-Item -ItemType Directory -Force -Path $script:Pasta | Out-Null; Start-Process explorer.exe $script:Pasta })
$btnPasta.Add_Click({
    $d = New-Object System.Windows.Forms.FolderBrowserDialog; $d.SelectedPath = $script:Pasta
    if ($d.ShowDialog() -eq 'OK') { $script:Pasta = $d.SelectedPath; SalvarCfg; Log "Pasta das fotos alterada para: $($script:Pasta)"; $lblStatus.Text = "Pasta das fotos: $($script:Pasta)" }
})
# ---- ATUALIZAR (27/10/2026): baixa a versao publicada no site e troca este arquivo (a atual vai para versao_anterior\)
$script:UrlAtualizacao = 'https://nantes3264.github.io/acessovirtual/'
$btnAtu.Add_Click({
    $url = $script:UrlAtualizacao + 'CAPTURA_FACIAL.ps1'
    try {
        Log "Atualizar: procurando versao nova em $url"
        $lblStatus.Text = 'Procurando versão nova...'; $f.Refresh()
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        $novo = $null
        try {
            $req = [System.Net.HttpWebRequest]::Create($url + '?t=' + [DateTime]::Now.Ticks)   # ?t= evita copia antiga em cache
            $req.Timeout = 15000; $req.Proxy = [System.Net.WebRequest]::GetSystemWebProxy(); $req.Proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
            $r = $req.GetResponse(); try { $ms = New-Object System.IO.MemoryStream; $r.GetResponseStream().CopyTo($ms); $novo = $ms.ToArray() } finally { $r.Close() }
        } catch { Log ("Atualizar: nao achei {0}: {1}" -f $url, $_.Exception.GetBaseException().Message) 'AVISO' }
        $txtNovo = if ($novo) { [System.Text.Encoding]::UTF8.GetString($novo).TrimStart([char]0xFEFF) } else { '' }
        if (-not $txtNovo -or $txtNovo -notmatch 'Ferramenta de suporte' -or $txtNovo -notmatch 'Captura Facial') {
            $lblStatus.Text = 'Nenhuma versão nova publicada.'
            if ([System.Windows.Forms.MessageBox]::Show("Não encontrei uma versão para baixar em:`n$url`n`n(Para publicar, coloque o CAPTURA_FACIAL.ps1 nesse endereço do site.)`n`nAbrir a página no navegador?", 'Atualizar', 'YesNo', 'Information') -eq 'Yes') { Start-Process $script:UrlAtualizacao }
            return
        }
        $atual = [System.IO.File]::ReadAllText($PSCommandPath, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
        $vN = if ($txtNovo -match "Captura Facial - versao ([\w.]+)") { $Matches[1] } else { '?' }
        $vA = if ($atual -match "Captura Facial - versao ([\w.]+)") { $Matches[1] } else { '?' }
        if ($txtNovo.Replace("`r`n", "`n") -eq $atual.Replace("`r`n", "`n")) { $lblStatus.Text = "Você já está na versão mais nova ($vA)."; [System.Windows.Forms.MessageBox]::Show("Você já está na versão mais nova ($vA).", 'Atualizar') | Out-Null; return }
        if ([System.Windows.Forms.MessageBox]::Show("Há uma versão diferente publicada.`n`nAtual: $vA`nNo site: $vN`n`nAtualizar agora? A versão atual fica guardada em versao_anterior e a ferramenta reabre.", 'Atualizar', 'YesNo', 'Question') -ne 'Yes') { return }
        # confere se o arquivo baixado e um script PowerShell valido antes de trocar
        $erros = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($txtNovo, [ref]$null, [ref]$erros)
        if ($erros -and $erros.Count) { throw "O arquivo do site tem erro de script (linha $($erros[0].Extent.StartLineNumber): $($erros[0].Message)). Nada foi trocado." }
        $pasta = Join-Path (Split-Path $PSCommandPath) 'versao_anterior'; New-Item -ItemType Directory -Force -Path $pasta | Out-Null
        $copia = Join-Path $pasta ('CAPTURA_FACIAL_{0}_{1}.ps1' -f $vA, (Get-Date -Format 'yyyyMMdd_HHmmss'))
        Copy-Item -LiteralPath $PSCommandPath -Destination $copia -Force
        [System.IO.File]::WriteAllText($PSCommandPath, $txtNovo, (New-Object System.Text.UTF8Encoding($true)))   # UTF-8 com BOM (acentos no PowerShell 5)
        Log "Atualizar: trocado $vA -> $vN (copia em $copia); reabrindo"
        Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"")
        $f.Close()
    } catch { MostrarErro 'Erro ao atualizar' $_.Exception }
})
$btnLog.Add_Click({
    if ($script:LogFile -and (Test-Path $script:LogFile)) { Start-Process explorer.exe "/select,`"$($script:LogFile)`"" }
    else { [System.Windows.Forms.MessageBox]::Show('Arquivo de log não encontrado.', 'Log') | Out-Null }
})
$timer.Add_Tick({
    if ($script:EmTick) { return }; $script:EmTick = $true
    try {
        $b = $null
        if (-not $script:Vid.Run) {
            # ainda nao sabe de onde vem o video: descobre (a cada 2 s) e liga as tarefas de segundo plano
            if (((Get-Date) - $script:VidTentou).TotalSeconds -ge 2) {
                $script:VidTentou = Get-Date
                $b = ObterQuadro
                if ($b) { TrocarImagem $picVideo (ParaImagem $b); $script:Quadros++; IniciarVideo; $script:VidUltimo = Get-Date }
                else { $script:Falhas++; if ($script:Falhas -eq 4) { Log 'Sem video: 4 tentativas seguidas falharam' 'AVISO' } }
            }
        } elseif ($script:Vid.Seq -ne $script:VidVisto) {
            $script:VidVisto = $script:Vid.Seq; $b = $script:Vid.Frame
            if ($b) {
                try { TrocarImagem $picVideo (ParaImagem $b) } catch {}
                $script:Quadros++; $agora = Get-Date; $script:VidUltimo = $agora
                $script:VidMarcas.Enqueue($agora); while ($script:VidMarcas.Count -gt 0 -and ($agora - $script:VidMarcas.Peek()).TotalSeconds -gt 2) { [void]$script:VidMarcas.Dequeue() }
                $fps = $script:VidMarcas.Count / 2.0
                $lblV.Text = ('Vídeo ao vivo do facial  ({0:N1} fotos/s)' -f $fps)
                if ($script:Quadros -eq 2 -or ($script:Quadros % 500) -eq 0) { Log ("Quadros de video exibidos: {0} ({1:N1} fotos/s)" -f $script:Quadros, $fps) }
            }
        } elseif (((Get-Date) - $script:VidUltimo).TotalSeconds -gt 5) {
            $lblV.Text = 'Vídeo ao vivo do facial  (sem imagem nova há mais de 5 s)'
        }
        if ($script:Capturando) { VerificarCaptura }
        elseif ($script:Falhas -ge 4 -and -not $picVideo.Image) { $lblStatus.Text = 'Sem vídeo deste facial (a captura de foto ainda funciona). Veja o log.' }
        elseif ($lblStatus.Text -like 'Conectado*' -and $picVideo.Image) { $lblStatus.Text = 'Vídeo ao vivo. Clique em ATIVAR CAPTURA quando o cliente estiver pronto.' }
    } catch { LogRep 'tick' ("Erro no ciclo (linha {0}): {1}" -f $_.InvocationInfo.ScriptLineNumber, $_.Exception.ToString()) }
    finally { $script:EmTick = $false }
})
$f.Add_FormClosing({ $timer.Stop(); PararVideo; if ($script:BuscaD) { $script:BuscaD.Run = $false }; try { if ($script:SnResp) { $script:SnResp.Close() } } catch {}; SalvarCfg })

# ================================================================ BUSCADOR DE IP (27/10/2026)
# Acha os equipamentos na rede, diz o modelo e se e da linha Bio-T (lista oficial do Portal de Integracao
# Intelbras), e para o escolhido: rede (trocar IP), porta (estado, status, comandos) e equipamento.
# Comandos usados (portal-integracao.intelbras.com.br/linha-de-faciais):
#   magicBox.cgi getSystemInfo / getDeviceType / getSoftwareVersion / getSerialNo / reboot
#   configManager.cgi getConfig&name=Network | AccessControl | AccessControlGeneral, setConfig
#   accessControl.cgi openDoor / closeDoor / getDoorStatus
# Busca: 1) aviso na rede (multicast 239.255.255.251:37810, o mesmo que o IP Utility usa para LISTAR,
#        sem senha); 2) varredura da faixa de IP (porta HTTP) + identificacao com usuario e senha.
$script:BioTComApi = @('SS 5520','SS 5530 MF FACE','SS 5530 MF FACE LITE','SS 3530 MF FACE W','SS 3430 BIO','SS 3430 MF BIO',
    'SS 7520 FACE T','SS 7530 FACE','SS 3530 MF FACE','SS 3540 MF FACE EX','SS 1540 MF W','SS 1530 MF W','SS 3540 MF FACE BIO EX',
    'SS 3540 MF FACE BIO','SS 3532 MF W','SS 3532 MF','SS 3542 MF W','SS 3531 MF','SS 5531 MF W','SS 5541 MF W','SS 5532 MF W',
    'SS 5542 MF W','SS 5430 MF BIO FT','SS 3541 MF','SS 3531 MF LITE','SS 3542 MF LITE','SS 5531 MF EX')
$script:BioTSemApi = @('SS 3420 BIO','SS 3420 MF BIO')
function NormModelo($m) { return (($m + '') -replace '[\s\-_]', '').ToUpperInvariant() }
function ClassificarBioT($modelo) {
    if (-not $modelo) { return '?' }
    if ($modelo -like 'INTELBRAS/DAHUA*') { return 'Intelbras - precisa da senha' }
    if ($modelo -like '(*') { return 'NÃO' }
    $n = NormModelo $modelo
    foreach ($x in $script:BioTComApi) { if ((NormModelo $x) -eq $n) { return 'SIM (Bio-T com API)' } }
    foreach ($x in $script:BioTSemApi) { if ((NormModelo $x) -eq $n) { return 'Bio-T SEM API' } }
    foreach ($x in $script:BioTComApi) { if ($n.StartsWith((NormModelo $x))) { return 'SIM (variante Bio-T)' } }
    if ($n -like 'SS*') { return 'Provável (linha SS, fora da lista)' }
    return 'NÃO'
}

# --- requisicao a um equipamento qualquer (Digest), sem mexer na conexao principal
function ReqEquip($ip, $porta, $usuario, $senha, $caminho, $timeout = 6000) {
    $base = "http://${ip}:$porta"
    try {
        $req = [System.Net.HttpWebRequest]::Create($base + $caminho)
        $req.Proxy = $null; $req.Timeout = $timeout; $req.ReadWriteTimeout = $timeout; $req.KeepAlive = $false
        $c = New-Object System.Net.CredentialCache; $c.Add([Uri]$base, 'Digest', (New-Object System.Net.NetworkCredential($usuario, $senha))); $req.Credentials = $c
        $r = $req.GetResponse()
        try { $t = (New-Object System.IO.StreamReader($r.GetResponseStream())).ReadToEnd() } finally { $r.Close() }
        Log ("[{0}] GET {1} -> {2}" -f $ip, $caminho, (Resumo $t 200))
        return @{ Status = 200; Texto = $t.Trim(); Realm = '' }
    } catch {
        $ex = $_.Exception; while ($ex.InnerException -and -not ($ex -is [System.Net.WebException])) { $ex = $ex.InnerException }
        $st = 0; $realm = ''; $corpo = ''
        if ($ex -is [System.Net.WebException] -and $ex.Response) {
            $st = [int]$ex.Response.StatusCode
            $realm = [string]$ex.Response.Headers['WWW-Authenticate']
            try { $corpo = (New-Object System.IO.StreamReader($ex.Response.GetResponseStream())).ReadToEnd() } catch {}
        }
        $srv = ''; try { if ($ex.Response) { $srv = [string]$ex.Response.Headers['Server'] } } catch {}
        Log ("[{0}] GET {1} -> ERRO HTTP {2}: {3}{4}{5}" -f $ip, $caminho, $st, $ex.Message, $(if ($realm) { " | WWW-Authenticate: $realm" } else { '' }), $(if ($srv) { " | Server: $srv" } else { '' })) 'AVISO'
        return @{ Status = $st; Texto = $corpo.Trim(); Realm = $realm; Erro = $ex.Message }
    }
}
function Tabela($texto) {
    $d = @{}
    foreach ($l in (($texto + '') -split "`n")) { $i = $l.IndexOf('='); if ($i -gt 0) { $d[$l.Substring(0, $i).Trim()] = $l.Substring($i + 1).Trim() } }
    return $d
}
function IpValido($s) { return ($s -match '^((25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(25[0-5]|2[0-4]\d|1?\d?\d)$') }
function IpNum($s) { $p = $s.Split('.'); return ([uint32]$p[0] -shl 24) + ([uint32]$p[1] -shl 16) + ([uint32]$p[2] -shl 8) + [uint32]$p[3] }
function NumIp($n) { return '{0}.{1}.{2}.{3}' -f (($n -shr 24) -band 255), (($n -shr 16) -band 255), (($n -shr 8) -band 255), ($n -band 255) }

# --- faixas das placas de rede deste PC (ex.: 10.1.31.1-10.1.31.254)
function FaixasDoPc {
    $r = @()
    foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($ni.OperationalStatus -ne 'Up' -or $ni.NetworkInterfaceType -eq 'Loopback') { continue }
        foreach ($u in $ni.GetIPProperties().UnicastAddresses) {
            if ($u.Address.AddressFamily -ne 'InterNetwork' -or -not $u.IPv4Mask) { continue }
            $ip = $u.Address.ToString(); if ($ip -like '169.254.*') { continue }
            $m = IpNum $u.IPv4Mask.ToString(); $mm = if ((IpNum '255.255.255.0') -gt $m) { IpNum '255.255.255.0' } else { $m }   # no maximo /24 (254 IPs)
            $rede = (IpNum $ip) -band $mm; $bc = $rede -bor ((-bnot $mm) -band 0xFFFFFFFF)
            $r += ('{0}-{1}' -f (NumIp ($rede + 1)), (NumIp ($bc - 1)))
        }
    }
    return $r
}

# --- 1) aviso na rede: DHDiscover.search (sem senha; acha ate em outra faixa de IP)
function BuscarMulticast($segundos = 3, $ipsDiretos = @()) {
    $achados = @()
    $json = '{"method":"DHDiscover.search","params":{"mac":"","uni":1}}'
    $corpo = [System.Text.Encoding]::UTF8.GetBytes($json)
    $cab = New-Object byte[] 32
    $cab[0] = 0x20; [Array]::Copy([System.Text.Encoding]::ASCII.GetBytes('DHIP'), 0, $cab, 4, 4)
    [Array]::Copy([BitConverter]::GetBytes([int]$corpo.Length), 0, $cab, 16, 4)
    [Array]::Copy([BitConverter]::GetBytes([int]$corpo.Length), 0, $cab, 24, 4)
    $pacote = New-Object byte[] (32 + $corpo.Length); [Array]::Copy($cab, $pacote, 32); [Array]::Copy($corpo, 0, $pacote, 32, $corpo.Length)
    $socks = @()
    try {
        $grupo = [System.Net.IPAddress]::Parse('239.255.255.251')
        # um socket por placa de rede (assim o aviso sai por todas)
        foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($ni.OperationalStatus -ne 'Up' -or $ni.NetworkInterfaceType -eq 'Loopback') { continue }
            foreach ($u in $ni.GetIPProperties().UnicastAddresses) {
                if ($u.Address.AddressFamily -ne 'InterNetwork' -or $u.Address.ToString() -like '169.254.*') { continue }
                try {
                    $s = New-Object System.Net.Sockets.UdpClient
                    $s.Client.SetSocketOption('Socket', 'ReuseAddress', $true)
                    # envia PELA porta 37810 (como o IP Utility): o aparelho responde para a 37810 e o Firewall do Windows
                    # aceita, porque e resposta ao que saiu dessa porta. Se a porta estiver ocupada, usa uma qualquer.
                    try { $s.Client.Bind((New-Object System.Net.IPEndPoint($u.Address, 37810))) }
                    catch { $s.Close(); $s = New-Object System.Net.Sockets.UdpClient; $s.Client.SetSocketOption('Socket', 'ReuseAddress', $true); $s.Client.Bind((New-Object System.Net.IPEndPoint($u.Address, 0))); Log ("Busca UDP: porta 37810 ocupada em {0} (IP Utility aberto?) - usando outra" -f $u.Address) 'AVISO' }
                    $s.EnableBroadcast = $true
                    try { $s.JoinMulticastGroup($grupo, $u.Address) } catch {}
                    [void]$s.Send($pacote, $pacote.Length, (New-Object System.Net.IPEndPoint($grupo, 37810)))
                    try { [void]$s.Send($pacote, $pacote.Length, (New-Object System.Net.IPEndPoint($grupo, 37820))) } catch {}   # o IP Utility usa as duas
                    [void]$s.Send($pacote, $pacote.Length, (New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Broadcast, 37810)))
                    $socks += $s
                } catch { Log ("Busca multicast: placa {0} falhou: {1}" -f $u.Address, $_.Exception.Message) 'AVISO' }
            }
        }
        # pedido direto a cada IP da faixa (UDP 37810), como o "Buscar por IP" do IP Utility: acha o modelo
        # sem senha mesmo quando a rede bloqueia o multicast
        if ($ipsDiretos.Count) {
            $env = 0
            foreach ($ipd in $ipsDiretos) {
                $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($ipd), 37810)
                foreach ($s in $socks) { try { [void]$s.Send($pacote, $pacote.Length, $ep); $env++ } catch {} }
            }
            Log ("Busca UDP direta: pedido enviado a {0} IP(s) ({1} envios)" -f $ipsDiretos.Count, $env)
        }
        # a resposta tambem pode vir para a porta 37810 (multicast)
        try {
            $s2 = New-Object System.Net.Sockets.UdpClient
            $s2.Client.SetSocketOption('Socket', 'ReuseAddress', $true)
            $s2.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 37810)))
            $s2.JoinMulticastGroup($grupo); $socks += $s2
        } catch { Log ("Busca multicast: nao deu para ouvir a porta 37810 ({0}) - seguimos so com as respostas diretas" -f $_.Exception.Message) 'AVISO' }
        Log ("Busca multicast enviada por {0} socket(s); ouvindo {1}s" -f $socks.Count, $segundos)
        $fim = (Get-Date).AddSeconds($segundos); $vistos = @{}
        while ((Get-Date) -lt $fim) {
            $algum = $false
            foreach ($s in $socks) {
                while ($s.Available -gt 0) {
                    $algum = $true
                    $de = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
                    $b = $s.Receive([ref]$de)
                    if ($b.Length -le 32) { continue }
                    $t = [System.Text.Encoding]::UTF8.GetString($b, 32, $b.Length - 32)
                    if ($t -notmatch 'deviceInfo') { continue }
                    try { $o = ($t.Substring($t.IndexOf('{'))) | ConvertFrom-Json } catch { Log ("Busca multicast: resposta ilegivel de {0}: {1}" -f $de.Address, (Resumo $t 200)) 'AVISO'; continue }
                    $di = $o.params.deviceInfo; if (-not $di) { continue }
                    $ip4 = $di.IPv4Address
                    $ip = if ($ip4 -and $ip4.IPAddress) { [string]$ip4.IPAddress } else { $de.Address.ToString() }
                    $mac = [string]$di.Mac
                    $chave = if ($mac) { $mac } else { $ip }
                    if ($vistos[$chave]) { continue }; $vistos[$chave] = $true
                    $porta = if ($di.HttpPort) { [string]$di.HttpPort } elseif ($di.Port) { '80' } else { '80' }
                    $achados += [pscustomobject]@{ IP = $ip; Porta = $porta; Modelo = [string]$di.DeviceType; Serie = [string]$di.SerialNo; MAC = $mac
                        Firmware = [string]$di.Version; Mascara = $(if ($ip4) { [string]$ip4.SubnetMask } else { '' }); Gateway = $(if ($ip4) { [string]$ip4.DefaultGateway } else { '' })
                        Dhcp = $(if ($ip4) { [string]$ip4.DhcpEnable } else { '' }); Origem = 'busca UDP (sem senha)' }
                    Log ("Busca multicast: {0} {1} serie={2} mac={3}" -f $ip, $di.DeviceType, $di.SerialNo, $mac)
                }
            }
            if (-not $algum) { Start-Sleep -Milliseconds 100 }
            Bombear
        }
    } catch { Log ("Busca multicast falhou: {0}" -f $_.Exception.Message) 'ERRO' }
    finally { foreach ($s in $socks) { try { $s.Close() } catch {} } }
    return $achados
}

# --- 2) varredura: quem responde na porta HTTP da faixa
# v3.2 (27/10): em lotes de 64 (254 de uma vez fazia a rede/PC perder respostas - ex.: .158 e .159 respondiam ping
# e nao apareciam), 1,5 s por IP, e olha tambem a porta 37777 (exclusiva dos Intelbras/Dahua) e o ping.
# Devolve um objeto por IP que respondeu: IP, Http (porta web aberta), P37777, Ping.
function VarrerFaixa($inicio, $fimIp, $porta, $msTimeout = 1500, $tamLote = 64, $lista = $null) {
    $a = IpNum $inicio; $z = IpNum $fimIp
    if ($z -lt $a) { $t = $a; $a = $z; $z = $t }
    if (($z - $a) -gt 1023) { throw 'Faixa grande demais (máximo 1024 IPs).' }
    $ips = @(); if ($lista) { $ips = @($lista) } else { for ($n = $a; $n -le $z; $n++) { $ips += (NumIp $n) } }
    $res = @()
    for ($b = 0; $b -lt $ips.Count; $b += $tamLote) {
        $lote = $ips[$b..([math]::Min($b + $tamLote - 1, $ips.Count - 1))]
        $tarefas = @()
        foreach ($ip in $lote) {
            $c1 = New-Object System.Net.Sockets.TcpClient; $c2 = New-Object System.Net.Sockets.TcpClient; $pg = New-Object System.Net.NetworkInformation.Ping
            $tarefas += [pscustomobject]@{ IP = $ip; C1 = $c1; T1 = $c1.ConnectAsync($ip, [int]$porta); C2 = $c2; T2 = $c2.ConnectAsync($ip, 37777); P = $pg; T3 = $pg.SendPingAsync($ip, $msTimeout) }
        }
        $limite = (Get-Date).AddMilliseconds($msTimeout + 300)
        while ((Get-Date) -lt $limite -and @($tarefas | Where-Object { -not ($_.T1.IsCompleted -and $_.T2.IsCompleted -and $_.T3.IsCompleted) }).Count -gt 0) { Start-Sleep -Milliseconds 50; Bombear }
        foreach ($x in $tarefas) {
            $h = ($x.T1.IsCompleted -and -not $x.T1.IsFaulted -and $x.C1.Connected)
            $d = ($x.T2.IsCompleted -and -not $x.T2.IsFaulted -and $x.C2.Connected)
            $p = $false; try { $p = ($x.T3.IsCompleted -and -not $x.T3.IsFaulted -and $x.T3.Result.Status -eq 'Success') } catch {}
            if ($h -or $d -or $p) { $res += [pscustomobject]@{ IP = $x.IP; Http = $h; P37777 = $d; Ping = $p } }
            try { $x.C1.Close() } catch {}; try { $x.C2.Close() } catch {}; try { $x.P.Dispose() } catch {}
        }
    }
    Log ("Varredura {0}-{1} ({7} IPs, {8} ms): {2} IP(s) responderam ({3} com porta {4}, {5} com porta 37777 Intelbras/Dahua, {6} so ping)" -f $inicio, $fimIp, $res.Count,
        @($res | Where-Object { $_.Http }).Count, $porta, @($res | Where-Object { $_.P37777 }).Count, @($res | Where-Object { -not $_.Http -and -not $_.P37777 }).Count, $ips.Count, $msTimeout)
    return $res
}
# --- identifica um IP: modelo, serie, firmware (precisa de usuario e senha; sem eles diz so se e Intelbras/Dahua)
# Pergunta que a tela de login web dos Intelbras/Dahua faz ANTES da senha: responde com realm "Login to <serie>".
function SondaSemSenha($ip, $porta) {
    $r = @{ Marca = $false; Serie = ''; Pista = '' }
    try {
        $req = [System.Net.HttpWebRequest]::Create("http://${ip}:$porta/RPC2_Login")
        $req.Proxy = $null; $req.Method = 'POST'; $req.ContentType = 'application/json'; $req.Timeout = 4000; $req.ReadWriteTimeout = 4000; $req.KeepAlive = $false
        $b = [System.Text.Encoding]::UTF8.GetBytes('{"method":"global.login","params":{"userName":"admin","password":"","clientType":"Web3.0","loginType":"Direct"},"id":1}')
        $st = $req.GetRequestStream(); $st.Write($b, 0, $b.Length); $st.Close()
        $resp = $req.GetResponse(); try { $t = (New-Object System.IO.StreamReader($resp.GetResponseStream())).ReadToEnd() } finally { $resp.Close() }
        Log ("[{0}] POST /RPC2_Login (sem senha) -> {1}" -f $ip, (Resumo $t 300))
        if ($t -match '"realm"\s*:\s*"Login to\s*([^"]*)"') { $r.Marca = $true; $r.Serie = $Matches[1].Trim(); $r.Pista = 'RPC2_Login' }
        elseif ($t -match '"encryption"\s*:' -and $t -match '"random"\s*:') { $r.Marca = $true; $r.Pista = 'RPC2_Login' }
    } catch { Log ("[{0}] POST /RPC2_Login (sem senha) -> {1}" -f $ip, $_.Exception.GetBaseException().Message) 'AVISO' }
    if (-not $r.Marca) {
        # pagina inicial da interface web nova (Web 2.0) dos Intelbras/Dahua
        try {
            $req = [System.Net.HttpWebRequest]::Create("http://${ip}:$porta/"); $req.Proxy = $null; $req.Timeout = 4000; $req.ReadWriteTimeout = 4000; $req.KeepAlive = $false
            $resp = $req.GetResponse(); try { $t = (New-Object System.IO.StreamReader($resp.GetResponseStream())).ReadToEnd() } finally { $resp.Close() }
            if ($t -match 'browserJudge\.js' -and $t -match 'tempToken') { $r.Marca = $true; $r.Pista = 'pagina web' }
            Log ("[{0}] GET / (sem senha) -> {1}" -f $ip, (Resumo ($t -replace '\s+', ' ') 200))
        } catch {}
    }
    return $r
}
# A tela de login web (Web 2.0) pergunta isto ANTES da senha - conferido num SS 3532 MF W em 27/10/2026:
#   POST /RPC2 {"method":"WebInit.getCaps","params":null,"id":1,"session":0}
#   -> {"params":{"DevModel":"SS 3532 MF W","SN":"...","SoftVersion":"...","vendor":"Intelbras","NetInfo":{"eth0":{"IP":..,"MAC":..}}},"result":true}
# Firmwares sem esse metodo: a pagina usa /current_config/webCapsConfig (mesmos campos).
function CapsSemSenha($ip, $porta) {
    $t = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create("http://${ip}:$porta/RPC2")
        $req.Proxy = $null; $req.Method = 'POST'; $req.ContentType = 'application/json'; $req.Timeout = 3000; $req.ReadWriteTimeout = 3000; $req.KeepAlive = $false
        $b = [System.Text.Encoding]::UTF8.GetBytes('{"method":"WebInit.getCaps","params":null,"id":1,"session":0}')
        $st = $req.GetRequestStream(); $st.Write($b, 0, $b.Length); $st.Close()
        $resp = $req.GetResponse(); try { $t = (New-Object System.IO.StreamReader($resp.GetResponseStream())).ReadToEnd() } finally { $resp.Close() }
        Log ("[{0}] POST /RPC2 WebInit.getCaps (sem senha) -> {1}" -f $ip, (Resumo $t 300))
    } catch { Log ("[{0}] POST /RPC2 WebInit.getCaps (sem senha) -> {1}" -f $ip, $_.Exception.GetBaseException().Message) 'AVISO' }
    if (-not ($t -match 'DevModel')) {
        try {
            $req = [System.Net.HttpWebRequest]::Create("http://${ip}:$porta/current_config/webCapsConfig?version=2.400"); $req.Proxy = $null; $req.Method = 'POST'; $req.ContentLength = 0; $req.Timeout = 3000; $req.ReadWriteTimeout = 3000; $req.KeepAlive = $false
            $resp = $req.GetResponse(); try { $t = (New-Object System.IO.StreamReader($resp.GetResponseStream())).ReadToEnd() } finally { $resp.Close() }
            Log ("[{0}] /current_config/webCapsConfig (sem senha) -> {1}" -f $ip, (Resumo $t 300))
        } catch { Log ("[{0}] /current_config/webCapsConfig (sem senha) -> {1}" -f $ip, $_.Exception.GetBaseException().Message) 'AVISO' }
    }
    if (-not ($t -match 'DevModel')) { return $null }
    try { $j = $t | ConvertFrom-Json } catch { return $null }
    $c = if ($j.params) { $j.params } else { $j }
    if (-not $c.DevModel) { return $null }
    $mac = ''; try { $mac = [string]$c.NetInfo.eth0.MAC } catch {}
    return @{ Modelo = [string]$c.DevModel; Serie = [string]$c.SN; Firmware = [string]$c.SoftVersion; MAC = $mac }
}
function Identificar($ip, $porta, $usuario, $senha) {
    $o = [pscustomobject]@{ IP = $ip; Porta = [string]$porta; Modelo = ''; Serie = ''; MAC = ''; Firmware = ''; Mascara = ''; Gateway = ''; Dhcp = ''; Origem = 'varredura' }
    # 1o SEM senha: modelo, serie, MAC e firmware (igual a tela de login)
    $cp = CapsSemSenha $ip $porta
    if ($cp) {
        $o.Modelo = $cp.Modelo; $o.Serie = $cp.Serie; $o.MAC = $cp.MAC; $o.Firmware = $cp.Firmware; $o.Origem = 'varredura (sem senha)'
        if (-not $senha) { return $o }
        $rd = ReqEquip $ip $porta $usuario $senha '/cgi-bin/configManager.cgi?action=getConfig&name=Network' 4000
        if ($rd.Status -eq 200) { $t = Tabela $rd.Texto; $nic = $t['table.Network.DefaultInterface']; if (-not $nic) { $nic = 'eth0' }
            if (-not $o.MAC) { $o.MAC = [string]$t["table.Network.$nic.PhysicalAddress"] }
            $o.Mascara = [string]$t["table.Network.$nic.SubnetMask"]; $o.Gateway = [string]$t["table.Network.$nic.DefaultGateway"]; $o.Dhcp = [string]$t["table.Network.$nic.DhcpEnable"] }
        return $o
    }
    $si = ReqEquip $ip $porta $usuario $senha '/cgi-bin/magicBox.cgi?action=getSystemInfo' 4000
    if ($si.Status -eq 200) {
        $t = Tabela $si.Texto; $o.Modelo = [string]$t['deviceType']; $o.Serie = [string]$t['serialNumber']
        if (-not $o.Modelo) { $dt = ReqEquip $ip $porta $usuario $senha '/cgi-bin/magicBox.cgi?action=getDeviceType' 4000; if ($dt.Status -eq 200) { $o.Modelo = [string](Tabela $dt.Texto)['type'] } }
        $v = ReqEquip $ip $porta $usuario $senha '/cgi-bin/magicBox.cgi?action=getSoftwareVersion' 4000; if ($v.Status -eq 200) { $o.Firmware = [string](Tabela $v.Texto)['version'] }
        $rd = ReqEquip $ip $porta $usuario $senha '/cgi-bin/configManager.cgi?action=getConfig&name=Network' 4000
        if ($rd.Status -eq 200) { $t = Tabela $rd.Texto; $nic = $t['table.Network.DefaultInterface']; if (-not $nic) { $nic = 'eth0' }
            $o.MAC = [string]$t["table.Network.$nic.PhysicalAddress"]; $o.Mascara = [string]$t["table.Network.$nic.SubnetMask"]; $o.Gateway = [string]$t["table.Network.$nic.DefaultGateway"]; $o.Dhcp = [string]$t["table.Network.$nic.DhcpEnable"] }
    } elseif ($si.Status -eq 401) {
        # Intelbras/Dahua respondem sem senha com realm "Login to <numero de serie>": da para saber que e Intelbras
        if ($si.Realm -match 'Login to\s*([^",\s]*)') {
            if ($Matches[1]) { $o.Serie = $Matches[1] }
            $o.Modelo = if ($senha) { 'INTELBRAS/DAHUA (senha errada: informe a certa para ver o modelo)' } else { 'INTELBRAS/DAHUA (sem senha: informe para ver o modelo)' }
        } else { $o.Modelo = '(outro equipamento: pede senha, mas não é Intelbras/Dahua)' }
    } elseif ($si.Status -gt 0) { $o.Modelo = "(outro equipamento: site HTTP $($si.Status), não é Intelbras/Dahua)" }
    else { $o.Modelo = '(porta aberta, mas não responde como site - PC ou outro equipamento)' }
    if ($o.Modelo -like '(*') {
        # firmware novo (Web 2.0) nao manda "Login to" no CGI: pergunta como a tela de login faz
        $sd = SondaSemSenha $ip $porta
        if ($sd.Marca) {
            if ($sd.Serie -and -not $o.Serie) { $o.Serie = $sd.Serie }
            $o.Modelo = if ($senha -and $si.Status -eq 401) { 'INTELBRAS/DAHUA (senha errada: informe a certa para ver o modelo)' } else { 'INTELBRAS/DAHUA (sem senha: informe para ver o modelo)' }
            Log ("[{0}] identificado como Intelbras/Dahua pela {1}" -f $ip, $sd.Pista)
        }
    }
    return $o
}

# ---------------------------------------------------------------- janela do buscador
# a janela e montada uma vez (como a principal) e reaberta pelo botao
    $w = New-Object System.Windows.Forms.Form
    $w.Text = 'Buscador de IP - equipamentos Intelbras'; $w.Size = New-Object System.Drawing.Size(1100, 760); $w.StartPosition = 'CenterParent'
    $w.MinimumSize = New-Object System.Drawing.Size(980, 680); $w.Font = $f.Font
    function BL($t, $x, $y, $pai) { $l = New-Object System.Windows.Forms.Label; $l.Text = $t; $l.Location = New-Object System.Drawing.Point($x, $y); $l.AutoSize = $true; $pai.Controls.Add($l); return $l }
    function BT($x, $y, $wd, $v, $pai) { $t = New-Object System.Windows.Forms.TextBox; $t.Location = New-Object System.Drawing.Point($x, $y); $t.Width = $wd; $t.Text = $v; $pai.Controls.Add($t); return $t }
    function BB($t, $x, $y, $wd, $pai) { $b = New-Object System.Windows.Forms.Button; $b.Text = $t; $b.Location = New-Object System.Drawing.Point($x, $y); $b.Size = New-Object System.Drawing.Size($wd, 30); $pai.Controls.Add($b); return $b }
    function BC($t, $x, $y, $pai) { $c = New-Object System.Windows.Forms.CheckBox; $c.Text = $t; $c.Location = New-Object System.Drawing.Point($x, $y); $c.AutoSize = $true; $pai.Controls.Add($c); return $c }
    function Combo($x, $y, $wd, $itens, $pai) { $c = New-Object System.Windows.Forms.ComboBox; $c.DropDownStyle = 'DropDownList'; $c.Location = New-Object System.Drawing.Point($x, $y); $c.Width = $wd; foreach ($i in $itens) { [void]$c.Items.Add($i) }; $pai.Controls.Add($c); return $c }

    # --- busca
    $faixas = @(FaixasDoPc); $fx = if ($faixas.Count) { $faixas[0] } else { '192.168.1.1-192.168.1.254' }
    if ($txtIp.Text -and (IpValido $txtIp.Text.Trim())) { $p = $txtIp.Text.Trim().Split('.'); $fx = "$($p[0]).$($p[1]).$($p[2]).1-$($p[0]).$($p[1]).$($p[2]).254" }
    BL 'Faixa de IP' 12 14 $w | Out-Null; $bFaixa = BT 95 10 230 $fx $w
    BL 'Porta' 335 14 $w | Out-Null;      $bPorta = BT 378 10 50 $(if ($txtPorta.Text) { $txtPorta.Text } else { '80' }) $w
    BL 'Usuário' 438 14 $w | Out-Null;    $bUser = BT 497 10 90 $txtUser.Text $w
    BL 'Senha' 597 14 $w | Out-Null;      $bSenha = BT 645 10 110 $txtSenha.Text $w; $bSenha.UseSystemPasswordChar = $true
    $btBuscar = BB 'BUSCAR' 765 8 110 $w; $btBuscar.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $btUsar = BB 'Usar na tela principal' 885 8 180 $w; $btUsar.Enabled = $false
    $lbFx = BL ('Faixas deste PC: ' + ($faixas -join '   ')) 12 42 $w; $lbFx.ForeColor = [System.Drawing.Color]::DimGray
    $bSo = BC 'Só Intelbras/Dahua (esconde PCs e outros)' 765 40 $w; $bSo.Checked = $false
    $bLivre = BC 'Mostrar IPs livres' 600 40 $w

    $lv = New-Object System.Windows.Forms.ListView; $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.GridLines = $true; $lv.HideSelection = $false; $lv.MultiSelect = $false
    $lv.ListViewItemSorter = New-Object OrdemPorNome
    $lv.Location = New-Object System.Drawing.Point(12, 64); $lv.Size = New-Object System.Drawing.Size(1060, 220); $lv.Anchor = 'Top,Left,Right'
    foreach ($c in @(@('IP', 110), @('Porta', 50), @('Modelo', 190), @('É Bio-T?', 170), @('Nº de série', 150), @('MAC', 130), @('Firmware', 170), @('Achado por', 90))) { [void]$lv.Columns.Add($c[0], $c[1]) }
    $w.Controls.Add($lv)
    $lbSt = BL 'Clique em BUSCAR. Usuário e senha servem para ler o modelo de quem só aparece na varredura.' 12 290 $w; $lbSt.AutoSize = $false; $lbSt.Width = 1060; $lbSt.Anchor = 'Top,Left,Right'

    # --- abas do equipamento escolhido
    $tabs = New-Object System.Windows.Forms.TabControl; $tabs.Location = New-Object System.Drawing.Point(12, 314); $tabs.Size = New-Object System.Drawing.Size(1060, 395); $tabs.Anchor = 'Top,Left,Right,Bottom'
    $tRede = New-Object System.Windows.Forms.TabPage 'Rede (trocar IP)'; $tPorta = New-Object System.Windows.Forms.TabPage 'Porta'; $tEq = New-Object System.Windows.Forms.TabPage 'Equipamento'
    $tabs.TabPages.AddRange(@($tRede, $tPorta, $tEq)); $tabs.Enabled = $false; $w.Controls.Add($tabs)

    # Rede
    BL 'IP' 12 18 $tRede | Out-Null;            $rIp = BT 140 14 140 '' $tRede
    BL 'Senha deste equipamento' 300 18 $tRede | Out-Null; $rSenha = BT 470 14 150 '' $tRede; $rSenha.UseSystemPasswordChar = $true
    $rSenhaInfo = BL '(vazio = usa a do alto)' 630 18 $tRede; $rSenhaInfo.ForeColor = [System.Drawing.Color]::DimGray
    BL 'Máscara' 12 52 $tRede | Out-Null;       $rMasc = BT 140 48 140 '' $tRede
    BL 'Gateway' 12 86 $tRede | Out-Null;       $rGw = BT 140 82 140 '' $tRede
    BL 'DNS 1' 12 120 $tRede | Out-Null;        $rDns1 = BT 140 116 140 '' $tRede
    BL 'DNS 2' 12 154 $tRede | Out-Null;        $rDns2 = BT 140 150 140 '' $tRede
    BL 'Porta HTTP' 12 188 $tRede | Out-Null;   $rPorta = BT 140 184 70 '' $tRede
    $rDhcp = BC 'DHCP ligado (o roteador escolhe o IP - não recomendado)' 12 220 $tRede
    $rInfo = BL '' 300 52 $tRede; $rInfo.ForeColor = [System.Drawing.Color]::DimGray
    $btRLer = BB 'Ler do equipamento' 12 260 170 $tRede
    $btRAplicar = BB 'APLICAR (mantém DHCP)' 192 260 190 $tRede; $btRAplicar.BackColor = [System.Drawing.Color]::FromArgb(255, 235, 200)
    $btRFixar = BB 'FIXAR IP' 392 260 150 $tRede; $btRFixar.BackColor = [System.Drawing.Color]::FromArgb(255, 215, 170); $btRFixar.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $rAviso = BL 'APLICAR envia IP, máscara, gateway, DNS e porta e deixa o DHCP como está na caixinha. FIXAR IP faz o mesmo e DESLIGA o DHCP (IP fixo). O equipamento reinicia a rede (até 90 s); este PC precisa alcançar a faixa nova.' 12 300 $tRede
    $rAviso.AutoSize = $false; $rAviso.Size = New-Object System.Drawing.Size(1000, 40); $rAviso.ForeColor = [System.Drawing.Color]::DarkRed

    # Porta
    $pSt = BL 'Status: -' 12 14 $tPorta; $pSt.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
    $btPAbrir = BB 'ABRIR PORTA' 12 50 150 $tPorta; $btPAbrir.BackColor = [System.Drawing.Color]::FromArgb(200, 240, 210)
    $btPFechar = BB 'FECHAR PORTA' 172 50 150 $tPorta
    $btPStatus = BB 'Ler status' 332 50 110 $tPorta
    $pAuto = BC 'Atualizar status a cada 1 s' 452 56 $tPorta
    BL 'Canal' 680 56 $tPorta | Out-Null; $pCanal = Combo 725 52 60 @('1', '2') $tPorta; $pCanal.SelectedIndex = 0
    BL 'Estado da porta' 12 100 $tPorta | Out-Null;  $pEstado = Combo 230 96 220 @('Normal', 'Sempre aberta (OpenAlways)', 'Sempre fechada (CloseAlways)') $tPorta
    BL 'Tempo de abertura (ms, 250 a 20000)' 12 134 $tPorta | Out-Null; $pTempo = BT 290 130 80 '' $tPorta
    $pSensor = BC 'Sensor de porta ligado' 12 166 $tPorta
    BL 'Tipo do sensor' 230 166 $tPorta | Out-Null;  $pTipoSensor = Combo 330 162 200 @('0 - Normal aberto (NA)', '1 - Normal fechado (NF)') $tPorta
    BL 'Atraso do sensor / alarme porta aberta (s)' 12 198 $tPorta | Out-Null; $pAtraso = BT 290 194 60 '' $tPorta
    $pBotao = BC 'Botão de saída ligado' 12 228 $tPorta
    $pRele = BC 'Status do relé (firmware 20260416+)' 230 228 $tPorta
    BL 'Nome da porta' 12 262 $tPorta | Out-Null;    $pNome = BT 230 258 220 '' $tPorta
    BL 'Zona de tempo sempre aberta (ID, 255 = nenhuma)' 480 100 $tPorta | Out-Null; $pZAberta = BT 800 96 60 '' $tPorta
    BL 'Zona de tempo sempre fechada (ID, 255 = nenhuma)' 480 134 $tPorta | Out-Null; $pZFechada = BT 800 130 60 '' $tPorta
    $metodos = @('0 - Só senha', '1 - Só cartão', '2 - Senha ou cartão', '3 - Cartão e depois senha', '5 - Diferente por horário', '6 - Só digital', '7 - Senha, cartão ou digital',
        '10 - Cartão e digital', '11 - Vários usuários', '17 - Só face', '18 - Face e senha', '19 - Digital e senha', '20 - Digital e face', '21 - Cartão e face', '22 - Face ou senha',
        '23 - Digital ou senha', '24 - Digital ou face', '25 - Cartão ou face', '26 - Cartão ou digital', '27 - Digital, face e senha', '28 - Cartão, face e senha', '29 - Cartão, digital e senha',
        '30 - Cartão, digital e face', '31 - Digital, face ou senha', '32 - Cartão, face ou senha', '33 - Cartão, digital ou face', '34 - Cartão, digital, face e senha',
        '35 - Cartão, digital, face ou senha', '169 - Todos juntos + controle remoto', '170 - Qualquer um + controle remoto')
    BL 'Método de autenticação (verificação)' 580 170 $tPorta | Out-Null; $pMetodo = Combo 580 192 360 $metodos $tPorta
    $btPLer = BB 'Ler configuração' 12 300 160 $tPorta
    $btPGravar = BB 'GRAVAR alterações' 182 300 180 $tPorta; $btPGravar.BackColor = [System.Drawing.Color]::FromArgb(255, 235, 200)
    $pInfo = BL 'Só os campos alterados são enviados.' 372 306 $tPorta; $pInfo.ForeColor = [System.Drawing.Color]::DimGray

    # Equipamento
    $eTxt = New-Object System.Windows.Forms.TextBox; $eTxt.Multiline = $true; $eTxt.ReadOnly = $true; $eTxt.ScrollBars = 'Vertical'; $eTxt.Font = New-Object System.Drawing.Font('Consolas', 9.5)
    $eTxt.Location = New-Object System.Drawing.Point(12, 12); $eTxt.Size = New-Object System.Drawing.Size(1020, 300); $eTxt.Anchor = 'Top,Left,Right,Bottom'; $tEq.Controls.Add($eTxt)
    $btELer = BB 'Ler informações' 12 320 160 $tEq; $btELer.Anchor = 'Left,Bottom'
    $btEReb = BB 'Reiniciar equipamento' 182 320 190 $tEq; $btEReb.Anchor = 'Left,Bottom'

    $tmP = New-Object System.Windows.Forms.Timer; $tmP.Interval = 1000
    $sel = @{ D = $null; Rede = $null; Porta = $null }
    $script:SenhaPorIp = @{}
    $corOk = [System.Drawing.SystemColors]::Window; $corErro = [System.Drawing.Color]::FromArgb(255, 190, 190)
    function MarcarSenha($motivo) {
        # a caixa que vale para este equipamento fica vermelha
        $cx = if ($rSenha.Text) { $rSenha } else { if ($tabs.SelectedTab -eq $tRede) { $rSenha } else { $bSenha } }
        $cx.BackColor = $corErro; if (-not $rSenha.Text) { $bSenha.BackColor = $corErro; $rSenha.BackColor = $corErro }
        $lbSt.Text = $(if ($motivo -eq 'vazia') { 'VERIFIQUE A SENHA: digite a senha do equipamento (caixa em vermelho).' } else { 'VERIFIQUE A SENHA: o equipamento recusou o usuário/senha (caixa em vermelho).' })
        $lbSt.ForeColor = [System.Drawing.Color]::DarkRed
        Log ("Buscador: senha {0} para {1}" -f $motivo, $(if ($sel.D) { $sel.D.IP } else { '?' })) 'AVISO'
    }
    function LimparMarcaSenha { $rSenha.BackColor = $corOk; $bSenha.BackColor = $corOk; $lbSt.ForeColor = [System.Drawing.SystemColors]::ControlText }
    $rSenha.Add_TextChanged({ LimparMarcaSenha }); $bSenha.Add_TextChanged({ LimparMarcaSenha }); $bUser.Add_TextChanged({ LimparMarcaSenha })
    # todo pedido dos botoes passa por aqui: sem senha ou senha errada -> "Verifique a senha" e caixa vermelha
    function ReqUI($caminho, $to = 6000) {
        $d = Atual; $u, $s = Cred
        if (-not $s) { MarcarSenha 'vazia'; throw 'Verifique a senha: digite a senha do equipamento na caixa em vermelho.' }
        $r = ReqEquip $d.IP $d.Porta $u $s $caminho $to
        if ($r.Status -eq 401) { MarcarSenha 'errada'; throw 'Verifique a senha: o equipamento recusou o usuário ou a senha. Digite a senha correta na caixa em vermelho.' }
        if ($r.Status -eq 200) { LimparMarcaSenha }
        return $r
    }
    function Cred { $s = $bSenha.Text; if ($rSenha.Text) { $s = $rSenha.Text }; return @($bUser.Text.Trim(), $s) }
    $rSenha.Add_TextChanged({ if ($sel.D) { $script:SenhaPorIp[$sel.D.IP] = $rSenha.Text } })
    function Atual { return $sel.D }

    function PintarLinha($it, $d) {
        $vals = @($d.IP, $d.Porta, $d.Modelo, (ClassificarBioT $d.Modelo), $d.Serie, $d.MAC, $d.Firmware, $d.Origem)
        while ($it.SubItems.Count -lt $vals.Count) { [void]$it.SubItems.Add('') }
        for ($k = 0; $k -lt $vals.Count; $k++) { $it.SubItems[$k].Text = [string]$vals[$k] }
        $bt = $vals[3]; $it.ForeColor = [System.Drawing.Color]::Black; $it.BackColor = [System.Drawing.Color]::White
        if ($bt -like 'SIM*') { $it.BackColor = [System.Drawing.Color]::FromArgb(220, 245, 225) } elseif ($bt -like '*SEM API*') { $it.BackColor = [System.Drawing.Color]::FromArgb(255, 240, 210) }
        elseif ($bt -like 'Intelbras*') { $it.BackColor = [System.Drawing.Color]::FromArgb(255, 250, 205) }
        elseif ($bt -eq 'NÃO') { $it.ForeColor = [System.Drawing.Color]::Gray }
        if ($d.Origem -eq 'livre') { $it.SubItems[3].Text = '-'; $it.BackColor = [System.Drawing.Color]::FromArgb(225, 238, 255); $it.ForeColor = [System.Drawing.Color]::DarkBlue }
        $it.Name = ChaveOrdem $d
    }
    $script:BItens = @{}
    # entra na lista na posicao certa (ordem de IP); se o IP ja esta la, junta os dados sem mexer no que o usuario esta editando
    $script:BTodos = @{}
    function Mostrar($d) { if ($d.Origem -eq 'livre') { return $bLivre.Checked }; return (-not $bSo.Checked) -or ((ClassificarBioT $d.Modelo) -ne 'NÃO') }
    function PreencherLinha($d) {
        $o = $script:BTodos[$d.IP]
        if ($o -and $o.Origem -eq 'livre' -and $d.Origem -ne 'livre') {   # era "livre" e respondeu: troca
            $it0 = $script:BItens[$d.IP]; if ($it0) { $lv.Items.Remove($it0); $script:BItens.Remove($d.IP) }; $script:BTodos.Remove($d.IP); $o = $null }
        if ($o) {
            # IP ja conhecido: junta os dados sem mexer no que o usuario esta editando
            $bom = { param($m) $m -and $m -notlike '(*' -and $m -notlike 'INTELBRAS/DAHUA*' }
            if ((& $bom $d.Modelo) -and -not (& $bom $o.Modelo)) { $o.Modelo = $d.Modelo }
            elseif ($d.Modelo -like 'INTELBRAS/DAHUA*' -and $o.Modelo -like '(*') { $o.Modelo = $d.Modelo }
            foreach ($k in @('Serie', 'MAC', 'Firmware', 'Mascara', 'Gateway', 'Dhcp')) { if (-not $o.$k -and $d.$k) { $o.$k = $d.$k } }
            if ($o.Origem -notlike "*$($d.Origem)*") { $o.Origem = "$($o.Origem) + $($d.Origem)" }
        } else { $o = $d; $script:BTodos[$d.IP] = $o }
        $it = $script:BItens[$o.IP]
        if (-not (Mostrar $o)) { if ($it -and -not $it.Selected) { $lv.Items.Remove($it); $script:BItens.Remove($o.IP) } elseif ($it) { PintarLinha $it $o }; return }
        if ($it) { PintarLinha $it $o; return }
        $it = New-Object System.Windows.Forms.ListViewItem($o.IP); $it.Tag = $o; PintarLinha $it $o
        [void]$lv.Items.Add($it); $script:BItens[$o.IP] = $it; $script:PrecisaOrdenar = $true
    }
    $script:PrecisaOrdenar = $false; $script:BFaixaIps = @()
    # IPs da faixa que nao responderam a nada (para escolher um IP novo)
    function AtualizarLivres {
        $lv.BeginUpdate()
        try {
            foreach ($k in @($script:BTodos.Keys)) { if ($script:BTodos[$k].Origem -eq 'livre') { $it = $script:BItens[$k]; if ($it) { $lv.Items.Remove($it); $script:BItens.Remove($k) }; $script:BTodos.Remove($k) } }
            if ($bLivre.Checked -and -not $script:BuscaD) {
                foreach ($ip in $script:BFaixaIps) { if (-not $script:BTodos[$ip]) {
                    PreencherLinha ([pscustomobject]@{ IP = $ip; Porta = ''; Modelo = 'IP LIVRE (não respondeu a nada)'; Serie = ''; MAC = ''; Firmware = ''; Mascara = ''; Gateway = ''; Dhcp = ''; Origem = 'livre' }) } }
            }
            $lv.Sort()
        } finally { $lv.EndUpdate() }
        $nl = @($script:BTodos.Values | Where-Object { $_.Origem -eq 'livre' }).Count
        if ($bLivre.Checked) { $lbSt.Text = $(if ($script:BuscaD) { 'Os IPs livres aparecem quando a busca terminar.' } elseif (-not $script:BFaixaIps.Count) { 'Clique em BUSCAR para saber os IPs livres da faixa.' } else { "$nl IP(s) livre(s) na faixa (em azul). Atenção: IP livre = não respondeu agora; confira se não é de um aparelho desligado." }) }
    }
    # ordem da lista: por IP, ou (clicando no titulo "É Bio-T?") os Bio-T primeiro
    $script:OrdemBioT = $false
    function ChaveOrdem($d) {
        $n = [double]$(if (IpValido $d.IP) { IpNum $d.IP } else { 0 })
        if (-not $script:OrdemBioT) { return '0{0:D10}' -f [long]$n }
        $c = ClassificarBioT $d.Modelo
        $r = if ($d.Origem -eq 'livre') { 7 } elseif ($c -like 'SIM*') { 0 } elseif ($c -like '*SEM API*') { 1 } elseif ($c -like 'Provável*') { 2 } elseif ($c -like 'Intelbras*') { 3 } elseif ($c -eq '?') { 4 } else { 5 }
        return '{0}{1:D10}' -f $r, [long]$n
    }
    function Reordenar {
        $ipSel = if ($lv.SelectedItems.Count) { $lv.SelectedItems[0].Tag.IP } else { $null }
        $lv.BeginUpdate()
        try { foreach ($it in $lv.Items) { $it.Name = ChaveOrdem $it.Tag }; $lv.Sort() } finally { $lv.EndUpdate() }
        if ($ipSel -and $script:BItens[$ipSel]) { $script:BItens[$ipSel].EnsureVisible() }
        $lv.Columns[3].Text = $(if ($script:OrdemBioT) { 'É Bio-T? ▲ (topo)' } else { 'É Bio-T?' }); $lv.Columns[0].Text = $(if ($script:OrdemBioT) { 'IP' } else { 'IP ▲' })
    }
    $lv.Add_ColumnClick({ param($s2, $e2)
        if ($e2.Column -eq 3) { $script:OrdemBioT = -not $script:OrdemBioT; Reordenar }
        elseif ($e2.Column -eq 0 -and $script:OrdemBioT) { $script:OrdemBioT = $false; Reordenar } })
    function RefazerLista { $lv.BeginUpdate(); try { foreach ($d in @($script:BTodos.Values)) { PreencherLinha $d } } finally { $lv.EndUpdate() } }
    $bLivre.Add_CheckedChanged({ AtualizarLivres })
    $bSo.Add_CheckedChanged({ RefazerLista; $lv.Sort(); $t, $b = ContarAchados; $lbSt.Text = "Mostrando $t de $($script:BTodos.Count) equipamento(s)" + $(if ($bSo.Checked) { ' (só Intelbras/Dahua)' } else { '' }) })
    $script:BuscaD = $null; $script:BTarefas = @(); $script:BIdent = $false
    $tmB = New-Object System.Windows.Forms.Timer; $tmB.Interval = 200
    function ContarAchados { $t = 0; $b = 0; foreach ($it in $lv.Items) { $t++; if ((ClassificarBioT $it.Tag.Modelo) -like 'SIM*') { $b++ } }; return @($t, $b) }
    $tmB.Add_Tick({
        try {
            $D = $script:BuscaD; if (-not $D) { $tmB.Stop(); return }
            $x = $null; while ($D.Fila.TryDequeue([ref]$x)) { PreencherLinha $x }
            # a varredura terminou: dispara a identificacao, varios IPs ao mesmo tempo
            $lotes = @()
            if ($null -ne $D.Vivos -and -not $script:BIdent) { $script:BIdent = $true; $lotes += ,@($D.Vivos) }
            if ($null -ne $D.Vivos2 -and -not $script:BIdent2) { $script:BIdent2 = $true; $lotes += ,@($D.Vivos2) }
            foreach ($lt in $lotes) {
                $D.Total = $D.Total + @($lt).Count
                foreach ($v in @($lt)) {
                    if (-not $v.Http) {
                        # sem porta web: ainda assim mostra (o .158/.159 do teste so respondiam ping)
                        $mod = if ($v.P37777) { 'INTELBRAS/DAHUA (porta 37777 aberta; web fechada ou em outra porta)' } else { '(responde ping, sem porta web - PC ou outro equipamento)' }
                        $D.Fila.Enqueue([pscustomobject]@{ IP = $v.IP; Porta = $D.Porta; Modelo = $mod; Serie = ''; MAC = ''; Firmware = ''; Mascara = ''; Gateway = ''; Dhcp = ''; Origem = $(if ($v.P37777) { 'varredura 37777' } else { 'ping' }) })
                        $D.Feitos = $D.Feitos + 1; continue
                    }
                    $j = [hashtable]::Synchronized(@{ Run = $true; Fila = $D.Fila; IP = $v.IP; Porta = $D.Porta; U = $D.U; S = $D.S; Pai = $D; Dh = $v.P37777 })
                    $script:BTarefas += IniciarBg '$r = Identificar $D.IP $D.Porta $D.U $D.S; if ($D.Dh -and $r.Modelo -like "(*") { $r.Modelo = "INTELBRAS/DAHUA (porta 37777 aberta: informe a senha para ver o modelo)" }; if ($D.Pai.Run) { $D.Fila.Enqueue($r) }; $D.Pai.Feitos = $D.Pai.Feitos + 1' $j
                }
            }
            if ($script:PrecisaOrdenar) { $script:PrecisaOrdenar = $false; $lv.Sort() }
            $ab = @($script:BTarefas | Where-Object { -not $_.H.IsCompleted }).Count
            $t, $b = ContarAchados
            if ($ab -gt 0 -or -not $script:BIdent -or -not $script:BIdent2) {
                $fase = if (-not $script:BIdent) { $D.Status } else { "Identificando $($D.Feitos) de $($D.Total)" }
                $lbSt.Text = "Buscando... $t achado(s), $b Bio-T  |  $fase   (já pode clicar num equipamento e trabalhar nele)"
            } else {
                $tmB.Stop(); foreach ($tf in $script:BTarefas) { FimBg $tf }; $script:BTarefas = @()
                $ocu = $script:BTodos.Count - $t
                $lbSt.Text = "Busca concluída: $t equipamento(s), $b da linha Bio-T" + $(if ($ocu -gt 0) { " ($ocu outro(s) escondido(s) - desmarque 'Só Intelbras' para ver)" } else { '' }) + '. Clique num para ver rede, porta e equipamento.'
                Log ("Buscador: {0} achado(s), {1} Bio-T" -f $t, $b)
                $btBuscar.Text = 'BUSCAR'; $script:BuscaD = $null
                AtualizarLivres
            }
        } catch { LogRep 'tmB' ("Buscador: erro ao atualizar a lista: {0}" -f $_.Exception.Message) }
    })
    $btBuscar.Add_Click({
        try {
            if ($script:BuscaD) {   # PARAR
                $script:BuscaD.Run = $false; $tmB.Stop(); foreach ($tf in $script:BTarefas) { FimBg $tf }; $script:BTarefas = @(); $script:BuscaD = $null
                $script:BFaixaIps = @(); $btBuscar.Text = 'BUSCAR'; $lbSt.Text = 'Busca interrompida. O que já foi achado continua na lista.'; Log 'Buscador: busca interrompida pelo usuario'; return
            }
            $lv.Items.Clear(); $script:BItens = @{}; $script:BTodos = @{}; $tabs.Enabled = $false; $btUsar.Enabled = $false; $sel.D = $null
            $porta = $bPorta.Text.Trim(); if (-not $porta) { $porta = '80' }
            $u, $s = Cred
            Log ("Buscador: BUSCAR faixa={0} porta={1} usuario={2} senha={3}" -f $bFaixa.Text, $porta, $u, $(if ($s) { 'informada' } else { 'VAZIA' }))
            $ipsFaixa = @(); $ini = $null; $fim = $null
            if ($bFaixa.Text -match '^\s*([\d.]+)\s*-\s*([\d.]+)\s*$' -and (IpValido $Matches[1]) -and (IpValido $Matches[2])) {
                $ini = $Matches[1]; $fim = $Matches[2]
                $a1 = IpNum $ini; $a2 = IpNum $fim; if ($a2 -lt $a1) { $tmp = $a1; $a1 = $a2; $a2 = $tmp }
                if (($a2 - $a1) -gt 1023) { throw 'Faixa grande demais (máximo 1024 IPs).' }
                for ($n = $a1; $n -le $a2; $n++) { $ipsFaixa += (NumIp $n) }
            } elseif ($bFaixa.Text.Trim()) { throw 'Faixa inválida (use 10.1.31.1-10.1.31.254).' }
            $script:BFaixaIps = $ipsFaixa; $script:BIdent2 = $false
            $D = [hashtable]::Synchronized(@{ Run = $true; Fila = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'); Status = 'Procurando...'; Vivos = $null; Vivos2 = $null
                Ips = $ipsFaixa; Ini = $ini; Fim = $fim; Porta = $porta; U = $u; S = $s; Feitos = 0; Total = 0 })
            $script:BuscaD = $D; $script:BIdent = $false
            # 1) sem senha pela rede (UDP)  e  2) varredura da porta HTTP - as duas ao mesmo tempo
            $script:BTarefas = @(
                (IniciarBg '$D.Status = "procurando sem senha pela rede..."; foreach ($x in @(BuscarMulticast 4 $D.Ips)) { if ($D.Run) { $D.Fila.Enqueue($x) } }' $D),
                (IniciarBg @'
# 1a passada: todos de uma vez, rapida (como antes); 2a: so quem nao respondeu, com calma (pega os retardatarios)
if ($D.Ini) {
    $D.Status = "varrendo a faixa..."; $v1 = @(VarrerFaixa $D.Ini $D.Fim $D.Porta 700 1024); $D.Vivos = $v1
    $resp = @{}; foreach ($x in $v1) { $resp[$x.IP] = 1 }; $resto = @($D.Ips | Where-Object { -not $resp[$_] })
    if ($D.Run -and $resto.Count) { $D.Status = "conferindo de novo os que não responderam..."; $D.Vivos2 = @(VarrerFaixa $D.Ini $D.Fim $D.Porta 1500 64 $resto) } else { $D.Vivos2 = @() }
} else { $D.Vivos = @(); $D.Vivos2 = @() }
'@ $D))
            $btBuscar.Text = 'PARAR'; $lbSt.Text = 'Buscando...'; $tmB.Start()
        } catch { LogExcecao 'Buscador: erro na busca' $_.Exception; $lbSt.Text = "Erro na busca: $($_.Exception.Message)" }
    })
    # ---- PING: testa o equipamento selecionado 1 vez por segundo, sem precisar abrir o prompt
    $rPing = BC 'Testar ping (1 por segundo)' 760 84 $tRede
    $rPingRes = BL 'Ping: -' 760 110 $tRede; $rPingRes.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
    $rPingEst = BL '' 760 140 $tRede; $rPingEst.ForeColor = [System.Drawing.Color]::DimGray
    $tmPing = New-Object System.Windows.Forms.Timer; $tmPing.Interval = 1000
    $script:PingT = $null; $script:PingIp = ''; $script:PingE = @{}
    function ZerarPing { $script:PingE = @{ Env = 0; Ok = 0; Min = [double]::MaxValue; Max = 0; Soma = 0 }; $rPingRes.Text = 'Ping: -'; $rPingRes.ForeColor = [System.Drawing.Color]::Black; $rPingEst.Text = '' }
    ZerarPing
    $tmPing.Add_Tick({
        try {
            if (-not $sel.D) { return }
            if ($script:PingIp -ne $sel.D.IP) { $script:PingIp = $sel.D.IP; $script:PingT = $null; ZerarPing }
            $e = $script:PingE
            if ($script:PingT -and $script:PingT.T.IsCompleted) {
                $e.Env++
                $ok = $false; try { $rp = $script:PingT.T.Result; $ok = ($rp.Status -eq 'Success') } catch {}
                if ($ok) {
                    $ms = [double]$rp.RoundtripTime; $e.Ok++; $e.Soma += $ms; if ($ms -lt $e.Min) { $e.Min = $ms }; if ($ms -gt $e.Max) { $e.Max = $ms }
                    $ttl = ''; try { $ttl = " (TTL $($rp.Options.Ttl))" } catch {}
                    $rPingRes.Text = "Ping $($script:PingIp): $ms ms$ttl"; $rPingRes.ForeColor = $(if ($ms -le 50) { [System.Drawing.Color]::DarkGreen } elseif ($ms -le 200) { [System.Drawing.Color]::DarkOrange } else { [System.Drawing.Color]::DarkRed })
                } else {
                    $st = 'sem resposta'; try { $st = [string]$script:PingT.T.Result.Status } catch {}
                    $rPingRes.Text = "Ping $($script:PingIp): SEM RESPOSTA ($st)"; $rPingRes.ForeColor = [System.Drawing.Color]::DarkRed
                }
                $perd = $e.Env - $e.Ok
                $rPingEst.Text = ("enviados {0}, recebidos {1}, perdidos {2} ({3:N0}%)" -f $e.Env, $e.Ok, $perd, (100.0 * $perd / $e.Env)) + $(if ($e.Ok) { ("  |  mín {0} / méd {1:N0} / máx {2} ms" -f $e.Min, ($e.Soma / $e.Ok), $e.Max) } else { '' })
                try { $script:PingT.P.Dispose() } catch {}; $script:PingT = $null
            }
            if (-not $script:PingT) { $pg = New-Object System.Net.NetworkInformation.Ping; $script:PingT = @{ P = $pg; T = $pg.SendPingAsync($script:PingIp, 900) } }
        } catch { LogRep 'ping' ("Ping: erro {0}" -f $_.Exception.Message) 'AVISO' }
    })
    $rPing.Add_CheckedChanged({ if ($rPing.Checked) { $script:PingIp = ''; $tmPing.Start() } else { $tmPing.Stop(); $script:PingT = $null } })
    $lv.Add_SelectedIndexChanged({
        if ($lv.SelectedItems.Count -eq 0) { return }
        $sel.D = $null; $rSenha.Text = [string]$script:SenhaPorIp[$lv.SelectedItems[0].Tag.IP]
        $sel.D = $lv.SelectedItems[0].Tag; $tabs.Enabled = $true; $btUsar.Enabled = $true
        $d = $sel.D; $rIp.Text = $d.IP; $rMasc.Text = $d.Mascara; $rGw.Text = $d.Gateway; $rPorta.Text = $d.Porta; $rDns1.Text = ''; $rDns2.Text = ''; $rDhcp.Checked = ($d.Dhcp -eq 'true' -or $d.Dhcp -eq 'True')
        $rInfo.Text = "Equipamento: $($d.Modelo)  |  série $($d.Serie)  |  MAC $($d.MAC)"
        $pSt.Text = 'Status: -'; $sel.Rede = $null; $sel.Porta = $null; $eTxt.Text = ''
        $lbSt.Text = "Escolhido: $($d.IP) - $($d.Modelo). Use 'Ler do equipamento' para trazer os dados atuais."
    })
    $btUsar.Add_Click({ $d = Atual; if ($d) { $txtIp.Text = $d.IP; $txtPorta.Text = $d.Porta; $u, $s = Cred; $txtUser.Text = $u; if ($s) { $txtSenha.Text = $s }; Log "Buscador: usar $($d.IP) na tela principal"; $w.Close() } })

    # ---- Rede
    function LerRede {
        $d = Atual; $u, $s = Cred
        $r = ReqUI '/cgi-bin/configManager.cgi?action=getConfig&name=Network'
        if ($r.Status -ne 200) { throw "Não foi possível ler a rede (HTTP $($r.Status)). Confira usuário e senha. $($r.Erro)" }
        $t = Tabela $r.Texto; $nic = $t['table.Network.DefaultInterface']; if (-not $nic) { $nic = 'eth0' }
        $g = { param($k) [string]$t["table.Network.$nic.$k"] }
        $rede = @{ Nic = $nic; IP = (& $g 'IPAddress'); Mascara = (& $g 'SubnetMask'); Gateway = (& $g 'DefaultGateway'); Dns1 = (& $g 'DnsServers[0]'); Dns2 = (& $g 'DnsServers[1]'); Dhcp = ((& $g 'DhcpEnable') -eq 'true'); MAC = (& $g 'PhysicalAddress'); Porta = $d.Porta }
        $wb = ReqUI '/cgi-bin/configManager.cgi?action=getConfig&name=Web'
        if ($wb.Status -eq 200) { $pw = (Tabela $wb.Texto)['table.Web.Port']; if ($pw) { $rede.Porta = $pw } }
        $rIp.Text = $rede.IP; $rMasc.Text = $rede.Mascara; $rGw.Text = $rede.Gateway; $rDns1.Text = $rede.Dns1; $rDns2.Text = $rede.Dns2; $rPorta.Text = $rede.Porta; $rDhcp.Checked = $rede.Dhcp
        $rInfo.Text = "Interface $nic  |  MAC $($rede.MAC)  |  hostname $($t['table.Network.Hostname'])"
        $sel.Rede = $rede; return $rede
    }
    $btRLer.Add_Click({ try { [void](LerRede); $lbSt.Text = 'Rede lida do equipamento.' } catch { MostrarErro 'Buscador: ler rede' $_.Exception } })
    function TrocarRede([bool]$fixar) {
        try {
            $d = Atual; $u, $s = Cred
            if (-not $s) { throw 'Informe a senha do equipamento (ao lado do IP ou no alto da janela).' }
            if (-not $sel.Rede) { [void](LerRede) }
            $a = $sel.Rede
            $ip = $rIp.Text.Trim(); $m = $rMasc.Text.Trim(); $g = $rGw.Text.Trim(); $d1 = $rDns1.Text.Trim(); $d2 = $rDns2.Text.Trim(); $pt = $rPorta.Text.Trim()
            foreach ($par in @(@('IP', $ip), @('Máscara', $m), @('Gateway', $g))) { if (-not (IpValido $par[1])) { throw "$($par[0]) inválido: $($par[1])" } }
            foreach ($par in @(@('DNS 1', $d1), @('DNS 2', $d2))) { if ($par[1] -and -not (IpValido $par[1])) { throw "$($par[0]) inválido: $($par[1])" } }
            if ($pt -notmatch '^\d+$' -or [int]$pt -lt 1 -or [int]$pt -gt 65535) { throw 'Porta HTTP inválida (1 a 65535).' }
            $mn = IpNum $m; $inv = (-bnot $mn) -band 0xFFFFFFFF
            if ($mn -eq 0 -or (($inv -band ($inv + 1)) -ne 0)) { throw "Máscara inválida: $m" }
            if (((IpNum $ip) -band $mn) -ne ((IpNum $g) -band $mn)) { throw "O gateway $g não está na mesma rede do IP $ip (máscara $m)." }
            if ($ip -eq $g) { throw 'O IP não pode ser igual ao gateway.' }
            $n = $a.Nic
            $dhcp = if ($fixar) { $false } else { $rDhcp.Checked }
            $q = "/cgi-bin/configManager.cgi?action=setConfig&Network.$n.DhcpEnable=$(if ($dhcp) { 'true' } else { 'false' })"
            $q += "&Network.$n.IPAddress=$ip&Network.$n.SubnetMask=$m&Network.$n.DefaultGateway=$g"
            if ($d1) { $q += "&Network.$n.DnsServers[0]=$d1" }; if ($d2) { $q += "&Network.$n.DnsServers[1]=$d2" }
            if ($pt -ne [string]$a.Porta) { $q += "&Web.Port=$pt" }
            if ($ip -ne $d.IP) {
                $c = New-Object System.Net.Sockets.TcpClient; $ocup = $false; try { $ocup = $c.ConnectAsync($ip, [int]$pt).Wait(1500) -and $c.Connected } catch {} finally { $c.Close() }
                if ($ocup) { throw "Já existe um aparelho respondendo em ${ip}:$pt. Escolha outro IP. Nada foi alterado." }
            }
            $acao = if ($fixar) { 'FIXAR IP' } else { 'APLICAR' }
            $txt = "$acao no equipamento $($d.IP) ($($d.Modelo))?`n`nDe: $($a.IP) / $($a.Mascara) / gw $($a.Gateway) / porta $($a.Porta) / DHCP $(if ($a.Dhcp) { 'ligado' } else { 'desligado' })`nPara: $ip / $m / gw $g / porta $pt / DHCP $(if ($dhcp) { 'ligado (o roteador pode trocar o IP)' } else { 'DESLIGADO (IP fixo)' })`n`nO equipamento reinicia a rede."
            if ([System.Windows.Forms.MessageBox]::Show($txt, $acao, 'YesNo', 'Warning') -ne 'Yes') { return }
            Log ("Buscador: {7} {0}:{1} -> {2}:{3} masc {4} gw {5} dhcp {6}" -f $d.IP, $d.Porta, $ip, $pt, $m, $g, $dhcp, $acao)
            $r = ReqUI $q 10000
            if ($r.Status -ne 0 -and ($r.Status -ne 200 -or $r.Texto -notlike 'OK*')) { throw "O equipamento recusou (HTTP $($r.Status): $(Resumo $r.Texto 120)). Nada foi alterado." }
            if ($dhcp -and $ip -eq $a.IP) { $lbSt.Text = 'Enviado (DHCP ligado). Se o roteador trocar o IP, clique em BUSCAR em alguns segundos.' }
            $fim = (Get-Date).AddSeconds(90); $ok = $false; $k = 0
            while ((Get-Date) -lt $fim) {
                $k++; $lbSt.Text = "Enviado. Esperando o equipamento responder em ${ip}:$pt... (tentativa $k)"; $w.Refresh()
                for ($z = 0; $z -lt 30; $z++) { Start-Sleep -Milliseconds 100; [System.Windows.Forms.Application]::DoEvents() }
                $t = ReqEquip $ip $pt $u $s '/cgi-bin/magicBox.cgi?action=getSoftwareVersion' 3000
                if ($t.Status -eq 200) { $ok = $true; break }
            }
            if ($ok) {
                Log "Buscador: equipamento respondeu no endereco novo ${ip}:$pt"
                $ant = $d.IP; $d.IP = $ip; $d.Porta = $pt; $d.Mascara = $m; $d.Gateway = $g; $d.Dhcp = $(if ($dhcp) { 'true' } else { 'false' }); $rDhcp.Checked = $dhcp
                if ($lv.SelectedItems.Count) { $lv.SelectedItems[0].Text = $ip; $lv.SelectedItems[0].SubItems[1].Text = $pt }; $sel.Rede = $null
                if ($ant -ne $ip) { $script:BTodos.Remove($ant); $script:BTodos[$ip] = $d; $it = $script:BItens[$ant]; $script:BItens.Remove($ant); if ($it) { $script:BItens[$ip] = $it }; if ($script:SenhaPorIp[$ant]) { $script:SenhaPorIp[$ip] = $script:SenhaPorIp[$ant] } }
                if ($txtIp.Text.Trim() -eq $a.IP) { $txtIp.Text = $ip; $txtPorta.Text = $pt }
                $lbSt.Text = "$acao concluído: o equipamento já responde em ${ip}:$pt$(if (-not $dhcp) { ' (IP fixo)' })."
                [System.Windows.Forms.MessageBox]::Show("Pronto! O equipamento responde em ${ip}:$pt$(if (-not $dhcp) { ' com IP FIXO' }).", $acao) | Out-Null
            } else {
                Log "Buscador: sem resposta em ${ip}:$pt depois de 90 s" 'AVISO'
                $lbSt.Text = "Enviado, mas não respondeu em ${ip}:$pt em 90 s. Talvez esteja numa faixa que este PC não alcança: use BUSCAR (aviso na rede acha em outra faixa)."
            }
        } catch { MostrarErro 'Buscador: trocar IP' $_.Exception }
    }
    $btRAplicar.Add_Click({ TrocarRede $false })
    $btRFixar.Add_Click({ TrocarRede $true })

    # ---- Porta
    function Canal { return [int]$pCanal.SelectedItem }
    function LerStatus {
        $d = Atual; $u, $s = Cred
        $r = ReqUI ("/cgi-bin/accessControl.cgi?action=getDoorStatus&channel={0}" -f (Canal)) 4000
        if ($r.Status -eq 200) {
            $v = (Tabela $r.Texto)['Info.status']
            $pt = switch ($v) { 'Open' { 'ABERTA' } 'Close' { 'FECHADA' } 'Break' { 'ARROMBADA' } default { $v } }
            $pSt.Text = "Status: $pt   ($($r.Texto))"; $pSt.ForeColor = $(if ($v -eq 'Open') { [System.Drawing.Color]::DarkGreen } else { [System.Drawing.Color]::Black })
        } else { $pSt.Text = "Status: erro (HTTP $($r.Status)) - o status do sensor precisa do sensor ligado"; $pSt.ForeColor = [System.Drawing.Color]::DarkRed }
    }
    function Comando($caminho, $oque) {
        $d = Atual; $u, $s = Cred
        Log "Buscador: $oque em $($d.IP)"
        $r = ReqUI $caminho
        if ($r.Status -eq 200 -and $r.Texto -like 'OK*') { $lbSt.Text = "$oque : OK"; return $true }
        $lbSt.Text = "$oque : recusado (HTTP $($r.Status) $(Resumo $r.Texto 80))"; return $false
    }
    $btPAbrir.Add_Click({ try { [void](Comando ("/cgi-bin/accessControl.cgi?action=openDoor&channel={0}&UserID=0&Type=Remote" -f (Canal)) 'Abrir porta'); Start-Sleep -Milliseconds 400; LerStatus } catch { MostrarErro 'Buscador: abrir porta' $_.Exception } })
    $btPFechar.Add_Click({ try { [void](Comando ("/cgi-bin/accessControl.cgi?action=closeDoor&channel={0}" -f (Canal)) 'Fechar porta'); Start-Sleep -Milliseconds 400; LerStatus } catch { MostrarErro 'Buscador: fechar porta' $_.Exception } })
    $btPStatus.Add_Click({ try { LerStatus } catch { MostrarErro 'Buscador: status da porta' $_.Exception } })
    $pAuto.Add_CheckedChanged({ if ($pAuto.Checked) { $tmP.Start() } else { $tmP.Stop() } })
    $tmP.Add_Tick({ if ($sel.D -and $tabs.SelectedTab -eq $tPorta) { try { LerStatus } catch {} } })
    function LerPorta {
        $d = Atual; $u, $s = Cred; $i = (Canal) - 1
        $a = ReqUI '/cgi-bin/configManager.cgi?action=getConfig&name=AccessControl'
        if ($a.Status -ne 200) { throw "Não foi possível ler a porta (HTTP $($a.Status)). Confira usuário e senha." }
        $g = ReqUI '/cgi-bin/configManager.cgi?action=getConfig&name=AccessControlGeneral'
        $rl = ReqUI '/cgi-bin/configManager.cgi?action=getConfig&name=_RelayStatus_'
        $ta = Tabela $a.Texto; $tg = Tabela $g.Texto; $tr = Tabela $rl.Texto
        $fA = { param($k) [string]$ta["table.AccessControl[$i].$k"] }
        $v = @{ State = (& $fA 'State'); UnlockHoldInterval = (& $fA 'UnlockHoldInterval'); SensorEnable = (& $fA 'SensorEnable'); CloseTimeout = (& $fA 'CloseTimeout'); Name = (& $fA 'Name')
            OpenAlwaysTime = (& $fA 'OpenAlwaysTime'); CloseAlwaysTime = (& $fA 'CloseAlwaysTime'); Method = (& $fA 'Method')
            SensorType = [string]$tg['table.AccessControlGeneral.SensorType']; ButtonExitEnable = [string]$tg['table.AccessControlGeneral.ButtonExitEnable']
            Rele = [string]$tr["table._RelayStatus_[$i].Enable"] }
        $pEstado.SelectedIndex = switch ($v.State) { 'OpenAlways' { 1 } 'CloseAlways' { 2 } default { 0 } }
        $pTempo.Text = $v.UnlockHoldInterval; $pSensor.Checked = ($v.SensorEnable -eq 'true'); $pAtraso.Text = $v.CloseTimeout; $pNome.Text = $v.Name
        $pZAberta.Text = $v.OpenAlwaysTime; $pZFechada.Text = $v.CloseAlwaysTime
        $pTipoSensor.SelectedIndex = $(if ($v.SensorType -eq '1') { 1 } else { 0 }); $pBotao.Checked = ($v.ButtonExitEnable -eq 'true')
        $pRele.Checked = ($v.Rele -eq 'true'); $pRele.Enabled = ($rl.Status -eq 200)
        $pMetodo.SelectedIndex = -1; for ($k = 0; $k -lt $pMetodo.Items.Count; $k++) { if (([string]$pMetodo.Items[$k]).Split(' ')[0] -eq $v.Method) { $pMetodo.SelectedIndex = $k } }
        $pInfo.Text = "Lido de $($d.IP), porta $((Canal)). Só os campos alterados são enviados." + $(if ($rl.Status -ne 200) { ' (Status do relé: firmware sem suporte)' } else { '' })
        $sel.Porta = $v; return $v
    }
    $btPLer.Add_Click({ try { [void](LerPorta); LerStatus } catch { MostrarErro 'Buscador: ler porta' $_.Exception } })
    $btPGravar.Add_Click({
        try {
            if (-not $sel.Porta) { throw 'Clique primeiro em "Ler configuração".' }
            $v = $sel.Porta; $i = (Canal) - 1; $q = @(); $desc = @()
            $est = @('Normal', 'OpenAlways', 'CloseAlways')[[math]::Max(0, $pEstado.SelectedIndex)]
            if ($est -ne $v.State) { $q += "AccessControl[$i].State=$est"; $desc += "estado $est" }
            if ($pTempo.Text.Trim() -ne $v.UnlockHoldInterval) { $n = 0; if (-not [int]::TryParse($pTempo.Text.Trim(), [ref]$n) -or $n -lt 250 -or $n -gt 20000) { throw 'Tempo de abertura: 250 a 20000 ms.' }; $q += "AccessControl[$i].UnlockHoldInterval=$n"; $desc += "tempo $n ms" }
            $se = $(if ($pSensor.Checked) { 'true' } else { 'false' }); if ($se -ne $v.SensorEnable) { $q += "AccessControl[$i].SensorEnable=$se"; $desc += "sensor $se" }
            if ($pAtraso.Text.Trim() -ne $v.CloseTimeout) { $n = 0; if (-not [int]::TryParse($pAtraso.Text.Trim(), [ref]$n) -or $n -lt 1 -or $n -gt 9999) { throw 'Atraso do sensor: número de segundos.' }; $q += "AccessControl[$i].CloseTimeout=$n"; $desc += "atraso $n s" }
            if ($pNome.Text.Trim() -ne $v.Name) { $q += "AccessControl[$i].Name=$([Uri]::EscapeDataString($pNome.Text.Trim()))"; $desc += "nome $($pNome.Text.Trim())" }
            foreach ($par in @(@($pZAberta, 'OpenAlwaysTime', 'zona aberta'), @($pZFechada, 'CloseAlwaysTime', 'zona fechada'))) {
                if ($par[0].Text.Trim() -ne $v[$par[1]]) { $n = 0; if (-not [int]::TryParse($par[0].Text.Trim(), [ref]$n) -or $n -lt 0 -or $n -gt 255) { throw "$($par[2]): ID de 0 a 255." }; $q += "AccessControl[$i].$($par[1])=$n"; $desc += "$($par[2]) $n" } }
            if ($pMetodo.SelectedIndex -ge 0) { $m = ([string]$pMetodo.SelectedItem).Split(' ')[0]; if ($m -ne $v.Method) { $q += "AccessControl[$i].Method=$m"; $desc += "método $m" } }
            $st = [string]$pTipoSensor.SelectedIndex; if ($pTipoSensor.SelectedIndex -ge 0 -and $st -ne $v.SensorType) { $q += "AccessControlGeneral.SensorType=$st"; $desc += "tipo sensor $st" }
            $be = $(if ($pBotao.Checked) { 'true' } else { 'false' }); if ($be -ne $v.ButtonExitEnable) { $q += "AccessControlGeneral.ButtonExitEnable=$be"; $desc += "botão saída $be" }
            $re = $(if ($pRele.Checked) { 'true' } else { 'false' }); if ($pRele.Enabled -and $re -ne $v.Rele) { $q += "_RelayStatus_[$i].Enable=$re"; $desc += "status relé $re" }
            if (-not $q.Count) { $lbSt.Text = 'Nada mudou.'; return }
            if ([System.Windows.Forms.MessageBox]::Show("Gravar no equipamento $((Atual).IP):`n`n- " + ($desc -join "`n- "), 'Gravar porta', 'YesNo', 'Question') -ne 'Yes') { return }
            Log ("Buscador: GRAVAR porta {0}: {1}" -f (Atual).IP, ($desc -join ', '))
            if (Comando ('/cgi-bin/configManager.cgi?action=setConfig&' + ($q -join '&')) 'Gravar porta') { [void](LerPorta) }
        } catch { MostrarErro 'Buscador: gravar porta' $_.Exception }
    })

    # ---- Equipamento
    $btELer.Add_Click({
        try {
            $d = Atual; $u, $s = Cred; $l = @("Equipamento $($d.IP):$($d.Porta)", '')
            foreach ($c in @(@('Informações do sistema', '/cgi-bin/magicBox.cgi?action=getSystemInfo'), @('Tipo', '/cgi-bin/magicBox.cgi?action=getDeviceType'),
                    @('Firmware', '/cgi-bin/magicBox.cgi?action=getSoftwareVersion'), @('Nº de série', '/cgi-bin/magicBox.cgi?action=getSerialNo'), @('Hora', '/cgi-bin/global.cgi?action=getCurrentTime'))) {
                $r = ReqUI $c[1] 5000
                $l += "== $($c[0])"; $l += $(if ($r.Status -eq 200) { $r.Texto } else { "(HTTP $($r.Status) $($r.Erro))" }); $l += ''
            }
            $l += "== É Bio-T?  $(ClassificarBioT $d.Modelo)"
            $eTxt.Text = ($l -join "`r`n")
        } catch { MostrarErro 'Buscador: ler equipamento' $_.Exception }
    })
    $btEReb.Add_Click({
        try {
            $d = Atual
            if ([System.Windows.Forms.MessageBox]::Show("Reiniciar o equipamento $($d.IP) ($($d.Modelo))?`nEle fica fora do ar por cerca de 1 minuto.", 'Reiniciar', 'YesNo', 'Warning') -ne 'Yes') { return }
            [void](Comando '/cgi-bin/magicBox.cgi?action=reboot' 'Reiniciar')
        } catch { MostrarErro 'Buscador: reiniciar' $_.Exception }
    })

    $w.Add_FormClosing({ $tmP.Stop(); $pAuto.Checked = $false; $tmPing.Stop(); $rPing.Checked = $false
        if ($script:BuscaD) { $script:BuscaD.Run = $false; $tmB.Stop(); foreach ($tf in $script:BTarefas) { FimBg $tf }; $script:BTarefas = @(); $script:BuscaD = $null; $btBuscar.Text = 'BUSCAR' }
        Log '--- Fechou o BUSCADOR DE IP' })
function AbrirBuscador {
    Log '--- Abriu o BUSCADOR DE IP'
    $script:faixas = @(FaixasDoPc)
    if ($txtIp.Text -and (IpValido $txtIp.Text.Trim())) { $p = $txtIp.Text.Trim().Split('.'); $bFaixa.Text = "$($p[0]).$($p[1]).$($p[2]).1-$($p[0]).$($p[1]).$($p[2]).254" }
    elseif ($script:faixas.Count -and -not $bFaixa.Text) { $bFaixa.Text = $script:faixas[0] }
    $lbFx.Text = 'Faixas deste PC: ' + ($script:faixas -join '   ')
    if ($txtPorta.Text) { $bPorta.Text = $txtPorta.Text }
    if ($txtUser.Text) { $bUser.Text = $txtUser.Text }
    if ($txtSenha.Text) { $bSenha.Text = $txtSenha.Text }
    [void]$w.ShowDialog($f)
}
$btnBusca.Add_Click({ try { AbrirBuscador } catch { MostrarErro 'Erro no Buscador de IP' $_.Exception } })

Log 'Interface aberta.'
try { [void]$f.ShowDialog() } catch { LogExcecao 'Erro fatal na interface' $_.Exception }
Log '=== Aplicativo encerrado ==='

Param(
  [string]$TestShot = '',
  [string]$Render = '',
  [switch]$InstallShortcut,
  [switch]$Autostart,
  [switch]$RemoveShortcut,
  [string]$Say = '',
  [switch]$OpenChat,
  [switch]$GreetNow,
  [switch]$LangTest,
  [switch]$ChatTwice
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$script:Root      = Split-Path -Parent $MyInvocation.MyCommand.Path

# 版本信息：由 scripts/sync-from-live.ps1 旁边的 version.json 提供，读不到就用内置默认
$script:AppVersion = '1.0.0'
$script:AppBuild   = 0
$script:AppDate    = ''
try {
  $vf = Join-Path $script:Root 'version.json'
  if (Test-Path $vf) {
    $vj = Get-Content -LiteralPath $vf -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($vj.version) { $script:AppVersion = [string]$vj.version }
    if ($vj.build)   { $script:AppBuild   = [int]$vj.build }
    if ($vj.date)    { $script:AppDate    = [string]$vj.date }
  }
} catch { }
function Get-VersionLine {
  if ($script:AppBuild -gt 0) {
    return ('v{0} · build {1} · {2}' -f $script:AppVersion, $script:AppBuild, $script:AppDate)
  }
  return ('v{0}' -f $script:AppVersion)
}
$script:Assets    = Join-Path $script:Root 'assets'
$script:WinFile   = Join-Path $script:Root 'window.json'
$script:PidFile   = Join-Path $script:Root 'widget.pid'
$script:DshHome      = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
$script:StateFile = Join-Path $script:DshHome 'feiyu-mood\state.json'
$script:ConfFile  = Join-Path $script:DshHome 'feiyu-mood\config.json'

$script:Pets  = @('活'); 
$script:PanelOpen = $false
$script:BridgeDir = Join-Path $script:Root 'bridge'
$script:ChatOpen  = $false
$script:LeaveTimer = $null
$script:CurFaceFile = ''
$script:FaceLockUntil = [DateTime]::MinValue   # 反应表情至少停留到这个时刻
$script:BlinkOn = $false
$script:BlinkTimer = $null
$script:BlinkScheduler = $null
$script:ReplyTicks = 0
$script:ReplyTimer = $null
$script:BubbleTimer = $null
$script:ReplyId = ''
$script:AppDir = $script:Root
$script:Launcher = Join-Path $script:Root 'launch.vbs'
$script:DeskLink = Join-Path ([Environment]::GetFolderPath('Desktop')) '鱼的心情.lnk'
$script:StartLink = Join-Path ([Environment]::GetFolderPath('Startup')) '鱼的心情.lnk'

$DIM_KEYS   = @('happy','calm','sweet','heartache','worry','sad','jealous')
$DIM_COLORS = @{ happy='#5DDC8A'; calm='#7AAADC'; sweet='#E28FC0'; heartache='#E0B070'; worry='#E8A25B'; sad='#7A96C8'; jealous='#C88FDC' }

# ---------- her settings (pet-settings.json) ----------
$script:SettingsPath = Join-Path $script:Root 'pet-settings.json'
$script:Settings = [pscustomobject]@{
  memory        = [pscustomobject]@{ enabled = $true; keepTurns = 3; compressEvery = 8; maxPoints = 5; warmPoints = 4 }
  knowWorkspace = $false
  bubbleSeconds = 6
  refreshMs     = 1200
  autostart     = $true
  model         = ''
  lang          = 'auto'
}

function Read-PetSettings {
  try {
    if (-not (Test-Path -LiteralPath $script:SettingsPath)) { return }
    $raw = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $raw) { return }
    foreach ($k in @('knowWorkspace', 'bubbleSeconds', 'refreshMs', 'autostart', 'model', 'lang')) {
      if ($null -ne $raw.$k) { $script:Settings.$k = $raw.$k }
    }
    if ($null -ne $raw.memory) {
      foreach ($k in @('enabled', 'keepTurns', 'compressEvery', 'maxPoints', 'warmPoints')) {
        if ($null -ne $raw.memory.$k) { $script:Settings.memory.$k = $raw.memory.$k }
      }
    }
  } catch { }
}

function Save-PetSettings {
  $obj = [pscustomobject]@{
    memory = [pscustomobject]@{
      enabled       = [bool]$script:Settings.memory.enabled
      keepTurns     = [int]$script:Settings.memory.keepTurns
      compressEvery = [int]$script:Settings.memory.compressEvery
      maxPoints     = [int]$script:Settings.memory.maxPoints
      warmPoints    = [int]$script:Settings.memory.warmPoints
    }
    knowWorkspace = [bool]$script:Settings.knowWorkspace
    bubbleSeconds = [int]$script:Settings.bubbleSeconds
    refreshMs     = [int]$script:Settings.refreshMs
    autostart     = [bool]$script:Settings.autostart
    model         = [string]$script:Settings.model
    lang          = [string]$script:Settings.lang
  }
  $json = $obj | ConvertTo-Json -Depth 6
  [System.IO.File]::WriteAllText($script:SettingsPath, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Set-Autostart([bool]$on) {
  try {
    $wsh = "$env:WINDIR\System32\wscript.exe"
    if ($on) {
      if (-not (Test-Path -LiteralPath (Join-Path $script:Root 'feiyu.ico'))) {
        New-IconFromPng (Join-Path $script:Assets 'feiyu.png') (Join-Path $script:Root 'feiyu.ico')
      }
      New-Lnk $script:StartLink $wsh ('"' + $script:Launcher + '"') (Join-Path $script:Root 'feiyu.ico') $script:Root '鱼的心情 · 桌面挂饰'
    } elseif (Test-Path -LiteralPath $script:StartLink) {
      Remove-Item -LiteralPath $script:StartLink -Force
    }
  } catch { }
}

function Apply-PetSettings {
  if ($script:Timer) {
    $ms = [Math]::Max(400, [int]$script:Settings.refreshMs)
    $script:Timer.Interval = [TimeSpan]::FromMilliseconds($ms)
  }
  Set-Autostart ([bool]$script:Settings.autostart)
}

# ---------- shortcuts ----------
function New-IconFromPng($png, $ico) {
  $src = [System.Drawing.Image]::FromFile($png)
  $bmp = New-Object System.Drawing.Bitmap 256, 256
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.Clear([System.Drawing.Color]::Transparent)
  $g.DrawImage($src, 0, 0, 256, 256)
  $g.Dispose()
  $ms = New-Object System.IO.MemoryStream
  $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose(); $src.Dispose()
  $pngBytes = $ms.ToArray(); $ms.Dispose()
  $fs = [System.IO.File]::Create($ico)
  $bw = New-Object System.IO.BinaryWriter $fs
  $bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]1)
  $bw.Write([Byte]0); $bw.Write([Byte]0); $bw.Write([Byte]0); $bw.Write([Byte]0)
  $bw.Write([UInt16]1); $bw.Write([UInt16]32)
  $bw.Write([UInt32]$pngBytes.Length); $bw.Write([UInt32]22)
  $bw.Write($pngBytes)
  $bw.Flush(); $bw.Close(); $fs.Close()
}

function New-Lnk($path, $target, $arguments, $icon, $workdir, $desc) {
  $sh = New-Object -ComObject WScript.Shell
  $lnk = $sh.CreateShortcut($path)
  $lnk.TargetPath = $target
  if ($arguments) { $lnk.Arguments = $arguments }
  if ($workdir) { $lnk.WorkingDirectory = $workdir }
  if ($icon) { $lnk.IconLocation = $icon }
  if ($desc) { $lnk.Description = $desc }
  $lnk.Save()
}

if ($InstallShortcut -or $RemoveShortcut) {
  $wsh = "$env:WINDIR\System32\wscript.exe"
  $ico = Join-Path $script:Root 'feiyu.ico'
  if ($RemoveShortcut) {
    foreach ($p in @($script:DeskLink, $script:StartLink)) { if (Test-Path $p) { Remove-Item $p -Force } }
    Write-Output 'shortcuts removed'
    exit 0
  }
  New-IconFromPng (Join-Path $script:Assets 'feiyu.png') $ico
  New-Lnk $script:DeskLink $wsh ('"' + $script:Launcher + '"') $ico $script:Root '鱼的心情 · 桌面挂饰'
  Write-Output "desktop shortcut: $script:DeskLink"
  if ($Autostart) {
    New-Lnk $script:StartLink $wsh ('"' + $script:Launcher + '"') $ico $script:Root '鱼的心情 · 桌面挂饰'
    Write-Output "startup shortcut: $script:StartLink"
  }
  exit 0
}

# ---------- single instance (exclusive lock file; robust against races) ----------
$script:InstanceLock = $null
$script:Handoff = $false
$script:LockPath = Join-Path $script:Root 'widget.lock'
$script:ReadyFlag = Join-Path $script:Root '_ready.flag'
$script:RestartFlag = Join-Path $script:Root '_restart.flag'
if (-not $TestShot -and -not $Render) {
  Remove-Item $script:ReadyFlag -Force -ErrorAction SilentlyContinue
  if (Test-Path $script:RestartFlag) {
    # Woken by a language switch: the previous instance still owns the lock and keeps its
    # window on screen. Show ours first, then take the lock once it has stepped aside.
    $script:Handoff = $true
    Remove-Item $script:RestartFlag -Force -ErrorAction SilentlyContinue
  } else {
    try {
      $script:InstanceLock = [System.IO.File]::Open($script:LockPath, [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    } catch {
      exit 0
    }
  }
}

# ---------- data ----------
Read-PetSettings

# ---------- interface language ----------
$script:Lang = 'zh'
$script:I18N = [ordered]@{
  '鱼的心情 · 桌面挂饰' = 'Feiyu · desktop widget'
  '鱼的心情' = 'Her mood'
  '她的设置…' = 'Her settings…'
  '她的设置' = 'Her settings'
  '和她说句话' = 'Say something'
  '鱼的状态' = 'Her status'
  '只影响桌面上的小鱼；DSH 那边不受影响。' = 'Only affects the little fish on your desktop; nothing inside DSH changes.'
  '让她记住我们聊过的事（温层压缩）' = 'Let her remember what we talked about (warm-layer memory)'
  '让她知道我在工作区忙什么（读最近一次摘要，默认关）' = 'Let her know what I am busy with (uses the last summary)'
  '保留最近' = 'Keep last'
  '轮；每' = 'turns; compress every'
  '轮压缩一次' = 'turns'
  '开机时自动出现' = 'Show up at startup'
  '英文界面（English interface）' = 'English interface'
  '气泡停留' = 'Bubble stays'
  '秒；心情刷新' = 's; mood refresh'
  '毫秒' = 'ms'
  '聊天用的模型（留空 = 自动挑一个）' = 'Model for chatting (leave empty = auto pick one)'
  '取消' = 'Cancel'
  '保存' = 'Save'
  '打开 / 收起面板' = 'Open / close panel'
  '重置位置' = 'Reset position'
  '开机自动启动' = 'Launch at startup'
  '打开面板' = 'Open panel'
  '把小鱼叫出来' = 'Show the little fish'
  '重新启动挂件' = 'Restart widget'
  '退出' = 'Quit'
  '小鱼在托盘里' = 'The little fish is in the tray'
  '双击托盘图标打开面板；右键有菜单，可以叫她出来或退出。' = 'Double-click the tray icon to open the panel; right-click for the menu.'
  '发送' = 'Send'
  '七根情绪' = 'Seven moods'
  '最近的心情' = 'Recent moods'
  '还没有判断过心情' = 'No mood reading yet'
  '（还没有记录）' = '(nothing recorded yet)'
  '还没开始' = 'Not yet'
  '等第一轮聊天' = 'waiting for the first chat'
  '数据：' = 'Data: '
  '写不进聊天通道：' = 'Cannot write to the chat bridge: '
  '……（DSH 好像没在后台跑，我收不到消息）' = '… (DSH does not seem to be running, so I get no messages)'
  '……（她没说话）' = '… (she said nothing)'
  '……（没等到回复，DSH 可能刚关掉）' = '… (no reply — DSH may have just closed)'
  '没连上模型（' = 'could not reach a model: '
  '今天也要好好休息呀～' = 'Rest well today too~'
  '你在干嘛呀' = 'What are you doing?'
  '这是测试回复，看看会不会压到输入框。' = 'Test reply — check it does not cover the input bar.'
  '欢喜' = 'Delighted'
  '开心' = 'Happy'
  '一般' = 'Okay'
  '心疼' = 'Aching'
  '难过' = 'Sad'
  '踏实' = 'Steady'
  '甜蜜' = 'Sweet'
  '担心' = 'Anxious'
  '吃醋' = 'Jealous'
  '还不太熟' = 'a stranger'
  '渐渐熟了' = 'getting familiar'
  '很亲近' = 'close'
  '黏着你' = 'clingy'
}
function L([string]$s) {
  if ($script:Lang -ne 'en') { return $s }
  if ($script:I18N.Contains($s)) { return $script:I18N[$s] }
  return $s
}
function T-Xaml([string]$x) {
  if ($script:Lang -ne 'en') { return $x }
  $keys = @($script:I18N.Keys) | Sort-Object -Property Length -Descending
  foreach ($k in $keys) { $x = $x.Replace($k, $script:I18N[$k]) }
  return $x
}
if ($script:Settings.lang -eq 'en') { $script:Lang = 'en' }
elseif ($script:Settings.lang -eq 'zh') { $script:Lang = 'zh' }
else {
  try {
    $uiLang = [System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName
    if ($uiLang -and $uiLang -ne 'zh') { $script:Lang = 'en' }
  } catch { }
}
$script:DIM_LABELS = if ($script:Lang -eq 'en') {
  @{ happy='Happy'; calm='Steady'; sweet='Sweet'; heartache='Aching'; worry='Anxious'; sad='Down'; jealous='Jealous' }
} else {
  @{ happy='开心'; calm='踏实'; sweet='甜蜜'; heartache='心疼'; worry='担心'; sad='难过'; jealous='吃醋' }
}

function Get-Entry {
  if (-not (Test-Path $script:StateFile)) { return $null }
  try {
    $raw = Get-Content -LiteralPath $script:StateFile -Raw -Encoding UTF8
    $state = $raw | ConvertFrom-Json
  } catch { return $null }
  if (-not $state.moods) { return $null }
  $key = $null
  if ($state.lastActive) { $key = [string]$state.lastActive }
  $props = @($state.moods.PSObject.Properties)
  if (-not $key -or -not ($props | Where-Object { $_.Name -eq $key })) {
    if ($props.Count -gt 0) { $key = $props[0].Name } else { return $null }
  }
  $entry = ($props | Where-Object { $_.Name -eq $key })[0].Value
  $names = @()
  if (Test-Path $script:ConfFile) {
    try {
      $conf = (Get-Content -LiteralPath $script:ConfFile -Raw -Encoding UTF8) | ConvertFrom-Json
      if ($conf.slots -and $conf.slots.Count -gt 0) {
        $slot = $conf.slots | Where-Object { [string]$_.id -eq $key } | Select-Object -First 1
        if ($slot -and $slot.label) { $names = @([string]$slot.label) }
      }
    } catch { }
  }
  return [pscustomobject]@{ Entry = $entry; Key = $key; Label = ($names -join '') }
}

function Get-FaceInfo([int]$v) {
  if ($v -ge 80) { return @{ File = 'face-great.png'; Label = (L '欢喜'); Color = '#5DDC8A' } }
  if ($v -ge 62) { return @{ File = 'face-good.png';  Label = (L '开心'); Color = '#7DDBA0' } }
  if ($v -ge 42) { return @{ File = 'face-ok.png';    Label = (L '一般'); Color = '#9AA0A6' } }
  if ($v -ge 25) { return @{ File = 'face-worry.png'; Label = (L '心疼'); Color = '#E8A25B' } }
  return @{ File = 'face-sad.png'; Label = (L '难过'); Color = '#7A96C8' }
}

# ---------- windows ----------
$petXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="鱼的心情" Width="164" Height="164"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False" ResizeMode="NoResize">
  <Grid x:Name="RootPanel" Background="Transparent">
    <!-- 旧状态条改成 0 尺寸占位；真正的状态条是独立窗口，显示在桌宠左侧 -->
    <Border x:Name="Pill" Width="0" Height="0" Visibility="Collapsed" Background="#00000000" BorderThickness="0" IsHitTestVisible="False">
      <TextBlock x:Name="PillText" FontFamily="Microsoft YaHei" FontSize="11.5"/>
    </Border>
    <Image x:Name="Pet" Width="156" Height="156" Stretch="Uniform" Cursor="SizeAll" RenderTransformOrigin="0.5,1">
      <Image.RenderTransform>
        <TransformGroup>
          <ScaleTransform x:Name="PetScale" ScaleX="1" ScaleY="1"/>
          <RotateTransform x:Name="PetRotate" Angle="0"/>
          <TranslateTransform x:Name="PetShift" X="0" Y="0"/>
        </TransformGroup>
      </Image.RenderTransform>
    </Image>
    <!-- 眨眼用的叠层：睁眼图不变，闭眼图淡入淡出，避免“整张图闪一下” -->
    <Image x:Name="PetGhost" Width="156" Height="156" Stretch="Uniform" Opacity="0"
           IsHitTestVisible="False" RenderTransformOrigin="0.5,1">
      <Image.RenderTransform>
        <TransformGroup>
          <ScaleTransform x:Name="PetGScale" ScaleX="1" ScaleY="1"/>
          <RotateTransform x:Name="PetGRotate" Angle="0"/>
          <TranslateTransform x:Name="PetGShift" X="0" Y="0"/>
        </TransformGroup>
      </Image.RenderTransform>
    </Image>
  </Grid>
</Window>
'@

$panelXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="鱼的心情" Width="316" SizeToContent="Height" MaxHeight="620"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False" ResizeMode="NoResize">
  <Border x:Name="Card" Background="#F21B1C1F" BorderBrush="#4D808080"
          BorderThickness="1" CornerRadius="12" Padding="14">
    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
      <StackPanel x:Name="Body"/>
    </ScrollViewer>
  </Border>
</Window>
'@

$pet = [Windows.Markup.XamlReader]::Parse((T-Xaml $petXaml))
$panel = [Windows.Markup.XamlReader]::Parse((T-Xaml $panelXaml))
$script:PetImg = $pet.FindName('Pet')
$script:PetGhost = $pet.FindName('PetGhost')
$script:PetGScale = $pet.FindName('PetGScale')
$script:PetGRotate = $pet.FindName('PetGRotate')
$script:PetGShift = $pet.FindName('PetGShift')
$script:Pill = $pet.FindName('Pill')
$script:PillText = $pet.FindName('PillText')
$script:Body = $panel.FindName('Body')

$bubbleXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="鱼的心情" Width="272" SizeToContent="Height" MaxWidth="272"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False" ResizeMode="NoResize">
  <Border x:Name="BubCard" Background="#E61C2740" BorderBrush="#5C8FB4FF"
          BorderThickness="1.2" CornerRadius="12" Padding="12,7">
    <TextBlock x:Name="BubText" FontFamily="Microsoft YaHei" FontSize="12.5"
               Foreground="#E9EFFA" TextWrapping="Wrap" MaxWidth="244"/>
  </Border>
</Window>
'@

$chatXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="和她说句话" Width="272" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize">
  <Border Background="#F2090C12" BorderBrush="#8E82A0FF" BorderThickness="1.2" CornerRadius="12" Padding="8">
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <Border Grid.Column="0" CornerRadius="10" Background="#1FFFFFFF" Margin="0,0,6,0">
        <TextBox x:Name="ChatInput" Background="Transparent" BorderThickness="0" Padding="8,5"
                 FontFamily="Microsoft YaHei" FontSize="13" Foreground="#F2F3F5" CaretBrush="#F2F3F5"
                 VerticalContentAlignment="Center"/>
      </Border>
      <Button x:Name="ChatSend" Grid.Column="1" Content="发送" Height="28" Margin="0,0,6,0"
              FontFamily="Microsoft YaHei" FontSize="12" Padding="12,0" Cursor="Hand"
              Background="#E8EEF9" Foreground="#1B1C1F" BorderThickness="0"/>
      <Button x:Name="ChatClose" Grid.Column="2" Content="✕" Width="26" Height="26"
              FontSize="12" Cursor="Hand" Background="Transparent" Foreground="#9AA0A6" BorderThickness="0"/>
    </Grid>
  </Border>
</Window>
'@

$statusXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="鱼的状态" SizeToContent="Manual" Width="120" Height="26"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False" ResizeMode="NoResize">
  <Border x:Name="StatusCard" Background="#D91B1C1F" BorderThickness="0"
          CornerRadius="10" Padding="9,2">
    <TextBlock x:Name="StatusText" FontFamily="Microsoft YaHei" FontSize="13" FontWeight="SemiBold" Foreground="#F2F3F5"/>
  </Border>
</Window>
'@

$bubble = [Windows.Markup.XamlReader]::Parse((T-Xaml $bubbleXaml))
$chat = [Windows.Markup.XamlReader]::Parse((T-Xaml $chatXaml))
$script:Bubble = $bubble
$script:BubText = $bubble.FindName('BubText')
$script:Chat = $chat
$script:ChatInput = $chat.FindName('ChatInput')
$script:ChatSend = $chat.FindName('ChatSend')
$script:ChatClose = $chat.FindName('ChatClose')
$script:Status = [Windows.Markup.XamlReader]::Parse((T-Xaml $statusXaml))
$script:StatusText = $script:Status.FindName('StatusText')
$script:StatusCard = $script:Status.FindName('StatusCard')
$script:PetScale = $pet.FindName('PetScale')
$script:PetRotate = $pet.FindName('PetRotate')
$script:PetShift = $pet.FindName('PetShift')

# 高 DPI 下保持清晰：进程设为系统 DPI 感知（失败也无妨）
try {
  if (-not ('DpiFix' -as [type])) {
    Add-Type -Namespace '' -Name 'DpiFix' -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetProcessDPIAware();
"@
  }
  [void][DpiFix]::SetProcessDPIAware()
} catch { }

# 窗口图标（任务栏/Alt-Tab 用）
try {
  $icoPath = Join-Path $script:Root 'feiyu.ico'
  if (-not (Test-Path $icoPath)) { New-IconFromPng (Join-Path $script:Assets 'feiyu.png') $icoPath }
  $icoUri = [Uri]::new($icoPath)
  $pet.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create($icoUri)
  $panel.Icon = $pet.Icon
} catch { }

function New-Text($text, $size, $brush, $weight) {
  $tb = New-Object System.Windows.Controls.TextBlock
  $tb.Text = $text
  $tb.FontFamily = New-Object System.Windows.Media.FontFamily 'Microsoft YaHei'
  $tb.FontSize = $size
  $tb.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($brush)
  if ($weight) { $tb.FontWeight = 'Bold' }
  $tb.TextWrapping = 'Wrap'
  return $tb
}

# header
$faceImg = New-Object System.Windows.Controls.Image
$faceImg.Width = 64; $faceImg.Height = 64; $faceImg.Stretch = 'Uniform'
$faceImg.Margin = '0,0,10,0'
$script:BigText = New-Text '—' 24 '#E8E8EA' $true
$script:SmallText = New-Text '' 12 '#9AA0A6'
$headStack = New-Object System.Windows.Controls.StackPanel
$headStack.Children.Add($script:BigText) | Out-Null
$headStack.Children.Add($script:SmallText) | Out-Null
$headGrid = New-Object System.Windows.Controls.Grid
$c1 = New-Object System.Windows.Controls.ColumnDefinition
$c1.Width = 'Auto'; $c2 = New-Object System.Windows.Controls.ColumnDefinition
$c2.Width = New-Object System.Windows.GridLength 1, 'Star'
$headGrid.ColumnDefinitions.Add($c1); $headGrid.ColumnDefinitions.Add($c2)
[System.Windows.Controls.Grid]::SetColumn($faceImg, 0)
[System.Windows.Controls.Grid]::SetColumn($headStack, 1)
$headGrid.Children.Add($faceImg) | Out-Null
$headGrid.Children.Add($headStack) | Out-Null
$script:Body.Children.Add($headGrid) | Out-Null

$script:Reason = New-Text '' 12 '#9AA0A6'
$script:Reason.Margin = '0,8,0,10'
$script:Body.Children.Add($script:Reason) | Out-Null

# dims
$dimsGrid = New-Object System.Windows.Controls.StackPanel
$script:DimRows = @{}
foreach ($k in $DIM_KEYS) {
  $row = New-Object System.Windows.Controls.Grid
  $labelW = if ($script:Lang -eq 'en') { '66' } else { '36' }
  foreach ($w in @($labelW,'1*','32')) {
    $cd = New-Object System.Windows.Controls.ColumnDefinition
    if ($w -eq '1*') { $cd.Width = New-Object System.Windows.GridLength 1, 'Star' } else { $cd.Width = [System.Windows.GridLength]::new([double]$w) }
    $row.ColumnDefinitions.Add($cd)
  }
  $lab = New-Text $script:DIM_LABELS[$k] 12 '#9AA0A6'
  $lab.VerticalAlignment = 'Center'
  [System.Windows.Controls.Grid]::SetColumn($lab, 0)
  $track = New-Object System.Windows.Controls.Border
  $track.Height = 7; $track.CornerRadius = [System.Windows.CornerRadius]::new(4)
  $track.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString('#33FFFFFF')
  $track.VerticalAlignment = 'Center'; $track.Margin = '0,0,8,0'
  $trackGrid = New-Object System.Windows.Controls.Grid
  $fill = New-Object System.Windows.Controls.Border
  $fill.Height = 7; $fill.CornerRadius = [System.Windows.CornerRadius]::new(4)
  $fill.HorizontalAlignment = 'Left'
  $fill.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($DIM_COLORS[$k])
  $trackGrid.Children.Add($fill) | Out-Null
  $track.Child = $trackGrid
  [System.Windows.Controls.Grid]::SetColumn($track, 1)
  $val = New-Text '0' 12 '#9AA0A6'
  $val.TextAlignment = 'Right'
  [System.Windows.Controls.Grid]::SetColumn($val, 2)
  $row.Children.Add($lab) | Out-Null
  $row.Children.Add($track) | Out-Null
  $row.Children.Add($val) | Out-Null
  $row.Margin = '0,3,0,3'
  $dimsGrid.Children.Add($row) | Out-Null
  $script:DimRows[$k] = @{ Fill = $fill; Val = $val; Track = $trackGrid }
}
$dimsHead = New-Text (L '七根情绪') 12 '#C9CDD3' $true
$dimsHead.Margin = '0,6,0,4'
$script:Body.Children.Add($dimsHead) | Out-Null
$script:Body.Children.Add($dimsGrid) | Out-Null

$sep = New-Object System.Windows.Controls.Border
$sep.Height = 1; $sep.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString('#26808080')
$sep.Margin = '0,12,0,8'
$script:Body.Children.Add($sep) | Out-Null

$tlHead = New-Text (L '最近的心情') 12 '#C9CDD3' $true
$tlHead.Margin = '0,0,0,4'
$script:Body.Children.Add($tlHead) | Out-Null
$script:TlPanel = New-Object System.Windows.Controls.StackPanel
$script:Body.Children.Add($script:TlPanel) | Out-Null

$script:Foot = New-Text '' 11 '#7A8088'
$script:Foot.Margin = '0,10,0,0'
$script:Body.Children.Add($script:Foot) | Out-Null

# ---------- state ----------
function Set-ImageSource($img, $path) {
  if (-not (Test-Path $path)) { return }
  $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
  $bmp.BeginInit()
  $bmp.CacheOption = 'OnLoad'
  $bmp.UriSource = [Uri]::new($path)
  $bmp.EndInit()
  $bmp.Freeze()
  $img.Source = $bmp
}

function Update-Ui {
  $data = Get-Entry
  if (-not $data) {
    $script:PillText.Text = (L '还没开始')
    Set-ImageSource $script:PetImg (Join-Path $script:Assets 'face-ok.png')
    $script:BigText.Text = '—'
    $script:SmallText.Text = (L '等第一轮聊天')
    return
  }
  $e = $data.Entry
  $mood = [int]$e.mood
  # 与长期情绪混合：桌面聊天攒出来的情绪更“贴身”，DSH 会话心情做参考。
  $emo = Get-Emotion
  $eff = $mood
  if ($emo.updatedAt -gt 0) {
    $emoBase = [double](($emo.valence + 100) / 2)
    $eff = [int][Math]::Round($mood * 0.35 + $emoBase * 0.65)
  }
  $face = Get-FaceInfo $eff
  if ([DateTime]::UtcNow -lt $script:FaceLockUntil -and $script:CurFaceFile -and (Test-Path (Join-Path $script:Assets $script:CurFaceFile))) {
    $face = @{ File = $script:CurFaceFile; Label = $face.Label; Color = $face.Color }
  }
  if ($script:CurFaceFile -and $script:CurFaceFile -ne $face.File -and $script:BlinkOn) { Stop-Blink }
  Set-ImageSource $script:PetImg (Join-Path $script:Assets $face.File)
  $script:CurFaceFile = $face.File
  Set-ImageSource $faceImg (Join-Path $script:Assets $face.File)
  $script:StatusText.Text = ('{0} · {1}' -f $face.Label, $eff)
  Fit-Status
  if ($script:Status.IsVisible) { Place-Status }
  try {
    $c = [System.Windows.Media.Color]::FromRgb(
      [Convert]::ToByte($face.Color.Substring(1,2),16),
      [Convert]::ToByte($face.Color.Substring(3,2),16),
      [Convert]::ToByte($face.Color.Substring(5,2),16))
    $script:Pill.BorderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(150, $c.R, $c.G, $c.B))
  } catch { }
  $script:BigText.Text = [string]$mood
  $script:BigText.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString('#E8E8EA')
  $slot = [string]$data.Label
  $rel = Get-RelationLabel $emo.relation
  if ($slot) { $script:SmallText.Text = ($face.Label + ' · ' + $slot) } else { $script:SmallText.Text = $face.Label }
  $script:SmallText.Text = $script:SmallText.Text + ' · ' + $rel
  $reason = ''
  if ($e.lastReason) { $reason = [string]$e.lastReason }
  $script:Reason.Text = if ($reason) { $reason } else { (L '还没有判断过心情') }
  foreach ($k in $DIM_KEYS) {
    $v = 0
    try { $v = [double]$e.dims.$k } catch { }
    $row = $script:DimRows[$k]
    $row.Val.Text = '{0:+0;-0;0}' -f [int]$v
    $trackW = 0.0
    try { $trackW = $row.Track.ActualWidth } catch { }
    if ($trackW -le 0) { $trackW = 180 }
    $ratio = [Math]::Min(1.0, [Math]::Abs($v) / 100.0)
    $row.Fill.Width = [Math]::Round($trackW * $ratio, 1)
  }
  # timeline
  $script:TlPanel.Children.Clear()
  if ($emo.updatedAt -gt 0) {
    $hiFmt = if ($script:Lang -eq 'en') { 'Closeness {0} · Energy {1} · Bond: {2}' } else { '亲密度 {0} · 精力 {1} · 关系 {2}' }
    $hi = New-Text ($hiFmt -f [int]$emo.affection, [int]$emo.energy, $rel) 11.5 '#9FB4D8'
    $hi.Margin = '0,0,0,3'
    $script:TlPanel.Children.Add($hi) | Out-Null
    $last = $null
    try { $last = @($emo.memories) | Select-Object -Last 1 } catch { }
    if ($last) {
      $memTxt = if ($script:Lang -eq 'en') { 'Last you said: "' + [string]$last.user + '"' } else { '上次你说：“' + [string]$last.user + '”' }
      $mem = New-Text $memTxt 11 '#8C93A0'
      $mem.TextTrimming = 'CharacterEllipsis'
      $mem.Margin = '0,0,0,5'
      $script:TlPanel.Children.Add($mem) | Out-Null
    }
  }
  $tl = @()
  try { $tl = @($e.timeline) } catch { }
  if ($tl.Count -eq 0) {
    $empty = New-Text (L '（还没有记录）') 12 '#7A8088'
    $script:TlPanel.Children.Add($empty) | Out-Null
  } else {
    $take = @($tl | Select-Object -Last 5)
    [array]::Reverse($take)
    foreach ($t in $take) {
      $line = New-Object System.Windows.Controls.Grid
      $c1 = New-Object System.Windows.Controls.ColumnDefinition
      $c1.Width = 'Auto'
      $c2 = New-Object System.Windows.Controls.ColumnDefinition
      $c2.Width = New-Object System.Windows.GridLength 1, 'Star'
      $line.ColumnDefinitions.Add($c1); $line.ColumnDefinitions.Add($c2)
      $time = ''
      if ($t.at) {
        try { $time = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$t.at).ToLocalTime().ToString('HH:mm') } catch { }
      }
      $delta = 0
      try { $delta = [int]$t.delta } catch { }
      $prefix = '{0} {1} {2:+0;-0;0}' -f $time, ([int]$t.mood), $delta
      $left = New-Text $prefix 11 '#8A93A0'
      $left.Margin = '0,0,8,0'
      $left.VerticalAlignment = 'Top'
      [System.Windows.Controls.Grid]::SetColumn($left, 0)
      $rn = New-Text ([string]$t.reason) 11.5 '#C9CDD3'
      [System.Windows.Controls.Grid]::SetColumn($rn, 1)
      $line.Children.Add($left) | Out-Null
      $line.Children.Add($rn) | Out-Null
      $line.Margin = '0,3,0,4'
      $script:TlPanel.Children.Add($line) | Out-Null
    }
  }
  $script:Foot.Text = (L '数据：') + $script:StateFile + ' · ' + (Get-Date).ToString('HH:mm:ss')
  $script:Body.Children | Out-Null
}

# ---------- positions ----------
function Get-WorkArea {
  $area = [System.Windows.SystemParameters]::WorkArea
  return $area
}

# 立绘四周本身是透明的：形象可见边缘离窗口边界还有一段距离。
# 允许窗口越过工作区这么多，形象底部/右侧才能真正贴到屏幕边上。
$script:PetInsets = @{ Left = 13.0; Right = 14.5; Top = 29.0; Bottom = 28.0 }

function Get-PetInsets { return $script:PetInsets }

function Render-Window($win, $path) {
  $dv = [System.Windows.Media.VisualTreeHelper]::GetDpi($win)
  $wDiu = if ($win.ActualWidth -gt 0) { $win.ActualWidth } else { $win.Content.ActualWidth }
  $hDiu = if ($win.ActualHeight -gt 0) { $win.ActualHeight } else { $win.Content.ActualHeight }
  $pw = [int][Math]::Max(1, [Math]::Round($wDiu * $dv.DpiScaleX))
  $ph = [int][Math]::Max(1, [Math]::Round($hDiu * $dv.DpiScaleY))
  $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap $pw, $ph, $dv.PixelsPerInchX, $dv.PixelsPerInchY, ([System.Windows.Media.PixelFormats]::Pbgra32)
  $rtb.Render($win.Content)
  $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
  $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
  $fs = [System.IO.File]::Create($path)
  $enc.Save($fs)
  $fs.Close()
}

function Test-RectOverlap($ax, $ay, $aw, $ah, $bx, $by, $bw, $bh) {
  if (($ax + $aw) -le ($bx + 2)) { return $false }
  if (($bx + $bw) -le ($ax + 2)) { return $false }
  if (($ay + $ah) -le ($by + 2)) { return $false }
  if (($by + $bh) -le ($ay + 2)) { return $false }
  return $true
}

function Place-Panel {
  # 面板不压输入条、不压回复气泡：优先放形象靠屏幕中间那一侧，
  # 侧面放不下再放到整摞气泡上方，最后兜底贴工作区顶部。
  if (-not $script:PanelOpen) { return }
  $wa = Get-WorkArea
  $panel.UpdateLayout()
  $w = if ($panel.Width -gt 0) { [double]$panel.Width } else { 316.0 }
  if ([double]::IsNaN($w)) { $w = 316.0 }
  $h = [double]$panel.ActualHeight
  if ([double]::IsNaN($h) -or $h -le 0) { $h = [double]$panel.Height }
  if ([double]::IsNaN($h) -or $h -le 0) { $h = 460.0 }

  $waL = [double]$wa.Left + 4
  $waT = [double]$wa.Top + 4
  $waR = [double]$wa.Right - 4
  $waB = [double]$wa.Bottom - 4

  $avoid = New-Object System.Collections.ArrayList
  if ($script:ChatOpen) {
    $cw = if ($script:Chat.ActualWidth -gt 0) { [double]$script:Chat.ActualWidth } else { 272.0 }
    $ch = if ($script:Chat.ActualHeight -gt 0) { [double]$script:Chat.ActualHeight } else { 46.0 }
    [void]$avoid.Add(@([double]$script:Chat.Left, [double]$script:Chat.Top, $cw, $ch))
  }
  if ($script:Bubble.IsVisible) {
    $bw = if ($script:Bubble.ActualWidth -gt 0) { [double]$script:Bubble.ActualWidth } else { 272.0 }
    $bh = if ($script:Bubble.ActualHeight -gt 0) { [double]$script:Bubble.ActualHeight } else { 60.0 }
    [void]$avoid.Add(@([double]$script:Bubble.Left, [double]$script:Bubble.Top, $bw, $bh))
  }

  $petBottom = [double]$pet.Top + [double]$pet.Height
  $petRight = [double]$pet.Left + [double]$pet.Width
  $petCx = [double]$pet.Left + [double]$pet.Width / 2
  $stackTop = [double]$pet.Top
  foreach ($r in $avoid) { if ([double]$r[1] -lt $stackTop) { $stackTop = [double]$r[1] } }

  $midX = ($waL + $waR) / 2
  if ($petCx -ge $midX) { $sideA = [double]$pet.Left - $w - 10 } else { $sideA = $petRight + 10 }
  if ($petCx -ge $midX) { $sideB = $petRight + 10 } else { $sideB = [double]$pet.Left - $w - 10 }
  $sideTop = $petBottom - $h
  $aboveTop = $stackTop - $h - 8

  $cands = New-Object System.Collections.ArrayList
  # 1) 整摞气泡上方（最自然） 2) 形象左侧 3) 形象右侧 4) 兜底
  [void]$cands.Add(@(($petRight - $w), $aboveTop))
  [void]$cands.Add(@($sideA, $sideTop))
  [void]$cands.Add(@($sideB, $sideTop))
  [void]$cands.Add(@(($waR - $w), $waT))

  $chosenX = $waR - $w
  $chosenY = $waT
  foreach ($c in $cands) {
    $l = [double]$c[0]
    $t = [double]$c[1]
    if ($l -lt $waL) { $l = $waL }
    if (($l + $w) -gt $waR) { $l = $waR - $w }
    if ($t -lt $waT) { $t = $waT }
    if (($t + $h) -gt $waB) { $t = $waB - $h }
    $bad = $false
    foreach ($r in $avoid) {
      if (Test-RectOverlap $l $t $w $h ([double]$r[0]) ([double]$r[1]) ([double]$r[2]) ([double]$r[3])) { $bad = $true; break }
    }
    if (-not $bad) { $chosenX = $l; $chosenY = $t; break }
  }
  $panel.Left = $chosenX
  $panel.Top = $chosenY
}

function Save-Position {
  try {
    $o = [pscustomobject]@{ left = [double]$pet.Left; top = [double]$pet.Top }
    $o | ConvertTo-Json -Compress | Set-Content -LiteralPath $script:WinFile -Encoding UTF8
  } catch { }
}

function Load-Position {
  if (Test-Path $script:WinFile) {
    try {
      $o = (Get-Content -LiteralPath $script:WinFile -Raw -Encoding UTF8) | ConvertFrom-Json
      $wa = Get-WorkArea
      $l = [double]$o.left; $tp = [double]$o.top
      $ins = Get-PetInsets
      if ($l -lt $wa.Left - $ins.Left) { $l = $wa.Left - $ins.Left + 8 }
      if ($tp -lt $wa.Top - $ins.Top) { $tp = $wa.Top - $ins.Top + 8 }
      if ($l + $pet.Width -gt $wa.Right + $ins.Right) { $l = $wa.Right - $pet.Width + $ins.Right - 8 }
      if ($tp + $pet.Height -gt $wa.Bottom + $ins.Bottom) { $tp = $wa.Bottom - $pet.Height + $ins.Bottom }
      $pet.Left = $l; $pet.Top = $tp
      return
    } catch { }
  }
  $wa = Get-WorkArea
  $pet.Left = $wa.Right - $pet.Width - 24
  $pet.Top  = $wa.Bottom - $pet.Height - 24
}

function Restart-WidgetLater([int]$Milliseconds = 0) {
  # Settings that need a rebuilt UI (language): flag the relaunch, start it right away,
  # then quit — the new instance waits for this one's lock instead of sleeping here.
  try {
    $flag = Join-Path $script:Root '_restart.flag'
    [System.IO.File]::WriteAllText($flag, ('{0:o}' -f (Get-Date)), (New-Object System.Text.UTF8Encoding($false)))
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($Milliseconds -gt 0) {
      $psi.FileName = (Join-Path $env:WINDIR 'System32\cmd.exe')
      $psi.Arguments = '/c ping -n ' + [Math]::Ceiling($Milliseconds / 1000.0) + ' -w ' + $Milliseconds + ' 127.0.0.1 >nul & "' + (Join-Path $env:WINDIR 'System32\wscript.exe') + '" "' + $script:Launcher + '"'
      $psi.UseShellExecute = $false
      $psi.CreateNoWindow = $true
    } else {
      # ShellExecute gives the new instance its own handles: the old process can exit at once
      # and whoever started us never waits on an inherited stdout pipe.
      $psi.FileName = (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe')
      $psi.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
      $psi.WorkingDirectory = $script:Root
      $psi.UseShellExecute = $true
      $psi.WindowStyle = 'Hidden'
    }
    Remove-Item $script:ReadyFlag -Force -ErrorAction SilentlyContinue
    [void][System.Diagnostics.Process]::Start($psi)
    BootLog ('restart: relaunch requested (' + $Milliseconds + 'ms)')
    # Keep this window visible until the new instance has painted.
    $handoffDeadline = [DateTime]::UtcNow.AddMilliseconds(2500)
    while (-not (Test-Path $script:ReadyFlag)) {
      if ([DateTime]::UtcNow -ge $handoffDeadline) { break }
      Start-Sleep -Milliseconds 30
    }
    Remove-Item $script:ReadyFlag -Force -ErrorAction SilentlyContinue
  } catch { BootLog ('restart: failed ' + $_.Exception.Message) }
  try { Save-Position } catch { }
  $script:Quitting = $true
  try { $panel.Close() } catch { }
  try { $pet.Close() } catch { }
  [System.Windows.Application]::Current.Shutdown()
}

function Toggle-Panel {
  $script:PanelOpen = -not $script:PanelOpen
  if ($script:PanelOpen) {
    Place-Panel
    Update-Ui
    $panel.Show()
  } else {
    $panel.Hide()
  }
}

# ---------- animation ----------
$script:AnimPhase = 0.0
$script:HopT = 0.0
$script:HopDur = 0.46
# 慢眨眼替代动作：眼神缓慢下沉再抬起（不靠立绘，纯位移+缩放）
$script:GazeT = 0.0
$script:GazeDur = 2.4
$script:GazeWait = 5.5

$script:FacingX = 1

function Update-PetFacing {
  # 形象朝哪边：主屏右半边保持原样，左半边整体左右镜像（以形象中心判断，跨屏时按所在屏幕算）
  try {
    $cx = $pet.Left + $pet.Width / 2
    $cy = $pet.Top + $pet.Height / 2
    $scr = [System.Windows.Forms.Screen]::FromPoint((New-Object System.Drawing.Point([int]$cx, [int]$cy)))
    if (-not $scr) { $scr = [System.Windows.Forms.Screen]::PrimaryScreen }
    $wa = $scr.WorkingArea
    $want = if ($cx -lt ($wa.Left + $wa.Width / 2.0)) { -1 } else { 1 }
    if ($want -ne $script:FacingX) {
      $script:FacingX = $want
      BootLog ("facing: mirror=" + ($want -lt 0) + " x=" + [int]$cx)
      Set-PetTransform
    }
  } catch { }
}

function Set-PetTransform {
  # 呼吸/摇摆都以下盘（脚的着地点）为支点：只做缩放和微角度，不上下位移，
  # 否则整只画会被“抬起来”，看着像腾空。
  # 呼吸：竖直方向拉伸/回缩，横向反向微缩，下盘钉住不动，看起来像在吸气呼气。
  $w = [Math]::Sin($script:AnimPhase * 0.78)
  $breathY = 1.0 + ($w * 0.045)
  $breathX = 1.0 - ($w * 0.020)
  # 轻微的重心侧摆，幅度很小，避免“腾空”的观感
  $tilt = [Math]::Sin($script:AnimPhase * 0.37) * 1.4
  $sx = $breathX
  $sy = $breathY
  # 吸气时整体极轻微上提，就像胸腔鼓起；只有 0.7px，不会跳起来
  $shift = -0.7 * [Math]::Max(0.0, $w)
  $rot = $tilt
  if ($script:HopT -gt 0) {
    # 轻快的弹跳：位移与缩放都走正弦，起落都有缓冲，不再是硬跳。
    $p = 1.0 - ($script:HopT / $script:HopDur)
    if ($p -lt 0) { $p = 0.0 }
    if ($p -gt 1) { $p = 1.0 }
    $s = [Math]::Sin([Math]::PI * $p)
    $shift = -6.0 * $s
    $sy = $breathY * (1.0 + 0.055 * $s)
    $sx = $breathX * (1.0 - 0.04 * $s)
    $rot = $tilt + 2.4 * [Math]::Sin(2.0 * [Math]::PI * $p)
  }
  if ($script:GazeT -gt 0) {
    # 0 -> 1 -> 0 的缓慢呼吸式“垂眼”：只下沉 2.2px、纵向缩放 0.6%、侧倾 0.5°
    $g = 1.0 - ($script:GazeT / $script:GazeDur)
    if ($g -lt 0) { $g = 0.0 }
    if ($g -gt 1) { $g = 1.0 }
    $gs = [Math]::Sin([Math]::PI * $g)
    $shift = $shift + (3.5 * $gs)
    $sy = $sy * (1.0 - 0.030 * $gs)
    $rot = $rot - 1.2 * $gs
  }
  $script:PetScale.ScaleX = $sx * $script:FacingX
  $script:PetScale.ScaleY = $sy
  $script:PetRotate.Angle = $rot
  $script:PetShift.Y = $shift
  # 叠层跟着一起动，否则眨眼时会和本体错位
  $script:PetGScale.ScaleX = $sx * $script:FacingX
  $script:PetGScale.ScaleY = $sy
  $script:PetGRotate.Angle = $rot
  $script:PetGShift.Y = $shift
}

function Start-Anim {
  if ($script:AnimTimer) { return }
  $script:AnimTimer = New-Object System.Windows.Threading.DispatcherTimer
  $script:AnimTimer.Interval = [TimeSpan]::FromMilliseconds(33)
  $script:AnimTimer.Add_Tick({
    $script:AnimPhase += 0.055
    if ($script:HopT -gt 0) {
      $script:HopT = $script:HopT - 0.033
      if ($script:HopT -lt 0) { $script:HopT = 0.0 }
    }
    if ($script:GazeT -gt 0) {
      $script:GazeT = $script:GazeT - 0.033
      if ($script:GazeT -lt 0) {
        $script:GazeT = 0.0
        $script:GazeWait = 5.5 + (Get-Random -Minimum 0 -Maximum 40) / 10.0
      }
    } else {
      $script:GazeWait = $script:GazeWait - 0.033
      if ($script:GazeWait -le 0) { $script:GazeT = $script:GazeDur }
    }
    Set-PetTransform
  })
  $script:AnimTimer.Start()
  # 眨眼：闭眼帧由 AI 生成后逐脸对齐（*-blink-ai.png），只换眼部区域
  # 眨眼已按用户要求停用（2026-10-26）：没有作者原生闭眼立绘，合成帧都会多一条上睫毛线。
$script:BlinkEnabled = $false
  if ($script:BlinkEnabled) {
    $script:BlinkScheduler = New-Object System.Windows.Threading.DispatcherTimer
    $script:BlinkScheduler.Interval = [TimeSpan]::FromMilliseconds(6200)
    $script:BlinkScheduler.Add_Tick({
      $script:BlinkScheduler.Interval = [TimeSpan]::FromMilliseconds((Get-Random -Minimum 5200 -Maximum 10500))
      Start-Blink
    })
    $script:BlinkScheduler.Start()
  }
}

function Stop-Blink {
  if ($script:BlinkTimer) { $script:BlinkTimer.Stop(); $script:BlinkTimer = $null }
  $script:BlinkOn = $false
  $script:BlinkStep = 0
  Blink $null
}

function Blink($tag) {
  # tag: 'p1'..'p6' 表示闭眼推进（1=刚闭一点，6=全闭），$null 表示睁眼
  if (-not $script:CurFaceFile) { return }
  if ($tag) {
    $bp = Join-Path $script:Assets ($script:CurFaceFile -replace '\.png$', ('-blink-' + $tag + '.png'))
  } else {
    $bp = Join-Path $script:Assets $script:CurFaceFile
  }
  if (Test-Path -LiteralPath $bp) { Set-ImageSource $script:PetImg $bp }
}

function Start-Blink {
  # 两帧眨眼：直接换成“作者闭眼帧”，停 0.34s（偶尔 0.50s）再睁开。
  # 因为闭眼帧和睁眼帧共用同一张脸、同一次对齐，换帧时不会出现“多出一双眼睛”。
  if ($script:BlinkOn) { return }
  if (-not $script:CurFaceFile) { return }
  $bp = Join-Path $script:Assets ($script:CurFaceFile -replace '\.png$', '-blink-ai.png')
  if (-not (Test-Path -LiteralPath $bp)) { return }
  $script:BlinkOn = $true
  Set-ImageSource $script:PetImg $bp
  $hold = 340
  if ((Get-Random -Maximum 100) -lt 28) { $hold = 500 }
  if ($script:BlinkTimer) { $script:BlinkTimer.Stop() }
  $script:BlinkTimer = New-Object System.Windows.Threading.DispatcherTimer
  $script:BlinkTimer.Interval = [TimeSpan]::FromMilliseconds($hold)
  $script:BlinkTimer.Add_Tick({
    $script:BlinkTimer.Stop()
    $script:BlinkTimer = $null
    $script:BlinkOn = $false
    Blink $null
  })
  $script:BlinkTimer.Start()
}

function Hop {
  # 连续点击不重复触发，等这一下弹完再允许下一次。
  if ($script:HopT -gt 0) { return }
  $script:HopT = $script:HopDur
}

# ---------- speech bubble ----------
function Set-BubbleText($text) {
  $script:BubText.Text = [string]$text
  if (-not $script:Bubble.IsVisible) { return }
  $script:Bubble.UpdateLayout()
  Place-Bubble
}

$script:BubbleGlideTimer = $null
$script:BubbleGlideFrom = $null
$script:BubbleGlideTo = $null
$script:BubbleGlideStep = 0

function Stop-BubbleGlide {
  if ($script:BubbleGlideTimer) {
    $script:BubbleGlideTimer.Stop()
    $script:BubbleGlideTimer = $null
  }
}

function Start-BubbleGlide($fromX, $fromY, $toX, $toY) {
  # 输入条收起/展开时，气泡在两个位置之间滑动，别瞬间跳上去或吊在半空
  if (-not $script:Bubble.IsVisible) { return }
  if ($script:BubbleGlideTimer) { $script:BubbleGlideTimer.Stop() }
  $script:BubbleGlideFrom = @([double]$fromX, [double]$fromY)
  $script:BubbleGlideTo = @([double]$toX, [double]$toY)
  $script:BubbleGlideStep = 0
  $script:Bubble.Left = $fromX
  $script:Bubble.Top = $fromY
  $t = New-Object System.Windows.Threading.DispatcherTimer
  $t.Interval = [TimeSpan]::FromMilliseconds(15)
  $t.Add_Tick({
    if (-not $script:BubbleGlideTimer) { return }
    $script:BubbleGlideStep = $script:BubbleGlideStep + 1
    $n = 16
    $p = [Math]::Min(1.0, $script:BubbleGlideStep / [double]$n)
    $e = 1.0 - [Math]::Pow(1.0 - $p, 3.0)      # cubic ease-out
    $fx = $script:BubbleGlideFrom[0]; $fy = $script:BubbleGlideFrom[1]
    $tx = $script:BubbleGlideTo[0];   $ty = $script:BubbleGlideTo[1]
    $script:Bubble.Left = $fx + ($tx - $fx) * $e
    $script:Bubble.Top  = $fy + ($ty - $fy) * $e
    if ($p -ge 1.0) {
      $script:BubbleGlideTimer.Stop()
      $script:BubbleGlideTimer = $null
      $script:Bubble.Left = $tx
      $script:Bubble.Top  = $ty
    }
  })
  $script:BubbleGlideTimer = $t
  $t.Start()
}

function Place-Stacks {
  # 布局约定：输入条永远贴在形象头顶（打开时位置固定，不随气泡跳动）；
  # 回复气泡叠在输入条上方；输入条收起时，气泡直接贴回形象头顶。
  $wa = Get-WorkArea
  $petRight = $pet.Left + $pet.Width
  $cursor = $pet.Top - 8
  if ($script:ChatOpen) {
    $script:Chat.UpdateLayout()
    $cw = if ($script:Chat.ActualWidth -gt 0) { $script:Chat.ActualWidth } else { 272 }
    $ch = if ($script:Chat.ActualHeight -gt 0) { $script:Chat.ActualHeight } else { 46 }
    $cx2 = $petRight - $cw
    $cy2 = $cursor - $ch
    if ($cx2 -lt $wa.Left + 4) { $cx2 = $wa.Left + 4 }
    if ($cx2 + $cw -gt $wa.Right - 4) { $cx2 = $wa.Right - $cw - 4 }
    if ($cy2 -lt $wa.Top + 4) { $cy2 = $pet.Top + $pet.Height - 2 }
    $script:Chat.Left = $cx2
    $script:Chat.Top = $cy2
    $cursor = $cy2 - 6
  }
  if ($script:Bubble.IsVisible) {
    $script:Bubble.UpdateLayout()
    $bw = if ($script:Bubble.ActualWidth -gt 0) { $script:Bubble.ActualWidth } else { 272 }
    $bh = if ($script:Bubble.ActualHeight -gt 0) { $script:Bubble.ActualHeight } else { 60 }
    $bx = $petRight - $bw
    $by = $cursor - $bh
    if ($bx -lt $wa.Left + 4) { $bx = $wa.Left + 4 }
    if ($bx + $bw -gt $wa.Right - 4) { $bx = $wa.Right - $bw - 4 }
    if ($by -lt $wa.Top + 4) { $by = $pet.Top + $pet.Height + 4 }
    $script:Bubble.Left = $bx
    $script:Bubble.Top = $by
  }
  if ($script:PanelOpen) { Place-Panel }
}

function Place-Bubble { Place-Stacks }

function Fit-Status {
  # 窗口默认会留一圈空白：按内容精确测量后显式设宽高，气泡框才贴合文字。
  $card = $script:StatusCard
  $card.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
  $d = $card.DesiredSize
  $w = [Math]::Ceiling($d.Width) + 1
  $h = [Math]::Ceiling($d.Height) + 1
  if ($w -gt 40 -and $h -gt 12) {
    if ([Math]::Abs($script:Status.Width - $w) -gt 0.6) { $script:Status.Width = $w }
    if ([Math]::Abs($script:Status.Height - $h) -gt 0.6) { $script:Status.Height = $h }
  }
}

function Place-Status {
  if (-not $script:Status.IsVisible) { return }
  $script:Status.UpdateLayout()
  $wa = Get-WorkArea
  $w = if ($script:Status.ActualWidth -gt 0) { $script:Status.ActualWidth } else { 90 }
  $h = if ($script:Status.ActualHeight -gt 0) { $script:Status.ActualHeight } else { 24 }
  $left = $pet.Left - $w - 8
  if ($left -lt $wa.Left + 4) { $left = $pet.Left + $pet.Width + 8 }
  $top = $pet.Top + (($pet.Height - $h) / 2)
  if ($top -lt $wa.Top + 4) { $top = $wa.Top + 4 }
  $script:Status.Left = $left
  $script:Status.Top = $top
}

function Start-LeaveTimer {
  if ($script:LeaveTimer) { $script:LeaveTimer.Stop() }
  $script:LeaveTimer = New-Object System.Windows.Threading.DispatcherTimer
  $script:LeaveTimer.Interval = [TimeSpan]::FromMilliseconds(550)
  $script:LeaveTimer.Add_Tick({
    $script:LeaveTimer.Stop()
    if (-not $script:ChatOpen) { return }
    if ($script:NoAutoClose) { return }
    if ($pet.IsMouseOver) { return }
    if ($script:Chat.IsMouseOver) { return }
    # 正在打字（输入框有焦点或有内容）时不要收起，否则输入会被打断
    if ($script:Chat.IsKeyboardFocusWithin) { return }
    if ($script:ChatInput.Text -and $script:ChatInput.Text.Trim().Length -gt 0) { return }
    if ($script:ReplyTimer -and $script:ReplyTimer.IsEnabled) { return }
    Toggle-Chat
  })
  $script:LeaveTimer.Start()
}

function Hide-BubbleLater($seconds) {
  if ($script:BubbleTimer) { $script:BubbleTimer.Stop() }
  $script:BubbleTimer = New-Object System.Windows.Threading.DispatcherTimer
  $script:BubbleTimer.Interval = [TimeSpan]::FromSeconds($seconds)
  $script:BubbleTimer.Add_Tick({
    $script:BubbleTimer.Stop()
    $script:BubbleTimer = $null
    BootLog 'bubble: hide (timer)'
    $script:Bubble.Hide()
    Place-Stacks
  })
  $script:BubbleTimer.Start()
}

function Show-Bubble($text, $seconds = -1) {
  if ($seconds -lt 0) { $seconds = [int]$script:Settings.bubbleSeconds }
  if (-not $text) { return }
  # A reply from the previous turn may still have a hide timer armed; drop it.
  if ($script:BubbleTimer) { $script:BubbleTimer.Stop(); $script:BubbleTimer = $null }
  $script:BubText.Text = [string]$text
  if (-not $script:Bubble.IsVisible) { $script:Bubble.Show() }
  BootLog 'bubble: show'
  $script:Bubble.UpdateLayout()
  Place-Bubble
  if ($seconds -gt 0) { Hide-BubbleLater $seconds }
}

# ---------- chat ----------
$script:Lines = @{
  idle  = @('嗯？','在看什么呢','要不要休息一下','我在这儿呢','（晃了晃脑袋）')
  morning   = @('早安呀','今天也要好好过','早餐吃了吗','开工啦')
  noon      = @('该吃饭了吧','午休一下？','不要饿着自己')
  afternoon = @('下午也要加油','喝点水吧','休息一下眼睛')
  evening   = @('晚上好呀','今天辛苦了','忙完就歇歇吧')
  night     = @('晚上了，别太辛苦','还在忙吗','快去睡觉吧')
  late      = @('这么晚了还不睡？','敷着着就睡吧','熬夜会变丑的')
  happy = @('今天心情不错呀','陪我聊两句？','嘿嘿')
  low   = @('你还好吗','有点累的样子','喝点水吧')
  sleepy = @('好困…眼睛要睁不开了','让我靠一会儿…','（打了个小哈欠）','困到说不出话了…')
  clingy = @('你又半天不理我了','在干嘛呀，看看我嘛','我就赖在你桌面上了','点点我嘛')
}
if ($script:Lang -eq 'en') {
  $script:Lines = @{
    idle   = @('Hm?', 'What are you looking at?', 'Shall we take a break?', 'I am right here', '(tilts her head)')
    morning   = @('Good morning~', 'Morning! Coffee yet?', 'Let us have a good day')
    noon      = @('Lunch time?', 'Take a nap?', 'Do not skip lunch')
    afternoon = @('Keep it up this afternoon', 'Drink some water', 'Rest your eyes for a bit')
    evening   = @('Good evening', 'Long day, huh', 'Take it easy tonight')
    night     = @('It is evening already', 'Still busy?', 'Go to bed soon')
    late      = @('Why are you still up?', 'Sleep already', 'Staying up late is bad for you')
    happy  = @('Feeling good today~', 'Talk to me for a while?', 'Hehe')
    low    = @('Are you okay?', 'You look a bit tired', 'Have some water')
    sleepy = @('So sleepy… my eyes are closing', 'Let me lean on you for a bit…', '(small yawn)', 'Too sleepy to talk…')
    clingy = @('You ignored me for ages', 'What are you doing? Look at me', 'I am staying on your desktop', 'Poke me already')
  }
}


function Get-MoodSnapshot {
  $mood = 0; $reason = ''
  $dims = @{}
  try {
    if (Test-Path $script:StateFile) {
      $s = Get-Content -LiteralPath $script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
      $key = if ($s.key) { [string]$s.key } else { '__default__' }
      $m = $s.moods.$key
      if ($m) {
        $mood = [int]$m.mood
        $reason = if ($m.reason) { [string]$m.reason } else { '' }
        if ($m.dims) { foreach ($p in $m.dims.PSObject.Properties) { $dims[$p.Name] = [int]$p.Value } }
      }
    }
  } catch { }
  return @{ mood = $mood; reason = $reason; dims = $dims }
}

function Read-BridgeAlive {
  $alive = Join-Path $script:BridgeDir 'alive.json'
  try {
    if (-not (Test-Path $alive)) { return $null }
    $j = Get-Content -LiteralPath $alive -Raw -Encoding UTF8 | ConvertFrom-Json
    $ts = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$j.ts).ToLocalTime()
    return @{ age = ((Get-Date) - $ts.DateTime).TotalSeconds; pid = $j.pid }
  } catch { return $null }
}

# 长期情绪（亲密度 / 精力 / 愉悦 / 关系 / 记忆）由桥插件写 emotion.json，挂件只读。
function Get-Emotion {
  $e = @{ valence = 0; energy = 100; affection = 0; trust = 0; relation = 'stranger'; memories = @(); updatedAt = 0 }
  try {
    $file = Join-Path $script:BridgeDir 'emotion.json'
    if (Test-Path $file) {
      $j = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($j.valence -ne $null) { $e.valence = [double]$j.valence }
      if ($j.energy -ne $null) { $e.energy = [double]$j.energy }
      if ($j.affection -ne $null) { $e.affection = [double]$j.affection }
      if ($j.trust -ne $null) { $e.trust = [double]$j.trust }
      if ($j.relation) { $e.relation = [string]$j.relation }
      if ($j.memories) { $e.memories = @($j.memories) }
      if ($j.updatedAt) { $e.updatedAt = [int64]$j.updatedAt }
    }
  } catch { }
  return $e
}

function Get-RelationLabel($rel) {
  switch ([string]$rel) {
    'stranger' { return (L '还不太熟') }
    'familiar' { return (L '渐渐熟了') }
    'close' { return (L '很亲近') }
    'clingy' { return (L '黏着你') }
    default { return (L '还不太熟') }
  }
}

function Place-Chat { Place-Stacks }

function Toggle-Chat {
  BootLog ('toggle-chat open=' + $script:ChatOpen)
  Stop-BubbleGlide
  $oldX = $script:Bubble.Left
  $oldY = $script:Bubble.Top
  $hadBubble = $script:Bubble.IsVisible
  if ($script:ChatOpen) {
    $script:Chat.Hide()
    $script:ChatOpen = $false
    Place-Stacks
    # 收起输入条后，气泡从原来吊在半空的位置落回她头顶
    if ($hadBubble) { Start-BubbleGlide $oldX $oldY $script:Bubble.Left $script:Bubble.Top }
    return
  }
  $script:ChatOpen = $true
  $script:Chat.Show()
  Place-Stacks
  if ($hadBubble) { Start-BubbleGlide $oldX $oldY $script:Bubble.Left $script:Bubble.Top }
  $script:ChatInput.Focus() | Out-Null
}

function Send-Chat {
  $text = $script:ChatInput.Text.Trim()
  if (-not $text) { return }
  $script:ChatInput.Text = ''
  $snap = Get-MoodSnapshot
  $id = 'w' + [DateTime]::UtcNow.Ticks.ToString()
  $script:ReplyId = $id
  $req = [ordered]@{
    id = $id; text = $text; mood = $snap.mood; dims = $snap.dims; reason = $snap.reason; lang = $script:Lang
  }
  try {
    New-Item -ItemType Directory -Force -Path (Join-Path $script:BridgeDir 'inbox') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $script:BridgeDir 'outbox') | Out-Null
    $json = $req | ConvertTo-Json -Depth 5 -Compress
    [System.IO.File]::WriteAllText((Join-Path $script:BridgeDir ('inbox\' + $id + '.json')), $json, (New-Object System.Text.UTF8Encoding($false)))
  } catch {
    Show-Bubble ((L '写不进聊天通道：') + $_.Exception.Message) 8
    return
  }
  $alive = Read-BridgeAlive
  if (-not $alive -or $alive.age -gt 10) {
    Show-Bubble (L '……（DSH 好像没在后台跑，我收不到消息）') 7
    return
  }
  Show-Bubble '…' 0
  $script:FaceLockUntil = [DateTime]::UtcNow.AddMilliseconds(1200)
  $script:CurFaceFile = 'face-great.png'
  Set-ImageSource $script:PetImg (Join-Path $script:Assets 'face-great.png')
  Wait-Reply $id
}

function Wait-Reply($id) {
  if ($script:ReplyTimer) { $script:ReplyTimer.Stop() }
  $script:ReplyTicks = 0
  $file = Join-Path $script:BridgeDir ('outbox\' + $id + '.json')
  $script:ReplyTimer = New-Object System.Windows.Threading.DispatcherTimer
  $script:ReplyTimer.Interval = [TimeSpan]::FromMilliseconds(220)
  $script:ReplyTimer.Add_Tick({
    $script:ReplyTicks++
    $file = Join-Path $script:BridgeDir ('outbox\' + $script:ReplyId + '.json')
    if (Test-Path $file) {
      $j = $null
      try { $j = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
      if ($j) {
        $txt = if ($j.text) { [string]$j.text } else { '' }
        if ($txt) {
          if ($txt -ne $script:BubText.Text) {
            $script:FaceLockUntil = [DateTime]::UtcNow.AddMilliseconds(9000)
            $script:CurFaceFile = 'face-good.png'
            Set-ImageSource $script:PetImg (Join-Path $script:Assets 'face-good.png')
            $script:BubText.Text = $txt
            if (-not $script:Bubble.IsVisible) {
              $script:Bubble.Show()
              BootLog 'bubble: restored while streaming'
            }
            $script:Bubble.UpdateLayout()
            Place-Bubble
          }
        }
        if ($j.done) {
          $script:ReplyTimer.Stop()
          $script:FaceLockUntil = [DateTime]::UtcNow.AddMilliseconds(2200)
          Update-Ui
          if (-not $txt -and $j.error) { Show-Bubble ((L '没连上模型（') + $j.error + ')') 8 }
          elseif ($txt) { Show-Bubble $txt 18 }
          else { Show-Bubble (L '……（她没说话）') 6 }
        }
      }
    } elseif ($script:ReplyTicks -gt 90) {
      $script:ReplyTimer.Stop()
      Update-Ui
      Show-Bubble (L '……（没等到回复，DSH 可能刚关掉）') 8
    }
  })
  $script:ReplyTimer.Start()
}

function Get-TimeBagKey {
  $h = (Get-Date).Hour
  if ($h -ge 5 -and $h -lt 9)  { return 'morning' }
  if ($h -ge 9 -and $h -lt 12) { return 'morning' }
  if ($h -ge 12 -and $h -lt 14) { return 'noon' }
  if ($h -ge 14 -and $h -lt 18) { return 'afternoon' }
  if ($h -ge 18 -and $h -lt 22) { return 'evening' }
  if ($h -ge 22 -or $h -lt 2)  { return 'night' }
  return 'late'
}

function Read-LastChatGapMinutes {
  # 上次聊天到现在过了多久（分钟）；没聊过或读不到返回 -1
  try {
    $f = Join-Path $script:BridgeDir 'memory.json'
    if (-not (Test-Path $f)) { return -1 }
    $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
    $turns = @($j.turns)
    if ($turns.Count -eq 0) { return -1 }
    $last = [int64]$turns[$turns.Count - 1].at
    if ($last -le 0) { return -1 }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    return [int](($now - $last) / 60000)
  } catch { return -1 }
}

function Get-GreetingLine {
  $h = (Get-Date).Hour
  $gap = Read-LastChatGapMinutes
  $en = ($script:Lang -eq 'en')
  $zhText = ''
  $enText = ''
  if ($h -ge 23 -or $h -lt 5) {
    $zhText = '这么晚了还没睡？'
    $enText = 'You are still up? It is so late'
  } elseif ($h -lt 9) {
    $zhText = '早安呀'
    $enText = 'Good morning~'
  } elseif ($h -ge 11 -and $h -lt 14) {
    $zhText = '吃饭了吗？'
    $enText = 'Have you had lunch?'
  } elseif ($h -ge 18 -and $h -lt 23) {
    $zhText = '晚上好呀'
    $enText = 'Good evening'
  } elseif ($gap -ge 720) {
    $zhText = '好久不见了，你去哪了呀'
    $enText = 'It has been ages! Where were you?'
  } elseif ($gap -ge 60) {
    $zhText = '你回来啦'
    $enText = 'You are back~'
  } else {
    $zhText = '我在这儿呢'
    $enText = 'Hey, I am here'
  }
  if ($en) { return $enText }
  return $zhText
}

function Say-GreetingOnStart {
  if ($Say -or $TestShot -or $Render) { return }
  $gap = Read-LastChatGapMinutes
  if ($GreetNow) { $gap = 999 }
  # 刚聊完就不打招呼；超过 45 分钟没见才开口
  if ($gap -ge 0 -and $gap -lt 45) { return }
  if ($gap -lt 0 -and $script:Lines -eq $null) { return }
  $script:GreetTimer = New-Object System.Windows.Threading.DispatcherTimer
  $script:GreetTimer.Interval = [TimeSpan]::FromMilliseconds(2600)
  $script:GreetTimer.Add_Tick({
    $script:GreetTimer.Stop()
    $line = Get-GreetingLine
    BootLog ('greeting: ' + $line + ' gapMin=' + (Read-LastChatGapMinutes))
    Show-Bubble $line 6
  })
  $script:GreetTimer.Start()
}

function Say-IdleLine {
  $snap = Get-MoodSnapshot
  $emo = Get-Emotion
  $bag = if ($snap.mood -ge 70) { $script:Lines.happy } elseif ($snap.mood -gt 0 -and $snap.mood -lt 45) { $script:Lines.low } else { $script:Lines[(Get-TimeBagKey)] }
  if (-not $bag) { $bag = $script:Lines.idle }
  # 情绪状态优先：困、黏人、闹小别扭各有各的说法
  if ($emo.updatedAt -gt 0) {
    if ($emo.energy -lt 22) { $bag = $script:Lines.sleepy }
    elseif ($emo.relation -eq 'clingy') { $bag = $script:Lines.clingy }
    elseif ($emo.valence -lt -30) { $bag = $script:Lines.low }
  }
  $line = $bag | Get-Random
  Hop
  Show-Bubble $line 5
}


# ---------- edge snapping ----------
function Get-SnapTarget {
  # 拖到屏幕（工作区）边缘附近就吸附过去；同时保证不跑到工作区外面。
  $wa = [System.Windows.SystemParameters]::WorkArea
  $w = if ($pet.ActualWidth -gt 0) { $pet.ActualWidth } else { $pet.Width }
  $h = if ($pet.ActualHeight -gt 0) { $pet.ActualHeight } else { $pet.Height }
  $ins = Get-PetInsets
  $minX = $wa.Left - $ins.Left
  $maxX = $wa.Right - $w + $ins.Right
  $minY = $wa.Top - $ins.Top
  $maxY = $wa.Bottom - $h + $ins.Bottom
  $x = [double]$pet.Left
  $y = [double]$pet.Top
  $s = 20.0
  if ([Math]::Abs($x - $minX) -lt $s) { $x = $minX }
  elseif ([Math]::Abs($x - $maxX) -lt $s) { $x = $maxX }
  if ([Math]::Abs($y - $minY) -lt $s) { $y = $minY }
  elseif ([Math]::Abs($y - $maxY) -lt $s) { $y = $maxY }
  if ($x -lt $minX) { $x = $minX }
  if ($x -gt $maxX) { $x = $maxX }
  if ($y -lt $minY) { $y = $minY }
  if ($y -gt $maxY) { $y = $maxY }
  return @($x, $y)
}

function Glide-To([double]$tx, [double]$ty) {
  # 120ms 的缓动滑行，避免“啪”一下跳过去
  if ($script:GlideTimer) { $script:GlideTimer.Stop(); $script:GlideTimer = $null }
  $sx = [double]$pet.Left
  $sy = [double]$pet.Top
  if ([Math]::Abs($sx - $tx) -lt 0.5 -and [Math]::Abs($sy - $ty) -lt 0.5) {
    $pet.Left = $tx; $pet.Top = $ty
    Place-Panel; Place-Bubble; Place-Chat; Place-Status
    return
  }
  $script:GlideStep = 0
  $script:GlideFrom = @($sx, $sy)
  $script:GlideTo = @($tx, $ty)
  $script:GlideTimer = New-Object System.Windows.Threading.DispatcherTimer
  $script:GlideTimer.Interval = [TimeSpan]::FromMilliseconds(12)
  $script:GlideTimer.Add_Tick({
    $script:GlideStep = $script:GlideStep + 1
    $t = [Math]::Min(1.0, $script:GlideStep / 10.0)
    $e = 1.0 - [Math]::Pow(1.0 - $t, 3)
    $cx = $script:GlideFrom[0] + ($script:GlideTo[0] - $script:GlideFrom[0]) * $e
    $cy = $script:GlideFrom[1] + ($script:GlideTo[1] - $script:GlideFrom[1]) * $e
    $pet.Left = $cx
    $pet.Top = $cy
    Place-Panel; Place-Bubble; Place-Chat; Place-Status
    if ($t -ge 1.0) {
      $script:GlideTimer.Stop()
      $script:GlideTimer = $null
      Save-Position
    }
  })
  $script:GlideTimer.Start()
}

function Snap-ToEdges {
  $target = Get-SnapTarget
  Glide-To $target[0] $target[1]
}


# ---------- fullscreen auto-hide ----------
function Ensure-FgWin {
  if ('FgWin' -as [type]) { return }
  if (-not ('FgWin' -as [type])) {
  Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class FgWin {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint dwFlags);
  [DllImport("user32.dll")] public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);
  [DllImport("user32.dll")] public static extern IntPtr GetDesktopWindow();
  [DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern IntPtr FindWindow(string cls, string win);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
  [DllImport("user32.dll", CharSet = CharSet.Auto)]
  public static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder lpClassName, int nMaxCount);
  public static string ClassName(IntPtr hwnd) {
    var sb = new System.Text.StringBuilder(256);
    GetClassName(hwnd, sb, 256);
    return sb.ToString();
  }
  public static bool IsFullscreen(IntPtr hwnd) {
    if (hwnd == IntPtr.Zero) return false;
    if (hwnd == GetDesktopWindow()) return false;
    RECT r;
    if (!GetWindowRect(hwnd, out r)) return false;
    IntPtr mon = MonitorFromWindow(hwnd, 2);
    MONITORINFO mi = new MONITORINFO();
    mi.cbSize = Marshal.SizeOf(mi);
    if (!GetMonitorInfo(mon, ref mi)) return false;
    RECT m = mi.rcMonitor;
    return r.Left <= m.Left + 1 && r.Top <= m.Top + 1 && r.Right >= m.Right - 1 && r.Bottom >= m.Bottom - 1;
  }
}
}
"@
}
}

$script:PetHidden = $false
$script:HideOnFullscreen = $true

function Hide-PetAll {
  if ($script:PetHidden) { return }
  $script:PetHidden = $true
  BootLog 'fullscreen: hide pet'
  try { $script:Status.Hide() } catch { }
  try { $script:Bubble.Hide() } catch { }
  try { $script:Chat.Hide() } catch { }
  try { $panel.Hide() } catch { }
  try { $pet.Hide() } catch { }
}

function Show-PetAll {
  if (-not $script:PetHidden) { return }
  $script:PetHidden = $false
  BootLog 'fullscreen: show pet'
  try { $pet.Show() } catch { }
  try { if ($script:ChatOpen) { $script:Chat.Show() } } catch { }
  try { if ($script:PanelOpen) { $panel.Show() } } catch { }
  Place-Stacks
  Place-Status
}

function Update-FullscreenGuard {
  Ensure-FgWin
  try {
    if (-not $script:HideOnFullscreen) { return }
    if ($script:SettingsWin) { return }   # never hide while her settings dialog is open
    $fg = [FgWin]::GetForegroundWindow()
    if ($fg -eq [IntPtr]::Zero) { return }
    $cls = ''
    try { $cls = [FgWin]::ClassName($fg) } catch { }
    if ($cls -eq 'Progman' -or $cls -eq 'WorkerW' -or $cls -eq 'Shell_TrayWnd' -or
        $cls -eq 'Shell_SecondaryTrayWnd' -or $cls -eq 'Windows.UI.Core.CoreWindow') {
      # desktop / taskbar / shell surface is not a fullscreen app - just bring her back
      if ($script:PetHidden) { Show-PetAll }
      return
    }
    $known = @($pet, $panel, $script:Bubble, $script:Chat, $script:Status)
    if ($script:SettingsWin) { $known += $script:SettingsWin }
    foreach ($w in $known) {
      if ($null -eq $w) { continue }
      try {
        if ([System.Windows.Interop.WindowInteropHelper]::new($w).Handle -eq $fg) {
          if ($script:PetHidden) { Show-PetAll }
          return
        }
      } catch { }
    }
    if ([FgWin]::IsFullscreen($fg)) {
      if (-not $script:PetHidden) { Hide-PetAll }
    } elseif ($script:PetHidden) {
      Show-PetAll
    }
  } catch { }
}


# 用 按下/移动/抬起 三段判断：只有真的拖动了才进 DragMove，否则当成一次点击。
$script:DragStart = $null
$script:DidDrag = $false

$script:PetImg.Add_MouseLeftButtonDown({
  $script:DragStart = [System.Windows.Input.Mouse]::GetPosition($pet)
  $script:DidDrag = $false
})

$script:PetImg.Add_MouseMove({
  if (-not $script:DragStart) { return }
  if ($_.LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed) { return }
  if ($script:DidDrag) { return }
  $now = [System.Windows.Input.Mouse]::GetPosition($pet)
  $dx = [Math]::Abs($now.X - $script:DragStart.X)
  $dy = [Math]::Abs($now.Y - $script:DragStart.Y)
  if ($dx -gt 4 -or $dy -gt 4) {
    $script:DidDrag = $true
    try { $pet.DragMove() } catch { BootLog ('dragmove fail: ' + $_.Exception.Message) }
    Snap-ToEdges
    if (-not $script:GlideTimer) {
      Save-Position
      Place-Panel
      Place-Bubble
      Place-Chat
    }
  }
})

$script:PetImg.Add_MouseLeftButtonUp({
  $started = $script:DragStart
  $script:DragStart = $null
  if (-not $started) { return }
  if ($script:DidDrag) { return }
  BootLog ('click cc=' + $_.ClickCount)
  if ($_.ClickCount -ge 2) {
    Hop
    Say-IdleLine
  } else {
    Hop
    if ($script:ChatOpen) {
      try { $script:Chat.Activate() } catch { }
      $script:ChatInput.Focus() | Out-Null
    } else {
      Toggle-Chat
    }
  }
})
# 鼠标悬停：心情状态条浮在桌宠左侧（独立窗口，不占布局、不推动形象）
$pet.Add_MouseEnter({
  Update-Ui
  $script:Status.Show()
  $script:Status.UpdateLayout()
  Place-Status
})
$pet.Add_MouseLeave({
  $script:Status.Hide()
  if ($script:ChatOpen) { Start-LeaveTimer }
})
# 鼠标离开桌宠、也不在输入条上，就自动收起聊天框
$script:Chat.Add_MouseEnter({ if ($script:LeaveTimer) { $script:LeaveTimer.Stop() } })
$script:Chat.Add_MouseLeave({ if ($script:ChatOpen) { Start-LeaveTimer } })
# 每次输入/获得焦点都取消收起计时，避免“打了几个字母就关掉”
$script:ChatInput.Add_TextChanged({ if ($script:LeaveTimer) { $script:LeaveTimer.Stop() } })
$script:ChatInput.Add_GotKeyboardFocus({ if ($script:LeaveTimer) { $script:LeaveTimer.Stop() } })
# 焦点离开输入框（点了别处）且没有内容时，才允许收起
$script:ChatInput.Add_LostKeyboardFocus({ if ($script:ChatOpen) { Start-LeaveTimer } })

$script:ChatSend.Add_Click({ Send-Chat })
$script:ChatClose.Add_Click({ Toggle-Chat })
$script:ChatInput.Add_KeyDown({
  if ($_.Key -eq [System.Windows.Input.Key]::Enter) {
    Send-Chat
    $_.Handled = $true
  } elseif ($_.Key -eq [System.Windows.Input.Key]::Escape) {
    Toggle-Chat
    $_.Handled = $true
  }
})

$pet.Add_LocationChanged({ Place-Panel; Place-Bubble; Place-Chat; Update-PetFacing })

$settingsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="她的设置" Width="396" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" Topmost="True" ResizeMode="NoResize">
  <Border Background="#F01B1C1F" BorderBrush="#59FFFFFF" BorderThickness="1" CornerRadius="14" Padding="18,15">
    <StackPanel>
      <TextBlock Text="她的设置" FontFamily="Microsoft YaHei" FontSize="15" FontWeight="SemiBold" Foreground="#F2F3F5"/>
      <TextBlock Text="只影响桌面上的小鱼；DSH 那边不受影响。" FontFamily="Microsoft YaHei" FontSize="10.5" Foreground="#8FA6C8" Margin="0,3,0,10"/>

      <CheckBox x:Name="OptMemory" FontFamily="Microsoft YaHei" FontSize="12.5" Foreground="#E9EFFA" Content="让她记住我们聊过的事（温层压缩）"/>
      <Grid Margin="0,8,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Column="0" Text="保留最近" FontFamily="Microsoft YaHei" FontSize="11.5" Foreground="#A8BCD8" VerticalAlignment="Center"/>
        <TextBox   Grid.Column="1" x:Name="NumKeep" Width="42" Margin="6,0,0,0" FontSize="12" Background="#22FFFFFF" BorderBrush="#33FFFFFF" Foreground="#F2F3F5" TextAlignment="Center"/>
        <TextBlock Grid.Column="2" Text="轮；每" FontFamily="Microsoft YaHei" FontSize="11.5" Foreground="#A8BCD8" Margin="6,0,0,0" VerticalAlignment="Center"/>
        <TextBox   Grid.Column="3" x:Name="NumEvery" Width="42" FontFamily="Microsoft YaHei" FontSize="12" Background="#22FFFFFF" BorderBrush="#33FFFFFF" Foreground="#F2F3F5" TextAlignment="Center"/>
        <TextBlock Grid.Column="4" Text="轮压缩一次" FontFamily="Microsoft YaHei" FontSize="11.5" Foreground="#A8BCD8" Margin="6,0,0,0" VerticalAlignment="Center"/>
      </Grid>

      <CheckBox x:Name="OptWorkspace" FontFamily="Microsoft YaHei" FontSize="12.5" Foreground="#E9EFFA" Margin="0,10,0,0" Content="让她知道我在工作区忙什么（读最近一次摘要，默认关）"/>
      <CheckBox x:Name="OptAutostart" FontFamily="Microsoft YaHei" FontSize="12.5" Foreground="#E9EFFA" Margin="0,6,0,0" Content="开机时自动出现"/>
      <CheckBox x:Name="OptEnglish" FontFamily="Microsoft YaHei" FontSize="12.5" Foreground="#E9EFFA" Margin="0,6,0,0" Content="英文界面（English interface）"/>

      <Grid Margin="0,10,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Column="0" Text="气泡停留" FontFamily="Microsoft YaHei" FontSize="11.5" Foreground="#A8BCD8" VerticalAlignment="Center"/>
        <TextBox   Grid.Column="1" x:Name="NumBubble" Width="42" Margin="6,0,0,0" FontFamily="Microsoft YaHei" FontSize="12" Background="#22FFFFFF" BorderBrush="#33FFFFFF" Foreground="#F2F3F5" TextAlignment="Center"/>
        <TextBlock Grid.Column="2" Text="秒；心情刷新" FontFamily="Microsoft YaHei" FontSize="11.5" Foreground="#A8BCD8" Margin="6,0,0,0" VerticalAlignment="Center"/>
        <TextBox   Grid.Column="3" x:Name="NumRefresh" Width="56" FontFamily="Microsoft YaHei" FontSize="12" Background="#22FFFFFF" BorderBrush="#33FFFFFF" Foreground="#F2F3F5" TextAlignment="Center"/>
        <TextBlock Grid.Column="4" Text="毫秒" FontFamily="Microsoft YaHei" FontSize="11.5" Foreground="#A8BCD8" Margin="6,0,0,0" VerticalAlignment="Center"/>
      </Grid>

      <TextBlock Text="聊天用的模型（留空 = 自动挑一个）" FontFamily="Microsoft YaHei" FontSize="11" Foreground="#8FA6C8" Margin="0,12,0,4"/>
      <TextBox x:Name="ModelBox" FontFamily="Microsoft YaHei" FontSize="11.5" Padding="6,4" Background="#22FFFFFF" BorderBrush="#33FFFFFF" Foreground="#F2F3F5"/>

      <TextBlock x:Name="VerText" Text="" FontFamily="Consolas" FontSize="10.5" Foreground="#7388A8" Margin="0,10,0,0"/>

      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
        <Button x:Name="BtnCancel" Content="取消" Width="66" Height="26" Margin="0,0,8,0" FontFamily="Microsoft YaHei" FontSize="12" Background="#22FFFFFF" BorderBrush="#33FFFFFF" Foreground="#D6E1F2"/>
        <Button x:Name="BtnSave" Content="保存" Width="66" Height="26" FontFamily="Microsoft YaHei" FontSize="12" Background="#82A0FF" BorderBrush="#B4C8FF" Foreground="#0B1220"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@

function New-SettingsWindow {
  $w = [System.Windows.Markup.XamlReader]::Parse((T-Xaml $settingsXaml))
  if ($script:Lang -eq 'en') { $w.Width = 486 }
  $s = $script:Settings
  $w.FindName('OptMemory').IsChecked     = [bool]$s.memory.enabled
  $w.FindName('OptWorkspace').IsChecked  = [bool]$s.knowWorkspace
  $w.FindName('OptAutostart').IsChecked  = [bool]$s.autostart
  $w.FindName('OptEnglish').IsChecked    = [bool]($script:Lang -eq 'en')
  $w.FindName('NumKeep').Text            = [string]$s.memory.keepTurns
  $w.FindName('NumEvery').Text           = [string]$s.memory.compressEvery
  $w.FindName('NumBubble').Text          = [string]$s.bubbleSeconds
  $w.FindName('NumRefresh').Text         = [string]$s.refreshMs
  $w.FindName('ModelBox').Text           = [string]$s.model
  try { $w.FindName('VerText').Text = (Get-VersionLine) } catch { }
  $w.FindName('BtnCancel').Add_Click({ BootLog 'settings: cancel'; $script:SettingsWin.Close() })
  $w.FindName('BtnSave').Add_Click({
    $toInt = { param($t, $d, $min, $max)
      $n = 0
      if (-not [int]::TryParse(([string]$t).Trim(), [ref]$n)) { return $d }
      if ($n -lt $min) { return $min }
      if ($n -gt $max) { return $max }
      return $n
    }
    $beforeLang = $script:Lang
    $script:Settings.memory.enabled       = [bool]$w.FindName('OptMemory').IsChecked
    $script:Settings.knowWorkspace        = [bool]$w.FindName('OptWorkspace').IsChecked
    $script:Settings.autostart            = [bool]$w.FindName('OptAutostart').IsChecked
    $script:Settings.memory.keepTurns     = & $toInt $w.FindName('NumKeep').Text 3 1 12
    $script:Settings.memory.compressEvery = & $toInt $w.FindName('NumEvery').Text 8 2 40
    $script:Settings.bubbleSeconds        = & $toInt $w.FindName('NumBubble').Text 6 1 30
    $script:Settings.refreshMs            = & $toInt $w.FindName('NumRefresh').Text 1200 400 10000
    $script:Settings.model                = [string]$w.FindName('ModelBox').Text
    $script:Settings.lang                 = if ($w.FindName('OptEnglish').IsChecked) { 'en' } else { 'zh' }
    BootLog 'settings: save'
    Save-PetSettings
    Apply-PetSettings
    $w.Close()
    if ($script:Settings.lang -ne $beforeLang) {
      BootLog ('lang: switch ' + $beforeLang + ' -> ' + $script:Settings.lang)
      Restart-WidgetLater
    }
  })
  $script:SettingsWin = $w
  return $w
}

function Show-Settings {
  BootLog 'settings: open'
  $w = New-SettingsWindow
  try { $w.Owner = $pet } catch { }
  $w.Left = $pet.Left + ($pet.Width - $w.Width) / 2
  $w.Top  = [Math]::Max(20, $pet.Top - 360)
  try { $w.ShowDialog() | Out-Null
  } catch {
    BootLog ('settings: dialog error ' + $_.Exception.Message)
  } finally {
    BootLog 'settings: closed'
    $script:SettingsWin = $null
    # the modal dialog can leave the layered window without a visual - force a repaint
    $script:PetHidden = $false
    try { $pet.Show() } catch { }
    try { $pet.Topmost = $true } catch { }
    try { $pet.InvalidateVisual(); $pet.UpdateLayout() } catch { }
    try { $status.InvalidateVisual() } catch { }
    Place-Stacks
    Place-Status
  }
}

$menu = New-Object System.Windows.Controls.ContextMenu
$miToggle = New-Object System.Windows.Controls.MenuItem
$miToggle.Header = (L '打开 / 收起面板')
$miToggle.Add_Click({ Toggle-Panel })
$miReset = New-Object System.Windows.Controls.MenuItem
$miReset.Header = (L '重置位置')
$miReset.Add_Click({
  $wa = Get-WorkArea
  $pet.Left = $wa.Right - $pet.Width - 24
  $pet.Top  = $wa.Bottom - $pet.Height - 24
  Save-Position; Place-Panel
})
$miStart = New-Object System.Windows.Controls.MenuItem
$miStart.Header = (L '开机自动启动')
$miStart.IsCheckable = $true
$miStart.IsChecked = (Test-Path $script:StartLink)
$miStart.Add_Click({
  $wsh = "$env:WINDIR\System32\wscript.exe"
  $ico = Join-Path $script:Root 'feiyu.ico'
  try {
    if (Test-Path $script:StartLink) { Remove-Item $script:StartLink -Force }
    else {
      if (-not (Test-Path $ico)) { New-IconFromPng (Join-Path $script:Assets 'feiyu.png') $ico }
      New-Lnk $script:StartLink $wsh ('"' + $script:Launcher + '"') $ico $script:Root '鱼的心情 · 桌面挂饰'
    }
  } catch { }
  $miStart.IsChecked = (Test-Path $script:StartLink)
})
$miQuit = New-Object System.Windows.Controls.MenuItem
$miQuit.Header = (L '退出')
$miQuit.Add_Click({
  Stop-Tray
  Save-Position
  $panel.Close(); $pet.Close()
  [System.Windows.Application]::Current.Shutdown()
})
$menu.Items.Add($miToggle) | Out-Null
$miChat = New-Object System.Windows.Controls.MenuItem
$miChat.Header = (L '和她说句话')
$miChat.Add_Click({ Toggle-Chat })
  $miSettings = New-Object System.Windows.Controls.MenuItem
  $miSettings.Header = (L '她的设置…')
  $miSettings.Add_Click({ $app.Dispatcher.BeginInvoke([Action]{ Show-Settings }) | Out-Null })
  [void]$menu.Items.Add($miSettings)
$menu.Items.Add($miChat) | Out-Null
$menu.Items.Add($miReset) | Out-Null
$menu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null
$menu.Items.Add($miStart) | Out-Null
$menu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null
$menu.Items.Add($miQuit) | Out-Null
$pet.ContextMenu = $menu

function Start-Tray {
  try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $ni = New-Object System.Windows.Forms.NotifyIcon
    $icoPath = Join-Path $script:Root 'feiyu.ico'
    if (-not (Test-Path -LiteralPath $icoPath)) { New-IconFromPng (Join-Path $script:Assets 'feiyu.png') $icoPath }
    $ni.Icon = New-Object System.Drawing.Icon $icoPath
    $ni.Text = ((L '鱼的心情 · 桌面挂饰') + ' · ' + (Get-VersionLine))
    $ni.Visible = $true

    $tray = New-Object System.Windows.Forms.ContextMenuStrip
    $iPanel = New-Object System.Windows.Forms.ToolStripMenuItem (L '打开面板')
    $iPanel.Add_Click({ $pet.Show(); $pet.Activate(); if (-not $script:PanelOpen) { Toggle-Panel } })
    $iChat = New-Object System.Windows.Forms.ToolStripMenuItem (L '和她说句话')
    $iChat.Add_Click({ $pet.Show(); $pet.Activate(); if (-not $script:ChatOpen) { Toggle-Chat } })
    $iShow = New-Object System.Windows.Forms.ToolStripMenuItem (L '把小鱼叫出来')
    $iShow.Add_Click({ $pet.Show(); $pet.Activate(); [void]$pet.Focus() })
    $iRestart = New-Object System.Windows.Forms.ToolStripMenuItem (L '重新启动挂件')
    $iRestart.Add_Click({
      try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Join-Path $env:WINDIR 'System32\wscript.exe')
        $psi.Arguments = '"' + $script:Launcher + '"'
        $psi.UseShellExecute = $true
        $psi.WindowStyle = 'Hidden'
        [void][System.Diagnostics.Process]::Start($psi)
      } catch { }
      Start-Sleep -Milliseconds 150
      Save-Position
      $panel.Close(); $pet.Close()
      [System.Windows.Application]::Current.Shutdown()
    })
    $iQuit = New-Object System.Windows.Forms.ToolStripMenuItem (L '退出')
    $iQuit.Add_Click({
      Save-Position
      $panel.Close(); $pet.Close()
      [System.Windows.Application]::Current.Shutdown()
    })
    [void]$tray.Items.Add($iShow)
    [void]$tray.Items.Add($iPanel)
    [void]$tray.Items.Add($iChat)
    [void]$tray.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$tray.Items.Add($iRestart)
    [void]$tray.Items.Add($iQuit)
    $ni.ContextMenuStrip = $tray
    $ni.Add_MouseDoubleClick({ $pet.Show(); $pet.Activate(); if (-not $script:PanelOpen) { Toggle-Panel } })
    $script:TrayIcon = $ni
    try { $ni.ShowBalloonTip(3200, (L '小鱼在托盘里'), (L '双击托盘图标打开面板；右键有菜单，可以叫她出来或退出。'), [System.Windows.Forms.ToolTipIcon]::Info) } catch { }
    BootLog 'tray icon ready'
  } catch { BootLog ('tray fail: ' + $_.Exception.Message) }
}

function Stop-Tray {
  try { if ($script:TrayIcon) { $script:TrayIcon.Visible = $false; $script:TrayIcon.Dispose(); $script:TrayIcon = $null } } catch { }
}

# ---------- timer ----------
$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds([Math]::Max(400, [int]$script:Settings.refreshMs))
$script:Timer.Add_Tick({
  Update-Ui
  if ($script:PanelOpen) { Place-Panel }
})

# ---------- app ----------
$app = New-Object System.Windows.Application
$app.Add_DispatcherUnhandledException({ param($s, $e) try { BootLog ('unhandled: ' + $e.Exception.GetType().Name + ': ' + $e.Exception.Message + ' | ' + $e.Exception.StackTrace) } catch { } })
# windows are created before the Application object, so WPF's window list stays empty;
# OnLastWindowClose would shut the app down whenever any dialog closes.
$app.ShutdownMode = 'OnExplicitShutdown'

$pet.Add_Loaded({
  Load-Position
  Update-PetFacing
  Update-Ui
  BootLog ('lang resolved: ' + $script:Lang + ' (setting=' + $script:Settings.lang + ')')
  if ($script:Handoff) {
    try { [System.IO.File]::WriteAllText($script:ReadyFlag, '1', (New-Object System.Text.UTF8Encoding($false))) } catch { }
    BootLog 'handoff: ready flag written'
    $script:LockTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:LockTimer.Interval = [TimeSpan]::FromMilliseconds(80)
    $script:LockTimer.Add_Tick({
      if ($script:InstanceLock) { $script:LockTimer.Stop(); return }
      try {
        $script:InstanceLock = [System.IO.File]::Open($script:LockPath, [System.IO.FileMode]::OpenOrCreate,
          [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $script:LockTimer.Stop()
        BootLog ('handoff: lock acquired after ' + [int]$script:LockTries + ' tries')
      } catch {
        if (-not $script:LockTries) { $script:LockTries = 0 }
        $script:LockTries++
        if ($script:LockTries -gt 60) {
          $script:LockTimer.Stop()
          try { $pet.Close() } catch { }
          [System.Windows.Application]::Current.Shutdown()
        }
      }
    })
    $script:LockTimer.Start()
  }
  Start-Anim
  $script:Timer.Start()
  Say-GreetingOnStart
  # Heavy startup bits run right after the first paint: the pet is on screen sooner,
  # which keeps the language-switch restart short.
  $script:WarmTimer = New-Object System.Windows.Threading.DispatcherTimer
  $script:WarmTimer.Interval = [TimeSpan]::FromMilliseconds(120)
  $script:WarmTimer.Add_Tick({
    $script:WarmTimer.Stop()
    try { Start-Tray } catch { }
    try {
      Ensure-FgWin
      $script:FgTimer = New-Object System.Windows.Threading.DispatcherTimer
      $script:FgTimer.Interval = [TimeSpan]::FromMilliseconds(1500)
      $script:FgTimer.Add_Tick({ Update-FullscreenGuard })
      $script:FgTimer.Start()
    } catch { }
  })
  $script:WarmTimer.Start()
  if ($Say) {
    $script:ChatInput.Text = $Say
    Send-Chat
    $script:SayTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:SayTimer.Interval = [TimeSpan]::FromSeconds(14)
    $script:SayTimer.Add_Tick({
      $script:SayTimer.Stop()
      try {
        $lines = @('bubble=' + $script:BubText.Text; 'alive=' + ((Read-BridgeAlive) | ConvertTo-Json -Compress))
        $lines | Set-Content -LiteralPath (Join-Path $script:Root '_say.txt') -Encoding UTF8
      } catch { }
      $pet.Close(); $panel.Close(); [System.Windows.Application]::Current.Shutdown()
    })
    $script:SayTimer.Start()
  }
})

$pet.Add_Closed({ if ($script:WarmTimer) { $script:WarmTimer.Stop() }; Stop-Tray; $script:Timer.Stop(); if ($script:FgTimer) { $script:FgTimer.Stop() }; try { Remove-Item $script:PidFile -Force -ErrorAction SilentlyContinue } catch { }; try { if (-not $script:Quitting) { $script:Quitting = $true; [System.Windows.Application]::Current.Shutdown() } } catch { } })

$panel.Add_Closed({ })

if ($ChatTwice) {
  $script:NoAutoClose = $true
  $script:CtStage = 0
  $script:CtTicks = 0
  $script:CtLog = New-Object System.Collections.ArrayList
  $script:CtTimer = New-Object System.Windows.Threading.DispatcherTimer
  $script:CtTimer.Interval = [TimeSpan]::FromMilliseconds(500)
  $script:CtTimer.Add_Tick({
    $script:CtTicks++
    [void]$script:CtLog.Add(('t={0} stage={1} bubble={2} text={3}' -f $script:CtTicks, $script:CtStage, $script:Bubble.IsVisible, $script:BubText.Text.Substring(0, [Math]::Min(8, $script:BubText.Text.Length))))
    if ($script:CtStage -eq 0) {
      Toggle-Chat
      Start-Sleep -Milliseconds 200
      $script:ChatInput.Text = '第一句话测试'
      Send-Chat
      $script:CtStage = 1
      return
    }
    if ($script:CtStage -eq 1) {
      $busy = ($script:ReplyTimer -and $script:ReplyTimer.IsEnabled)
      if (-not $busy -and $script:CtTicks -gt 4) {
        $script:ChatInput.Text = '第二句话测试'
        Send-Chat
        $script:CtStage = 2
      }
      return
    }
    if ($script:CtStage -eq 2) {
      $busy = ($script:ReplyTimer -and $script:ReplyTimer.IsEnabled)
      if (-not $busy -and $script:CtTicks -gt 2) {
        $script:CtTimer.Stop()
        $script:CtLog | Set-Content -LiteralPath (Join-Path $script:Root '_chat2.txt') -Encoding UTF8
        try { $pet.Close() } catch { }
        [System.Windows.Application]::Current.Shutdown()
      }
    }
  })
  $script:CtTimer.Start()
}

if ($TestShot) {
  $shotTimer = New-Object System.Windows.Threading.DispatcherTimer
  $shotTimer.Interval = [TimeSpan]::FromSeconds(3)
  $shotTimer.Add_Tick({
    $shotTimer.Stop()
    try {
      if ($OpenChat) { Place-Stacks }
      Toggle-Panel
      $script:Shot2 = New-Object System.Windows.Threading.DispatcherTimer
      $script:Shot2.Interval = [TimeSpan]::FromMilliseconds(1500)
      $script:Shot2.Add_Tick({
        $script:Shot2.Stop()
        try {
          $base = [System.IO.Path]::ChangeExtension($TestShot, $null)
          Render-Window $pet   ($base + '_pet.png')
          Render-Window $panel ($base + '_panel.png')
          if ($script:ChatOpen) { try { Render-Window $script:Chat ($base + '_chat.png') } catch { } }
          if ($script:Bubble.IsVisible) { try { Render-Window $script:Bubble ($base + '_bubble.png') } catch { } }
          $rects = [ordered]@{
            pet    = @($pet.Left, $pet.Top, $pet.Width, $pet.Height)
            panel  = @($panel.Left, $panel.Top, $panel.Width, $panel.ActualHeight)
            chat   = @($script:Chat.Left, $script:Chat.Top, $script:Chat.Width, $script:Chat.ActualHeight)
            bubble = @($script:Bubble.Left, $script:Bubble.Top, $script:Bubble.Width, $script:Bubble.ActualHeight)
          }
          ($rects | ConvertTo-Json -Compress) | Set-Content -LiteralPath ($base + '_rects.json') -Encoding UTF8
        } catch {
          Set-Content -LiteralPath ($TestShot + '.err.txt') -Value ($_.Exception.ToString()) -Encoding UTF8
        }
        $panel.Close(); $pet.Close()
        [System.Windows.Application]::Current.Shutdown()
      })
      $script:Shot2.Start()
    } catch { }
  })
  $shotTimer.Start()
}

function BootLog($m) { try { Add-Content -LiteralPath (Join-Path $script:Root '_boot.log') -Value ((Get-Date).ToString('HH:mm:ss.fff') + ' ' + $m) -Encoding UTF8 } catch { } }
if ($Render) {
  try {
    Update-Ui
    $pc = $pet.Content
    $pc.Measure([System.Windows.Size]::new([double]$pet.Width, [double]::PositiveInfinity))
    $pc.Arrange([System.Windows.Rect]::new(0, 0, [double]$pet.Width, $pc.DesiredSize.Height))
    $pc.UpdateLayout()
    $bd = $panel.Content
    $bd.Measure([System.Windows.Size]::new([double]$panel.Width, [double]::PositiveInfinity))
    $bd.Arrange([System.Windows.Rect]::new(0, 0, [double]$panel.Width, $bd.DesiredSize.Height))
    $bd.UpdateLayout()
    Render-Window $pet   ($Render + '_pet.png')
    Render-Window $panel ($Render + '_panel.png')

    # 慢眨眼替代动作的分帧：g=0..1 采样 6 帧，方便合成 GIF 预览
    for ($gi = 0; $gi -le 5; $gi++) {
      $script:GazeT = $script:GazeDur * (1.0 - ($gi / 5.0))
      Set-PetTransform
      Render-Window $pet ($Render + ('_gaze' + $gi + '.png'))
    }
    $script:GazeT = 0.0
    Set-PetTransform

    # 气泡与聊天输入条：离屏排版后单独出图，方便看效果
    $script:BubText.Text = (L '今天也要好好休息呀～')
    $bc = $script:Bubble.Content
    $bc.Measure([System.Windows.Size]::new(300, [double]::PositiveInfinity))
    $bc.Arrange([System.Windows.Rect]::new(0, 0, 300, $bc.DesiredSize.Height))
    $bc.UpdateLayout()
    Render-Window $script:Bubble ($Render + '_bubble.png')

    $script:ChatInput.Text = (L '你在干嘛呀')
    $cc = $script:Chat.Content
    $cc.Measure([System.Windows.Size]::new([double]$script:Chat.Width, [double]::PositiveInfinity))
    $cc.Arrange([System.Windows.Rect]::new(0, 0, [double]$script:Chat.Width, $cc.DesiredSize.Height))
    $cc.UpdateLayout()
    Render-Window $script:Chat ($Render + '_chat.png')

    $script:StatusText.Text = ((L '开心') + ' · 70')
    $script:Status.Show()
    Fit-Status
    $sc = $script:Status.Content
    $sc.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
    $sc.Arrange([System.Windows.Rect]::new(0, 0, $sc.DesiredSize.Width, $sc.DesiredSize.Height))
    $sc.UpdateLayout()
    Render-Window $script:Status ($Render + '_status.png')
    $script:Status.Hide()

    # 眨眼序列（供合成 GIF 预览）
    if ($script:CurFaceFile) {
      $closed = Join-Path $script:Assets ($script:CurFaceFile -replace '\.png$', '-blink-ai.png')
      if (-not (Test-Path -LiteralPath $closed)) { $closed = Join-Path $script:Assets 'face-ok-blink-ai.png' }
      if (Test-Path -LiteralPath $closed) {
        $dbg = @()
        $dbg += 'ghostNull=' + [bool]($null -eq $script:PetGhost)
        $dbg += 'findNull=' + [bool]($null -eq $pet.FindName('PetGhost'))
        Set-ImageSource $script:PetGhost $closed
        $dbg += 'srcNull=' + [bool]($null -eq $script:PetGhost.Source)
        $dbg += 'closed=' + $closed
        Set-Content -LiteralPath ($Render + '.blkdbg.txt') -Value $dbg -Encoding UTF8
        $ops = @(0.18, 0.40, 0.62, 0.82, 0.95, 1.00, 0.95, 0.80, 0.60, 0.38, 0.16, 0.0)
        for ($bi = 0; $bi -lt $ops.Count; $bi++) {
          $script:PetGhost.Opacity = [double]$ops[$bi]
          Render-Window $pet ($Render + ('_blk' + ('{0:00}' -f $bi) + '.png'))
        }
        $script:PetGhost.Opacity = 0
        $script:PetGhost.Source = $null
      }
    }

    $swin = New-SettingsWindow
    $swin.FindName('OptMemory').IsChecked = $true
    $swin.FindName('NumKeep').Text = '3'
    $swin.FindName('NumEvery').Text = '8'
    $swin.FindName('NumBubble').Text = '6'
    $swin.FindName('NumRefresh').Text = '1200'
    $swin.Content.Measure([System.Windows.Size]::new([double]$swin.Width, [double]::PositiveInfinity))
    $swin.Content.Arrange([System.Windows.Rect]::new(0, 0, [double]$swin.Width, $swin.Content.DesiredSize.Height))
    $swin.Content.UpdateLayout()
    Render-Window $swin ($Render + '_settings.png')
  } catch {
    Set-Content -LiteralPath ($Render + '.err.txt') -Value ($_.Exception.ToString()) -Encoding UTF8
  }
  exit 0
}
try { Set-Content -LiteralPath $script:PidFile -Value ([string]$PID) -Encoding ASCII; BootLog ('pid written ' + $script:PidFile) } catch { BootLog ('pid fail: ' + $_.Exception.Message) }
$pet.Show()
if ($LangTest) {
  $from = $script:Lang
  $script:Settings.lang = if ($from -eq 'en') { 'zh' } else { 'en' }
  Save-PetSettings
  BootLog ('lang: switch ' + $from + ' -> ' + $script:Settings.lang + ' (LangTest)')
  Restart-WidgetLater
}
if ($OpenChat) { $script:NoAutoClose = $true; Toggle-Chat; Show-Bubble (L '这是测试回复，看看会不会压到输入框。') 0; Place-Stacks }
Place-Panel
[void]$app.Run()
BootLog 'BOOTLOG exit'

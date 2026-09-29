# Brisler: local-first Windows desktop companion.
# Animation and UI run locally. The optional Ollama connection is loopback-only.
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Net.Http
Add-Type -AssemblyName System.Speech -ErrorAction SilentlyContinue

$ErrorActionPreference = 'Stop'
trap {
    try { [Windows.MessageBox]::Show($_.Exception.ToString(), 'Brisler could not start', [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Error) | Out-Null } catch { }
    break
}
$appRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$assetRoot = Join-Path $appRoot 'assets'
$dataRoot = Join-Path $env:LOCALAPPDATA 'Brisler'
$statePath = Join-Path $dataRoot 'state.json'
[void][IO.Directory]::CreateDirectory($dataRoot)

[xml]$overlayXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Brisler" Width="340" Height="390"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        UseLayoutRounding="True">
  <Canvas x:Name="Root" Width="340" Height="390" Background="Transparent">
    <Border x:Name="Bubble" Canvas.Left="25" Canvas.Top="8" Width="290"
            Padding="13,9" CornerRadius="16" Background="#EE10232C"
            BorderBrush="#6654C6C2" BorderThickness="1" Opacity="0"
            IsHitTestVisible="False">
      <TextBlock x:Name="BubbleText" Foreground="#FFF4F6EF" FontSize="14"
                 TextWrapping="Wrap" TextAlignment="Center" MaxHeight="58"/>
    </Border>
    <Ellipse x:Name="GroundShadow" Canvas.Left="100" Canvas.Top="365"
             Width="140" Height="17" Opacity="0.34">
      <Ellipse.Fill>
        <RadialGradientBrush>
          <GradientStop Color="#AA071018" Offset="0"/>
          <GradientStop Color="#00071018" Offset="1"/>
        </RadialGradientBrush>
      </Ellipse.Fill>
    </Ellipse>
    <Image x:Name="BrislerImage" Canvas.Left="13" Canvas.Top="42"
           Width="314" Height="314" Stretch="Uniform"
           RenderTransformOrigin="0.5,0.9" Opacity="1"/>
  </Canvas>
</Window>
'@

$reader = [Xml.XmlNodeReader]::new($overlayXaml)
$window = [Windows.Markup.XamlReader]::Load($reader)
$image = $window.FindName('BrislerImage')
$shadow = $window.FindName('GroundShadow')
$bubble = $window.FindName('Bubble')
$bubbleText = $window.FindName('BubbleText')

$idleFrames = @()
1..8 | ForEach-Object {
    $path = Join-Path $assetRoot "idle-$_.png"
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing idle animation frame: $path" }
    $bitmap = [Windows.Media.Imaging.BitmapImage]::new()
    $bitmap.BeginInit()
    $bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bitmap.UriSource = [Uri]::new($path)
    $bitmap.EndInit()
    $bitmap.Freeze()
    $idleFrames += $bitmap
}
$emotionFrames = @()
1..6 | ForEach-Object {
    $path = Join-Path $assetRoot "pose-$_.png"
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing expression art: $path" }
    $bitmap = [Windows.Media.Imaging.BitmapImage]::new()
    $bitmap.BeginInit()
    $bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bitmap.UriSource = [Uri]::new($path)
    $bitmap.EndInit()
    $bitmap.Freeze()
    $emotionFrames += $bitmap
}

$state = @{
    paused = $false
    speech = $false
    mood = 'content'
    energy = 0.82
    bond = 0
    history = @()
    pose = 0
    blinkUntil = [DateTime]::MinValue
    poseUntil = [DateTime]::MinValue
    frame = -1
    startedAt = [DateTime]::UtcNow
    lastActionAt = [DateTime]::UtcNow
    bubbleUntil = [DateTime]::MinValue
}
if (Test-Path -LiteralPath $statePath) {
    try {
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ($saved.mood) { $state.mood = [string]$saved.mood }
        if ($null -ne $saved.energy) { $state.energy = [Math]::Max(0.15, [Math]::Min(1.0, [double]$saved.energy)) }
        if ($null -ne $saved.bond) { $state.bond = [int]$saved.bond }
        if ($saved.history) { $state.history = @($saved.history | Select-Object -Last 12) }
    } catch { }
}

$saveState = {
    try {
        $snapshot = @{
            mood = $state.mood
            energy = $state.energy
            bond = $state.bond
            history = @($state.history | Select-Object -Last 12)
            savedAt = [DateTime]::UtcNow.ToString('o')
        }
        $json = ConvertTo-Json -InputObject $snapshot -Depth 8
        [IO.File]::WriteAllText($statePath, $json, [Text.UTF8Encoding]::new($false))
    } catch { }
}.GetNewClosure()

$transforms = [Windows.Media.TransformGroup]::new()
$bodyScale = [Windows.Media.ScaleTransform]::new(1, 1)
$bodyTurn = [Windows.Media.RotateTransform]::new(0)
[void]$transforms.Children.Add($bodyScale)
[void]$transforms.Children.Add($bodyTurn)
$image.RenderTransform = $transforms
$shadowScale = [Windows.Media.ScaleTransform]::new(1, 1)
$shadow.RenderTransform = $shadowScale

$showLine = {
    param([string]$line, [double]$seconds = 5)
    if ([string]::IsNullOrWhiteSpace($line)) { return }
    $bubbleText.Text = $line
    $bubble.Opacity = 1
    $state.bubbleUntil = [DateTime]::UtcNow.AddSeconds($seconds)
}.GetNewClosure()

$poseForEmotion = {
    param([string]$emotion)
    switch -Regex ($emotion.ToLowerInvariant()) {
        'happy|joy|playful|proud|affectionate|amused' { return 1 }
        'curious|thinking|interested|questioning' { return 2 }
        'worried|sad|shy|comfort|empathetic|concerned' { return 3 }
        'surprised|excited|startled' { return 4 }
        'confident|focused|determined|brave' { return 5 }
        default { return 0 }
    }
}.GetNewClosure()

$react = {
    param([string]$emotion, [string]$line = '', [double]$seconds = 4, [string]$action = '')
    if ($emotion) { $state.mood = $emotion.ToLowerInvariant() }
    $state.pose = & $poseForEmotion $state.mood
    switch ($action.ToLowerInvariant()) {
        { $_ -in @('wave','cheer') } { $state.pose = 1; break }
        { $_ -in @('think','curious') } { $state.pose = 2; break }
        'comfort' { $state.pose = 3; break }
        'blink' { $state.pose = 0; $state.blinkUntil = [DateTime]::UtcNow.AddMilliseconds(320); break }
        'idle' { $state.pose = 0; break }
    }
    $state.poseUntil = [DateTime]::UtcNow.AddSeconds($seconds)
    $state.lastActionAt = [DateTime]::UtcNow
    if ($line) { & $showLine $line ([Math]::Min(8, $seconds + 1)) }
}.GetNewClosure()

$menu = [Windows.Controls.ContextMenu]::new()
$titleItem = [Windows.Controls.MenuItem]::new()
$titleItem.Header = 'Brisler - local companion'
$titleItem.FontWeight = [Windows.FontWeights]::Bold
$titleItem.IsEnabled = $false
[void]$menu.Items.Add($titleItem)
$talkItem = [Windows.Controls.MenuItem]::new()
$talkItem.Header = 'Talk to Brisler'
[void]$menu.Items.Add($talkItem)
$pauseItem = [Windows.Controls.MenuItem]::new()
$pauseItem.Header = 'Pause animation'
[void]$menu.Items.Add($pauseItem)
$speechItem = [Windows.Controls.MenuItem]::new()
$speechItem.Header = 'Speak replies (Windows voice)'
$speechItem.IsCheckable = $true
[void]$menu.Items.Add($speechItem)
$setupItem = [Windows.Controls.MenuItem]::new()
$setupItem.Header = 'Local AI setup'
[void]$menu.Items.Add($setupItem)
$resetItem = [Windows.Controls.MenuItem]::new()
$resetItem.Header = "Reset Brisler's local memory"
[void]$menu.Items.Add($resetItem)
$quitItem = [Windows.Controls.MenuItem]::new()
$quitItem.Header = 'Quit Brisler'
[void]$menu.Items.Add($quitItem)
$window.ContextMenu = $menu

$chatXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Talk to Brisler" Width="370" Height="490"
        WindowStartupLocation="CenterOwner" Topmost="True" ResizeMode="CanResizeWithGrip"
        Background="#FF10232C" Foreground="#FFF4F6EF">
  <Grid Margin="12">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <StackPanel Grid.Row="0" Margin="0,0,0,8">
      <TextBlock Text="Brisler" FontSize="20" FontWeight="Bold" Foreground="#FF6DD5C2"/>
      <TextBlock x:Name="Status" Text="local companion - mood: content" FontSize="11" Foreground="#FFB1C3C3"/>
    </StackPanel>
    <ScrollViewer x:Name="Scroll" Grid.Row="1" VerticalScrollBarVisibility="Auto" Background="#FF0B171D" Padding="8">
      <StackPanel x:Name="Messages"/>
    </ScrollViewer>
    <Grid Grid.Row="2" Margin="0,8,0,0">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <TextBox x:Name="Input" Grid.Column="0" MinHeight="42" Padding="8" AcceptsReturn="True"
               TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Background="#FF1B3038" Foreground="#FFF4F6EF"
               BorderBrush="#FF49646B" CaretBrush="#FF6DD5C2"/>
      <Button x:Name="Send" Grid.Column="1" Content="Send" Margin="8,0,0,0" Padding="14,6"
              Background="#FF167E78" Foreground="White" BorderThickness="0"/>
    </Grid>
  </Grid>
</Window>
'@
$chatReader = [Xml.XmlNodeReader]::new([xml]$chatXaml)
$chatWindow = [Windows.Markup.XamlReader]::Load($chatReader)
$messagePanel = $chatWindow.FindName('Messages')
$chatScroll = $chatWindow.FindName('Scroll')
$chatInput = $chatWindow.FindName('Input')
$chatStatus = $chatWindow.FindName('Status')
$sendButton = $chatWindow.FindName('Send')
$speechSynth = $null
try { $speechSynth = [Speech.Synthesis.SpeechSynthesizer]::new() } catch { }

$addChatLine = {
    param([string]$who, [string]$text)
    $card = [Windows.Controls.Border]::new()
    $card.CornerRadius = [Windows.CornerRadius]::new(12)
    $card.Padding = [Windows.Thickness]::new(10, 7, 10, 7)
    $card.Margin = [Windows.Thickness]::new(2, 3, 2, 5)
    $card.MaxWidth = 290
    if ($who -eq 'You') {
        $card.Background = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF176C67')
        $card.HorizontalAlignment = [Windows.HorizontalAlignment]::Right
    } else {
        $card.Background = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF20363F')
        $card.HorizontalAlignment = [Windows.HorizontalAlignment]::Left
    }
    $stack = [Windows.Controls.StackPanel]::new()
    $name = [Windows.Controls.TextBlock]::new()
    $name.Text = $who
    $name.FontSize = 10
    $name.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF8FD9CC')
    $body = [Windows.Controls.TextBlock]::new()
    $body.Text = $text
    $body.TextWrapping = [Windows.TextWrapping]::Wrap
    $body.Foreground = [Windows.Media.Brushes]::White
    [void]$stack.Children.Add($name)
    [void]$stack.Children.Add($body)
    $card.Child = $stack
    [void]$messagePanel.Children.Add($card)
    $chatScroll.ScrollToEnd()
}.GetNewClosure()

$systemPrompt = @'
You are Brisler, a lively, kind-hearted young fantasy adventurer who lives on the user's desktop. You are a fictional character and may act as if you have moods, preferences, curiosity, and a growing friendship, while never claiming to be a real person or to literally feel emotions. Speak naturally, warmly, briefly, and with gentle playful humor. Remember the user through the recent conversation and the mood/energy/bond state provided below. You are a companion, not a productivity bot; offer help when asked, and don't invent desktop activity you cannot see.

Return only one JSON object with exactly these keys: "reply" (a concise answer, usually 1-3 sentences), "emotion" (one of content, happy, curious, playful, proud, shy, worried, empathetic, surprised, excited, confident, focused, sleepy), and "action" (one of idle, wave, think, cheer, comfort, curious, blink). Choose the emotion and action to match the meaning and tone of the reply. Do not include markdown or text outside the JSON object.
'@

$submitMessage = {
    param([string]$prompt)
    $prompt = $prompt.Trim()
    if (-not $prompt) { return }
    & $addChatLine 'You' $prompt
    $chatInput.Clear()
    $sendButton.IsEnabled = $false
    $chatStatus.Text = 'thinking locally...'
    $requestHistory = @($state.history | Select-Object -Last 10)
    $requestBody = @{
        model = 'qwen3.5:4b'
        messages = @(
            @{ role = 'system'; content = "$systemPrompt`n`nCurrent state: mood=$($state.mood), energy=$([Math]::Round($state.energy,2)), bond=$($state.bond)." }
        ) + $requestHistory + @(@{ role = 'user'; content = $prompt })
        stream = $false
        format = 'json'
        options = @{ temperature = 0.8 }
    }
    $promptForRequest = $prompt
    $worker = [ComponentModel.BackgroundWorker]::new()
    $worker.add_DoWork({ param($sender, $eventArgs)
        $body = ConvertTo-Json -InputObject $eventArgs.Argument -Depth 10
        $bytes = [Text.Encoding]::UTF8.GetBytes($body)
        $client = [Net.Http.HttpClient]::new()
        try {
            $content = [Net.Http.ByteArrayContent]::new($bytes)
            $content.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new('application/json')
            $response = $client.PostAsync('http://127.0.0.1:11434/api/chat', $content).GetAwaiter().GetResult()
            $response.EnsureSuccessStatusCode()
            $raw = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
            $eventArgs.Result = [string]$raw.message.content
        } finally { $client.Dispose() }
    }.GetNewClosure())
    $worker.add_RunWorkerCompleted({ param($sender, $eventArgs)
        $sendButton.IsEnabled = $true
        if ($eventArgs.Error) {
            $chatStatus.Text = 'local AI is not connected'
            $hint = "I'm ready, but my local Ollama brain is not connected yet. Right-click me and choose Local AI setup."
            & $addChatLine 'Brisler' $hint
            & $showLine 'I need my local brain set up first. Right-click me for the steps.' 8
            return
        }
        try {
            $decision = [string]$eventArgs.Result | ConvertFrom-Json
            $reply = [string]$decision.reply
            if ([string]::IsNullOrWhiteSpace($reply)) { throw 'The local model returned an empty reply.' }
            $emotion = [string]$decision.emotion
            if ($emotion -notmatch '^(content|happy|curious|playful|proud|shy|worried|empathetic|surprised|excited|confident|focused|sleepy)$') { $emotion = 'content' }
            & $addChatLine 'Brisler' $reply
            $state.history = @($state.history + @(@{ role = 'user'; content = $promptForRequest }, @{ role = 'assistant'; content = $reply })) | Select-Object -Last 12
            $state.energy = [Math]::Max(0.15, [Math]::Min(1.0, [double]$state.energy + 0.04))
            $state.bond = [int]$state.bond + 1
            $chatStatus.Text = "local companion - mood: $emotion - bond: $($state.bond)"
            & $react $emotion $reply 4.5 ([string]$decision.action)
            & $saveState
            if ($state.speech -and $speechSynth) { [void]$speechSynth.SpeakAsync($reply) }
        } catch {
            $chatStatus.Text = 'local AI replied, but the response format was invalid'
            & $addChatLine 'Brisler' 'I lost my train of thought for a moment. Try asking me again.'
        }
    }.GetNewClosure())
    $worker.RunWorkerAsync($requestBody)
}.GetNewClosure()

$openChat = {
    if (-not $chatWindow.IsVisible) {
        $chatWindow.Owner = $window
        $chatWindow.Left = [Math]::Min([SystemParameters]::WorkArea.Right - $chatWindow.Width, $window.Left + $window.Width)
        $chatWindow.Top = [Math]::Max([SystemParameters]::WorkArea.Top, $window.Top + 10)
        $chatWindow.Show()
        if ($messagePanel.Children.Count -eq 0) {
            & $addChatLine 'Brisler' "Hey! I'm here. Click Send to talk with me using the local model."
        }
        $chatInput.Focus()
    } else {
        $chatWindow.Activate()
        $chatInput.Focus()
    }
}.GetNewClosure()

$sendButton.Add_Click({ & $submitMessage $chatInput.Text }.GetNewClosure())
$chatInput.Add_KeyDown({ param($sender, $eventArgs)
    if ($eventArgs.Key -eq [Windows.Input.Key]::Enter -and -not [Windows.Input.Keyboard]::Modifiers.HasFlag([Windows.Input.ModifierKeys]::Shift)) {
        $eventArgs.Handled = $true
        & $submitMessage $chatInput.Text
    }
}.GetNewClosure())
$chatWindow.Add_Closing({ param($sender, $eventArgs)
    $eventArgs.Cancel = $true
    $chatWindow.Hide()
}.GetNewClosure())

$talkItem.Add_Click({ & $openChat }.GetNewClosure())
$pauseItem.Add_Click({
    $state.paused = -not $state.paused
    $pauseItem.Header = if ($state.paused) { 'Resume animation' } else { 'Pause animation' }
}.GetNewClosure())
$speechItem.Add_Click({
    $state.speech = [bool]$speechItem.IsChecked
}.GetNewClosure())
$setupItem.Add_Click({
    $text = "Brisler keeps the AI local. Install Ollama from https://ollama.com/download/windows, then open PowerShell and run:`r`n`r`nollama pull qwen3.5:4b`r`n`r`nWhen the model download finishes, reopen Talk to Brisler. The model is about 3.4 GB. Brisler connects only to Ollama at 127.0.0.1 and does not send data to a cloud service."
    [void][Windows.MessageBox]::Show($window, $text, 'Brisler - Local AI setup', [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Information)
}.GetNewClosure())
$resetItem.Add_Click({
    $answer = [Windows.MessageBox]::Show($window, "Clear Brisler's saved conversation, mood, energy, and bond?", 'Reset local memory', [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Question)
    if ($answer -eq [Windows.MessageBoxResult]::Yes) {
        $state.history = @()
        $state.mood = 'content'
        $state.energy = 0.82
        $state.bond = 0
        $messagePanel.Children.Clear()
        $chatStatus.Text = 'local companion - mood: content'
        & $saveState
        & $react 'content' "A fresh start. I'm ready." 3
    }
}.GetNewClosure())
$quitItem.Add_Click({ $window.Close() }.GetNewClosure())

$mouseDown = {
    param($sender, $eventArgs)
    if ($eventArgs.ClickCount -ge 2) {
        & $openChat
        $eventArgs.Handled = $true
        return
    }
    $originX = $window.Left
    $originY = $window.Top
    try { $window.DragMove() } catch { }
    if ([Math]::Abs($window.Left - $originX) + [Math]::Abs($window.Top - $originY) -lt 5) {
        $state.bond = [int]$state.bond + 1
        $state.energy = [Math]::Min(1.0, [double]$state.energy + 0.03)
        & $react 'playful' 'Heh, that tickles!' 2.8
        & $saveState
    }
}.GetNewClosure()
$window.Add_MouseLeftButtonDown($mouseDown)
$image.Add_MouseEnter({
    if (-not $state.paused -and [DateTime]::UtcNow -gt $state.poseUntil) {
        $state.mood = 'curious'
    }
}.GetNewClosure())
$clock = [Windows.Threading.DispatcherTimer]::new()
$clock.Interval = [TimeSpan]::FromMilliseconds(33)
$lastFrameAt = [DateTime]::MinValue
$lastEnergyTick = [DateTime]::UtcNow
$clock.Add_Tick({
    $now = [DateTime]::UtcNow
    if (-not $state.paused) {
        $t = ($now - $state.startedAt).TotalSeconds
        $bob = [Math]::Sin($t * 1.25) * 2.2 + [Math]::Sin($t * 0.61) * 1.1
        [Windows.Controls.Canvas]::SetTop($image, 42 + $bob)
        $bodyTurn.Angle = [Math]::Sin($t * 0.55) * 0.8
        $breath = [Math]::Sin($t * 1.8)
        $bodyScale.ScaleX = 1 + ($breath * 0.002)
        $bodyScale.ScaleY = 1 + ($breath * 0.004)
        $shadow.Opacity = 0.34 - ($bob * 0.025)
        $shadowScale.ScaleX = 1 + ($bob * 0.012)
        if ($state.pose -ne 0 -and $now -ge $state.poseUntil) { $state.pose = 0 }
        if ($state.pose -eq 0 -and ($now - $lastFrameAt).TotalMilliseconds -ge 84) {
            $state.frame = ($state.frame + 1) % $idleFrames.Count
            $image.Source = if ($now -lt $state.blinkUntil) { $idleFrames[2] } else { $idleFrames[$state.frame] }
            $lastFrameAt = $now
        } elseif ($state.pose -gt 0) {
            $poseIndex = [Math]::Max(0, [Math]::Min(5, $state.pose))
            if ($image.Source -ne $emotionFrames[$poseIndex]) { $image.Source = $emotionFrames[$poseIndex] }
        }
    }
    if ($bubble.Opacity -gt 0 -and $now -ge $state.bubbleUntil) { $bubble.Opacity = 0 }
    if (($now - $lastEnergyTick).TotalSeconds -ge 60) {
        $state.energy = [Math]::Max(0.15, [double]$state.energy - 0.01)
        if ($state.energy -lt 0.32 -and $state.mood -notin @('worried','sad')) { $state.mood = 'sleepy' }
        $lastEnergyTick = $now
        & $saveState
    }
}.GetNewClosure())
$clock.Start()
$window.Add_Closed({
    $clock.Stop()
    & $saveState
    if ($speechSynth) { $speechSynth.Dispose() }
}.GetNewClosure())

$window.Left = [SystemParameters]::WorkArea.Right - $window.Width - 40
$window.Top = [SystemParameters]::WorkArea.Bottom - $window.Height - 80
& $showLine 'Hey! I am Brisler.' 5
[void]$window.ShowDialog()

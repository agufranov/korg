# Windows investigation: KORG nanoKEY Studio BLE-MIDI

Цель: собрать с Windows-машины, где nanoKEY Studio успешно подключается, максимум данных о том, **что Windows/KORG-драйвер делает иначе**, чем macOS.

Главный вопрос: как на Windows создаётся encrypted/authenticated BLE-соединение и есть ли дополнительные записи в KORG vendor characteristic.

## Что мы уже знаем с macOS

На macOS устройство видно, но protected GATT-доступ падает:

```text
Authentication is insufficient
Encryption is insufficient
```

Устройство имеет сервисы:

```text
180A                                      Device Information
D0611E78-BBB4-4591-A5F8-487910AE4366     KORG/vendor-specific service
03B80E5A-EDE8-4B33-A751-6CE34EC4C700     standard BLE-MIDI service
```

Интересные characteristics:

```text
D0611E78-BBB4-4591-A5F8-487910AE4366 / 8667556C-9A37-4C91-84ED-54EE27D90049
  properties: write, notify

03B80E5A-EDE8-4B33-A751-6CE34EC4C700 / 7772E5DB-3868-4112-A1A9-F2669D106BF3
  properties: read, writeWithoutResponse, notify
```

## Короткий план

Идём от простого к сильному:

1. Собрать версии Windows, Bluetooth adapter, KORG driver/app.
2. Подтвердить, как именно устройство появляется в системе после подключения.
3. Собрать Windows Bluetooth ETW trace без внешнего железа.
4. Если получится — снять настоящий over-the-air BLE trace через nRF52840 + Wireshark.
5. По результатам сравнить Windows success vs macOS failure.

## Артефакты, которые нужно вернуть в проект

Создай на Windows папку, например:

```powershell
mkdir C:\Temp\korg-nanokey-investigation
```

В идеале в итоге нужны:

```text
systeminfo.txt
bluetooth-devices.txt
pnp-devices.txt
korg-files.txt
korg-driver-info.txt
korg-registry.txt
bluetooth-etw.etl
bluetooth-etw.txt      если получится сконвертировать
wireshark.pcapng       если будет nRF/BLE sniffer
notes.md               что именно нажималось и в какое время
```

## Шаг 1. Информация о системе

Открой PowerShell **от имени администратора** и выполни:

```powershell
$Out = "C:\Temp\korg-nanokey-investigation"
New-Item -ItemType Directory -Force -Path $Out | Out-Null

systeminfo > "$Out\systeminfo.txt"
Get-ComputerInfo | Out-File "$Out\computer-info.txt"
Get-PnpDevice -Class Bluetooth | Format-List * | Out-File "$Out\bluetooth-devices.txt"
Get-PnpDevice | Where-Object { $_.FriendlyName -match 'KORG|nanoKEY|MIDI|Bluetooth' -or $_.InstanceId -match 'KORG|BTH|MIDI' } | Format-List * | Out-File "$Out\pnp-devices.txt"
```

Также вручную запиши в `notes.md`:

```text
Windows version:
Bluetooth adapter model:
KORG BLE-MIDI Driver version:
How device is connected: Windows Bluetooth settings / KORG utility / DAW / other
Does it appear as MIDI input? Where exactly?
```

## Шаг 2. Найти KORG-драйвер и файлы

В PowerShell:

```powershell
$Out = "C:\Temp\korg-nanokey-investigation"

Get-ChildItem "C:\Program Files", "C:\Program Files (x86)" -Recurse -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -match 'KORG|BLE|MIDI|nanoKEY' } |
  Select-Object FullName, Length, LastWriteTime |
  Out-File "$Out\korg-files.txt"

Get-CimInstance Win32_PnPSignedDriver |
  Where-Object { $_.DeviceName -match 'KORG|nanoKEY|MIDI|Bluetooth' -or $_.DriverProviderName -match 'KORG' } |
  Format-List * |
  Out-File "$Out\korg-driver-info.txt"
```

Если найдёшь `.sys`, `.dll`, `.exe` KORG BLE-MIDI driver/app — скопируй список путей в `notes.md`. Сами бинарники пока не обязательно переносить, но они могут понадобиться для strings/reverse later.

## Шаг 3. Registry-поиск KORG/BLE-MIDI

Осторожно: только чтение.

```powershell
$Out = "C:\Temp\korg-nanokey-investigation"

reg query HKLM /f KORG /s > "$Out\registry-korg-hklm.txt" 2>&1
reg query HKCU /f KORG /s > "$Out\registry-korg-hkcu.txt" 2>&1
reg query HKLM /f nanoKEY /s > "$Out\registry-nanokey-hklm.txt" 2>&1
reg query HKCU /f nanoKEY /s > "$Out\registry-nanokey-hkcu.txt" 2>&1
reg query HKLM /f "BLE-MIDI" /s > "$Out\registry-blemidi-hklm.txt" 2>&1
reg query HKCU /f "BLE-MIDI" /s > "$Out\registry-blemidi-hkcu.txt" 2>&1
```

## Шаг 4. Windows Bluetooth ETW trace без внешнего сниффера

Это не полноценный радио-сниффер, но может показать pairing/security/GATT ошибки и поведение Windows Bluetooth stack.

### Вариант A: netsh trace

1. Выключи nanoKEY Studio.
2. Удали/Forget устройство из Windows Bluetooth settings, если оно уже paired, чтобы поймать clean pairing.
3. Запусти PowerShell/CMD от администратора:

```powershell
$Out = "C:\Temp\korg-nanokey-investigation"
netsh trace start capture=yes report=yes persistent=no maxSize=1024 tracefile="$Out\bluetooth-netsh.etl" scenario=Bluetooth
```

Если `scenario=Bluetooth` не поддерживается, используй fallback:

```powershell
netsh trace start capture=yes report=yes persistent=no maxSize=1024 tracefile="$Out\bluetooth-netsh.etl"
```

4. Включи nanoKEY Studio и подключи его так, как обычно работает на Windows.
5. Нажми несколько клавиш/пэдов, покрути ручки.
6. Останови trace:

```powershell
netsh trace stop
```

Результат будет в:

```text
C:\Temp\korg-nanokey-investigation\bluetooth-netsh.etl
C:\Temp\korg-nanokey-investigation\bluetooth-netsh.cab / report files, если Windows их создаст
```

### Вариант B: pktmon ETW

Если `netsh trace` не даёт полезного результата:

```powershell
$Out = "C:\Temp\korg-nanokey-investigation"
pktmon start --etw -p 0 -f "$Out\pktmon.etl"
```

Затем подключи nanoKEY Studio, нажми клавиши, останови:

```powershell
pktmon stop
pktmon format "$Out\pktmon.etl" -o "$Out\pktmon.txt"
```

## Шаг 5. Microsoft Message Analyzer / Windows Performance Analyzer

Если есть Windows Performance Toolkit, можно открыть `.etl` в WPA. Если нет — просто передай `.etl`; мы потом разберём отдельно.

Полезно искать строки/события:

```text
nanoKEY
KORG
03B80E5A
7772E5DB
D0611E78
8667556C
Pairing
Bond
Encrypt
Authentication
GATT
ATT
```

## Шаг 6. Самый ценный вариант: nRF52840 + Wireshark

Если есть возможность достать nRF52840 dongle, это лучший путь.

Нужно:

- nRF52840 USB dongle или DK
- Wireshark
- Nordic nRF Sniffer for Bluetooth LE

Что делать:

1. Установить Wireshark.
2. Установить Nordic nRF Sniffer plugin.
3. Прошить dongle firmware sniffer'а по инструкции Nordic.
4. В Wireshark выбрать интерфейс `nRF Sniffer for Bluetooth LE`.
5. Запустить capture.
6. Включить nanoKEY Studio.
7. В Wireshark выбрать advertising device `nanoKEY Studio` / MAC / name.
8. На Windows выполнить успешное подключение.
9. Нажать несколько клавиш.
10. Сохранить `.pcapng`.

### Важно: проверить, что sniffer реально пошёл за соединением

Первый полученный capture поймал `CONNECT_IND`, но не поймал data-channel пакеты после подключения. Это значит, что nRF Sniffer видел рекламу и запрос подключения, но **не follow'ил connection**.

Перед сохранением нового capture проверь в Wireshark:

1. В окне/панели nRF Sniffer выбран именно `nanoKEY Studio`, а не просто общий advertising stream.
2. После `CONNECT_IND` появляются пакеты не только с advertising access address `0x8E89BED6`, но и с новым connection access address из `CONNECT_IND`.
3. В списке протоколов/пакетов видны хотя бы некоторые из:
   - `LL_ENC_REQ`, `LL_ENC_RSP`, `LL_START_ENC_REQ`, `LL_START_ENC_RSP`;
   - `SMP Pairing Request/Response`;
   - `ATT`, `GATT`, `Write Request`, `Write Command`, `Handle Value Notification`;
   - обращения к handle `0x2902`/CCCD или BLE-MIDI characteristic.

Если после подключения в Wireshark всё ещё идут только `ADV_IND`/`SCAN_RSP` от nanoKEY и нет data-channel пакетов — capture для нашей главной задачи неполный. Нужно перезапустить capture, выбрать устройство в nRF Sniffer device list и повторить подключение.

Практический порядок для повторного capture:

1. Выключить nanoKEY Studio.
2. Запустить Wireshark capture на `nRF Sniffer for Bluetooth LE`.
3. Включить nanoKEY Studio и дождаться `nanoKEY Studio` в device list.
4. Кликнуть/выбрать `nanoKEY Studio` в nRF Sniffer toolbar/device list.
5. Только после этого нажать Connect в Windows/KORG.
6. Убедиться, что после CONNECT_IND появляются data-channel пакеты.
7. Нажать несколько клавиш.
8. Сохранить `.pcapng`.

Что хотим увидеть:

- LL connection setup;
- SMP Pairing Request/Response;
- encryption start;
- ATT read/write/notify;
- записи в vendor characteristic `8667556C...`, если они есть;
- подписку на CCCD `2902` для BLE-MIDI characteristic.

Важно: если соединение шифруется, payload после encryption может быть нечитабелен без ключей. Но нам критично понять сам pairing/security flow и отличия от macOS.

## Шаг 7. Ручные заметки во время эксперимента

В `notes.md` запиши таймлайн:

```text
15:20:00 started trace
15:20:15 turned nanoKEY Studio on
15:20:30 clicked Connect in Windows
15:20:40 Windows says Connected
15:20:50 opened DAW / MIDI monitor
15:21:00 pressed C4, D4, pad 1, knob 1
15:21:20 stopped trace
```

Таймлайн очень поможет сопоставить события в `.etl`/`.pcapng`.

## Нужно ли писать Windows-скрипт?

Да, если ручные команды неудобны. Пока достаточно PowerShell-команд выше. Если понадобится, следующий шаг — создать `windows/collect-korg-info.ps1`, который автоматически соберёт systeminfo, PnP devices, registry search и запустит trace с подсказками.

## Что прислать обратно

Минимум:

```text
systeminfo.txt
bluetooth-devices.txt
pnp-devices.txt
korg-driver-info.txt
registry-*.txt
bluetooth-netsh.etl или pktmon.etl
notes.md
```

Идеально:

```text
всё выше + Wireshark .pcapng с nRF52840
```

Если файлы большие, можно архивом:

```powershell
Compress-Archive -Path C:\Temp\korg-nanokey-investigation\* -DestinationPath C:\Temp\korg-nanokey-investigation.zip -Force
```

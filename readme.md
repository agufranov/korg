# KORG nanoKEY Studio Bluetooth investigation

Мы пытаемся заставить KORG nanoKEY Studio работать по Bluetooth на macOS/Apple Silicon, где официальный путь через **Audio MIDI Setup** и приложение **KORG Bluetooth MIDI Connect** видит устройство, но не подключает его.

Текущая машина пользователя: **MacBook Pro 14", Apple M3 Pro, 36 GB RAM, macOS Sonoma 14.6**.

## Где мы сейчас

Устройство видно на уровне BLE. Оно рекламирует стандартный BLE-MIDI сервис:

```text
03B80E5A-EDE8-4B33-A751-6CE34EC4C700
```

Мы написали несколько диагностических инструментов:

```bash
npm run scan       # BLE scan
npm run midi       # попытка читать BLE-MIDI события через Node/noble
npm run dump       # GATT dump через Node/noble
npm run dump:objc  # GATT dump напрямую через macOS CoreBluetooth
```

Wireshark CLI tools (`tshark`, `capinfos`, `editcap`, `mergecap`, `rawshark`) установлены через Homebrew в `/opt/homebrew/bin`. Дальше `.pcapng`-дампы разбираем ими, а не самописным быстрым парсером.

На macOS самый важный результат дал `npm run dump:objc`: macOS напрямую сообщает, что для чтения/notify не хватает BLE security:

```text
Authentication is insufficient
Encryption is insufficient
```

То есть проблема сейчас не в парсинге MIDI. MIDI-байты просто не приходят, потому что устройство требует authenticated/encrypted BLE-соединение, а macOS/KORG flow его не создаёт или не завершает.

Windows/nRF Sniffer capture уже получен. Самые важные файлы:

```text
5.pcapng  Windows pairing/encryption + GATT discovery
6.pcapng  полный рабочий Windows BLE-MIDI flow
```

`6.pcapng` показывает успешный путь Windows:

1. `CONNECT_IND` к `10:98:C3:53:6B:1B`.
2. SMP pairing: Windows central запрашивает Bonding + MITM.
3. LL encryption: `LL_ENC_REQ/RSP`, `LL_START_ENC_REQ/RSP`.
4. GATT discovery.
5. Подписка на BLE-MIDI CCCD:

   ```text
   handle 0x001c = CCCD для 7772E5DB-3868-4112-A1A9-F2669D106BF3
   write value 0x0001 = Notification enabled
   ```

6. Реальные BLE-MIDI notifications с:

   ```text
   handle 0x001b = BLE-MIDI characteristic value
   ```

Примеры payload из `6.pcapng`:

```text
95 ed 90 47 4d
97 c3 80 47 40
9e 9f 90 47 3d
9f db 80 47 40
```

Они выглядят как стандартные BLE-MIDI packets: timestamp bytes + MIDI channel messages (`0x90` note on, `0x80` note off). В успешном Windows flow не видно необходимости в KORG vendor characteristic: записи в `0x0017/0x0018` не наблюдались.

## Что нашли внутри устройства

У nanoKEY Studio есть:

```text
180A                                      Device Information
D0611E78-BBB4-4591-A5F8-487910AE4366     vendor/KORG service
03B80E5A-EDE8-4B33-A751-6CE34EC4C700     standard BLE-MIDI service
```

Vendor/KORG characteristic:

```text
8667556C-9A37-4C91-84ED-54EE27D90049 properties=write,notify
```

BLE-MIDI characteristic:

```text
7772E5DB-3868-4112-A1A9-F2669D106BF3 properties=read,writeWithoutResponse,notify
```

## Что нашли про KORG Bluetooth MIDI Connect

Установленное приложение:

```text
/Applications/Bluetooth MIDI Connect.app
```

Похоже, это не отдельный драйвер и не сложный проприетарный стек. Оно использует системные Apple-фреймворки:

```text
CoreBluetooth
CoreMIDI
CoreAudioKit
```

Внутри есть ссылка на Apple-класс:

```text
CABTLEMIDIWindowController
```

Поэтому текущая гипотеза: KORG-приложение просто оборачивает системный Apple BLE-MIDI механизм, а реальный баг находится ниже — в BLE pairing/security flow на macOS/Apple Silicon или в совместимости прошивки устройства с этим flow.

## Что предстоит сделать

Ближайшие технические шаги после Windows capture:

1. Улучшить native CoreBluetooth dumper (`dump-ble.m`): больше логов, повторные попытки read/notify, точная диагностика состояния peripheral.
2. Сделать LLDB-трассировку `Bluetooth MIDI Connect.app`, чтобы увидеть реальные вызовы CoreBluetooth и ошибки при нажатии Connect.
3. Сравнить macOS failure с Windows success из `5.pcapng`/`6.pcapng`, особенно момент, где Windows инициирует SMP pairing + LL encryption.
4. Исследовать KORG firmware updater, если он доступен: возможно, он покажет версию прошивки.
5. Если software tracing не хватит — использовать дополнительный BLE-сниффинг на macOS:
   - Apple PacketLogger, если установить Additional Tools for Xcode;
   - nRF52840 BLE sniffer + Wireshark.
6. Дальняя цель — свой мост CoreBluetooth -> CoreMIDI, который создаёт virtual MIDI input. Но сначала надо победить BLE authentication/encryption.

## Что нужно от человека сейчас

На данном этапе полезно:

1. Вернуться к macOS и выяснить, как заставить CoreBluetooth инициировать pairing/encryption для nanoKEY.
2. Проверить, какая версия прошивки у nanoKEY Studio, если KORG updater это показывает.
3. Не делать случайные записи в vendor characteristic без осознанного решения: там может быть служебный/firmware/update протокол.

## Документация состояния

Подробное техническое состояние для следующей LLM/сессии лежит в [`state.md`](./state.md). Его нужно обновлять после каждого значимого шага.

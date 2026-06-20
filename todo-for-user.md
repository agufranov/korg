# Что нужно сделать сейчас

Нужно переснять BLE-дамп на Windows через nRF Sniffer так, чтобы он поймал не только рекламу устройства, но и трафик **после подключения**.

Первый дамп поймал `CONNECT_IND`, но не поймал data-channel пакеты. Поэтому нам не хватило главного: pairing/encryption/GATT/MIDI traffic.

## Короткая инструкция

1. Выключи `nanoKEY Studio`.

2. Открой Wireshark.

3. Выбери интерфейс:

   ```text
   nRF Sniffer for Bluetooth LE
   ```

4. Запусти capture.

5. Включи `nanoKEY Studio`.

6. Дождись, пока в nRF Sniffer device list появится:

   ```text
   nanoKEY Studio
   ```

7. **Обязательно кликни/выбери `nanoKEY Studio` в nRF Sniffer device list / toolbar.**

   Это ключевой шаг. Нужно, чтобы sniffer начал follow connection.

8. Только после этого подключи клавиатуру на Windows обычным рабочим способом.

9. Проверь в Wireshark, что после `CONNECT_IND` появились не только `ADV_IND` / `SCAN_RSP`, а пакеты типа:

   ```text
   LL_ENC_REQ
   LL_ENC_RSP
   LL_START_ENC_REQ
   LL_START_ENC_RSP
   SMP Pairing Request/Response
   ATT
   GATT
   Write Request
   Write Command
   Handle Value Notification
   ```

   Если после подключения всё ещё идут только рекламные пакеты — дамп опять неполный, нужно перезапустить capture и ещё раз выбрать `nanoKEY Studio` в списке nRF Sniffer.

10. Когда Windows покажет, что клавиатура подключена, нажми несколько клавиш/пэдов и покрути ручку.

11. Сохрани файл как:

    ```text
    wireshark-followed-connection.pcapng
    ```

12. Передай этот `.pcapng` сюда.

## Что важно увидеть в новом дампе

Нам нужны пакеты после подключения:

- pairing/security;
- encryption start;
- ATT/GATT read/write;
- подписка на notify/CCCD `2902`;
- BLE-MIDI notifications;
- возможные записи в KORG vendor characteristic `8667556C...`.

Без этих data-channel пакетов мы видим только факт попытки подключения, но не видим, почему Windows работает и что именно она делает иначе.

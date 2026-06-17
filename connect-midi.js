const noble = require('@abandonware/noble');

const BLE_MIDI_SERVICE_UUID = '03b80e5aede84b33a7516ce34ec4c700';
const BLE_MIDI_CHARACTERISTIC_UUID = '7772e5db38684112a1a9f2669d106bf3';
const DEVICE_NAME = (process.env.DEVICE_NAME || 'nanokey').toLowerCase();
const READ_POLL_MS = Number.parseInt(process.env.READ_POLL_MS || '0', 10);

let connectedPeripheral = null;
let readPollTimer = null;

function formatName(peripheral) {
  return (
    peripheral.advertisement.localName ||
    peripheral.advertisement.shortenedLocalName ||
    peripheral.name ||
    '<no name>'
  );
}

function hex(buffer) {
  return [...buffer].map((byte) => byte.toString(16).padStart(2, '0')).join(' ');
}

function printMidiPacket(data, source) {
  if (!data || data.length === 0) return;

  const timestamp = new Date().toISOString();
  console.log(`[${timestamp}] ${source}: ${hex(data)}`);

  const messages = parseBleMidiPacket(data);
  for (const message of messages) {
    console.log(`  ${message}`);
  }
}

function isMidiStatus(byte) {
  return byte >= 0x80 && byte <= 0xff;
}

function dataLengthForStatus(status) {
  const type = status & 0xf0;

  if (type === 0xc0 || type === 0xd0) return 1;
  if (type >= 0x80 && type <= 0xe0) return 2;

  switch (status) {
    case 0xf1:
    case 0xf3:
      return 1;
    case 0xf2:
      return 2;
    default:
      return 0;
  }
}

function noteName(noteNumber) {
  const names = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
  const octave = Math.floor(noteNumber / 12) - 1;
  return `${names[noteNumber % 12]}${octave}`;
}

function describeMidiMessage(status, dataBytes) {
  const channel = (status & 0x0f) + 1;
  const type = status & 0xf0;

  if (type === 0x80) {
    return `Note Off    ch=${channel} note=${dataBytes[0]}(${noteName(dataBytes[0])}) velocity=${dataBytes[1]}`;
  }

  if (type === 0x90) {
    const eventName = dataBytes[1] === 0 ? 'Note Off' : 'Note On ';
    return `${eventName}    ch=${channel} note=${dataBytes[0]}(${noteName(dataBytes[0])}) velocity=${dataBytes[1]}`;
  }

  if (type === 0xa0) {
    return `PolyTouch   ch=${channel} note=${dataBytes[0]}(${noteName(dataBytes[0])}) pressure=${dataBytes[1]}`;
  }

  if (type === 0xb0) {
    return `Control     ch=${channel} cc=${dataBytes[0]} value=${dataBytes[1]}`;
  }

  if (type === 0xc0) {
    return `Program     ch=${channel} program=${dataBytes[0]}`;
  }

  if (type === 0xd0) {
    return `Aftertouch  ch=${channel} pressure=${dataBytes[0]}`;
  }

  if (type === 0xe0) {
    const value14bit = dataBytes[0] + (dataBytes[1] << 7);
    return `Pitch Bend  ch=${channel} value=${value14bit} signed=${value14bit - 8192}`;
  }

  return `System/status 0x${status.toString(16)} data=[${dataBytes.map((byte) => `0x${byte.toString(16)}`).join(', ')}]`;
}

function parseBleMidiPacket(packet) {
  const messages = [];
  let index = 1; // byte 0 is BLE-MIDI timestamp header
  let runningStatus = null;

  while (index < packet.length) {
    // BLE-MIDI usually places a timestamp byte before every MIDI message.
    // If the next byte also looks like a MIDI status, treat the current byte as timestamp.
    if ((packet[index] & 0x80) && index + 1 < packet.length && isMidiStatus(packet[index + 1])) {
      index += 1;
    }

    let status = packet[index];
    if (isMidiStatus(status)) {
      runningStatus = status;
      index += 1;
    } else if (runningStatus !== null) {
      status = runningStatus;
    } else {
      messages.push(`Unparsed data byte without running status: 0x${status.toString(16)}`);
      index += 1;
      continue;
    }

    const dataLength = dataLengthForStatus(status);
    const dataBytes = [];

    while (dataBytes.length < dataLength && index < packet.length) {
      const byte = packet[index];

      if ((byte & 0x80) && index + 1 < packet.length && !isMidiStatus(packet[index + 1])) {
        index += 1; // timestamp before running-status data
        continue;
      }

      if (isMidiStatus(byte)) break;

      dataBytes.push(byte);
      index += 1;
    }

    if (dataBytes.length === dataLength) {
      messages.push(describeMidiMessage(status, dataBytes));
    } else {
      messages.push(`Incomplete MIDI message: status=0x${status.toString(16)} data=${hex(Buffer.from(dataBytes))}`);
    }
  }

  return messages;
}

async function connectToPeripheral(peripheral) {
  connectedPeripheral = peripheral;
  const name = formatName(peripheral);

  console.log(`Found ${name}`);
  console.log(`id: ${peripheral.id}`);
  console.log(`rssi: ${peripheral.rssi}`);
  console.log('Connecting...');

  await noble.stopScanningAsync();
  await peripheral.connectAsync();

  console.log('Connected. Discovering BLE-MIDI service...');

  peripheral.once('disconnect', () => {
    console.log('\nDisconnected.');
    process.exit(0);
  });

  const { services, characteristics } = await peripheral.discoverSomeServicesAndCharacteristicsAsync(
    [BLE_MIDI_SERVICE_UUID],
    [],
  );

  console.log('Discovered services:');
  for (const service of services) {
    console.log(`  service ${service.uuid}`);
  }

  console.log('Discovered characteristics:');
  for (const characteristic of characteristics) {
    console.log(`  characteristic ${characteristic.uuid} properties=${characteristic.properties.join(',')}`);
  }

  const midiCharacteristic = characteristics.find(
    (characteristic) => characteristic.uuid === BLE_MIDI_CHARACTERISTIC_UUID,
  );
  if (!midiCharacteristic) {
    throw new Error('BLE-MIDI characteristic was not found on this device.');
  }

  console.log(`Using characteristic ${midiCharacteristic.uuid}`);
  console.log(`Properties: ${midiCharacteristic.properties.join(',')}`);

  midiCharacteristic.on('data', (data) => printMidiPacket(data, 'data'));
  midiCharacteristic.on('read', (data, isNotification) => {
    printMidiPacket(data, isNotification ? 'notification' : 'read');
  });
  midiCharacteristic.on('notify', (state) => {
    console.log(`Notify state changed: ${state}`);
  });

  await midiCharacteristic.subscribeAsync();
  console.log('Subscribed. Now press keys / pads / knobs on nanoKEY Studio. Ctrl+C to stop.\n');

  if (READ_POLL_MS > 0) {
    console.log(`Polling read every ${READ_POLL_MS}ms because READ_POLL_MS is set.`);
    readPollTimer = setInterval(async () => {
      try {
        const data = await midiCharacteristic.readAsync();
        if (data.length > 0) printMidiPacket(data, 'poll-read');
      } catch (error) {
        console.error('Read polling failed:', error.message);
      }
    }, READ_POLL_MS);
  }
}

async function startScanning() {
  console.log('Scanning for BLE-MIDI nanoKEY Studio...');
  console.log(`Device name filter: ${DEVICE_NAME}`);
  console.log(`BLE-MIDI service: ${BLE_MIDI_SERVICE_UUID}`);

  noble.on('discover', async (peripheral) => {
    const name = formatName(peripheral);
    const lowerName = name.toLowerCase();
    const serviceUuids = peripheral.advertisement.serviceUuids || [];
    const hasMidiService = serviceUuids.includes(BLE_MIDI_SERVICE_UUID);
    const matchesName = lowerName.includes(DEVICE_NAME);

    if (!hasMidiService && !matchesName) return;

    noble.removeAllListeners('discover');

    try {
      await connectToPeripheral(peripheral);
    } catch (error) {
      console.error('Failed to connect/read MIDI:', error);
      process.exit(1);
    }
  });

  await noble.startScanningAsync([BLE_MIDI_SERVICE_UUID], true);
}

noble.on('stateChange', async (state) => {
  console.log(`Bluetooth adapter state: ${state}`);

  if (state !== 'poweredOn') {
    if (state === 'unauthorized') {
      console.error('Bluetooth access is unauthorized. Allow Bluetooth for your terminal app in macOS Privacy & Security settings.');
    } else {
      console.error(`Bluetooth is not ready: ${state}`);
    }
    return;
  }

  try {
    await startScanning();
  } catch (error) {
    console.error('Failed to start scan:', error);
    process.exit(1);
  }
});

process.on('SIGINT', async () => {
  try {
    if (readPollTimer) clearInterval(readPollTimer);
    await noble.stopScanningAsync();
    if (connectedPeripheral?.state === 'connected') {
      await connectedPeripheral.disconnectAsync();
    }
  } finally {
    console.log('\nStopped.');
    process.exit(0);
  }
});

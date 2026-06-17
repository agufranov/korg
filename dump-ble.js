const noble = require('@abandonware/noble');

const DEVICE_NAME = (process.env.DEVICE_NAME || 'nanokey').toLowerCase();
const SCAN_SERVICE_UUID = process.env.SCAN_SERVICE_UUID || '';
const READ_POLL_MS = Number.parseInt(process.env.READ_POLL_MS || '0', 10);
const READ_DESCRIPTORS = process.env.READ_DESCRIPTORS === '1';

let connectedPeripheral = null;
let pollTimer = null;
let pollCharacteristics = [];

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

function ascii(buffer) {
  return [...buffer]
    .map((byte) => (byte >= 0x20 && byte <= 0x7e ? String.fromCharCode(byte) : '.'))
    .join('');
}

function printData(source, data) {
  if (!data || data.length === 0) return;

  const timestamp = new Date().toISOString();
  console.log(`[${timestamp}] ${source}`);
  console.log(`  len:   ${data.length}`);
  console.log(`  hex:   ${hex(data)}`);
  console.log(`  ascii: ${ascii(data)}`);
}

function propertiesOf(characteristic) {
  return characteristic.properties || [];
}

function canRead(characteristic) {
  return propertiesOf(characteristic).includes('read');
}

function canNotify(characteristic) {
  const properties = propertiesOf(characteristic);
  return properties.includes('notify') || properties.includes('indicate');
}

async function discoverAndDump(peripheral) {
  connectedPeripheral = peripheral;
  const name = formatName(peripheral);

  console.log(`Found ${name}`);
  console.log(`id: ${peripheral.id}`);
  console.log(`rssi: ${peripheral.rssi}`);
  console.log(`advertised services: ${(peripheral.advertisement.serviceUuids || []).join(', ') || '-'}`);
  console.log(`manufacturer data: ${peripheral.advertisement.manufacturerData ? hex(peripheral.advertisement.manufacturerData) : '-'}`);
  console.log('Connecting...');

  await noble.stopScanningAsync();
  await peripheral.connectAsync();

  peripheral.once('disconnect', () => {
    console.log('\nDisconnected.');
    process.exit(0);
  });

  console.log('Connected. Discovering all services and characteristics...');
  const { services, characteristics } = await peripheral.discoverAllServicesAndCharacteristicsAsync();

  console.log(`\nServices (${services.length}):`);
  for (const service of services) {
    console.log(`  ${service.uuid}${service.name ? ` (${service.name})` : ''}`);
  }

  console.log(`\nCharacteristics (${characteristics.length}):`);
  for (const characteristic of characteristics) {
    const props = propertiesOf(characteristic).join(',') || '-';
    console.log(`  service=${characteristic._serviceUuid} characteristic=${characteristic.uuid} properties=${props}`);

    try {
      const descriptors = await characteristic.discoverDescriptorsAsync();
      for (const descriptor of descriptors) {
        console.log(`    descriptor=${descriptor.uuid}${descriptor.name ? ` (${descriptor.name})` : ''}`);

        if (READ_DESCRIPTORS) {
          try {
            const descriptorData = await descriptor.readValueAsync();
            printData(`descriptor ${characteristic.uuid}/${descriptor.uuid}`, descriptorData);
          } catch (error) {
            console.log(`      descriptor read failed: ${error.message}`);
          }
        }
      }
    } catch (error) {
      console.log(`    descriptor discovery failed: ${error.message}`);
    }
  }

  console.log('\nReading readable characteristics once...');
  for (const characteristic of characteristics.filter(canRead)) {
    try {
      const data = await characteristic.readAsync();
      printData(`read ${characteristic._serviceUuid}/${characteristic.uuid}`, data);
    } catch (error) {
      console.log(`  read failed ${characteristic._serviceUuid}/${characteristic.uuid}: ${error.message}`);
    }
  }

  console.log('\nSubscribing to notify/indicate characteristics...');
  for (const characteristic of characteristics.filter(canNotify)) {
    const source = `${characteristic._serviceUuid}/${characteristic.uuid}`;

    characteristic.on('data', (data) => printData(`data ${source}`, data));
    characteristic.on('read', (data, isNotification) => {
      printData(`${isNotification ? 'notification' : 'read-event'} ${source}`, data);
    });
    characteristic.on('notify', (state) => {
      console.log(`  notify state ${source}: ${state}`);
    });

    try {
      await characteristic.subscribeAsync();
      console.log(`  subscribed ${source}`);
    } catch (error) {
      console.log(`  subscribe failed ${source}: ${error.message}`);
    }
  }

  pollCharacteristics = characteristics.filter(canRead);
  if (READ_POLL_MS > 0 && pollCharacteristics.length > 0) {
    console.log(`\nPolling ${pollCharacteristics.length} readable characteristics every ${READ_POLL_MS}ms...`);
    pollTimer = setInterval(async () => {
      for (const characteristic of pollCharacteristics) {
        try {
          const data = await characteristic.readAsync();
          printData(`poll ${characteristic._serviceUuid}/${characteristic.uuid}`, data);
        } catch {
          // Keep polling other characteristics. Some devices reject reads while busy.
        }
      }
    }, READ_POLL_MS);
  }

  console.log('\nDump is running. Press keys / pads / knobs. Ctrl+C to stop.');
}

async function startScanning() {
  const serviceFilter = SCAN_SERVICE_UUID ? [SCAN_SERVICE_UUID] : [];

  console.log('Scanning for BLE device...');
  console.log(`Device name filter: ${DEVICE_NAME || '<none>'}`);
  console.log(`Service filter: ${serviceFilter.join(', ') || '<none>'}`);
  console.log(`Read descriptors: ${READ_DESCRIPTORS}`);

  noble.on('discover', async (peripheral) => {
    const name = formatName(peripheral);
    const matchesName = !DEVICE_NAME || name.toLowerCase().includes(DEVICE_NAME);
    const serviceUuids = peripheral.advertisement.serviceUuids || [];
    const matchesService = !SCAN_SERVICE_UUID || serviceUuids.includes(SCAN_SERVICE_UUID);

    if (!matchesName || !matchesService) return;

    noble.removeAllListeners('discover');

    try {
      await discoverAndDump(peripheral);
    } catch (error) {
      console.error('BLE dump failed:', error);
      process.exit(1);
    }
  });

  await noble.startScanningAsync(serviceFilter, true);
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
    console.error('Failed to start BLE dump:', error);
    process.exit(1);
  }
});

process.on('SIGINT', async () => {
  try {
    if (pollTimer) clearInterval(pollTimer);
    await noble.stopScanningAsync();
    if (connectedPeripheral?.state === 'connected') {
      await connectedPeripheral.disconnectAsync();
    }
  } finally {
    console.log('\nStopped.');
    process.exit(0);
  }
});

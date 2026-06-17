const noble = require('@abandonware/noble');

const SCAN_SECONDS = Number.parseInt(process.env.SCAN_SECONDS || '30', 10);
const NAME_FILTER = (process.env.NAME_FILTER || '').toLowerCase();

const seen = new Map();
const startedAt = Date.now();

function formatList(value) {
  if (!value || value.length === 0) return '-';
  return value.join(', ');
}

function formatName(peripheral) {
  return (
    peripheral.advertisement.localName ||
    peripheral.advertisement.shortenedLocalName ||
    peripheral.name ||
    '<no name>'
  );
}

function isInteresting(peripheral) {
  const name = formatName(peripheral).toLowerCase();
  const manufacturer = peripheral.advertisement.manufacturerData?.toString('hex') || '';
  return (
    name.includes('korg') ||
    name.includes('nanokey') ||
    manufacturer.includes('0947') ||
    manufacturer.includes('4709')
  );
}

function printPeripheral(peripheral) {
  const name = formatName(peripheral);
  const lowerName = name.toLowerCase();

  if (NAME_FILTER && !lowerName.includes(NAME_FILTER)) return;

  const previous = seen.get(peripheral.id);
  const payload = {
    id: peripheral.id,
    address: peripheral.address,
    addressType: peripheral.addressType,
    connectable: peripheral.connectable,
    rssi: peripheral.rssi,
    name,
    serviceUuids: peripheral.advertisement.serviceUuids || [],
    serviceDataUuids: (peripheral.advertisement.serviceData || []).map((item) => item.uuid),
    manufacturerData: peripheral.advertisement.manufacturerData?.toString('hex') || null,
  };

  if (previous && JSON.stringify(previous) === JSON.stringify(payload)) return;
  seen.set(peripheral.id, payload);

  const marker = isInteresting(peripheral) ? ' <<< possible KORG/nanoKEY' : '';
  const elapsed = ((Date.now() - startedAt) / 1000).toFixed(1).padStart(5, ' ');

  console.log(`\n[${elapsed}s] ${name}${marker}`);
  console.log(`  id:              ${payload.id}`);
  console.log(`  address:         ${payload.address || '-'}`);
  console.log(`  address type:    ${payload.addressType || '-'}`);
  console.log(`  connectable:     ${payload.connectable}`);
  console.log(`  rssi:            ${payload.rssi}`);
  console.log(`  service UUIDs:   ${formatList(payload.serviceUuids)}`);
  console.log(`  service data:    ${formatList(payload.serviceDataUuids)}`);
  console.log(`  manufacturer:    ${payload.manufacturerData || '-'}`);
}

async function startScanning() {
  console.log('Starting BLE scan...');
  console.log(`Scan duration: ${SCAN_SECONDS}s`);
  console.log('Tip: switch nanoKEY Studio to pairing/Bluetooth mode and keep it close to the Mac.');
  if (NAME_FILTER) console.log(`Name filter: ${NAME_FILTER}`);

  noble.on('discover', printPeripheral);

  await noble.startScanningAsync([], true);

  setTimeout(async () => {
    await noble.stopScanningAsync();
    console.log(`\nDone. Unique devices seen: ${seen.size}`);
    if (seen.size === 0) {
      console.log('No BLE advertisements were visible to Node/CoreBluetooth. Check macOS Bluetooth permissions for Terminal/iTerm/your shell.');
    }
    process.exit(0);
  }, SCAN_SECONDS * 1000);
}

noble.on('stateChange', async (state) => {
  console.log(`Bluetooth adapter state: ${state}`);

  if (state === 'poweredOn') {
    try {
      await startScanning();
    } catch (error) {
      console.error('Failed to start scan:', error);
      process.exit(1);
    }
    return;
  }

  if (state === 'unsupported') {
    console.error('BLE is unsupported by this adapter or unavailable to Node.');
  } else if (state === 'unauthorized') {
    console.error('Bluetooth access is unauthorized. Allow Bluetooth for your terminal app in macOS Privacy & Security settings.');
  } else {
    console.error(`Bluetooth is not ready yet: ${state}`);
  }
});

process.on('SIGINT', async () => {
  try {
    await noble.stopScanningAsync();
  } finally {
    console.log(`\nStopped. Unique devices seen: ${seen.size}`);
    process.exit(0);
  }
});

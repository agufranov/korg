#import <CoreBluetooth/CoreBluetooth.h>
#import <Foundation/Foundation.h>

static NSFileHandle *logFile = nil;

static void Log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"%@", msg);
    if (logFile) {
        [logFile writeData:[[msg stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    }
}

static NSString *Hex(NSData *data) {
    const unsigned char *bytes = data.bytes;
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:data.length];
    for (NSUInteger i = 0; i < data.length; i++) {
        [parts addObject:[NSString stringWithFormat:@"%02x", bytes[i]]];
    }
    return [parts componentsJoinedByString:@" "];
}

static NSString *Ascii(NSData *data) {
    const unsigned char *bytes = data.bytes;
    NSMutableString *result = [NSMutableString stringWithCapacity:data.length];
    for (NSUInteger i = 0; i < data.length; i++) {
        unsigned char byte = bytes[i];
        [result appendFormat:@"%c", byte >= 0x20 && byte <= 0x7e ? byte : '.'];
    }
    return result;
}

static void PrintData(NSString *source, NSData *data) {
    if (!data || data.length == 0) return;
    Log(@"DATA %@ len=%lu hex=%@ ascii=%@", source, (unsigned long)data.length, Hex(data), Ascii(data));
}

static NSString *ShortProps(CBCharacteristicProperties p) {
    NSMutableArray *a = [NSMutableArray array];
    if (p & CBCharacteristicPropertyRead) [a addObject:@"R"];
    if (p & CBCharacteristicPropertyWrite) [a addObject:@"W"];
    if (p & CBCharacteristicPropertyWriteWithoutResponse) [a addObject:@"WNR"];
    if (p & CBCharacteristicPropertyNotify) [a addObject:@"N"];
    if (p & CBCharacteristicPropertyIndicate) [a addObject:@"I"];
    if (p & CBCharacteristicPropertyNotifyEncryptionRequired) [a addObject:@"Nenc"];
    if (p & CBCharacteristicPropertyIndicateEncryptionRequired) [a addObject:@"Ienc"];
    return [a componentsJoinedByString:@","];
}

@interface BleDumper : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate>
@property(nonatomic, strong) CBCentralManager *central;
@property(nonatomic, strong) CBPeripheral *peripheral;
@property(nonatomic, strong) NSMutableDictionary<NSString *, CBCharacteristic *> *allChars;
@property(nonatomic, assign) BOOL didConnect;
@property(nonatomic, assign) BOOL didDiscover;
@property(nonatomic, assign) int pairAttempts;
@end

@implementation BleDumper

- (instancetype)init {
    self = [super init];
    _allChars = [NSMutableDictionary dictionary];
    _central = [[CBCentralManager alloc] initWithDelegate:self queue:dispatch_get_main_queue()];
    return self;
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    Log(@"STATE: %ld", (long)central.state);
    if (central.state != CBManagerStatePoweredOn) return;
    Log(@"SCANNING for 'nanokey'...");
    [central scanForPeripheralsWithServices:nil options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @YES}];
}

- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral advertisementData:(NSDictionary<NSString *,id> *)adData RSSI:(NSNumber *)rssi {
    NSString *name = adData[CBAdvertisementDataLocalNameKey] ?: peripheral.name ?: @"";
    if ([name.lowercaseString rangeOfString:@"nanokey"].location == NSNotFound) return;

    Log(@"FOUND: %@ (id=%@ rssi=%@)", name, peripheral.identifier.UUIDString, rssi);
    self.peripheral = peripheral;
    peripheral.delegate = self;
    [central stopScan];

    Log(@"CONNECTING...");
    [central connectPeripheral:peripheral options:@{
        CBConnectPeripheralOptionNotifyOnConnectionKey: @YES,
        CBConnectPeripheralOptionNotifyOnDisconnectionKey: @YES,
        CBConnectPeripheralOptionNotifyOnNotificationKey: @YES,
    }];
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    Log(@"CONNECTED. Starting discovery in 1s...");
    self.didConnect = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [peripheral discoverServices:nil];
    });
}

- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    Log(@"CONNECT FAIL: %@", error);
    exit(1);
}

- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    Log(@"DISCONNECTED: %@ (code=%ld)", error.localizedDescription ?: @"no error", (long)error.code);
    if (error && (error.code == CBErrorConnectionTimeout || error.code == CBErrorPeripheralDisconnected)) {
        Log(@"Device requires pairing to stay connected. Check Bluetooth system dialog.");
    }
    exit(0);
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if (error) { Log(@"SERVICE ERR: %@", error); exit(1); }
    Log(@"SERVICES: %lu found", (unsigned long)peripheral.services.count);
    for (CBService *s in peripheral.services) {
        Log(@"  svc: %@", s.UUID.UUIDString);
        [peripheral discoverCharacteristics:nil forService:s];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    if (error) { Log(@"CHAR ERR for %@: %@", service.UUID.UUIDString, error); return; }
    Log(@"CHARS for %@: %lu found", service.UUID.UUIDString, (unsigned long)service.characteristics.count);
    for (CBCharacteristic *c in service.characteristics) {
        NSString *key = [NSString stringWithFormat:@"%@/%@", service.UUID.UUIDString, c.UUID.UUIDString];
        self.allChars[key] = c;
        Log(@"  char: %@ [%@]", c.UUID.UUIDString, ShortProps(c.properties));

        if (c.properties & CBCharacteristicPropertyRead) {
            Log(@"  -> reading %@ (may trigger pairing dialog!)", key);
            [peripheral readValueForCharacteristic:c];
        }
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self enableNotifications];
    });
}

- (void)enableNotifications {
    Log(@"Enabling notifications on appropriate characteristics...");
    for (NSString *key in self.allChars) {
        CBCharacteristic *c = self.allChars[key];
        if ((c.properties & CBCharacteristicPropertyNotify) || (c.properties & CBCharacteristicPropertyIndicate)) {
            Log(@"  -> enabling notify on %@...", key);
            [self.peripheral setNotifyValue:YES forCharacteristic:c];
        }
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    NSString *key = [NSString stringWithFormat:@"%@/%@", characteristic.service.UUID.UUIDString, characteristic.UUID.UUIDString];

    if (error) {
        Log(@"READ ERR %@: %@ (domain=%@ code=%ld)", key, error.localizedDescription, error.domain, (long)error.code);
        if (error.code == CBATTErrorInsufficientAuthentication || error.code == CBATTErrorInsufficientEncryption) {
            Log(@"  -> Pairing REQUIRED! macOS should show pairing dialog.");
            Log(@"  -> Check: System Settings > Bluetooth");
            Log(@"  -> If dialog didn't appear, try: Audio MIDI Setup > MIDI Studio > Bluetooth Configuration");
            self.pairAttempts++;
            if (self.pairAttempts < 5) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    Log(@"  -> RETRYING read %@ (pairing should be in progress)...", key);
                    [peripheral readValueForCharacteristic:characteristic];
                });
            }
        }
        return;
    }

    Log(@"READ OK %@", key);
    PrintData(key, characteristic.value);
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    NSString *key = [NSString stringWithFormat:@"%@/%@", characteristic.service.UUID.UUIDString, characteristic.UUID.UUIDString];
    if (error) {
        Log(@"NOTIFY ERR %@: %@ (domain=%@ code=%ld)", key, error.localizedDescription, error.domain, (long)error.code);
        if (error.code == CBATTErrorInsufficientAuthentication || error.code == CBATTErrorInsufficientEncryption) {
            Log(@"  -> Pairing REQUIRED for notifications!");
        }
        return;
    }
    Log(@"NOTIFY %@: %s", key, characteristic.isNotifying ? "ON" : "OFF");
    if (characteristic.isNotifying) {
        Log(@"  -> READY! Press keys/pads/knobs now. Data will appear here.");
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverDescriptorsForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    for (CBDescriptor *d in characteristic.descriptors ?: @[]) {
        Log(@"  desc: %@", d.UUID.UUIDString);
    }
}

@end

int main(void) {
    @autoreleasepool {
        NSString *logPath = @"/tmp/korg-dump.log";
        [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
        logFile = [NSFileHandle fileHandleForWritingAtPath:logPath];
        [logFile truncateFileAtOffset:0];
        setvbuf(stdout, NULL, _IOLBF, 0);

        Log(@"=== KORG BLE DUMP v3 (with pairing support) ===");
        Log(@"Log: %@", logPath);
        printf("=== KORG BLE DUMP v3 ===\n");
        printf("Log: %s\n", [logPath UTF8String]);
        printf("Make sure nanoKEY Studio is ON and in Bluetooth range.\n");
        printf("If pairing dialog appears - ACCEPT IT.\n");
        printf("Ctrl+C to stop.\n\n");

        BleDumper *d = [BleDumper new];
        (void)d;
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
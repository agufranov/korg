#import <CoreBluetooth/CoreBluetooth.h>
#import <Foundation/Foundation.h>

static NSString *DeviceNameFilter(void) {
    NSString *value = [[[NSProcessInfo processInfo] environment] objectForKey:@"DEVICE_NAME"];
    if (value.length == 0) return @"nanokey";
    return [value lowercaseString];
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
    if (data.length == 0) return;

    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ";
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];

    printf("[%s] %s\n", [[formatter stringFromDate:[NSDate date]] UTF8String], [source UTF8String]);
    printf("  len:   %lu\n", (unsigned long)data.length);
    printf("  hex:   %s\n", [Hex(data) UTF8String]);
    printf("  ascii: %s\n", [Ascii(data) UTF8String]);
}

static NSString *DescribeProperties(CBCharacteristicProperties properties) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if (properties & CBCharacteristicPropertyBroadcast) [names addObject:@"broadcast"];
    if (properties & CBCharacteristicPropertyRead) [names addObject:@"read"];
    if (properties & CBCharacteristicPropertyWriteWithoutResponse) [names addObject:@"writeWithoutResponse"];
    if (properties & CBCharacteristicPropertyWrite) [names addObject:@"write"];
    if (properties & CBCharacteristicPropertyNotify) [names addObject:@"notify"];
    if (properties & CBCharacteristicPropertyIndicate) [names addObject:@"indicate"];
    if (properties & CBCharacteristicPropertyAuthenticatedSignedWrites) [names addObject:@"authenticatedSignedWrites"];
    if (properties & CBCharacteristicPropertyExtendedProperties) [names addObject:@"extendedProperties"];
    if (properties & CBCharacteristicPropertyNotifyEncryptionRequired) [names addObject:@"notifyEncryptionRequired"];
    if (properties & CBCharacteristicPropertyIndicateEncryptionRequired) [names addObject:@"indicateEncryptionRequired"];
    return names.count == 0 ? @"-" : [names componentsJoinedByString:@","];
}

@interface BleDumper : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate>
@property(nonatomic, strong) CBCentralManager *central;
@property(nonatomic, strong) CBPeripheral *peripheral;
@property(nonatomic, copy) NSString *nameFilter;
@end

@implementation BleDumper

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    _nameFilter = DeviceNameFilter();
    _central = [[CBCentralManager alloc] initWithDelegate:self queue:dispatch_get_main_queue()];
    return self;
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    printf("Bluetooth state: %ld\n", (long)central.state);

    if (central.state != CBManagerStatePoweredOn) {
        printf("Bluetooth is not powered on/ready yet.\n");
        return;
    }

    printf("Scanning for device name containing: %s\n", [self.nameFilter UTF8String]);
    [central scanForPeripheralsWithServices:nil options:@{ CBCentralManagerScanOptionAllowDuplicatesKey: @YES }];
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *, id> *)advertisementData
                  RSSI:(NSNumber *)RSSI {
    NSString *localName = advertisementData[CBAdvertisementDataLocalNameKey];
    NSString *name = localName.length > 0 ? localName : (peripheral.name.length > 0 ? peripheral.name : @"<no name>");

    if ([[name lowercaseString] rangeOfString:self.nameFilter].location == NSNotFound) return;

    printf("Found %s\n", [name UTF8String]);
    printf("identifier: %s\n", [peripheral.identifier.UUIDString UTF8String]);
    printf("rssi: %s\n", [[RSSI stringValue] UTF8String]);

    NSArray<CBUUID *> *serviceUuids = advertisementData[CBAdvertisementDataServiceUUIDsKey];
    if (serviceUuids.count > 0) {
        NSMutableArray<NSString *> *values = [NSMutableArray array];
        for (CBUUID *uuid in serviceUuids) [values addObject:uuid.UUIDString];
        printf("advertised services: %s\n", [[values componentsJoinedByString:@", "] UTF8String]);
    }

    NSData *manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey];
    if (manufacturerData.length > 0) PrintData(@"manufacturer data", manufacturerData);

    self.peripheral = peripheral;
    peripheral.delegate = self;
    [central stopScan];
    // Try connection with notification options
    NSDictionary *connectOptions = @{
        CBConnectPeripheralOptionNotifyOnConnectionKey: @YES,
        CBConnectPeripheralOptionNotifyOnDisconnectionKey: @YES,
        CBConnectPeripheralOptionNotifyOnNotificationKey: @YES,
    };
    printf("Connecting with options...\n");
    [central connectPeripheral:peripheral options:connectOptions];
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    printf("Connected. Waiting 500ms before service discovery...\n");
    // Some BLE devices need a short delay after connection before GATT operations
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        printf("Discovering services...\n");
        [peripheral discoverServices:nil];
    });
}

- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    printf("Failed to connect: %s\n", [error.localizedDescription UTF8String]);
    exit(1);
}

- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    printf("Disconnected.\n");
    if (error) {
        printf("  domain: %s\n", [error.domain UTF8String]);
        printf("  code: %ld\n", (long)error.code);
        printf("  description: %s\n", [error.localizedDescription UTF8String]);
        if (error.userInfo) {
            printf("  userInfo: %s\n", [[error.userInfo description] UTF8String]);
        }
    } else {
        printf("  no error\n");
    }
    exit(0);
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if (error) {
        printf("Service discovery failed: %s\n", [error.localizedDescription UTF8String]);
        exit(1);
    }

    printf("Services (%lu):\n", (unsigned long)peripheral.services.count);
    for (CBService *service in peripheral.services) {
        printf("  %s\n", [service.UUID.UUIDString UTF8String]);
        [peripheral discoverCharacteristics:nil forService:service];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    if (error) {
        printf("Characteristic discovery failed for %s: %s\n", [service.UUID.UUIDString UTF8String], [error.localizedDescription UTF8String]);
        return;
    }

    printf("Characteristics for service %s (%lu):\n", [service.UUID.UUIDString UTF8String], (unsigned long)service.characteristics.count);
    for (CBCharacteristic *characteristic in service.characteristics) {
        printf("  %s properties=%s\n", [characteristic.UUID.UUIDString UTF8String], [DescribeProperties(characteristic.properties) UTF8String]);
        [peripheral discoverDescriptorsForCharacteristic:characteristic];

        if (characteristic.properties & CBCharacteristicPropertyRead) {
            [peripheral readValueForCharacteristic:characteristic];
        }

        if ((characteristic.properties & CBCharacteristicPropertyNotify) || (characteristic.properties & CBCharacteristicPropertyIndicate)) {
            printf("  enabling notify for %s/%s\n", [service.UUID.UUIDString UTF8String], [characteristic.UUID.UUIDString UTF8String]);
            [peripheral setNotifyValue:YES forCharacteristic:characteristic];
        }
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverDescriptorsForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (error) {
        printf("Descriptor discovery failed for %s: %s\n", [characteristic.UUID.UUIDString UTF8String], [error.localizedDescription UTF8String]);
        return;
    }

    for (CBDescriptor *descriptor in characteristic.descriptors) {
        printf("    descriptor %s for characteristic %s\n", [descriptor.UUID.UUIDString UTF8String], [characteristic.UUID.UUIDString UTF8String]);
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (error) {
        printf("Value update failed for %s: %s\n", [characteristic.UUID.UUIDString UTF8String], [error.localizedDescription UTF8String]);
        return;
    }

    NSString *source = [NSString stringWithFormat:@"value %@/%@", characteristic.service.UUID.UUIDString, characteristic.UUID.UUIDString];
    PrintData(source, characteristic.value);
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (error) {
        printf("Notify failed %s/%s: %s\n", [characteristic.service.UUID.UUIDString UTF8String], [characteristic.UUID.UUIDString UTF8String], [error.localizedDescription UTF8String]);
        return;
    }

    printf("Notify state %s/%s: %s\n", [characteristic.service.UUID.UUIDString UTF8String], [characteristic.UUID.UUIDString UTF8String], characteristic.isNotifying ? "true" : "false");
}

@end

static BleDumper *globalDumper;

int main(void) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        globalDumper = [BleDumper new];
        printf("CoreBluetooth Objective-C BLE dump started. Ctrl+C to stop.\n");
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}

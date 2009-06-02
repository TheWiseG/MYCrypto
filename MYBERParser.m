//
//  MYBERParser.m
//  MYCrypto
//
//  Created by Jens Alfke on 6/2/09.
//  Copyright 2009 Jens Alfke. All rights reserved.
//

#import "MYBERParser.h"
#import "MYASN1Object.h"
#import "MYOID.h"
#import "MYErrorUtils.h"
#import "CollectionUtils.h"
#import "Test.h"


#define MYBERParserException @"MYBERParserException"



typedef struct {
    const uint8_t *nextChar;
    size_t length;
} InputData;


static void requireLength (size_t length, size_t expectedLength) {
    if (length != expectedLength)
        [NSException raise: MYBERParserException format: @"Unexpected value length"];
}


static const void* readOrDie (InputData *input, size_t len) {
    if (len > input->length)
        [NSException raise: MYBERParserException format: @"Unexpected EOF on input"];
    const void *bytes = input->nextChar;
    input->nextChar += len;
    input->length -= len;
    return bytes;
}


static NSData* readDataOrDie(InputData *input, size_t length) {
    return [NSMutableData dataWithBytes: readOrDie(input,length) length: length];
}


static NSString* readStringOrDie(InputData *input, size_t length, NSStringEncoding encoding) {
    NSString *str = [[NSString alloc] initWithBytes: readOrDie(input,length) 
                                             length: length
                                           encoding: encoding];
    if (!str)
        [NSException raise: MYBERParserException format: @"Unparseable string"];
    return [str autorelease];
}    


static uint32_t readBigEndianUnsignedInteger (InputData *input, size_t length) {
    if (length == 0 || length > 4)
        [NSException raise: MYBERParserException format: @"Invalid integer length"];
    uint32_t result = 0;
    memcpy(((uint8_t*)&result)+(4-length), readOrDie(input, length), length);
    return result;
}

static int32_t readBigEndianSignedInteger (InputData *input, size_t length) {
    int32_t result = (int32_t) readBigEndianUnsignedInteger(input,length);
    uint8_t *dst = ((uint8_t*)&result)+(4-length);
    if (*dst & 0x80) { // sign-extend negative value
        while (--dst >= (uint8_t*)&result)
            *dst = 0xFF;
    }
    return result;
}


NSDateFormatter* MYBERGeneralizedTimeFormatter() {
    static NSDateFormatter *sFmt;
    if (!sFmt) {
        sFmt = [[NSDateFormatter alloc] init];
        sFmt.dateFormat = @"yyyyMMddHHmmss'Z'";
        sFmt.timeZone = [NSTimeZone timeZoneWithName: @"GMT"];
    }
    return sFmt;
}

NSDateFormatter* MYBERUTCTimeFormatter() {
    static NSDateFormatter *sFmt;
    if (!sFmt) {
        sFmt = [[NSDateFormatter alloc] init];
        sFmt.dateFormat = @"yyMMddHHmmss'Z'";
        sFmt.timeZone = [NSTimeZone timeZoneWithName: @"GMT"];
    }
    return sFmt;
}

static NSDate* parseDate (NSString *dateStr, unsigned tag) {
    NSDateFormatter *fmt = (tag==23 ?MYBERUTCTimeFormatter() :MYBERGeneralizedTimeFormatter());
    NSDate *date = [fmt dateFromString: dateStr];
    if (!date)
        [NSException raise: MYBERParserException format: @"Unparseable date '%@'", dateStr];
    return date;
}


static id parseBER(InputData *input) {
    struct {
        unsigned tag            :5;
        unsigned isConstructed  :1;
        unsigned tagClass       :2;
        unsigned length         :7;
        unsigned isLengthLong   :1;
    } header;
    memcpy(&header, readOrDie(input,2), 2);
    
    if (header.tag == 0x1F)
        [NSException raise: MYBERParserException format: @"Long tags not supported"];
    
    // Parse the length:
    size_t length;
    if (!header.isLengthLong)
        length = header.length;
    else if (header.length == 0)
        [NSException raise: MYBERParserException format: @"Indefinite length not supported"];
    else
        length = NSSwapBigIntToHost(readBigEndianUnsignedInteger(input,header.length));
    
    Class defaultClass = [MYASN1Object class];
    
    // Tag values can be found in <Security/x509defs.h>. I'm not using them here because that
    // header does not exist on iPhone!
    
    if (header.isConstructed) {
        // Constructed:
        NSMutableArray *items = $marray();
        InputData subInput = {input->nextChar, length};
        while (subInput.length > 0) {
            [items addObject: parseBER(&subInput)];
        }
        input->nextChar += length;
        input->length -= length;

        switch (header.tag) {
            case 16: // sequence
                return items;
            case 17: // set
                return [NSSet setWithArray: items];
            default:
                return [[[MYASN1Object alloc] initWithTag: header.tag
                                                  ofClass: header.tagClass
                                               components: items] autorelease];
        }
    } else {
        // Primitive:
        switch (header.tag) {
            case 1: { // boolean
                requireLength(length,1);
                return *(const uint8_t*)readOrDie(input, 1) ?$true :$false;
            }
            case 2: // integer
            case 10: // enum
            {
                if (length <= 4) {
                    int32_t value = NSSwapBigIntToHost(readBigEndianSignedInteger(input,length));
                    return [NSNumber numberWithInteger: value];
                } else {
                    // Big integer!
                    defaultClass = [MYASN1BigInteger class];
                    break;
                }
            }
            case 3: // bitstring
            {
                UInt8 unusedBits = *(const UInt8*) readOrDie(input, 1);
                if (unusedBits)
                    Log(@"Bit-string has %u unused bits", (unsigned)unusedBits);
                if (unusedBits > 7 || length < 1)
                    [NSException raise: MYBERParserException format: @"Bogus bit-string"];
                return [[[MYBitString alloc] initWithBits: readDataOrDie(input, length-1)
                                                    count: 8*(length-1) - unusedBits] autorelease];
            }
            case 4: // octetstring
                return readDataOrDie(input, length);
            case 5: // null
                requireLength(length,0);
                return [NSNull null];
            case 6: // OID
                return [[[MYOID alloc] initWithBEREncoding: readDataOrDie(input, length)] autorelease];
            case 12: // UTF8String
                return readStringOrDie(input,length,NSUTF8StringEncoding);
            case 18: // numeric string
            case 19: // printable string:
                return readStringOrDie(input,length,NSASCIIStringEncoding);
            case 23: // UTC time:
            case 24: // Generalized time:
                return parseDate(readStringOrDie(input,length,NSASCIIStringEncoding), header.tag);
            default:
                break;
        }
    }

    // Generic case -- create and return a MYASN1Object:
    NSData *value = readDataOrDie(input, length);
    id result = [[[defaultClass alloc] initWithTag: header.tag
                                           ofClass: header.tagClass 
                                       constructed: header.isConstructed
                                             value: value] autorelease];
    if( defaultClass == [MYASN1Object class])
        Warn(@"parseBER: Returning default %@", result);
    return result;
}


id MYBERParse (NSData *ber, NSError **outError) {
    @try{
        InputData input = {ber.bytes, ber.length};
        return parseBER(&input);
    }@catch (NSException *x) {
        if ($equal(x.name, MYBERParserException)) {
            *outError = MYError(1,MYASN1ErrorDomain, @"%@", x.reason);
        } else {
            @throw(x);
        }
    }
    return nil;
}




#pragma mark -
#pragma mark TEST CASES:


#define $data(BYTES...)    ({const uint8_t bytes[] = {BYTES}; [NSData dataWithBytes: bytes length: sizeof(bytes)];})

TestCase(ParseBER) {
    CAssertEqual(MYBERParse($data(0x05, 0x00), nil),
                 [NSNull null]);
    CAssertEqual(MYBERParse($data(0x01, 0x01, 0xFF), nil),
                 $true);
    CAssertEqual(MYBERParse($data(0x01, 0x01, 0x00), nil),
                 $false);
    
    // integers:
    CAssertEqual(MYBERParse($data(0x02, 0x01, 0x00), nil),
                 $object(0));
    CAssertEqual(MYBERParse($data(0x02, 0x01, 0x48), nil),
                 $object(72));
    CAssertEqual(MYBERParse($data(0x02, 0x01, 0x80), nil),
                 $object(-128));
    CAssertEqual(MYBERParse($data(0x02, 0x02, 0x00, 0x80), nil),
                 $object(128));
    CAssertEqual(MYBERParse($data(0x02, 0x02, 0x30,0x39), nil),
                 $object(12345));
    CAssertEqual(MYBERParse($data(0x02, 0x02, 0xCF, 0xC7), nil),
                 $object(-12345));
    CAssertEqual(MYBERParse($data(0x02, 0x04, 0x07, 0x5B, 0xCD, 0x15), nil),
                 $object(123456789));
    CAssertEqual(MYBERParse($data(0x02, 0x04, 0xF8, 0xA4, 0x32, 0xEB), nil),
                 $object(-123456789));
    CAssertEqual(MYBERParse($data(0x02, 0x04, 0xF8, 0xA4, 0x32, 0xEB), nil),
                 $object(-123456789));
    
    // octet strings:
    CAssertEqual(MYBERParse($data(0x04, 0x05, 'h', 'e', 'l', 'l', 'o'), nil),
                 [@"hello" dataUsingEncoding: NSASCIIStringEncoding]);
    CAssertEqual(MYBERParse($data(0x04, 0x00), nil),
                 [NSData data]);
    CAssertEqual(MYBERParse($data(0x0C, 0x05, 'h', 'e', 'l', 'l', 'o'), nil),
                 @"hello");
    
    // sequences:
    CAssertEqual(MYBERParse($data(0x30, 0x06,  0x02, 0x01, 0x48,  0x01, 0x01, 0xFF), nil),
                 $array($object(72), $true));
    CAssertEqual(MYBERParse($data(0x30, 0x10,  
                                  0x30, 0x06,  0x02, 0x01, 0x48,  0x01, 0x01, 0xFF,
                                  0x30, 0x06,  0x02, 0x01, 0x48,  0x01, 0x01, 0xFF), nil),
                 $array( $array($object(72), $true), $array($object(72), $true)));
}


TestCase(ParseCert) {
    NSData *cert = [NSData dataWithContentsOfFile: @"../../Tests/selfsigned.cer"];
    NSError *error = nil;
    id parsed = MYBERParse(cert,&error);
    CAssert(parsed);
    CAssertNil(error);
    NSString *dump = [MYASN1Object dump: parsed];
    CAssert(dump);

    cert = [NSData dataWithContentsOfFile: @"../../Tests/iphonedev.cer"];
    parsed = MYBERParse(cert,&error);
    CAssert(parsed);
    CAssertNil(error);
    dump = [MYASN1Object dump: parsed];
    CAssert(dump);
}
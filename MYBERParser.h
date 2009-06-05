//
//  MYBERParser.h
//  MYCrypto
//
//  Created by Jens Alfke on 6/2/09.
//  Copyright 2009 Jens Alfke. All rights reserved.
//

#import <Foundation/Foundation.h>


#define MYASN1ErrorDomain @"MYASN1ErrorDomain"


/** Parses a block of BER-formatted data into an object tree.
    This is mostly used internally by MYParsedCertificate. */
id MYBERParse (NSData *ber, NSError **outError);

size_t MYBERGetLength (NSData *ber, NSError **outError);
const void* MYBERGetContents (NSData *ber, NSError **outError);

NSDateFormatter* MYBERGeneralizedTimeFormatter();
NSDateFormatter* MYBERUTCTimeFormatter();

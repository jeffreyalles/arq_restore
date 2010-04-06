/*
 Copyright (c) 2009, Stefan Reitshamer http://www.haystacksoftware.com
 
 All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 
 * Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 
 * Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 
 * Neither the names of PhotoMinds LLC or Haystack Software, nor the names of 
 their contributors may be used to endorse or promote products derived from
 this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
 TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */ 

#import "Blob.h"
#import "RegexKitLite.h"
#import "NSError_S3.h"
#import "S3Lister.h"
#import "S3AuthorizationParameters.h"
#import "S3AuthorizationProvider.h"
#import "S3Service.h"
#import "PathReceiver.h"
#import "SetNSError.h"
#import "HTTPResponse.h"
#import "HTTPRequest.h"
#import "HTTP.h"
#import "S3ObjectReceiver.h"
#import "ServerBlob.h"
#import "NSErrorCodes.h"
#import "S3Request.h"

/*
 * WARNING:
 * This class *must* be reentrant!
 */

@interface S3Service (internal)
- (NSXMLDocument *)listBuckets:(NSError **)error;
@end

@implementation S3Service
+ (NSString *)errorDomain {
    return @"S3ServiceErrorDomain";
}
+ (NSString *)serverErrorDomain {
    return @"S3ServiceServerErrorDomain";
}
+ (NSString *)displayNameForBucketRegion:(int)region {
    switch (region) {
        case BUCKET_REGION_US_STANDARD:
            return @"US Standard";
        case BUCKET_REGION_US_WEST:
            return @"US West";
        case BUCKET_REGION_EU:
            return @"EU";
    }
    NSAssert(NO, @"invalid S3 bucket region");
    return nil;
}
- (id)initWithS3AuthorizationProvider:(S3AuthorizationProvider *)theSAP useSSL:(BOOL)isUseSSL retryOnNetworkError:(BOOL)retry {
	if (self = [super init]) {
		sap = [theSAP retain];
        useSSL = isUseSSL;
        retryOnNetworkError = retry;
    }
    return self;
}
- (void)dealloc {
	[sap release];
	[super dealloc];
}
- (NSArray *)s3BucketNames:(NSError **)error {
	NSXMLDocument *doc = [self listBuckets:error];
    if (!doc) {
        return nil;
    }
	NSXMLElement *rootElem = [doc rootElement];
	NSArray *nameNodes = [rootElem nodesForXPath:@"//ListAllMyBucketsResult/Buckets/Bucket/Name" error:error];
	if (!nameNodes) {
        return nil;
    }
	NSMutableArray *bucketNames = [[[NSMutableArray alloc] init] autorelease];
	for (NSXMLNode *nameNode in nameNodes) {
		[bucketNames addObject:[nameNode stringValue]];
	}
	return bucketNames;
}
- (BOOL)s3BucketExists:(NSString *)s3BucketName {
    NSError *error = nil;
    NSArray *s3BucketNames = [self s3BucketNames:&error];
    if (!s3BucketNames) {
        HSLogDebug(@"error getting S3 bucket names: %@", [error localizedDescription]);
        return NO;
    }
    return [s3BucketNames containsObject:s3BucketName];
}
- (NSArray *)pathsWithPrefix:(NSString *)prefix error:(NSError **)error {
    NSArray *array = nil;
    PathReceiver *rec = [[[PathReceiver alloc] init] autorelease];
    if (rec && [self listObjectsWithPrefix:prefix receiver:rec error:error]) {
        array = [rec paths];
    }
    return array;
}
- (NSArray *)objectsWithPrefix:(NSString *)prefix error:(NSError **)error {
    S3ObjectReceiver *receiver = [[[S3ObjectReceiver alloc] init] autorelease];
    if (![self listObjectsWithPrefix:prefix receiver:receiver error:error]) {
        return NO;
    }
    return [receiver objects];
}
- (BOOL)listObjectsWithPrefix:(NSString *)prefix receiver:(id <S3Receiver>)receiver error:(NSError **)error {
	return [self listObjectsWithMax:-1 prefix:prefix receiver:receiver error:error];
}
- (BOOL)listObjectsWithMax:(int)maxResults prefix:(NSString *)prefix receiver:(id <S3Receiver>)receiver error:(NSError **)error {
	S3Lister *lister = [[[S3Lister alloc] initWithS3AuthorizationProvider:sap useSSL:useSSL retryOnNetworkError:retryOnNetworkError max:maxResults prefix:prefix receiver:receiver] autorelease];
    return lister && [lister listObjects:error];
}
- (BOOL)containsBlobAtPath:(NSString *)path {
    NSError *error = nil;
    PathReceiver *rec = [[PathReceiver alloc] init];
    S3Lister *lister = [[S3Lister alloc] initWithS3AuthorizationProvider:sap useSSL:useSSL retryOnNetworkError:retryOnNetworkError max:-1 prefix:path receiver:rec];
    BOOL ret = [lister listObjects:&error];
    if (!ret) {
        HSLogError(@"listObjects(%@): %@", path, [error localizedDescription]);
    } else {
        ret = [[rec paths] containsObject:path];
        HSLogDebug(@"S3 path %@ %@", path, (ret ? @"exists" : @"does not exist"));
    }
    [lister release];
    [rec release];
    return ret;
}
- (NSData *)dataAtPath:(NSString *)path error:(NSError **)error {
    ServerBlob *sb = [self newServerBlobAtPath:path error:error];
    if (sb == nil) {
        return nil;
    }
    NSData *data = [sb slurp:error];
    [sb release];
    return data;
}
- (ServerBlob *)newServerBlobAtPath:(NSString *)path error:(NSError **)error {
    HSLogDebug(@"getting %@", path);
    S3Request *s3r = [[S3Request alloc] initWithMethod:@"GET" path:path queryString:nil authorizationProvider:sap useSSL:useSSL retryOnNetworkError:retryOnNetworkError];
    ServerBlob *sb = [s3r newServerBlob:error];
    [s3r release];
    return sb;
}
- (NSArray *)commonPrefixesForPathPrefix:(NSString *)prefix delimiter:(NSString *)delimiter error:(NSError **)error {
	if (![prefix hasPrefix:@"/"]) {
        HSLogError(@"invalid prefix %@", prefix);
        SETNSERROR([S3Service errorDomain], -1, @"path must begin with /");
        return nil;
	}
	NSRange searchRange = NSMakeRange(1, [prefix length] - 1);
	NSRange nextSlashRange = [prefix rangeOfString:@"/" options:0 range:searchRange];
	if (nextSlashRange.location == NSNotFound) {
        SETNSERROR([S3Service errorDomain], -1, @"path must be of the format /<bucket name>/path");
        return nil;
	}
	NSString *s3BucketName = [prefix substringWithRange:NSMakeRange(1, nextSlashRange.location - 1)];
	NSString *subPath = [prefix substringFromIndex:nextSlashRange.location + 1];
    NSString *urlPath = [NSString stringWithFormat:@"/%@/", s3BucketName];
    NSString *queryString = [NSString stringWithFormat:@"?prefix=%@&delimiter=%@", 
                             [subPath stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding],
                             delimiter];

    S3Request *s3r = [[S3Request alloc] initWithMethod:@"GET" path:urlPath queryString:queryString authorizationProvider:sap useSSL:useSSL retryOnNetworkError:retryOnNetworkError];
    ServerBlob *sb = [s3r newServerBlob:error];
    [s3r release];
    if (sb == nil) {
        return nil;
    }
    NSData *output = [sb slurp:error];
    [sb release];
    if (output == nil) {
        return nil;
    }
    NSXMLDocument *xmlDoc = [[[NSXMLDocument alloc] initWithData:output options:0 error:error] autorelease];
    if (xmlDoc == nil) {
        SETNSERROR([S3Service errorDomain], -1, @"failed to parse XML");
        return nil;
    }
    NSXMLElement *rootElement = [xmlDoc rootElement];
    NSArray *objects = [rootElement nodesForXPath:@"//ListBucketResult/CommonPrefixes/Prefix" error:error];
    if (objects == nil) {
        return nil;
    }
    NSMutableArray *commonPrefixes = [NSMutableArray array];
    if ([objects count] > 0) {
        NSUInteger subPathLen = [subPath length];
        for (NSXMLNode *objectNode in objects) {
            NSString *prefix = [objectNode stringValue];
            NSUInteger prefixLen = [prefix length];
            NSRange range = NSMakeRange(subPathLen, prefixLen - subPathLen - 1);
            NSString *prefixSubstring = [prefix substringWithRange:range];
            [commonPrefixes addObject:prefixSubstring];
        }
    }
    return commonPrefixes;
}
@end

@implementation S3Service (internal)
- (NSXMLDocument *)listBuckets:(NSError **)error {
    S3Request *s3r = [[S3Request alloc] initWithMethod:@"GET" path:@"/" queryString:nil authorizationProvider:sap useSSL:useSSL retryOnNetworkError:retryOnNetworkError];
    ServerBlob *sb = [s3r newServerBlob:error];
    [s3r release];
    if (sb == nil) {
        return nil;
    }
    NSData *data = [sb slurp:error];
    [sb release];
    if (data == nil) {
        return nil;
    }
    return [[[NSXMLDocument alloc] initWithData:data options:0 error:error] autorelease];
}
@end
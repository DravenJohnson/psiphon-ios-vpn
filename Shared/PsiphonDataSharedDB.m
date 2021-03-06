/*
 * Copyright (c) 2017, Psiphon Inc.
 * All rights reserved.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

#import "PsiphonDataSharedDB.h"
#import "Logging.h"
#import "NSDateFormatter+RFC3339.h"
#import "NoticeLogger.h"

// File operations parameters
#define MAX_RETRIES 3
#define RETRY_SLEEP_TIME 0.1f  // Sleep for 100 milliseconds.

/* Shared NSUserDefaults keys */
#define EGRESS_REGIONS_KEY @"egress_regions"
#define TUN_CONNECTED_KEY @"tun_connected"
#define APP_FOREGROUND_KEY @"app_foreground"
#define SERVER_TIMESTAMP_KEY @"server_timestamp"
#define SPONSOR_ID_KEY @"sponsor_id"


@implementation Homepage
@end

@implementation PsiphonDataSharedDB {
    NSUserDefaults *sharedDefaults;

    NSString *appGroupIdentifier;

    // RFC3339 Date Formatter
    NSDateFormatter *rfc3339Formatter;
}

/*!
 * @brief Don't share an instance across threads.
 * @param identifier
 * @return
 */
- (id)initForAppGroupIdentifier:(NSString*)identifier {
    self = [super init];
    if (self) {
        appGroupIdentifier = identifier;
        sharedDefaults = [[NSUserDefaults alloc] initWithSuiteName:identifier];
        rfc3339Formatter = [NSDateFormatter createRFC3339MilliFormatter];
    }
    return self;
}

#pragma mark - File operations

#ifndef TARGET_IS_EXTENSION

+ (NSString *)tryReadingFile:(NSString *)filePath {
    NSFileHandle *fileHandle;
    // NSFileHandle will close automatically when deallocated.
    return [PsiphonDataSharedDB tryReadingFile:filePath
                               usingFileHandle:&fileHandle
                                readFromOffset:0
                                  readToOffset:nil];
}

/*!
 * If fileHandlePtr points to nil, then a new NSFileHandle for
 * reading filePath is created and fileHandlePtr is set to point to the new object.
 * If fileHandlePtr points to a NSFileHandle, it will be used for reading.
 * Reading operation is retried MAX_RETRIES more times if it fails for any reason,
 * while putting the thread to sleep for an amount of time defined by RETRY_SLEEP_TIME.
 * No errors are thrown if opening the file/reading operations fail.
 * @param filePath Path used to create a NSFileHandle if fileHandlePtr points to nil.
 * @param fileHandlePtr Pointer to existing NSFileHandle or nil.
 * @param bytesOffset The byte offset to seek to before reading.
 * @param readToOffset Populated with the file offset that was read to.
 * @return UTF8 string of read file content.
 */
+ (NSString *)tryReadingFile:(NSString *_Nonnull)filePath
             usingFileHandle:(NSFileHandle *__strong *_Nonnull)fileHandlePtr
              readFromOffset:(unsigned long long)bytesOffset
                readToOffset:(unsigned long long *)readToOffset {

    NSData *fileData;
    NSError *err;

    for (int i = 0; i < MAX_RETRIES; ++i) {

        if (!(*fileHandlePtr)) {
            // NOTE: NSFileHandle created with fileHandleForReadingFromURL
            //       the handle owns its associated file descriptor, and will
            //       close it automatically when deallocated.
            (*fileHandlePtr) = [NSFileHandle fileHandleForReadingFromURL:[NSURL fileURLWithPath:filePath]
                                                                error:&err];
            if (err) {
                LOG_WARN(@"Error opening file handle for %@: Error: %@", filePath, err);
                // On failure explicitly setting fileHandlePtr to point to nil.
                (*fileHandlePtr) = nil;
            }
        }

        if ((*fileHandlePtr)) {
            @try {
                // From https://developer.apple.com/documentation/foundation/nsfilehandle/1413916-readdataoflength?language=objc
                // readDataToEndOfFile raises NSFileHandleOperationException if attempts
                // to determine file-handle type fail or if attempts to read from the file
                // or channel fail.
                [(*fileHandlePtr) seekToFileOffset:bytesOffset];
                fileData = [(*fileHandlePtr) readDataToEndOfFile];

                if (fileData) {
                    if (readToOffset) {
                        (*readToOffset) = [(*fileHandlePtr) offsetInFile];
                    }
                    return [[NSString alloc] initWithData:fileData encoding:NSUTF8StringEncoding];
                } else {
                    (*readToOffset) = (unsigned long long) 0;
                }
            }
            @catch (NSException *e) {
                LOG_ERROR(@"Error reading file: %@", [e debugDescription]);

            }
        }

        // Put thread to sleep for 100 ms and try again.
        [NSThread sleepForTimeInterval:RETRY_SLEEP_TIME];
    }

    return nil;
}

// readLogsData tries to parse logLines, and for each JSON formatted line creates
// a DiagnosticEntry which is appended to entries.
// This method doesn't throw any errors on failure, and will log errors encountered.
- (void)readLogsData:(NSString *)logLines intoArray:(NSMutableArray<DiagnosticEntry *> *)entries {
    NSError *err;

    if (logLines) {
        for (NSString *logLine in [logLines componentsSeparatedByString:@"\n"]) {

            if (!logLine || [logLine length] == 0) {
                continue;
            }

            NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:[logLine dataUsingEncoding:NSUTF8StringEncoding]
                                                                 options:0 error:&err];
            if (err) {
                LOG_ERROR(@"Failed to parse log line (%@). Error: %@", logLine, err);
            }

            if (dict) {
                // data key of dict dictionary, could either contains a dictionary, or another simple object.
                // In case the value is a dictionary, cannot rely on description method of dictionary, since it adds new-line characters
                // and semicolons to make it human-readable, but is unsuitable for our purposes.
                NSString *data = nil;
                if (![dict[@"data"] isKindOfClass:[NSDictionary class]]) {
                    data = [dict[@"data"] description];
                } else {
                    NSData *serializedDictionary = [NSJSONSerialization dataWithJSONObject:dict[@"data"] options:kNilOptions error:&err];
                    data = [[NSString alloc] initWithData:serializedDictionary encoding:NSUTF8StringEncoding];
                }
                
                NSString *msg = nil;
                if (err) {
                    LOG_ERROR(@"Failed to serialize dictionary as JSON (%@)", dict[@"noticeType"]);
                } else {
                    msg = [NSString stringWithFormat:@"%@: %@", dict[@"noticeType"], data];
                }

                NSDate *timestamp = [rfc3339Formatter dateFromString:dict[@"timestamp"]];

                if (!msg) {
                    LOG_ERROR(@"Failed to read notice message for log line (%@).", logLine);
                    // Puts place holder value for message.
                    msg = @"Failed to read notice message.";
                }

                if (!timestamp) {
                    LOG_ERROR(@"Failed to parse timestamp: (%@) for log line (%@)", dict[@"timestamp"], logLine);
                    // Puts placeholder value for timestamp.
                    timestamp = [NSDate dateWithTimeIntervalSince1970:0];
                }

                [entries addObject:[[DiagnosticEntry alloc] init:msg andTimestamp:timestamp]];
            }
        }
    }
}

#if DEBUG
- (NSString *)getFileSize:(NSString *)filePath {
    NSError *err;
    unsigned long long byteCount = [[[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:&err] fileSize];
    if (err) {
        return nil;
    }
    return [NSByteCountFormatter stringFromByteCount:byteCount countStyle:NSByteCountFormatterCountStyleBinary];
}
#endif

#endif

#pragma mark - Homepage methods

#ifndef TARGET_IS_EXTENSION
/*!
 * Reads shared homepages file.
 * @return NSArray of Homepages.
 */
- (NSArray<Homepage *> *)getHomepages {
    NSMutableArray<Homepage *> *homepages = nil;
    NSError *err;

    NSString *data = [PsiphonDataSharedDB tryReadingFile:[self homepageNoticesPath]];

    if (!data) {
        LOG_ERROR(@"Failed reading homepage notices file. Error:%@", err);
        return nil;
    }

    // Pre-allocation optimization
    homepages = [NSMutableArray arrayWithCapacity:50];
    NSArray *homepageNotices = [data componentsSeparatedByString:@"\n"];

    for (NSString *line in homepageNotices) {

        if (!line || [line length] == 0) {
            continue;
        }

        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding]
                                                             options:0 error:&err];

        if (err) {
            LOG_ERROR(@"Failed parsing homepage notices file. Error:%@", err);
        }

        if (dict) {
            Homepage *h = [[Homepage alloc] init];
            h.url = [NSURL URLWithString:dict[@"data"][@"url"]];
            h.timestamp = [rfc3339Formatter dateFromString:dict[@"timestamp"]];
            [homepages addObject:h];
        }
    }

    return homepages;
}
#endif

- (NSString *)homepageNoticesPath {
    return [[[[NSFileManager defaultManager]
      containerURLForSecurityApplicationGroupIdentifier:appGroupIdentifier] path]
      stringByAppendingPathComponent:@"homepage_notices"];
}

#pragma mark - Egress Regions Table methods

/*!
 * @brief Sets set of egress regions in shared NSUserDefaults
 * @param regions
 * @return TRUE if data was saved to disk successfully, otherwise FALSE.
 */
// TODO: is timestamp needed? Maybe we can use this to detect staleness later
- (BOOL)insertNewEgressRegions:(NSArray<NSString *> *)regions {
    [sharedDefaults setObject:regions forKey:EGRESS_REGIONS_KEY];
    return [sharedDefaults synchronize];
}

/*!
 * @return NSArray of region codes.
 */
- (NSArray<NSString *> *)getAllEgressRegions {
    return [sharedDefaults objectForKey:EGRESS_REGIONS_KEY];
}

#pragma mark - Logging

- (NSString *)rotatingLogNoticesPath {
    return [[[[NSFileManager defaultManager]
      containerURLForSecurityApplicationGroupIdentifier:appGroupIdentifier] path]
            stringByAppendingPathComponent:@"rotating_notices"];
}

- (NSString *)rotatingOlderLogNoticesPath {
    return [[self rotatingLogNoticesPath] stringByAppendingString:@".1"];
}

#ifndef TARGET_IS_EXTENSION

// Reads all log files and tries parses the json lines contained in each.
// This method is not meant to handle large files.
- (NSArray<DiagnosticEntry*>*)getAllLogs {

    LOG_DEBUG(@"Log filesize:%@", [self getFileSize:[self rotatingLogNoticesPath]]);
    LOG_DEBUG(@"Log backup filesize:%@", [self getFileSize:[self rotatingOlderLogNoticesPath]]);

    NSMutableArray<NSMutableArray<DiagnosticEntry *> *> *entriesArray = [[NSMutableArray alloc] initWithCapacity:3];

    // Reads both tunnel-core log files all at once (max of 2MB) into memory,
    // and defers any processing after the read in order to reduce
    // the chance of a log rotation happening midway.
    entriesArray[0] = [[NSMutableArray alloc] init];
    NSString *tunnelCoreOlderLogs = [PsiphonDataSharedDB tryReadingFile:[self rotatingOlderLogNoticesPath]];
    NSString *tunnelCoreLogs = [PsiphonDataSharedDB tryReadingFile:[self rotatingLogNoticesPath]];
    [self readLogsData:tunnelCoreOlderLogs intoArray:entriesArray[0]];
    [self readLogsData:tunnelCoreLogs intoArray:entriesArray[0]];

    entriesArray[1] = [[NSMutableArray alloc] init];
    NSString *containerOlderLogs = [PsiphonDataSharedDB tryReadingFile:[NoticeLogger containerRotatingOlderLogNoticesPath]];
    NSString *containerLogs = [PsiphonDataSharedDB tryReadingFile:[NoticeLogger containerRotatingLogNoticesPath]];
    [self readLogsData:containerOlderLogs intoArray:entriesArray[1]];
    [self readLogsData:containerLogs intoArray:entriesArray[1]];

    entriesArray[2] = [[NSMutableArray alloc] init];
    NSString *extensionOlderLogs = [PsiphonDataSharedDB tryReadingFile:[NoticeLogger extensionRotatingOlderLogNoticesPath]];
    NSString *extensionLogs = [PsiphonDataSharedDB tryReadingFile:[NoticeLogger extensionRotatingLogNoticesPath]];
    [self readLogsData:extensionOlderLogs intoArray:entriesArray[2]];
    [self readLogsData:extensionLogs intoArray:entriesArray[2]];


    // Sorts classes of logs in entriesArray based on the timestamp of the last log in each class.
    NSArray *sortedEntriesArray = [entriesArray sortedArrayUsingComparator:^NSComparisonResult(id obj1, id obj2) {
        NSDate *obj1LastTimestamp = [[(NSArray<DiagnosticEntry *> *) obj1 lastObject] timestamp];
        NSDate *obj2LastTimestamp = [[(NSArray<DiagnosticEntry *> *) obj2 lastObject] timestamp];
        return [obj2LastTimestamp compare:obj1LastTimestamp];
    }];

    // Calculates total number of logs and initializes an array of that size.
    NSUInteger totalNumLogs = 0;
    for (NSUInteger i = 0; i < [entriesArray count]; ++i) {
        totalNumLogs += [entriesArray[i] count];
    }

    NSMutableArray<DiagnosticEntry *> *allEntries = [[NSMutableArray alloc] initWithCapacity:totalNumLogs];

    for (NSUInteger j = 0; j < [sortedEntriesArray count]; ++j) {
        [allEntries addObjectsFromArray:sortedEntriesArray[j]];
    }

    return allEntries;
}

#endif

#pragma mark - Tunnel State table methods

/**
 * @brief Sets tunnel connection state in shared NSUserDefaults dictionary.
 *        NOTE: This method blocks until changes are written to disk.
 * @param connected Tunnel core connected status.
 * @return TRUE if change was persisted to disk successfully, FALSE otherwise.
 */
- (BOOL)updateTunnelConnectedState:(BOOL)connected {
    [sharedDefaults setBool:connected forKey:TUN_CONNECTED_KEY];
    return [sharedDefaults synchronize];
}

/**
 * @brief Returns previously persisted tunnel state from the shared NSUserDefaults.
 *        This state is invalid if the network extension is not running.
 *        NOTE: returns FALSE if no previous value was set using updateTunnelConnectedState:
 * @return TRUE if tunnel is connected, FALSE otherwise.
 */
- (BOOL)getTunnelConnectedState {
    // Returns FALSE if no previous value was associated with this key.
    return [sharedDefaults boolForKey:TUN_CONNECTED_KEY];
}

# pragma mark - App State table methods

/**
 * @brief Sets app foreground state in shared NSSUserDefaults dictionary.
 *        NOTE: this method blocks until changes are written to disk.
 * @param foreground Whether app is on the foreground or not.
 * @return TRUE if change was persisted to disk successfully, FALSE otherwise.
 */
- (BOOL)updateAppForegroundState:(BOOL)foreground {
    [sharedDefaults setBool:foreground forKey:APP_FOREGROUND_KEY];
    return [sharedDefaults synchronize];
}

/**
 * @brief Returns previously persisted app foreground state from the shared NSUserDefaults
 *        NOTE: returns FALSE if no previous value was set using updateAppForegroundState:
 * @return TRUE if app if on the foreground, FALSE otherwise.
 */
- (BOOL)getAppForegroundState {
    return [sharedDefaults boolForKey:APP_FOREGROUND_KEY];
}

#pragma mark - Server timestamp methods

/**
 * @brief Sets server timestamp in shared NSSUserDefaults dictionary.
 * @param timestamp from the handshake in RFC3339 format.
 * @return TRUE if change was persisted to disk successfully, FALSE otherwise.
 */
- (void)updateServerTimestamp:(NSString*) timestamp {
	[sharedDefaults setObject:timestamp forKey:SERVER_TIMESTAMP_KEY];
	[sharedDefaults synchronize];
}

/**
 * @brief Returns previously persisted server timestamp from the shared NSUserDefaults
 * @return NSString* timestamp in RFC3339 format.
 */
- (NSString*)getServerTimestamp {
	return [sharedDefaults stringForKey:SERVER_TIMESTAMP_KEY];
}

# pragma mark - Sponsor ID

- (void) updateSponsorId:(NSString*)sponsorId {
    if(sponsorId && [sponsorId length]) {
        [sharedDefaults setObject:sponsorId forKey:SPONSOR_ID_KEY];
    } else {
        [sharedDefaults removeObjectForKey:SPONSOR_ID_KEY];
    }
    [sharedDefaults synchronize];
}

- (NSString*)getSponsorId {
    return [sharedDefaults stringForKey:SPONSOR_ID_KEY];
}

@end

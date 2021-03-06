//
//  MFFilesystemController.m
//  MacFusion2
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// 
//      http://www.apache.org/licenses/LICENSE-2.0
// 
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#import "MFFilesystemController.h"
#import "MFPluginController.h"
#import "MFServerPlugin.h"
#import "MFServerFS.h"
#import "MFError.h"
#import "MFConstants.h"
#import "MFLogging.h"

#import <DiskArbitration/DiskArbitration.h>

#define FSDEF_EXTENSION @"macfusion"
#define RECENTS_PATH @"~/Library/Application Support/Macfusion/recents.plist"
#define CACHE_PATH @"~/Library/Application Support/Macfusion/cache.plist" 

@interface MFFilesystemController ()
- (void)setUpVolumeMonitoring;
- (void)loadRecentFilesystems;
- (void)recordRecentFilesystem:(MFServerFS *)fs;
- (void)addMountedPath:(NSString *)path;
- (void)removeMountedPath:(NSString *)path;
- (void)storeFilesystem:(MFServerFS *)fs;
- (void)removeFilesystem:(MFServerFS *)fs;
- (void)invalidateTokensForFS:(MFServerFS *)fs;

@property(readwrite, strong) NSMutableArray *filesystems;
@property(readwrite, strong) NSMutableArray *recents;
@end

@implementation MFFilesystemController

static MFFilesystemController* sharedController = nil;

#pragma mark Init and Singleton methods
+ (MFFilesystemController *)sharedController {
	if (sharedController == nil) {
		sharedController = [[self alloc] init];
	}
	
	return sharedController;
}

- (void)registerGeneralNotifications {
}

- (id) init {
	if (self = [super init]) {
		_filesystemsDictionary = [NSMutableDictionary dictionary];
		_filesystems = [NSMutableArray array];
		_mountedPaths = [NSMutableArray array];
		_recents = [NSMutableArray array];
		_tokens = [NSMutableDictionary dictionary];
		[self loadFilesystems];
		[self loadRecentFilesystems];
		[self setUpVolumeMonitoring];
	}
	
	return self;
}

+ (NSSet *)keyPathsForValuesAffectingFilesystems {
	return [NSSet setWithObjects:@"filesystemsDictionary", nil];
}

- (id)copyWithZone:(NSZone*)zone {
	return self;
}

#pragma mark Filesystem loading
- (NSArray *)pathsToFilesystemDefs {
	BOOL isDir = NO;
	NSFileManager *fm = [NSFileManager defaultManager];
	NSArray *libraryPaths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, 																NSAllDomainsMask - NSSystemDomainMask, YES);
	NSMutableArray *fsDefSearchPaths = [NSMutableArray array];
	NSMutableArray *fsDefPaths = [NSMutableArray array];
	
	for(NSString *path in libraryPaths) {
		NSString *specificPath = [path stringByAppendingPathComponent:@"Macfusion/Filesystems/"];
		if ([fm fileExistsAtPath:specificPath isDirectory:&isDir] && isDir) {
			[fsDefSearchPaths addObject:specificPath];
		}
	}
	
	for(NSString *path in fsDefSearchPaths) {
		for(NSString *fsDefPath in [fm contentsOfDirectoryAtPath:path error:NULL]) {
			if ([[fsDefPath pathExtension] isEqualToString:FSDEF_EXTENSION]) {
				[fsDefPaths addObject:[path stringByAppendingPathComponent: fsDefPath]];
			}
		}
	}
	
	return [fsDefPaths copy];
}

- (void)loadFilesystems {
	NSArray *filesystemPaths = [self pathsToFilesystemDefs];
	NSDictionary *cacheDict = [NSDictionary dictionaryWithContentsOfFile:[CACHE_PATH stringByExpandingTildeInPath]];
							   
	for(NSString *fsPath in filesystemPaths) {
		MFLogS(self, @"Loading fs at %@", fsPath);

		NSError *error;
		MFServerFS *fs = [MFServerFS loadFilesystemAtPath:fsPath error:&error];
		if (fs) {
			[self storeFilesystem: fs ];
			if ([[[NSFileManager defaultManager] contentsOfDirectoryAtPath:fs.mountPath error:NULL] count] > 0 && ([[cacheDict objectForKey: fs.uuid] isEqualToString: fs.mountPath])) {
				MFLogSO(self, fs, @"Detected Already Mounted fs %@", fs);
				[fs handleMountNotification];
			}
		} else {
			MFLogS(self, @"Failed to load FS. Error: %@", [error localizedDescription]);
		}
	}
}

#pragma mark Action methods
- (MFServerFS *)newFilesystemWithPlugin:(MFServerPlugin *)plugin {
	MFServerFS *fs = [MFServerFS newFilesystemWithPlugin:plugin];
	if (fs) {
		[self storeFilesystem:fs];
		return fs;
	} else {
		MFLogSO(self, plugin, @"Failed to create new filesystem with plugin %@", plugin);
		return nil;
	}
}

- (MFServerFS *)quickMountWithURL:(NSURL *)url error:(NSError **)error {
	MFServerPlugin *plugin = nil;
	for(MFServerPlugin *p in [[MFPluginController sharedController] plugins]) {
		if ([[[p delegate] urlSchemesHandled] containsObject:[url scheme]])
			plugin = p;
	}
	
	if (!plugin) {
		NSString* description = [NSString stringWithFormat:@"No plugin for URLs of type %@", [url scheme]];
		if (error) {
			*error = [MFError errorWithErrorCode:kMFErrorCodeNoPluginFound description:description];
		}
		
		return nil;
	}
	
	MFServerFS *fs = [MFServerFS filesystemFromURL:url plugin:plugin error:error];
	[self storeFilesystem: fs];
	[fs performSelector:@selector(mount) withObject:nil afterDelay:0];
	return fs;
}

- (void)deleteFilesystem:(MFServerFS *)fs {
	if (fs.filePath) {
		[[NSFileManager defaultManager] removeItemAtPath:fs.filePath error:NULL];
	}
	[self removeFilesystem: fs];
}

#pragma mark Recents Managment
- (void)writeRecentFilesystems {
	 NSString *recentsPath = [RECENTS_PATH stringByExpandingTildeInPath];
	 BOOL isDir;
	 
	 if (![[NSFileManager defaultManager] fileExistsAtPath:[recentsPath stringByDeletingLastPathComponent] isDirectory:&isDir] || !isDir) {
		 NSError *error = nil;
		 BOOL ok = [[NSFileManager defaultManager] createDirectoryAtPath:recentsPath withIntermediateDirectories:YES attributes:nil error:&error];
		 if (!ok) {
			 MFLogS(self, @"Failed to create directory for writing recents: %@", [error localizedDescription]);
		 }
	 }
	
	BOOL writeOK = [_recents writeToFile: recentsPath atomically:NO];
	if (!writeOK) {
		MFLogS(self, @"Could not write recents to file!");
	}
}

- (void)loadRecentFilesystems {
	NSString *filePath = [RECENTS_PATH stringByExpandingTildeInPath];
	NSArray *recentsRead =[NSArray arrayWithContentsOfFile:filePath];
	[[self mutableArrayValueForKey:@"recents"] removeAllObjects];
	
	if (!recentsRead) {
		MFLogS(self, @"Could not read recents from file at path %@", filePath);
	} else {
		[[self mutableArrayValueForKey:@"recents"] addObjectsFromArray: recentsRead];
	}
}

- (void)recordRecentFilesystem:(MFServerFS *)fs {
	NSMutableDictionary *params = [fs.parameters mutableCopy];
	// Strip the UUID so it never repeats
	[params setValue:nil forKey:kMFFSUUIDParameter];
	
	for(NSDictionary *recent in _recents) {
		BOOL equal = YES;
		for(NSString *key in [recent allKeys]) {
			equal = ([[recent objectForKey:key] isEqual:[params objectForKey:key]]);
			if (!equal) {
				break;
			}
		}
		
		if (equal) {
			// MFLogS(self, @"Duplicate recents detected, %@ and %@",params, recent);
			// We already have this exact dictionary in recents. Don't add it.
			return; 
		}
	}
	
	[[self mutableArrayValueForKey:@"recents"] addObject:params];
	if ([_recents count] > 10) {
		[_recents removeObjectAtIndex: 0];
	}
	[self writeRecentFilesystems];
}

#pragma mark Volume monitoring
static void diskMounted(DADiskRef disk, void *mySelf) {
	CFDictionaryRef description = DADiskCopyDescription(disk);
	CFURLRef pathURL = CFDictionaryGetValue(description, kDADiskDescriptionVolumePathKey);
	
	if (pathURL) {
		CFStringRef tempPath = CFURLCopyFileSystemPath(pathURL,kCFURLPOSIXPathStyle);
		NSString *path = [(__bridge NSString *)tempPath stringByStandardizingPath];
		CFRelease(tempPath);
		
		[[MFFilesystemController sharedController] addMountedPath:path];
	}
	
	CFRelease(description);
}


static void diskUnMounted(DADiskRef disk, void *mySelf) {
	CFDictionaryRef description = DADiskCopyDescription(disk);
	CFURLRef pathURL = CFDictionaryGetValue(description, kDADiskDescriptionVolumePathKey);
	
	if (pathURL) {
		CFStringRef tempPath = CFURLCopyFileSystemPath(pathURL,kCFURLPOSIXPathStyle);
		NSString *path = [(__bridge NSString*)tempPath stringByStandardizingPath];
		CFRelease(tempPath);
		
		[[MFFilesystemController sharedController] removeMountedPath:path];
	}
	
	CFRelease(description);
}

- (void)setUpVolumeMonitoring {
	_appearSession = DASessionCreate(kCFAllocatorDefault);
	_disappearSession = DASessionCreate(kCFAllocatorDefault);
	
	DASessionScheduleWithRunLoop(_appearSession, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
	DASessionScheduleWithRunLoop(_disappearSession, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
	
	DARegisterDiskAppearedCallback(_appearSession, kDADiskDescriptionMatchVolumeMountable, diskMounted, (__bridge void *)(self));
	DARegisterDiskDisappearedCallback(_disappearSession, kDADiskDescriptionMatchVolumeMountable, diskUnMounted, (__bridge void *)(self));
	
	// Make the evenets go through
	CFRunLoopRunInMode( kCFRunLoopDefaultMode, 1, YES );
}

- (void)updateStatusForFilesystem:(MFServerFS *)fs {
	if ([_mountedPaths containsObject: fs.mountPath]) {
		[fs handleMountNotification];
	}
}

# pragma mark Self-monitoring
- (void)registerObservationOnFilesystem:(MFServerFS *)fs {
	[fs addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:nil];
}

- (void)unregisterObservationOnFilesystem:(MFServerFS *)fs {
	[fs removeObserver:self forKeyPath:@"status"];
}

- (void) observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
//	NSLog(@"MFFilesystemController observes: keypath %@, object %@, change %@",keyPath, object, change);
	NSString *newStatus = [change objectForKey:NSKeyValueChangeNewKey];
	MFServerFS *fs = object;
	
	// Remove temporarily filesystems if they fail to mount
	if ([newStatus isEqualToString:kMFStatusFSFailed] && ![fs isPersistent]) {
		[self performSelector:@selector(removeFilesystem:) withObject:fs afterDelay:0];
	}
	if ([newStatus isEqualToString:kMFStatusFSFailed]) {
		[self invalidateTokensForFS: fs];
	}
}

# pragma mark Security Tokens
- (NSString *)tokenForFilesystem:(MFServerFS *)fs {
	CFUUIDRef uuidObject = CFUUIDCreate(NULL);
    CFStringRef uuidCFString = CFUUIDCreateString(NULL, uuidObject);
    CFRelease(uuidObject);
    NSString *tokenString = (__bridge_transfer NSString *)(uuidCFString);
	if ([[_tokens allValues] containsObject: fs]) {
		MFLogSO(self, fs, @"Uh oh ... adding a second token for an FS already in tokens");
		// MFLogSO(self, _tokens, @"Tokens Before %@", _tokens);
	}
	
	[_tokens setObject: fs forKey: tokenString];
	// MFLogS(self, @"Returning token %@ for fs %@", tokenString, fs);
	return tokenString;
}

- (void)invalidateToken:(NSString *)token {
	MFLogS(self, @"Invalidating token %@", token);
	NSAssert(token, @"Token is nil in invalidateToken");
	NSAssert([[_tokens allKeys] containsObject: token], @"Invalid token in invalidateToken");
	[_tokens removeObjectForKey: token];
}

- (void)invalidateTokensForFS:(MFServerFS *)fs {
	for(NSString *key in [_tokens allKeys]) {
		if ([_tokens objectForKey: key] == fs)
			[_tokens removeObjectForKey: key];
	}
}

- (MFServerFS *)filesystemForToken:(NSString *)token {
	NSAssert(token, @"Token nil in filesystemForToken");
	NSAssert([[_tokens allKeys] count], @"No tokens available, internal inconsistency, please restart your machine and try again");
	if (![[_tokens allKeys] containsObject:token]) {
		MFLogS(self, @"Invalid token in filesystemsForToken: %@, available tokens are: %@, available filesystems are: %@", token, [[_tokens allKeys] count], [_tokens allKeys], [_filesystemsDictionary allKeys]);
	}
	
	return [_tokens objectForKey: token];
}

# pragma mark Filesystem Persistence
- (void)updateFSPersistenceCache {
	NSArray *mountedFilesystems = [self.filesystems filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self.status == %@", kMFStatusFSMounted]];
	// MFLogS(self, @"Updating Cache. Mounted Filesystems %@", mountedFilesystems);
	NSDictionary *mountedDict = [NSDictionary dictionaryWithObjects:(NSArray*)[mountedFilesystems valueForKey:@"mountPath"]
															forKeys:(NSArray*)[mountedFilesystems valueForKey:@"uuid"]];
	// MFLogS(self, @"Mounted Cache Dictionary %@", mountedDict);
	NSString *cachePath = [@"~/Library/Application Support/Macfusion/cache.plist" stringByExpandingTildeInPath];
	[mountedDict writeToFile:cachePath atomically:YES];
}

# pragma mark Accessors and Getters
- (void)storeFilesystem:(MFServerFS *)fs {
	NSAssert(fs && fs.uuid, @"FS or uuid is nil, storeFilesystem in MFFilesystemController");
	[_filesystemsDictionary setObject: fs forKey: fs.uuid];
	if ([_filesystems indexOfObject:fs] == NSNotFound) {
		[[self mutableArrayValueForKey:@"filesystems"] addObject: fs];
		[self registerObservationOnFilesystem: fs];
	}
}

- (void)removeFilesystem:(MFServerFS *)fs {
	NSAssert(fs, @"Asked to remove nil fs in MFFilesystemController");
	NSAssert([fs isUnmounted] || [fs isFailedToMount], @"Asked to remove fs in mounted or waiting state");
	[fs removeMountPoint];
	[_filesystemsDictionary removeObjectForKey: fs.uuid];
	if ([_filesystems indexOfObject:fs] != NSNotFound) {
		[[self mutableArrayValueForKey:@"filesystems"] removeObject: fs];
	}
}

- (MFServerFS *)filesystemWithUUID:(NSString *)uuid {
	NSAssert(uuid, @"UUID nill in filesystemWithUUID");
	return [_filesystemsDictionary objectForKey:uuid];
}

- (NSDictionary *)filesystemsDictionary {
	return (NSDictionary *)_filesystemsDictionary;
}

- (void)addMountedPath:(NSString *)path {
//	MFLogS(self, @"Adding mounted path %@", path);
	NSAssert(path, @"Mounted Path nil in MFFilesystemControlled addMountedPath");
	if (![_mountedPaths containsObject: path]) {
		[_mountedPaths addObject:path];
		for(MFServerFS *fs in _filesystems) {
			if ([fs.mountPath isEqualToString: path] && ([fs isWaiting] )) {
				[fs handleMountNotification];
				[self invalidateTokensForFS: fs];
				[self updateFSPersistenceCache];
			}
			
			if (![fs isPersistent]) {
				[self recordRecentFilesystem: fs];
			}
		}
	}
}

- (void)removeMountedPath:(NSString *)path {
	NSAssert(path, @"Mounted Path nil in MFFilesystemControlled removeMountedPath");
	if ([_mountedPaths containsObject:path]) {
		[_mountedPaths removeObject:path];
		NSArray *matchingFilesystems = [_filesystems filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self.mountPath == %@", path]];
		[matchingFilesystems makeObjectsPerformSelector:@selector(handleUnmountNotification)];
		[self updateFSPersistenceCache];
		
		NSArray *matchingTemporaryFilesystems = [matchingFilesystems filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self.isPersistent != YES"]];
		for(MFServerFS *fs in matchingTemporaryFilesystems) {
			[self removeFilesystem:fs];
		}
	}
}

@synthesize filesystems=_filesystems, recents=_recents;
@end 
